//
//  FileOperationEngine.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 18
//
//  Copy and Move, done the way Midnight Commander does them, with Michael's rules on top.
//
//  WHY THIS EXISTS. Until build 55 a Move was one `moveItem` call inside the view: a
//  same-named item in the target made it throw, the error went to the console, nothing
//  moved and he was never told. It also ran on the main thread, so a 6 GB move to Cold
//  Storage over the network froze the window. Copy silently added "2" to names.
//
//  WHAT WAS TAKEN FROM MIDNIGHT COMMANDER (GPL v3+, read from its source 2026-09-18 —
//  src/filemanager/file.c and filegui.c). The IDEAS, rewritten in Swift, not its code:
//    • a move on the same drive is a rename — nothing is copied;
//    • across drives a move is copy → delete, and the source is deleted only after its
//      copy succeeded; source folders are removed only when EMPTY, so anything skipped
//      stays exactly where it was;
//    • "Replace if newer" / "Replace if size differs";
//    • never overwrite a real file with a zero-length one;
//    • refuse when source and target are the same file;
//    • every error asks: Retry · Skip · Skip all · Cancel.
//
//  WHAT IS MICHAEL'S (locked line by line, 2026-09-18):
//    • a same-named folder asks Merge · Replace · Skip · Cancel (MC merges without asking);
//    • a same-named file asks Replace · Skip · Keep Both (+ the two MC choices), "and be
//      explicit to the user";
//    • IDENTICAL files are asked about too — "i think you have to explicitly run this by
//      the user";
//    • a folder Replace gets a second confirm naming what it removes;
//    • Apply to all; many sources at once; source and target, never left and right.
//
//  ENGINEER'S CALLS (plan section 3, marked ENG):
//    • TWO PHASES. Every question is asked BEFORE anything is touched, so a long transfer
//      then runs unattended and a Cancel during the questions changes nothing.
//    • A MOVE VERIFIES EVERY BYTE before it deletes the source: SHA-256 while copying, then
//      the written file is read back with the cache bypassed and hashed again. The delete
//      cannot be undone, so the check has to be the strong one. A COPY checks the size.
//    • REPLACE NEVER ERASES OUTRIGHT: the item already there goes to the Trash. A network
//      drive has no Trash, so there it is deleted — and every popup says so beforehand.
//    • A LIBRARY IS ONE ITEM. .photoslibrary and other packages are never merged file by
//      file — mixing two libraries' files leaves one the app cannot open.
//    • Dates, permissions, Finder tags and extended attributes are kept; a symbolic link is
//      copied as a link, never followed.
//    • Everything is logged to disk so a whole Move can be undone later.
//

import Foundation
import CryptoKit
import Darwin

/// The UI side: asks Michael, shows progress. Implemented by FileOperationController.
@MainActor
protocol FileOpDelegate: AnyObject, Sendable {
    func askFolder(_ question: FolderQuestion) async -> Answer<FolderChoice>
    func confirmReplace(_ question: ReplaceConfirm) async -> Bool
    func askFile(_ question: FileQuestion) async -> Answer<FileChoice>
    func askError(_ question: ErrorQuestion) async -> ErrorChoice
    func report(_ progress: FileOpProgress)
}

nonisolated final class FileOperationEngine: @unchecked Sendable {

    // MARK: - Planned steps

    private enum Op {
        /// Same drive: one rename, nothing copied.
        case renameMove(src: URL, dst: URL)
        case makeFolder(src: URL, dst: URL)
        /// Apply the source folder's dates and attributes once its contents are in.
        case finishFolder(src: URL, dst: URL)
        case transfer(src: URL, dst: URL, move: Bool, replaceExisting: Bool, size: Int64)
        /// Put the item already in the target in the Trash (or delete it on a network drive).
        case dispose(URL)
        case removeDuplicate(src: URL, keptAt: URL)
        /// Finder's window-layout file (.DS_Store) in a merge — not his data.
        case discardSourceDSStore(URL)
        case removeSourceFolderIfEmpty(URL)
    }

    private struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - State

    let kind: FileOpKind
    let sources: [URL]
    let targetDir: URL
    let control: FileOpControl
    let delegate: any FileOpDelegate
    private let undoLog: OperationLog?

    private let fm = FileManager.default
    private var ops: [Op] = []
    private var progress = FileOpProgress()
    private var summary: FileOpSummary
    private var log: OperationLog
    private var logURL: URL?
    private var lastReport = Date.distantPast
    private var lastLogSave = Date()
    private var activeSeconds: Double = 0
    private var runningSince: Date?

    // "Apply to all" answers, one per kind of question.
    private var folderForAll: FolderChoice?
    private var replaceForAllConfirmed = false
    private var fileForAllDiffering: FileChoice?
    private var fileForAllIdentical: FileChoice?
    private var fileForAllUnit: FileChoice?
    private var skipAllErrors = false

    // Conflicts found by the pre-scan and not yet asked — what "Apply to all" would cover.
    private var pendingFolders = Set<String>()
    private var pendingDiffering = Set<String>()
    private var pendingIdentical = Set<String>()
    private var pendingUnit = Set<String>()
    private var sameness: [String: FileQuestion.Sameness] = [:]

    /// Target folders that could not be created — everything planned inside them is
    /// skipped instead of producing an error prompt per file.
    private var failedFolders: [String] = []

    init(kind: FileOpKind, sources: [URL], targetDir: URL, control: FileOpControl,
         delegate: any FileOpDelegate) {
        self.kind = kind
        self.sources = sources.map { $0.standardizedFileURL }
        self.targetDir = targetDir.standardizedFileURL
        self.targetDevice = Self.device(of: targetDir)
        self.control = control
        self.delegate = delegate
        self.undoLog = nil
        self.summary = FileOpSummary(kind: kind)
        self.log = OperationLog(kind: kind, sources: sources.map(\.path), target: targetDir.path)
    }

    /// Undo a logged Move: everything goes back where it came from.
    init(undoing log: OperationLog, control: FileOpControl, delegate: any FileOpDelegate) {
        self.kind = .move
        self.sources = []
        self.targetDir = URL(fileURLWithPath: log.target)
        self.targetDevice = Self.device(of: URL(fileURLWithPath: log.target))
        self.control = control
        self.delegate = delegate
        self.undoLog = log
        self.summary = FileOpSummary(kind: .move)
        self.log = log
    }

    // MARK: - Run

    /// ⛔ `@concurrent` IS LOAD-BEARING. Without it a nonisolated async function runs on
    /// its CALLER's actor under this project's settings — the main actor — and every byte
    /// of a 6 GB move would be read on the main thread: the exact window freeze this engine
    /// exists to end. Caught by the self-test on 2026-09-18 (progress never reached the
    /// test until the copy was over).
    @concurrent
    func run() async -> FileOpSummary {
        if undoLog != nil { return await runUndo() }

        do {
            let valid = validatedSources()
            progress.phase = .checking
            for src in valid {
                try await preScan(src: src, dst: targetDir.appendingPathComponent(src.lastPathComponent))
            }
            for src in valid {
                try await decide(src: src, dst: targetDir.appendingPathComponent(src.lastPathComponent))
            }
            try await execute()
        } catch is FileOpCancelled {
            summary.cancelled = true
            log.cancelled = true
        } catch {
            summary.failed.append(.init(path: targetDir.path, reason: error.localizedDescription))
        }

        progress.phase = .finishing
        await report(force: true)
        saveLog()
        summary.logURL = logURL
        summary.canUndo = kind == .move && log.entries.contains {
            switch $0 {
            case .moved, .trashed, .removedDuplicate: return true
            default: return false
            }
        }
        return summary
    }

    /// Refuse what cannot be done at all: a folder into itself, or an item onto itself.
    private func validatedSources() -> [URL] {
        sources.filter { src in
            let t = targetDir.path
            if t == src.path || t.hasPrefix(src.path + "/") {
                summary.failed.append(.init(path: src.path,
                    reason: "A folder cannot be \(kind.pastTense) into itself."))
                return false
            }
            if src.deletingLastPathComponent().standardizedFileURL.path == t {
                summary.failed.append(.init(path: src.path,
                    reason: "It is already in this folder — source and target are the same."))
                return false
            }
            return true
        }
    }

    // MARK: - Phase 1a: find every conflict (nothing is touched)

    private func preScan(src: URL, dst: URL) async throws {
        try checkCancelled()
        progress.itemsChecked += 1
        progress.currentName = src.lastPathComponent
        await report()

        guard exists(dst) else { return }
        let s = facts(src), t = facts(dst)

        if isPlainFolder(s) && isPlainFolder(t) {
            pendingFolders.insert(dst.path)
            for child in children(of: src) {
                try await preScan(src: child, dst: dst.appendingPathComponent(child.lastPathComponent))
            }
        } else if isUnit(s, t) {
            pendingUnit.insert(dst.path)
        } else if src.lastPathComponent != ".DS_Store" {
            let same = try await compare(s, t)
            sameness[dst.path] = same
            if same == .differs { pendingDiffering.insert(dst.path) } else { pendingIdentical.insert(dst.path) }
        }
    }

    /// Identical means identical: whenever two files are the same size, every byte is
    /// compared. His rule: "you have to do a forensic byte per byte comparison inside the
    /// media file if in doubt."
    ///
    /// ⚠️ The first version called same size + same date "identical" without reading them.
    /// The UI self-test caught two DIFFERENT 1-byte files, written in the same second,
    /// being presented as "these two files look identical". Honest wording, wrong question.
    private func compare(_ s: FileFacts, _ t: FileFacts) async throws -> FileQuestion.Sameness {
        if s.isSymlink && t.isSymlink {
            let a = try? fm.destinationOfSymbolicLink(atPath: s.url.path)
            let b = try? fm.destinationOfSymbolicLink(atPath: t.url.path)
            return (a != nil && a == b) ? .sameContents : .differs
        }
        guard s.size == t.size else { return .differs }
        return try await bytesEqual(s.url, t.url) ? .sameContents : .differs
    }

    // MARK: - Phase 1b: ask every question, build the list of steps

    private func decide(src: URL, dst: URL) async throws {
        try checkCancelled()
        let s = facts(src)
        let move = mayMove(src)

        guard exists(dst) else {
            try addNew(src: src, dst: dst, facts: s, move: move)
            return
        }
        if sameFile(src, dst) {
            summary.failed.append(.init(path: src.path, reason: "Source and target are the same item."))
            return
        }
        let t = facts(dst)

        // A folder meeting a folder: Merge · Replace · Skip · Cancel.
        if isPlainFolder(s) && isPlainFolder(t) {
            pendingFolders.remove(dst.path)
            var choice = folderForAll
            var applyToAll = false
            if choice == nil {
                let answer = await delegate.askFolder(FolderQuestion(
                    kind: kind, source: s, target: t, remainingLikeThis: pendingFolders.count))
                choice = answer.choice
                applyToAll = answer.applyToAll
                if applyToAll { folderForAll = answer.choice }
            }
            switch choice ?? .cancel {
            case .cancel:
                throw FileOpCancelled()
            case .skip:
                skip(src, "A folder with this name is already there — you chose Skip.")
                dropPending(under: dst)
            case .merge:
                for child in children(of: src) {
                    try await decide(src: child, dst: dst.appendingPathComponent(child.lastPathComponent))
                }
                if move { ops.append(.removeSourceFolderIfEmpty(src)) }
            case .replace:
                if await confirmReplace(dst, forAll: applyToAll) {
                    dropPending(under: dst)
                    ops.append(.dispose(dst))
                    try addNew(src: src, dst: dst, facts: s, move: move)
                } else {
                    skip(src, "Replace was not confirmed, so nothing was changed.")
                    dropPending(under: dst)
                }
            }
            return
        }

        // Finder's window-layout file inside a merge: the one already there stays.
        let unit = isUnit(s, t)
        if !unit && src.lastPathComponent == ".DS_Store" {
            if move { ops.append(.discardSourceDSStore(src)) }
            return
        }

        // A file (or a library, or a file meeting a folder) with the same name.
        let same: FileQuestion.Sameness
        if unit {
            same = .differs
            pendingUnit.remove(dst.path)
        } else {
            if let known = sameness[dst.path] { same = known } else { same = try await compare(s, t) }
            pendingDiffering.remove(dst.path)
            pendingIdentical.remove(dst.path)
        }

        var choice: FileChoice? = unit ? fileForAllUnit
            : (same == .differs ? fileForAllDiffering : fileForAllIdentical)
        if choice == nil {
            let remaining = unit ? pendingUnit.count
                : (same == .differs ? pendingDiffering.count : pendingIdentical.count)
            let answer = await delegate.askFile(FileQuestion(
                kind: kind, source: s, target: t, sameness: same, unitOnly: unit,
                remainingLikeThis: remaining, targetGoesToTrash: isLocalVolume(dst)))
            choice = answer.choice
            if answer.applyToAll {
                if unit { fileForAllUnit = answer.choice }
                else if same == .differs { fileForAllDiffering = answer.choice }
                else { fileForAllIdentical = answer.choice }
            }
        }

        switch choice ?? .cancel {
        case .cancel:
            throw FileOpCancelled()
        case .skip:
            skip(src, same == .differs
                 ? "An item with this name is already there — you chose Skip."
                 : "The identical file is already there — you chose Skip.")
        case .removeFromSource:
            if kind == .move && same != .differs {
                ops.append(.removeDuplicate(src: src, keptAt: dst))
            } else {
                skip(src, "Left in place.")
            }
        case .keepBoth:
            try addNew(src: src, dst: uniqueName(for: dst), facts: s, move: move)
        case .replace:
            try await replace(src: src, dst: dst, s: s, t: t, move: move)
        case .replaceIfNewer:
            if let a = s.modified, let b = t.modified, a.timeIntervalSince(b) >= 1 {
                try await replace(src: src, dst: dst, s: s, t: t, move: move)
            } else {
                skip(src, "Not replaced: the file already there is the same age or newer.")
            }
        case .replaceIfSizeDiffers:
            if s.size != t.size {
                try await replace(src: src, dst: dst, s: s, t: t, move: move)
            } else {
                skip(src, "Not replaced: it is the same size as the file already there.")
            }
        }
    }

    private func replace(src: URL, dst: URL, s: FileFacts, t: FileFacts, move: Bool) async throws {
        // MC's safeguard: an empty file never wipes a real one.
        if !s.isDirectory && s.size == 0 && !t.isDirectory && t.size > 0 {
            skip(src, "Not replaced: the incoming file is empty and the one already there is not.")
            return
        }
        if t.isDirectory {
            // A library or a folder is about to go: same second confirm as a folder Replace.
            guard await confirmReplace(dst, forAll: false) else {
                skip(src, "Replace was not confirmed, so nothing was changed.")
                return
            }
            ops.append(.dispose(dst))
            try addNew(src: src, dst: dst, facts: s, move: move)
        } else if s.isDirectory {
            ops.append(.dispose(dst))
            try addNew(src: src, dst: dst, facts: s, move: move)
        } else {
            ops.append(.transfer(src: src, dst: dst, move: move, replaceExisting: true, size: s.size))
        }
    }

    /// Plan an item whose target name is free (or about to be freed by a Replace).
    private func addNew(src: URL, dst: URL, facts s: FileFacts, move: Bool) throws {
        if s.isSymlink || !s.isDirectory {
            ops.append(.transfer(src: src, dst: dst, move: move, replaceExisting: false, size: s.size))
            return
        }
        if move && sameVolume(src) && !MoveGuard.containsGuarded(src) {
            ops.append(.renameMove(src: src, dst: dst))
            return
        }
        ops.append(.makeFolder(src: src, dst: dst))
        for child in children(of: src) {
            try addNew(src: child, dst: dst.appendingPathComponent(child.lastPathComponent),
                       facts: facts(child), move: move && mayMove(child))
        }
        ops.append(.finishFolder(src: src, dst: dst))
        if move { ops.append(.removeSourceFolderIfEmpty(src)) }
    }

    /// The second confirm (his 5.2): names what goes and how much of it.
    private func confirmReplace(_ dst: URL, forAll: Bool) async -> Bool {
        if replaceForAllConfirmed { return true }
        var targets = [dst]
        if forAll {
            let others = pendingFolders.map { URL(fileURLWithPath: $0) }
            targets += others.filter { o in !others.contains { o.path.hasPrefix($0.path + "/") } }
        }
        var files = 0
        var bytes: Int64 = 0
        for t in targets { tally(t, files: &files, bytes: &bytes) }
        let ok = await delegate.confirmReplace(ReplaceConfirm(
            targets: targets, fileCount: files, byteCount: bytes, goesToTrash: isLocalVolume(dst)))
        if forAll {
            if ok { replaceForAllConfirmed = true } else { folderForAll = nil }
        }
        return ok
    }

    // MARK: - Phase 2: do it

    private func execute() async throws {
        var files = 0
        var bytes: Int64 = 0
        for op in ops {
            switch op {
            case .renameMove:
                files += 1
            case let .transfer(src, _, move, _, size):
                files += 1
                if !(move && sameVolume(src)) { bytes += move ? size * 2 : size }
            default:
                break
            }
        }
        progress.phase = .transferring
        progress.filesTotal = files
        progress.bytesTotal = bytes
        runningSince = Date()
        await report(force: true)

        for op in ops {
            try checkCancelled()
            if let blocked = blockedByFailedFolder(op) {
                skip(blocked, "Its folder could not be created in the target.")
                continue
            }
            while true {
                do {
                    try await perform(op)
                    break
                } catch is FileOpCancelled {
                    throw FileOpCancelled()
                } catch {
                    let path = pathOf(op)
                    let choice: ErrorChoice = skipAllErrors ? .skip
                        : await delegate.askError(ErrorQuestion(path: path, message: error.localizedDescription))
                    switch choice {
                    case .retry:
                        continue
                    case .skip, .skipAll:
                        if choice == .skipAll { skipAllErrors = true }
                        summary.failed.append(.init(path: path, reason: error.localizedDescription))
                        log.entries.append(.failed(path: path, message: error.localizedDescription))
                        if case let .makeFolder(_, dst) = op { failedFolders.append(dst.path) }
                    case .cancel:
                        throw FileOpCancelled()
                    }
                    break
                }
            }
            saveLogIfDue()
        }
    }

    private func perform(_ op: Op) async throws {
        switch op {
        case let .dispose(url):
            try dispose(url)

        case let .renameMove(src, dst):
            progress.currentName = src.lastPathComponent
            guard !exists(dst) else { throw EngineError(message: "“\(dst.lastPathComponent)” appeared in the target while this was running.") }
            try posixRename(src, dst)
            log.entries.append(.moved(from: src.path, to: dst.path))
            progress.filesDone += 1
            summary.filesTransferred += 1
            await report()

        case let .makeFolder(_, dst):
            if !exists(dst) {
                try fm.createDirectory(at: dst, withIntermediateDirectories: false)
                log.entries.append(.createdFolder(path: dst.path))
            }

        case let .finishFolder(src, dst):
            // Best effort — the contents are what matter — but never silent.
            if copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_ACL)) != 0 {
                summary.notes.append(.init(path: dst.path, reason: "Its folder dates or attributes could not be copied."))
            }

        case let .transfer(src, dst, move, replaceExisting, size):
            try await transfer(src: src, dst: dst, move: move, replaceExisting: replaceExisting, size: size)

        case let .removeDuplicate(src, keptAt):
            // "Same size, same date" is strong but it is not proof, and this deletes. Every
            // byte is compared first; if they differ, nothing is removed.
            guard try await bytesEqual(src, keptAt) else {
                throw EngineError(message: "“\(src.lastPathComponent)” is not byte-for-byte identical to the file already in the target, so it was NOT removed from the source.")
            }
            try fm.removeItem(at: src)
            log.entries.append(.removedDuplicate(path: src.path, keptAt: keptAt.path))
            summary.notes.append(.init(path: src.path, reason: "Removed from the source — the identical file is already in the target, as you chose."))

        case let .discardSourceDSStore(src):
            try? fm.removeItem(at: src)

        case let .removeSourceFolderIfEmpty(src):
            if rmdir(src.path) == 0 {
                log.entries.append(.removedSourceFolder(path: src.path))
            } else if errno != ENOTEMPTY && errno != ENOENT {
                throw posixError("Could not remove the emptied source folder", src)
            }
            // Not empty = something in it was skipped or guarded. It stays, on purpose.
        }
    }

    /// One file (or symbolic link) to its new home.
    private func transfer(src: URL, dst: URL, move: Bool, replaceExisting: Bool, size: Int64) async throws {
        progress.currentName = src.lastPathComponent
        await report()

        // Same drive: a rename. Nothing is copied, so there is nothing to verify.
        // ⚠️ Measured against the folder it is going INTO, not the operation's target —
        // Undo sends files back to a different drive through this same function.
        let sameDrive = sameVolume(src, as: dst.deletingLastPathComponent())
        if move && sameDrive {
            if replaceExisting && exists(dst) { try dispose(dst) }
            guard !exists(dst) else { throw EngineError(message: "“\(dst.lastPathComponent)” is already in the target.") }
            try posixRename(src, dst)
            log.entries.append(.moved(from: src.path, to: dst.path))
            progress.filesDone += 1
            summary.filesTransferred += 1
            return
        }

        let s = facts(src)
        let partial = dst.deletingLastPathComponent()
            .appendingPathComponent(".\(dst.lastPathComponent).ngc-partial-\(UUID().uuidString.prefix(8))")
        var partialExists = false
        defer { if partialExists { try? fm.removeItem(at: partial) } }

        if s.isSymlink {
            let destination = try fm.destinationOfSymbolicLink(atPath: src.path)
            try fm.createSymbolicLink(atPath: partial.path, withDestinationPath: destination)
            partialExists = true
        } else if !move && sameDrive && clonefile(src.path, partial.path, UInt32(CLONE_NOFOLLOW)) == 0 {
            // Same-drive copy on APFS: an instant clone that takes no extra space.
            partialExists = true
            addBytes(size)
        } else {
            partialExists = true
            let digest = try await streamCopy(from: src, to: partial, hashing: move)
            if copyfile(src.path, partial.path, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_ACL)) != 0 {
                summary.notes.append(.init(path: dst.path, reason: "Copied, but its dates or attributes could not be."))
            }
            if move {
                // The source is about to be deleted — read the copy back from the drive and
                // prove it matches before that happens.
                progress.currentName = "Verifying " + src.lastPathComponent
                let written = try await hashFile(partial)
                guard written == digest else {
                    throw EngineError(message: "The copy of “\(src.lastPathComponent)” does not match the original. The original was NOT deleted.")
                }
            } else {
                let copied = facts(partial).size
                guard copied == size else {
                    throw EngineError(message: "The copy of “\(src.lastPathComponent)” is \(copied) bytes; the original is \(size).")
                }
            }
        }

        if replaceExisting && exists(dst) { try dispose(dst) }
        guard !exists(dst) else { throw EngineError(message: "“\(dst.lastPathComponent)” is already in the target.") }
        try posixRename(partial, dst)
        partialExists = false

        if move {
            try fm.removeItem(at: src)
            log.entries.append(.moved(from: src.path, to: dst.path))
        } else {
            log.entries.append(.copied(from: src.path, to: dst.path))
        }
        progress.filesDone += 1
        summary.filesTransferred += 1
        summary.bytesTransferred += size
        await report()
    }

    /// Trash on a drive that has one; delete on a network drive, which does not. Every
    /// popup that leads here said which it would be (his 5.3: "not our lane").
    private func dispose(_ url: URL) throws {
        if isLocalVolume(url) {
            var result: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &result)
            log.entries.append(.trashed(original: url.path, trashPath: result?.path ?? ""))
        } else {
            try fm.removeItem(at: url)
            log.entries.append(.deleted(original: url.path))
        }
    }

    // MARK: - Undo a whole Move

    private func runUndo() async -> FileOpSummary {
        guard var undone = undoLog else { return summary }
        summary.wasUndo = true
        progress.phase = .transferring
        runningSince = Date()
        let entries = undone.entries.reversed()
        progress.filesTotal = entries.filter {
            if case .moved = $0 { return true }
            if case .removedDuplicate = $0 { return true }
            return false
        }.count
        log = OperationLog(kind: .move, sources: [undone.target], target: "undo of \(undone.id)")

        do {
            for entry in entries {
                try checkCancelled()
                switch entry {
                case let .moved(from, to):
                    let back = URL(fileURLWithPath: from), here = URL(fileURLWithPath: to)
                    guard !exists(back) else {
                        skip(here, "Not moved back: something is already at its original place.")
                        continue
                    }
                    try await undoStep(here) {
                        try self.fm.createDirectory(at: back.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let size = self.facts(here).isDirectory ? 0 : self.facts(here).size
                        if self.sameVolume(here, as: back.deletingLastPathComponent()) {
                            try self.posixRename(here, back)
                            self.progress.filesDone += 1
                            self.summary.filesTransferred += 1
                        } else if self.facts(here).isDirectory {
                            try self.fm.moveItem(at: here, to: back)
                            self.progress.filesDone += 1
                            self.summary.filesTransferred += 1
                        } else {
                            try await self.transfer(src: here, dst: back, move: true, replaceExisting: false, size: size)
                        }
                    }
                case let .removedDuplicate(path, keptAt):
                    let back = URL(fileURLWithPath: path), kept = URL(fileURLWithPath: keptAt)
                    guard !exists(back), exists(kept) else { continue }
                    try await undoStep(kept) {
                        try self.fm.createDirectory(at: back.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try await self.transfer(src: kept, dst: back, move: false, replaceExisting: false, size: self.facts(kept).size)
                    }
                case let .trashed(original, trashPath):
                    let back = URL(fileURLWithPath: original), inTrash = URL(fileURLWithPath: trashPath)
                    guard !trashPath.isEmpty, exists(inTrash), !exists(back) else {
                        summary.notes.append(.init(path: original, reason: "Could not be restored from the Trash — it is no longer there, or its place is taken."))
                        continue
                    }
                    try await undoStep(inTrash) { try self.fm.moveItem(at: inTrash, to: back) }
                case let .deleted(original):
                    summary.notes.append(.init(path: original, reason: "Was on a network drive with no Trash, so it cannot be restored."))
                case let .createdFolder(path):
                    _ = rmdir(path)
                case let .removedSourceFolder(path):
                    try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
                case .copied, .skipped, .failed:
                    break
                }
            }
        } catch is FileOpCancelled {
            summary.cancelled = true
        } catch {
            summary.failed.append(.init(path: targetDir.path, reason: error.localizedDescription))
        }

        undone.undone = !summary.cancelled
        saveLog(undone, to: undoneLogURL(undone))
        progress.phase = .finishing
        await report(force: true)
        return summary
    }

    private func undoStep(_ url: URL, _ body: () async throws -> Void) async throws {
        while true {
            do { try await body(); return }
            catch is FileOpCancelled { throw FileOpCancelled() }
            catch {
                let choice: ErrorChoice = skipAllErrors ? .skip
                    : await delegate.askError(ErrorQuestion(path: url.path, message: error.localizedDescription))
                switch choice {
                case .retry: continue
                case .skip, .skipAll:
                    if choice == .skipAll { skipAllErrors = true }
                    summary.failed.append(.init(path: url.path, reason: error.localizedDescription))
                    return
                case .cancel: throw FileOpCancelled()
                }
            }
        }
    }

    // MARK: - Byte work

    private static let chunk = 4 << 20

    /// Copy the data, hashing it on the way through when a Move needs the proof.
    private func streamCopy(from src: URL, to dst: URL, hashing: Bool) async throws -> Data? {
        let input = open(src.path, O_RDONLY)
        guard input >= 0 else { throw posixError("Could not read", src) }
        defer { close(input) }
        let output = open(dst.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard output >= 0 else { throw posixError("Could not write to the target", dst) }
        defer { close(output) }

        var hasher = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            try await gate()
            let n = read(input, buffer, Self.chunk)
            if n < 0 { if errno == EINTR { continue }; throw posixError("Could not read", src) }
            if n == 0 { break }
            if hashing { hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n)) }
            var written = 0
            while written < n {
                let w = write(output, buffer + written, n - written)
                if w < 0 { if errno == EINTR { continue }; throw posixError("Could not write to the target", dst) }
                written += w
            }
            addBytes(Int64(n))
            await report()
        }
        // Make sure it is on the drive, not just in memory, before anything is deleted.
        if fcntl(output, F_FULLFSYNC) != 0 { fsync(output) }
        return hashing ? Data(hasher.finalize()) : nil
    }

    /// Read a file back with the cache bypassed, so the hash reflects what is on the drive.
    private func hashFile(_ url: URL) async throws -> Data {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw posixError("Could not read back the copy", url) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            try await gate()
            let n = read(fd, buffer, Self.chunk)
            if n < 0 { if errno == EINTR { continue }; throw posixError("Could not read back the copy", url) }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            addBytes(Int64(n))
            await report()
        }
        return Data(hasher.finalize())
    }

    private func bytesEqual(_ a: URL, _ b: URL) async throws -> Bool {
        let fa = open(a.path, O_RDONLY), fb = open(b.path, O_RDONLY)
        defer { if fa >= 0 { close(fa) }; if fb >= 0 { close(fb) } }
        guard fa >= 0, fb >= 0 else { return false }
        let size = 1 << 20
        let ba = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        let bb = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { ba.deallocate(); bb.deallocate() }
        progress.currentName = "Comparing " + a.lastPathComponent
        while true {
            try await gate()
            let na = readFully(fa, ba, size), nb = readFully(fb, bb, size)
            if na != nb { return false }
            if na <= 0 { return na == 0 }
            if memcmp(ba, bb, na) != 0 { return false }
            await report()
        }
    }

    private func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var total = 0
        while total < count {
            let n = read(fd, buffer + total, count - total)
            if n < 0 { if errno == EINTR { continue }; return -1 }
            if n == 0 { break }
            total += n
        }
        return total
    }

    // MARK: - Pause, cancel, progress

    private func gate() async throws {
        if control.isPaused {
            let pausedAt = Date()
            progress.isPaused = true
            await report(force: true)
            while control.isPaused {
                try checkCancelled()
                try? await Task.sleep(for: .milliseconds(200))
            }
            runningSince = runningSince.map { $0.addingTimeInterval(Date().timeIntervalSince(pausedAt)) }
            progress.isPaused = false
            await report(force: true)
        }
        try checkCancelled()
    }

    private func checkCancelled() throws {
        if control.isCancelled { throw FileOpCancelled() }
    }

    private func addBytes(_ n: Int64) {
        progress.bytesDone += n
        if let since = runningSince {
            let seconds = Date().timeIntervalSince(since)
            if seconds > 0.5 { progress.bytesPerSecond = Double(progress.bytesDone) / seconds }
        }
    }

    private func report(force: Bool = false) async {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.2 else { return }
        lastReport = now
        let snapshot = progress
        await delegate.report(snapshot)
    }

    // MARK: - Log

    private func saveLogIfDue() {
        if Date().timeIntervalSince(lastLogSave) > 3 { saveLog() }
    }

    private func saveLog() {
        if logURL == nil {
            let stamp = ISO8601DateFormatter().string(from: log.date).replacingOccurrences(of: ":", with: "-")
            // The id is in the name: two operations can start in the same second, and a
            // name made of the time alone let the second one overwrite the first's log.
            logURL = OperationLog.folder.appendingPathComponent("\(stamp) \(kind.rawValue) \(log.id.uuidString.prefix(8)).json")
        }
        if let url = logURL { saveLog(log, to: url) }
        lastLogSave = Date()
    }

    private func saveLog(_ log: OperationLog, to url: URL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(log) { try? data.write(to: url, options: .atomic) }
    }

    private func undoneLogURL(_ log: OperationLog) -> URL {
        let files = (try? fm.contentsOfDirectory(at: OperationLog.folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let found = try? decoder.decode(OperationLog.self, from: data), found.id == log.id {
                return url
            }
        }
        return OperationLog.folder.appendingPathComponent("\(log.id).json")
    }

    // MARK: - Helpers

    private func skip(_ url: URL, _ reason: String) {
        summary.skipped.append(.init(path: url.path, reason: reason))
        log.entries.append(.skipped(path: url.path, reason: reason))
    }

    private func mayMove(_ url: URL) -> Bool {
        guard kind == .move else { return false }
        if let reason = MoveGuard.reason(url) {
            // Note it once, at the top of the guarded part.
            if MoveGuard.reason(url.deletingLastPathComponent()) == nil {
                summary.notes.append(.init(path: url.path, reason: "Copied, not moved — \(reason)."))
            }
            return false
        }
        return true
    }

    private func dropPending(under dst: URL) {
        let prefix = dst.path + "/"
        pendingFolders = pendingFolders.filter { !$0.hasPrefix(prefix) }
        pendingDiffering = pendingDiffering.filter { !$0.hasPrefix(prefix) }
        pendingIdentical = pendingIdentical.filter { !$0.hasPrefix(prefix) }
        pendingUnit = pendingUnit.filter { !$0.hasPrefix(prefix) }
    }

    private func blockedByFailedFolder(_ op: Op) -> URL? {
        guard !failedFolders.isEmpty else { return nil }
        let dst: URL
        switch op {
        case let .transfer(_, d, _, _, _), let .makeFolder(_, d), let .finishFolder(_, d), let .renameMove(_, d):
            dst = d
        default:
            return nil
        }
        return failedFolders.contains { dst.path.hasPrefix($0 + "/") || dst.path == $0 } ? dst : nil
    }

    private func pathOf(_ op: Op) -> String {
        switch op {
        case let .renameMove(s, _), let .makeFolder(s, _), let .finishFolder(s, _),
             let .transfer(s, _, _, _, _), let .removeDuplicate(s, _):
            return s.path
        case let .dispose(u), let .discardSourceDSStore(u), let .removeSourceFolderIfEmpty(u):
            return u.path
        }
    }

    private func uniqueName(for dst: URL) -> URL {
        let folder = dst.deletingLastPathComponent()
        let ext = dst.pathExtension
        let base = ext.isEmpty ? dst.lastPathComponent : dst.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !exists(candidate) && !plannedTargets.contains(candidate.path) {
                plannedTargets.insert(candidate.path)
                return candidate
            }
            n += 1
        }
    }
    private var plannedTargets = Set<String>()

    private func children(of url: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
        return items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func facts(_ url: URL) -> FileFacts {
        var st = stat()
        let isLink = lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
        let isDir = !isLink && (values?.isDirectory ?? false)
        return FileFacts(
            url: url,
            isDirectory: isDir,
            isPackage: isDir && ((values?.isPackage ?? false) || MoveGuard.isLibraryPackage(url)),
            isSymlink: isLink,
            size: Int64(isLink ? Int(st.st_size) : (values?.fileSize ?? Int(st.st_size))),
            modified: values?.contentModificationDate
        )
    }

    private func isPlainFolder(_ f: FileFacts) -> Bool { f.isDirectory && !f.isPackage && !f.isSymlink }

    /// Asked as one item: a library/package on either side, or a file meeting a folder.
    private func isUnit(_ s: FileFacts, _ t: FileFacts) -> Bool {
        s.isPackage || t.isPackage || s.isDirectory != t.isDirectory || s.isSymlink != t.isSymlink
    }

    private func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    private func sameFile(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0, lstat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    private let targetDevice: dev_t

    private static func device(of url: URL) -> dev_t {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_dev : 0
    }

    private func sameVolume(_ src: URL) -> Bool {
        var st = stat()
        return lstat(src.path, &st) == 0 && st.st_dev == targetDevice
    }

    private func sameVolume(_ a: URL, as folder: URL) -> Bool {
        var sa = stat(), sb = stat()
        return lstat(a.path, &sa) == 0 && stat(folder.path, &sb) == 0 && sa.st_dev == sb.st_dev
    }

    private func isLocalVolume(_ url: URL) -> Bool {
        var probe = url
        while !exists(probe) && probe.path != "/" { probe = probe.deletingLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
    }

    private func tally(_ url: URL, files: inout Int, bytes: inout Int64) {
        let f = facts(url)
        guard f.isDirectory else { files += 1; bytes += f.size; return }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return }
        for case let item as URL in walker {
            let v = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true { files += 1; bytes += Int64(v?.fileSize ?? 0) }
        }
    }

    private func posixRename(_ from: URL, _ to: URL) throws {
        guard rename(from.path, to.path) == 0 else { throw posixError("Could not move", from) }
    }

    private func posixError(_ what: String, _ url: URL) -> Error {
        EngineError(message: "\(what) “\(url.lastPathComponent)”: \(String(cString: strerror(errno))).")
    }
}
