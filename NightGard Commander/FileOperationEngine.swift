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
import ImageIO
import UniformTypeIdentifiers

/// The UI side: asks Michael, shows progress. Implemented by FileOperationController.
@MainActor
protocol FileOpDelegate: AnyObject, Sendable {
    func askFolder(_ question: FolderQuestion) async -> Answer<FolderChoice>
    func confirmReplace(_ question: ReplaceConfirm) async -> Bool
    func askFile(_ question: FileQuestion) async -> Answer<FileChoice>
    func askError(_ question: ErrorQuestion) async -> ErrorChoice
    /// 7.5 — true = remove the now-empty source folders; false = leave them (the default).
    func askEmptyFolders(_ question: EmptyFoldersQuestion) async -> Bool
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
        /// Extract (7.6): one original out of a Photos library under its real name, dated
        /// when it was taken, converted when `format` is not `.original` (7.9).
        case extract(src: URL, dst: URL, move: Bool, format: ExtractFormat, date: Date?, size: Int64)
        /// Build 77, Merge / Replace / Keep the Other One on a Move: once the file being kept
        /// has landed at `landedAt`, this source leaves — removed if every byte matches
        /// (`identical`), otherwise sent to the Trash. `owner` is the source another bar is
        /// carrying there, when it is another bar's. Always run after every transfer.
        case retire(src: URL, landedAt: URL, match: RetireMatch, owner: URL?)
    }

    /// How the retiring source was judged the same as the file that landed. Build 88 adds
    /// `.audioTwin`: same music, different tags — the LARGER of the two is the one kept.
    enum RetireMatch: Sendable { case bytes, audioTwin, none }

    private struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - State

    let kind: FileOpKind
    let mode: FileOpMode
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

    /// Build 76: the names planned by every bar started from the same scan. Nil for a job
    /// running on its own.
    private let sharedTargets: TargetClaims?

    init(kind: FileOpKind, sources: [URL], targetDir: URL, control: FileOpControl,
         delegate: any FileOpDelegate, mode: FileOpMode = .standard, sharedTargets: TargetClaims? = nil) {
        self.sharedTargets = sharedTargets
        self.kind = kind
        self.mode = mode
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
        self.sharedTargets = nil
        self.kind = .move
        self.mode = .standard
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
        if kind == .delete { return await runDelete() }

        do {
            let valid = validatedSources()
            progress.phase = .checking
            // Build 98: what this bar was handed. A Photos library counts as one item here —
            // how many photos come out of it is only known once its database is read — so the
            // figure is stated as the bar's share, never dressed up as a file count it is not.
            progress.expectedTotal = valid.count
            switch mode {
            case .standard:
                for src in valid {
                    try await preScan(src: src, dst: targetDir.appendingPathComponent(src.lastPathComponent))
                }
                for src in valid {
                    try await decide(src: src, dst: targetDir.appendingPathComponent(src.lastPathComponent))
                }
            case .flatten:
                try await planFlatten(valid)
            case let .extract(format):
                try await planExtract(valid, format: format)
            case let .media(plan):
                try await planMedia(valid, plan: plan)
            }
            try await execute()
            if mode == .flatten && kind == .move { try await offerEmptyFolders(valid) }
        } catch is FileOpCancelled {
            summary.cancelled = true
            log.cancelled = true
        } catch {
            summary.failed.append(.init(path: targetDir.path, reason: error.localizedDescription))
        }

        // Build 77: said once each, not a line per file.
        if mergedCount > 0 {
            summary.notes.append(.init(path: targetDir.path,
                reason: "\(countText(mergedCount, "identical duplicate")) merged: one copy of each is in the target, the \(mergedCount == 1 ? "other was" : "others were") removed from the source after every byte was compared."))
        }
        if retiredCount > 0 {
            summary.notes.append(.init(path: targetDir.path,
                reason: "\(countText(retiredCount, "file")) you chose not to keep \(retiredCount == 1 ? "was" : "were") \(retiredToTrash ? "sent to the Trash" : "deleted (a network drive has no Trash)")."))
        }
        sharedTargets?.finish(claimedSources)

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
        guard s.size == t.size else {
            // Build 88: two MP3s of different sizes can still hold the same music — the gap is
            // the tag block. Read past the tags before calling them different files.
            if !s.isDirectory && !t.isDirectory,
               AudioContentCompare.isMP3(s.url), AudioContentCompare.isMP3(t.url) {
                progress.currentName = "Comparing the audio in " + s.url.lastPathComponent
                if try await AudioContentCompare.sameAudio(s.url, t.url) { return .sameAudio }
            }
            return .differs
        }
        // Plan 8.5: proven equal on an earlier run and untouched since — not read again.
        if verified.matches(source: s, target: t) { return .verifiedEarlier }
        let equal = try await bytesEqual(s.url, t.url)
        if equal { verified.record(source: s, target: t) }
        return equal ? .sameContents : .differs
    }

    private let verified = VerifiedCopies()

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
                var question = FolderQuestion(kind: kind, source: s, target: t, remainingLikeThis: pendingFolders.count)
                // Plan 6.2: how much each side holds, so the complete copy is obvious.
                question.sourceTally = folderTally(src)
                question.targetTally = folderTally(dst)
                let answer = await delegate.askFolder(question)
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
        case .merge, .keepOther:
            // Only a flatten or media sort offers these (build 77); never asked here.
            skip(src, "Left in place.")
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

    private func countText(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)\(n == 1 ? "" : "s")" }

    // MARK: - Plan 6.2: how much a folder holds

    private func folderTally(_ url: URL) -> FolderTally? {
        var files = 0
        var bytes: Int64 = 0
        guard exists(url) else { return nil }
        tally(url, files: &files, bytes: &bytes)
        return FolderTally(items: files, bytes: bytes)
    }

    // MARK: - Plan 7.1–7.5: Flatten

    /// "Apply to all" for the flatten question — for files that differ, and (build 77) for
    /// identical ones, kept apart so a Merge-for-all never lands on a pair that differs.
    private var flattenForAll: FileChoice?
    private var flattenForAllIdentical: FileChoice?
    /// Build 77: every source this bar claimed a name for in the shared registry — marked
    /// finished when the bar ends, so a sibling's Merge stops waiting on it.
    private var claimedSources = Set<String>()
    /// Scan for Media plans several libraries and loose files into the same folders in
    /// one job, so the names each one claims must be shared — otherwise two libraries
    /// both claim “IMG_0001.JPG” and the second fails at copy time. Caught by the build-68
    /// test. Nil outside a media job.
    private var sharedClaims: [String: URL]?
    private var hiddenLeftBehind = 0

    /// Every file under each source goes straight into the target. Libraries and other
    /// packages travel whole, like a single file (7.3). Hidden files stay put (7.4).
    private func planFlatten(_ roots: [URL]) async throws {
        var items: [URL] = []
        for root in roots { try await collectFlat(root, isRoot: true, into: &items) }
        if hiddenLeftBehind > 0 {
            summary.notes.append(.init(path: roots.first?.path ?? targetDir.path,
                reason: "\(countText(hiddenLeftBehind, "hidden item")) (such as .DS_Store) \(hiddenLeftBehind == 1 ? "was" : "were") left in the source — Flatten skips hidden files."))
        }
        var remaining = countFlatClashes(items.map(\.lastPathComponent))
        var claimed: [String: URL] = [:]
        for src in items {
            try checkCancelled()
            let s = facts(src)
            let move = mayMove(src)
            guard let dst = try await resolveFlatTarget(src: src, facts: s, name: src.lastPathComponent,
                                                        remaining: &remaining, claimed: &claimed, srcMoves: move) else { continue }
            try addNew(src: src, dst: dst, facts: s, move: move)
        }
    }

    private func collectFlat(_ url: URL, isRoot: Bool, into items: inout [URL]) async throws {
        try checkCancelled()
        if !isRoot && url.lastPathComponent.hasPrefix(".") { hiddenLeftBehind += 1; return }
        if isPlainFolder(facts(url)) {
            for child in children(of: url) { try await collectFlat(child, isRoot: false, into: &items) }
            return
        }
        items.append(url)
        progress.itemsChecked += 1
        progress.currentName = url.lastPathComponent
        await report()
    }

    /// How many incoming names will meet something — already in the target, or another
    /// incoming file with the same name. What "Apply to all" covers.
    private func countFlatClashes(_ names: [String], in folder: URL? = nil) -> Int {
        let dir = folder ?? targetDir
        var seen = Set<String>()
        var clashes = 0
        for name in names {
            let path = dir.appendingPathComponent(name).path
            if seen.contains(path) || exists(URL(fileURLWithPath: path)) { clashes += 1 }
            seen.insert(path)
        }
        return clashes
    }

    /// The target for one flattened item, or nil when it will not travel under a name of its
    /// own (Skip, Merge, Keep the Other One).
    ///
    /// 7.2 offered only Skip or Keep Both. ⭐ BUILD 77 — on a Move, his words 2026-09-19: "i
    /// dont want to skip because the move is how i keep track" · "i only want to kep one and
    /// move both" · "you need to either add merge or replave or have it merge the metadata
    /// but keeep one file". So a Move also offers, for two FILES:
    ///  • Merge (identical, byte for byte) — one lands, the twin leaves the source.
    ///  • Replace (they differ) — this one lands; the other goes to the Trash, or, if it is
    ///    already in the target on a network drive, is deleted. Not offered when another bar
    ///    is carrying the other one — its step is not this bar's to change.
    ///  • Keep the Other One (they differ) — the other lands; this one goes to the Trash.
    /// Whatever leaves the source leaves only AFTER the kept file has landed.
    /// `srcMoves` is whether this source may leave its folder at all (photos never do).
    private func resolveFlatTarget(src: URL, facts s: FileFacts, name: String, remaining: inout Int,
                                   claimed: inout [String: URL], in folder: URL? = nil,
                                   srcMoves: Bool = false) async throws -> URL? {
        var dst = (folder ?? targetDir).appendingPathComponent(name)
        let inTarget = exists(dst)
        var incoming = claimed[dst.path]
        var fromSibling = false
        // Build 76: a sibling bar from the same scan may already have planned this name.
        // Claiming is one locked step, so two bars can never both find it free.
        if !inTarget, incoming == nil {
            if let other = sharedTargets?.claim(dst.path, for: src) {
                incoming = other
                fromSibling = true
            } else if sharedTargets != nil {
                claimedSources.insert(src.path)
            }
        }
        if inTarget || incoming != nil {
            remaining = max(0, remaining - 1)
            // What the other one is — compared, not assumed. If another bar has already moved
            // it, it is the file now in the target.
            let other: URL? = inTarget ? dst : (incoming.flatMap { exists($0) ? $0 : nil } ?? (exists(dst) ? dst : nil))
            let otherFacts = other.map(facts)
            let bothFiles = !s.isDirectory && otherFacts.map { !$0.isDirectory } == true
            var same: FileQuestion.Sameness = .differs
            if bothFiles, let o = otherFacts {
                same = try await compare(s, o)
                // Another bar can move its file away while this one is reading it — the read
                // then fails and says "differs". Caught by the build-77 test. Compare with the
                // copy that has just landed instead.
                if same == .differs, !inTarget, !exists(o.url), exists(dst), !facts(dst).isDirectory {
                    same = try await compare(s, facts(dst))
                }
            }
            let sameAudio = same == .sameAudio
            let identical = same != .differs && !sameAudio
            let onMove = kind == .move && bothFiles
            // Build 81: Merge is SHOWN for every pair of files — "i want to see merge, full stop" —
            // and USABLE only when they are identical. Merging two different files would throw
            // one away. A source that cannot leave (a library's photo, a guarded folder) stays,
            // which the popup says.
            // Build 88 — his: "it becomes, mergge all meta data". Same music in two files that
            // differ only by their tags merges too: the larger one (the one carrying the extra
            // metadata) is kept, the smaller one's tags are folded into it, both sources go.
            // Build 91 — his rule, and it replaces the greyed-out button: *"i want merge
            // available, its not our responsibility … if they are the same everything i want
            // to merge but if they are different like this i want to keep both."*
            // Merge is LIVE on every pair of files. Identical (or same-audio) pairs merge;
            // a pair that differs keeps both, which is the outcome that loses nothing. One
            // answer, one apply-to-all, covers a bar of thousands.
            let mergeOK = bothFiles
            let replaceOK = onMove && !identical
            // Build 85 — his: "keep both and replace were not both there". Offered for a library
            // photo too; for one it means "do not bring this one in", and it stays in its library.
            let keepOtherOK = onMove && !identical

            func offered(_ c: FileChoice) -> Bool {
                switch c {
                case .keepBoth, .skip, .cancel: return true
                case .merge: return mergeOK
                case .replace: return replaceOK
                case .keepOther: return keepOtherOK
                default: return false
                }
            }
            // Build 88: an audio twin answers with the identical pairs — Merge is the offered
            // action for both, and `offered()` re-checks every pair before the answer is used,
            // so a remembered Merge can never land on a pair that is neither.
            var choice = (identical || sameAudio) ? flattenForAllIdentical : flattenForAll
            if let c = choice, !offered(c) { choice = nil }
            if choice == nil {
                var question = FileQuestion(kind: kind, source: s, target: otherFacts ?? facts(dst),
                                            sameness: same, unitOnly: false, remainingLikeThis: remaining,
                                            targetGoesToTrash: isLocalVolume(dst))
                question.flattenOnly = true
                question.targetIsIncoming = !inTarget
                question.landingName = dst.lastPathComponent
                question.mergeOffered = bothFiles
                question.mergeEnabled = mergeOK
                question.sourceStays = !srcMoves
                question.replaceOffered = replaceOK
                question.keepOtherOffered = keepOtherOK
                question.mediaSort = { if case .media = mode { return true }; return false }()
                question.otherGoesToTrash = inTarget ? isLocalVolume(dst) : (incoming.map(isLocalVolume) ?? true)
                let answer = await delegate.askFile(question)
                choice = answer.choice
                if answer.applyToAll {
                    if answer.choice == .merge {
                        // Build 91: "merge when the same, keep both when different" is ONE
                        // rule, so it is remembered for both kinds of pair in this bar.
                        flattenForAllIdentical = .merge
                        flattenForAll = .merge
                    } else if identical || sameAudio {
                        flattenForAllIdentical = answer.choice
                    } else {
                        flattenForAll = answer.choice
                    }
                }
            }
            let owner = fromSibling ? incoming : nil
            switch choice ?? .cancel {
            case .cancel:
                throw FileOpCancelled()
            case .keepBoth:
                dst = uniqueName(for: dst, claimant: src)
            case .merge where !identical && !sameAudio:
                // They differ: keeping both is what "merge" has to mean here, because
                // throwing one away is the one thing it must never do.
                dst = uniqueName(for: dst, claimant: src)
                summary.notes.append(.init(path: src.path,
                    reason: "Kept both: this \u{201C}\(name)\u{201D} and the other one are different files, so nothing was merged and nothing was thrown away."))
            case .merge:
                if srcMoves {
                    ops.append(.retire(src: src, landedAt: dst, match: sameAudio ? .audioTwin : .bytes, owner: owner))
                } else {
                    skip(src, kind == .move
                         ? "Merged: identical to the “\(name)” arriving there. This one stays where it is — photos inside a Photos library are always copied, never moved."
                         : "Merged: identical to the “\(name)” arriving there, so it was not copied twice.")
                }
                return nil
            case .keepOther:
                if srcMoves {
                    ops.append(.retire(src: src, landedAt: dst, match: .none, owner: owner))
                } else {
                    // ⛔ Never delete from inside a Photos library (or a guarded folder): the
                    // other one is kept, this one is simply not brought in and stays put.
                    skip(src, "Not brought in — you kept the other “\(name)”. This one stays where it is, inside its Photos library.")
                }
                return nil
            case .replace:
                if inTarget {
                    ops.append(.dispose(dst))
                } else if fromSibling {
                    // Another bar holds the name. If its file has not started moving, this one
                    // takes the name and that bar sends its copy to the Trash when it gets
                    // there. Too late = both are kept, and said — never a silent loss.
                    if sharedTargets?.overrule(dst.path, winner: src) == true {
                        claimedSources.insert(src.path)
                    } else {
                        dst = uniqueName(for: dst, claimant: src)
                        summary.notes.append(.init(path: src.path,
                            reason: "The other “\(name)” had already started moving when you chose to keep this one, so both were kept — this one as “\(dst.lastPathComponent)”."))
                    }
                } else if let other = incoming {
                    _ = sharedTargets?.overrule(dst.path, winner: src)
                    if dropPlannedStep(of: other, to: dst) {
                        // The other one was going to move here; now it leaves the source for
                        // the Trash instead — once this one has landed.
                        ops.append(.retire(src: other, landedAt: dst, match: .none, owner: nil))
                    }
                }
            default:
                skip(src, inTarget ? "A file named “\(name)” is already in the target — you chose Skip."
                                   : "Another file named “\(name)” is coming from a different folder — you chose Skip.")
                return nil
            }
        }
        claimed[dst.path] = src
        plannedTargets.insert(dst.path)
        return dst
    }

    /// Build 77 Replace: takes the planned step carrying `other` to `dst` out of the plan.
    /// True when that step would have MOVED it — so it must still leave the source.
    private func dropPlannedStep(of other: URL, to dst: URL) -> Bool {
        func matches(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }
        guard let i = ops.lastIndex(where: { op in
            switch op {
            case let .transfer(s, d, _, _, _): return matches(s, other) && matches(d, dst)
            case let .extract(s, d, _, _, _, _): return matches(s, other) && matches(d, dst)
            case let .renameMove(s, d): return matches(s, other) && matches(d, dst)
            default: return false
            }
        }) else { return false }
        let moved: Bool
        switch ops[i] {
        case let .transfer(_, _, m, _, _): moved = m
        case let .extract(_, _, m, _, _, _): moved = m
        case .renameMove: moved = true
        default: moved = false
        }
        ops.remove(at: i)
        return moved
    }

    /// 7.5 — after a Flatten Move the source folders are empty shells. Leave them unless he
    /// says otherwise. A folder still holding anything (a skipped file, a hidden file other
    /// than Finder's .DS_Store) is never offered.
    private func offerEmptyFolders(_ roots: [URL]) async throws {
        var empties: [URL] = []
        for root in roots where isPlainFolder(facts(root)) { _ = collectEmpty(root, into: &empties) }
        guard !empties.isEmpty else { return }
        guard await delegate.askEmptyFolders(EmptyFoldersQuestion(folders: empties)) else {
            summary.notes.append(.init(path: roots.first?.path ?? "",
                reason: "\(countText(empties.count, "empty folder")) left in the source, as you chose."))
            return
        }
        for folder in empties {   // deepest first — collectEmpty adds a folder after its children
            try? fm.removeItem(at: folder.appendingPathComponent(".DS_Store"))
            if rmdir(folder.path) == 0 {
                log.entries.append(.removedSourceFolder(path: folder.path))
            } else {
                summary.notes.append(.init(path: folder.path, reason: "Could not remove this empty folder: \(String(cString: strerror(errno)))."))
            }
        }
        saveLog()
    }

    private func collectEmpty(_ url: URL, into out: inout [URL]) -> Bool {
        let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? ["?"]
        var empty = true
        for name in names where name != ".DS_Store" {
            let child = url.appendingPathComponent(name)
            if isPlainFolder(facts(child)) {
                if !collectEmpty(child, into: &out) { empty = false }
            } else {
                empty = false
            }
        }
        if empty { out.append(url) }
        return empty
    }

    // MARK: - Plan 7.6–7.11: Extract from a Photos library

    /// `folder` puts the photos in a subfolder of the target (Scan for Media sorts them);
    /// `forceCopy` leaves the library whole even when the action is Move.
    private func planExtract(_ roots: [URL], format: ExtractFormat, into folder: URL? = nil,
                             forceCopy: Bool = false) async throws {
        let dir = folder ?? targetDir
        guard roots.count == 1, let library = roots.first else {
            summary.failed.append(.init(path: targetDir.path, reason: "Choose one Photos library to extract from."))
            return
        }
        guard PhotosLibraryReader.isPhotosLibrary(library) else {
            summary.failed.append(.init(path: library.path, reason: "“\(library.lastPathComponent)” is not a Photos library."))
            return
        }
        progress.currentName = "Reading the Photos library's database…"
        await report(force: true)
        let contents = try PhotosLibraryReader.read(library)

        if contents.trashed > 0 {
            summary.notes.append(.init(path: library.path, reason: "\(countText(contents.trashed, "photo")) in Recently Deleted \(contents.trashed == 1 ? "was" : "were") not extracted."))
        }
        if contents.missingOriginals > 0 {
            summary.notes.append(.init(path: library.path, reason: "\(countText(contents.missingOriginals, "photo")) \(contents.missingOriginals == 1 ? "has" : "have") no original on this drive (kept in iCloud only), so \(contents.missingOriginals == 1 ? "it was" : "they were") not extracted."))
        }
        if kind == .move, !forceCopy, let reason = MoveGuard.reason(library) {
            summary.notes.append(.init(path: library.path, reason: "Copied, not moved — \(reason). Moving originals out of the library Photos is using would break it."))
        }

        // Each asset, plus a Live Photo's video beside it: (stored file, name to give it, date, convert?)
        var planned: [(src: URL, name: String, date: Date?, convert: Bool)] = []
        for asset in contents.assets {
            let ext = asset.storedURL.pathExtension
            let isImage = UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
            var name = asset.realName
            if isImage, let newExt = format.fileExtension {
                name = (asset.realName as NSString).deletingPathExtension + "." + newExt
            }
            planned.append((asset.storedURL, name, asset.dateTaken, isImage && format != .original))
            if let video = asset.livePhotoVideo {
                planned.append((video, (asset.realName as NSString).deletingPathExtension + ".mov", asset.dateTaken, false))
            }
        }

        var remaining = countFlatClashes(planned.map(\.name), in: dir)
        var claimed: [String: URL] = sharedClaims ?? [:]
        defer { if sharedClaims != nil { sharedClaims = claimed } }
        for item in planned {
            try checkCancelled()
            let s = facts(item.src)
            progress.itemsChecked += 1
            progress.currentName = item.name
            await report()
            guard let dst = try await resolveFlatTarget(src: item.src, facts: s, name: item.name,
                                                        remaining: &remaining, claimed: &claimed, in: dir) else { continue }
            let move = kind == .move && !forceCopy && MoveGuard.reason(item.src) == nil
            ops.append(.extract(src: item.src, dst: dst, move: move,
                                format: item.convert ? format : .original, date: item.date, size: s.size))
            // Build 95: a library of 30,000 photos starts arriving straight away.
            // ⚠️ `sharedClaims` is written back by the defer above, so the chunk must see the
            // claims made so far — it does: `claimed` is the same dictionary the flush reads
            // through `uniqueName`, and nothing in a chunk changes which name a later file
            // was promised.
            try await flushChunk()
        }
    }

    // MARK: - Delete (build 70)

    /// ⭐ HIS CONDITION, 2026-09-19: "only if deleting to trash doesnt copy all the files to
    /// the trashcan and references because if it takes an hour to copy from source to
    /// destination it is too long". It does not copy: on a drive attached to this Mac the
    /// Trash is a folder ON THAT DRIVE and trashing is a rename — instant at any size.
    /// A network drive has no Trash (Finder says the same), so there the delete stays
    /// permanent, as it always was — now off the main thread, with a bar, Pause and Cancel.
    /// ⛔ If the Trash refuses an item, NOTHING is deleted — it never falls back to erasing.
    private func runDelete() async -> FileOpSummary {
        // Named on the finished popup — his ask, 2026-09-19: "it should say the name of the
        // parent folder or file i selected to delete as confirmation because this popup
        // doesnt say".
        summary.sources = sources.map(\.path)
        do {
            progress.phase = .checking
            var trashable: [URL] = []
            var permanent: [URL] = []
            for src in sources where exists(src) {
                if isLocalVolume(src) { trashable.append(src) } else { permanent.append(src) }
            }
            // Count what a permanent delete will remove, so its bar means something.
            var inside: [String: [URL]] = [:]
            for root in permanent where facts(root).isDirectory && !facts(root).isSymlink {
                var list: [URL] = []
                if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) {
                    while let url = walker.nextObject() as? URL {
                        try checkCancelled()
                        list.append(url)
                        progress.itemsChecked += 1
                        progress.currentName = url.lastPathComponent
                        await report()
                    }
                }
                inside[root.path] = list
            }
            progress.filesTotal = trashable.count + permanent.count + inside.values.reduce(0) { $0 + $1.count }
            progress.phase = .transferring
            runningSince = Date()

            for src in trashable {
                try await gate()
                try checkCancelled()
                progress.currentName = src.lastPathComponent
                await report()
                var landed: NSURL?
                do {
                    try fm.trashItem(at: src, resultingItemURL: &landed)
                    log.entries.append(.trashed(original: src.path, trashPath: landed?.path ?? ""))
                    summary.filesTransferred += 1
                } catch {
                    summary.failed.append(.init(path: src.path,
                        reason: "Could not be moved to the Trash, so it was NOT deleted: \(error.localizedDescription)"))
                }
                progress.filesDone += 1
                saveLogIfDue()
            }
            if summary.filesTransferred > 0 {
                summary.notes.append(.init(path: trashable.first?.path ?? "",
                    reason: "Moved to the Trash on its own drive — instant, nothing was copied. Empty the Trash to free the space."))
            }

            var erased = 0
            for root in permanent {
                // Deepest first: the walk lists a folder before what is in it, so reversed,
                // everything inside a folder goes before the folder itself.
                for item in (inside[root.path] ?? []).reversed() + [root] {
                    try await gate()
                    try checkCancelled()
                    progress.currentName = item.lastPathComponent
                    do {
                        try fm.removeItem(at: item)
                    } catch where exists(item) {
                        summary.failed.append(.init(path: item.path, reason: error.localizedDescription))
                    } catch {}
                    progress.filesDone += 1
                    await report()
                }
                if !exists(root) {
                    erased += 1
                    summary.filesTransferred += 1
                    log.entries.append(.deleted(original: root.path))
                }
                saveLogIfDue()
            }
            if erased > 0 {
                summary.notes.append(.init(path: permanent.first?.path ?? "",
                    reason: "Deleted permanently — a network drive has no Trash."))
            }
        } catch is FileOpCancelled {
            summary.cancelled = true
            log.cancelled = true
        } catch {
            summary.failed.append(.init(path: sources.first?.path ?? "", reason: error.localizedDescription))
        }
        progress.phase = .finishing
        await report(force: true)
        saveLog()
        summary.logURL = logURL
        return summary
    }

    // MARK: - Plan: Scan for Media (build 68)

    /// Each scanned file into its subfolder; each Photos library through Extract, copied.
    /// Clashes are asked the Flatten way — Skip or Keep Both, never Replace.
    private func planMedia(_ sources: [URL], plan givenPlan: MediaPlan) async throws {
        var plan = givenPlan
        // Build 87: finish each video's shelf by reading it — Video/1080p/H.264/. Done before
        // any folder is made, so only folders that will hold something are created.
        let toProbe = sources.filter { plan.probe.contains($0.path) }
        for (i, src) in toProbe.enumerated() {
            try checkCancelled()
            progress.currentName = "Reading video details — \((i + 1).formatted()) of \(toProbe.count.formatted())"
            await report()
            let sub = await VideoProbe.shelf(for: src)
            let base = plan.folders[src.path] ?? ""
            plan.folders[src.path] = base.isEmpty ? sub : base + "/" + sub
        }
        // The subfolders first, so every file has somewhere to land.
        var badFolders = Set<String>()
        for rel in Set(plan.folders.values).union(plan.libraries.values) where !rel.isEmpty {
            let dir = targetDir.appendingPathComponent(rel, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                badFolders.insert(rel)
                summary.failed.append(.init(path: dir.path, reason: "Could not create the folder: \(error.localizedDescription)"))
            }
        }

        sharedClaims = [:]
        // Photos libraries — through their own database, always copied.
        for src in sources {
            guard let rel = plan.libraries[src.path], !badFolders.contains(rel) else { continue }
            try await planExtract([src], format: .original,
                                  into: rel.isEmpty ? nil : targetDir.appendingPathComponent(rel), forceCopy: true)
        }

        // Loose files.
        let files = sources.filter { plan.folders[$0.path] != nil && !badFolders.contains(plan.folders[$0.path] ?? "") }
        var remaining = 0
        var byFolder: [String: [String]] = [:]
        for src in files { byFolder[plan.folders[src.path] ?? "", default: []].append(src.lastPathComponent) }
        for (rel, names) in byFolder {
            remaining += countFlatClashes(names, in: rel.isEmpty ? nil : targetDir.appendingPathComponent(rel))
        }
        var claimed: [String: URL] = sharedClaims ?? [:]
        var alreadyHome = 0
        for src in files {
            try checkCancelled()
            let rel = plan.folders[src.path] ?? ""
            let folder = rel.isEmpty ? targetDir : targetDir.appendingPathComponent(rel)
            // A file already where it would go (scanning the media folder itself) stays put.
            if src.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path {
                alreadyHome += 1
                continue
            }
            let s = facts(src)
            progress.itemsChecked += 1
            progress.currentName = src.lastPathComponent
            await report()
            let move = !plan.copyOnly.contains(src.path) && mayMove(src)
            guard let dst = try await resolveFlatTarget(src: src, facts: s, name: src.lastPathComponent,
                                                        remaining: &remaining, claimed: &claimed, in: folder,
                                                        srcMoves: move) else { continue }
            try addNew(src: src, dst: dst, facts: s, move: move)
            try await flushChunk()
        }
        if alreadyHome > 0 {
            summary.notes.append(.init(path: targetDir.path,
                reason: "\(countText(alreadyHome, "file")) \(alreadyHome == 1 ? "was" : "were") already in \(alreadyHome == 1 ? "its" : "their") media folder and left where \(alreadyHome == 1 ? "it was" : "they were")."))
        }
        let photosCopied = files.filter { plan.copyOnly.contains($0.path) }.count
        // His wording, 2026-09-19: "it should tell the user photos were copied not moved
        // because they were in {photolibrary name and filepath}". One line per library.
        if kind == .move {
            for library in plan.libraries.keys.sorted() {
                let url = URL(fileURLWithPath: library)
                summary.notes.append(.init(path: library,
                    reason: "Photos in “\(url.lastPathComponent)” (\(library)) were copied, not moved, because they are inside that Photos library."))
            }
        }
        if kind == .move && photosCopied > 0 {
            summary.notes.append(.init(path: targetDir.path,
                reason: "\(countText(photosCopied, "photo")) copied, not moved."))
        }
    }

    /// One original out of the library. Written under a hidden partial name and renamed
    /// only when complete, like every other transfer. Dated when the photo was taken.
    ///
    /// ⚠️ A MOVE THAT CONVERTS cannot byte-verify — the new file is meant to differ. So the
    /// converted file is read back as an image first, and the original then goes to the
    /// Trash (deleted on a network drive, which has none) rather than being erased, so Undo
    /// can bring it back where it can.
    private func extractFile(src: URL, dst: URL, move: Bool, format: ExtractFormat, date: Date?, size: Int64) async throws {
        progress.currentName = dst.lastPathComponent
        await report()
        let partial = dst.deletingLastPathComponent()
            .appendingPathComponent(".\(dst.lastPathComponent).ngc-partial-\(UUID().uuidString.prefix(8))")
        var partialExists = false
        defer { if partialExists { try? fm.removeItem(at: partial) } }
        // Build 77: a sibling bar's stale-partial sweep must not take this one mid-write.
        sharedTargets?.markLive(partial.path)
        defer { sharedTargets?.markDone(partial.path) }

        if format == .original {
            partialExists = true
            let digest = try await streamCopy(from: src, to: partial, hashing: move)
            _ = copyfile(src.path, partial.path, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR))
            if move {
                progress.currentName = "Verifying " + dst.lastPathComponent
                guard try await hashFile(partial) == digest else {
                    throw EngineError(message: "The copy of “\(dst.lastPathComponent)” does not match the original. The original was NOT removed.")
                }
            } else if facts(partial).size != size {
                throw EngineError(message: "The copy of “\(dst.lastPathComponent)” is the wrong size.")
            }
        } else {
            partialExists = true
            try await gate()
            try convertImage(src, to: partial, format: format)
            addBytes(size)
            guard let check = CGImageSourceCreateWithURL(partial as CFURL, nil), CGImageSourceGetCount(check) > 0 else {
                throw EngineError(message: "The converted copy of “\(dst.lastPathComponent)” could not be read back. The original was NOT removed.")
            }
        }

        if let date {
            try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: partial.path)
        }
        // ⭐ BUILD 101 — the name is taken. Until now this threw, and the generic error box
        // offered Retry / Skip / Skip All: his merge rule was never consulted on this path, so
        // a Photos library full of UUID files whose real names collide asked him the same
        // question hundreds of times. His words, 2026-09-20: *"not knowing it can save both
        // files or merge because it never asked"* — and then the fix itself: *"the list of
        // files skipped could also be diverted to a quarantined finder folder."*
        //
        // ⚠️ The copy in `partial` is already written AND hash-verified at this point, so both
        // branches below are a rename. **Nothing is copied twice and nothing is thrown away.**
        if exists(dst) {
            if try await bytesEqual(partial, dst) {
                // Identical — his rule is merge. The copy already in the target is where the
                // content lives; this one never needed to travel.
                try? fm.removeItem(at: partial)
                partialExists = false
                if move {
                    // Only now, with a verified identical copy proven to be in the target.
                    try fm.removeItem(at: src)
                    log.entries.append(.removedDuplicate(path: src.path, keptAt: dst.path))
                }
                summary.notes.append(.init(path: src.path,
                    reason: "Identical to “\(dst.lastPathComponent)” already in the target, so it was merged\(move ? " and removed from the source" : "")."))
                progress.filesDone += 1
                await report()
                return
            }
            // Different files, same name — his rule is keep both, but he names them, not me.
            let home = try quarantineFolder()
            let parked = uniqueName(for: home.appendingPathComponent(dst.lastPathComponent))
            try posixRename(partial, parked)
            partialExists = false
            if move { try fm.removeItem(at: src) }
            log.entries.append(.quarantined(from: src.path, to: parked.path, clashedWith: dst.path))
            summary.quarantined.append(.init(path: parked.path,
                reason: "Its name “\(dst.lastPathComponent)” was already taken by a different file. Give it a name and move it where it belongs."))
            summary.quarantineFolder = home.path
            summary.filesTransferred += 1
            summary.bytesTransferred += size
            progress.filesDone += 1
            await report()
            return
        }
        try posixRename(partial, dst)
        partialExists = false

        if move {
            if format == .original {
                try fm.removeItem(at: src)
                log.entries.append(.moved(from: src.path, to: dst.path))
            } else {
                log.entries.append(.copied(from: src.path, to: dst.path))
                try dispose(src)
            }
        } else {
            log.entries.append(.copied(from: src.path, to: dst.path))
        }
        progress.filesDone += 1
        summary.filesTransferred += 1
        summary.bytesTransferred += size
        await report()
    }

    /// 7.9–7.10: macOS's own image converters (the ones Preview uses). Adding the image FROM
    /// its source carries the metadata across — date taken, location, orientation.
    private func convertImage(_ src: URL, to dst: URL, format: ExtractFormat) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw EngineError(message: "“\(src.lastPathComponent)” could not be read as an image.")
        }
        let type: UTType
        var options: [CFString: Any] = [:]
        switch format {
        case .original: throw EngineError(message: "Nothing to convert.")
        case let .jpeg(quality):
            type = .jpeg
            options[kCGImageDestinationLossyCompressionQuality] = quality
        case .png: type = .png
        case .tiff: type = .tiff
        }
        guard let destination = CGImageDestinationCreateWithURL(dst as CFURL, type.identifier as CFString, 1, nil) else {
            throw EngineError(message: "Could not create “\(dst.lastPathComponent)”.")
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw EngineError(message: "“\(src.lastPathComponent)” could not be converted to \(format.label).")
        }
    }

    // MARK: - Phase 2: do it

    /// Build 95 — his ask: *"can it di it in chunks? instead of spending hours checking
    /// first"* · *"youve already asked instructions to merge or keep both … but it does
    /// chunks when executing"*.
    ///
    /// Planning no longer has to finish before anything moves. Every `chunkSize` steps the
    /// plan is executed and the planning goes on, so files start arriving in seconds instead
    /// of after a whole drive has been checked. **The questions are unchanged** — each one is
    /// still asked before its own file moves, and an answer given "for this bar" carries
    /// across the chunks.
    ///
    /// ⛔ **Retires are the exception and they wait for the end.** A retire deletes a source
    /// once its twin has landed (build 77); if it ran inside a chunk whose twin is planned in
    /// a LATER chunk, it would find nothing there and leave the file behind. They are held
    /// back and run in the final pass.
    private let chunkSize = 300
    private var pendingRetires: [Op] = []
    private var startedTransferring = false

    /// Run the plan so far, if it has grown past a chunk, and carry on planning.
    private func flushChunk() async throws {
        guard ops.count >= chunkSize else { return }
        try await execute(final: false)
        progress.phase = .checking
        await report(force: true)
    }

    private func execute(final: Bool = true) async throws {
        // Build 77: a file only leaves the source after the one kept in its place has landed,
        // so every retire step goes last.
        let isRetire: (Op) -> Bool = { if case .retire = $0 { return true }; return false }
        if final {
            ops = ops.filter { !isRetire($0) } + pendingRetires + ops.filter(isRetire)
            pendingRetires = []
        } else {
            pendingRetires += ops.filter(isRetire)
            ops = ops.filter { !isRetire($0) }
        }
        guard !ops.isEmpty else { return }
        var files = 0
        var bytes: Int64 = 0
        for op in ops {
            switch op {
            case .renameMove:
                files += 1
            case let .transfer(src, _, move, _, size):
                files += 1
                if !(move && sameVolume(src)) { bytes += move ? size * 2 : size }
            case let .extract(_, _, move, format, _, size):
                files += 1
                bytes += (move && format == .original) ? size * 2 : size
            default:
                break
            }
        }

        try await buildFolderTree()
        planFolderProgress()

        progress.phase = .transferring
        // Build 95: the totals GROW as later chunks are planned, so they are added to, never
        // replaced. ⚠️ That makes the total an estimate until the last chunk is planned —
        // said plainly rather than shown as a total that silently shrinks the percentage.
        progress.filesTotal += files
        progress.bytesTotal += bytes
        // Build 102: the last chunk is the moment the totals stop growing, and therefore the
        // first moment the time left is a finish time rather than a running subtotal.
        if final { progress.allPlanned = true }
        if !startedTransferring { runningSince = Date(); startedTransferring = true }
        await report(force: true)

        for op in ops {
            try checkCancelled()
            // A new folder is always shown, never lost to the 0.2 s report throttle.
            if enterFolder(for: op) { await report(force: true) }
            if let blocked = blockedByFailedFolder(op) {
                skip(blocked, "Its folder could not be created in the target.")
                continue
            }
            while true {
                do {
                    let opStarted = Date(), pausedBefore = pausedSeconds
                    try await perform(op)
                    noteFileTime(op, seconds: Date().timeIntervalSince(opStarted) - (pausedSeconds - pausedBefore))
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
        ops = []
    }

    // MARK: - Plan 8.2: the whole folder tree first

    /// Makes every target folder before a single file moves. His reason: *"if it sets up the
    /// destination file tree i can quit the app and come back later and finish the copy. the
    /// merge skip merge makes it almost like a download manager."* A second run of the same
    /// operation meets folders that already exist, Merge covers them, and only what is
    /// missing is sent.
    ///
    /// ⚠️ Folders at or under something a Replace is about to dispose of are NOT made early:
    /// the dispose would then throw the fresh, empty folders into the Trash with it. Those are
    /// made in the normal pass, right after their dispose.
    private func buildFolderTree() async throws {
        var disposed: [String] = []
        for op in ops { if case let .dispose(url) = op { disposed.append(url.path) } }
        let early = ops.compactMap { op -> URL? in
            guard case let .makeFolder(_, dst) = op else { return nil }
            let p = dst.path
            return disposed.contains { p == $0 || p.hasPrefix($0 + "/") } ? nil : dst
        }
        progress.phase = .buildingFolders
        progress.foldersToMake = early.count
        await report(force: true)

        for dst in early {
            try await gate()
            if failedFolders.contains(where: { dst.path.hasPrefix($0 + "/") }) { continue }
            progress.currentName = dst.lastPathComponent
            do {
                if !exists(dst) {
                    try fm.createDirectory(at: dst, withIntermediateDirectories: false)
                    log.entries.append(.createdFolder(path: dst.path))
                }
            } catch {
                // Same rule as the main pass: everything planned inside it is skipped,
                // said once, instead of one error prompt per file.
                failedFolders.append(dst.path)
                summary.failed.append(.init(path: dst.path, reason: error.localizedDescription))
                log.entries.append(.failed(path: dst.path, message: error.localizedDescription))
            }
            progress.foldersMade += 1
            await report()
        }
        removeStalePartials()
        saveLog()
    }

    /// Plan 8.6. A copy in flight is written as `.<name>.ngc-partial-XXXXXXXX` and renamed
    /// only when complete, so a power cut never leaves a half file under the real name. It
    /// can leave that hidden partial, though. Those names are Commander's own — nothing else
    /// makes them — so they are cleared from every folder this run is about to write into.
    private func removeStalePartials() {
        var folders = Set<String>()
        for op in ops {
            if case let .transfer(_, dst, _, _, _) = op { folders.insert(dst.deletingLastPathComponent().path) }
            if case let .extract(_, dst, _, _, _, _) = op { folders.insert(dst.deletingLastPathComponent().path) }
        }
        var cleared = 0
        for folder in folders {
            let names = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasPrefix(".") && name.contains(".ngc-partial-") {
                // ⛔ Build 77: a sibling bar from the same scan may be writing this one RIGHT
                // NOW. Build 76 swept those too — the other bar's copy then failed its check
                // ("0 bytes") and asked Retry; the original stayed put. Caught by the test.
                if sharedTargets?.isLive(folder + "/" + name) == true { continue }
                if (try? fm.removeItem(atPath: folder + "/" + name)) != nil { cleared += 1 }
            }
        }
        if cleared > 0 {
            summary.notes.append(.init(path: targetDir.path,
                reason: "Cleared \(cleared) unfinished file\(cleared == 1 ? "" : "s") left by an earlier run that was cut off. Their originals were never deleted, so they were sent again."))
        }
    }

    // MARK: - Plan 8.4: progress by folder

    private var folderOrder: [String: Int] = [:]
    private var folderFileCounts: [Int] = []
    private var currentFolder = -1

    private func planFolderProgress() {
        for op in ops {
            let dst: URL
            switch op {
            case let .transfer(_, d, _, _, _), let .renameMove(_, d), let .extract(_, d, _, _, _, _): dst = d
            default: continue
            }
            let key = dst.deletingLastPathComponent().path
            if let i = folderOrder[key] {
                folderFileCounts[i] += 1
            } else {
                folderOrder[key] = folderFileCounts.count
                folderFileCounts.append(1)
            }
        }
        progress.folderCount = folderFileCounts.count
    }

    /// True when this step starts a new folder.
    private func enterFolder(for op: Op) -> Bool {
        let dst: URL
        switch op {
        case let .transfer(_, d, _, _, _), let .renameMove(_, d), let .extract(_, d, _, _, _, _): dst = d
        default: return false
        }
        let key = dst.deletingLastPathComponent().path
        guard let i = folderOrder[key] else { return false }
        let isNew = i != currentFolder
        if isNew {
            currentFolder = i
            progress.folderIndex = i + 1
            progress.filesInFolder = folderFileCounts[i]
            progress.fileInFolder = 0
            let root = targetDir.path
            var name = key.hasPrefix(root + "/") ? String(key.dropFirst(root.count + 1)) : (key as NSString).lastPathComponent
            if key == root { name = (root as NSString).lastPathComponent }
            progress.folderName = name
        }
        // ⛔ Build 97 — his screen read "file 231 of 91". The folder's TOTAL was set only when
        // the folder changed, so once build 95 began planning in chunks the numerator kept
        // growing while the denominator stayed at the first chunk's count. It is re-read on
        // every step now, because later chunks add files to a folder already in progress.
        progress.filesInFolder = folderFileCounts[i]
        progress.fileInFolder += 1
        return isNew
    }

    private func perform(_ op: Op) async throws {
        // Build 77: he chose, in another bar, to keep a different file under this name. This
        // one does not travel; on a Move it leaves the source for the Trash.
        if let claims = sharedTargets, let (src, dst, moves) = carried(op), !claims.begin(dst.path, by: src) {
            if moves {
                if !isLocalVolume(src) { retiredToTrash = false }
                try dispose(src)
                retiredCount += 1
            } else {
                skip(src, "Not \(kind == .move ? "moved" : "copied") — you kept the other “\(dst.lastPathComponent)”.")
            }
            progress.filesDone += 1
            await report()
            return
        }
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

        case let .extract(src, dst, move, format, date, size):
            try await extractFile(src: src, dst: dst, move: move, format: format, date: date, size: size)

        case let .removeDuplicate(src, keptAt):
            // "Same size, same date" is strong but it is not proof, and this deletes. Every
            // byte is compared first; if they differ, nothing is removed.
            guard try await bytesEqual(src, keptAt) else {
                throw EngineError(message: "“\(src.lastPathComponent)” is not byte-for-byte identical to the file already in the target, so it was NOT removed from the source.")
            }
            mergeMetadata(from: src, into: keptAt)
            try fm.removeItem(at: src)
            log.entries.append(.removedDuplicate(path: src.path, keptAt: keptAt.path))
            summary.notes.append(.init(path: src.path, reason: "Removed from the source — the identical file is already in the target, as you chose."))

        case let .retire(src, landedAt, match, owner):
            try await retire(src: src, landedAt: landedAt, match: match, owner: owner)

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
        // Build 77: a sibling bar's stale-partial sweep must not take this one mid-write.
        sharedTargets?.markLive(partial.path)
        defer { sharedTargets?.markDone(partial.path) }

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
            // Plan 8.5: a re-run of this Copy will not re-read it. The target's date is read
            // back from the drive, so the record matches what the next run will see.
            if !s.isSymlink { verified.record(source: s, target: facts(dst)) }
        }
        progress.filesDone += 1
        summary.filesTransferred += 1
        summary.bytesTransferred += size
        await report()
    }

    /// Trash on a drive that has one; delete on a network drive, which does not. Every
    /// popup that leads here said which it would be (his 5.3: "not our lane").
    // MARK: - Build 77: keep one, and both leave the source

    private var mergedCount = 0
    private var retiredCount = 0
    private var retiredToTrash = true

    /// The kept file must be in place before this one leaves — another bar may still be
    /// carrying it, so wait for it (Pause and Cancel still work) unless that bar has ended.
    private func retire(src: URL, landedAt: URL, match: RetireMatch, owner: URL?) async throws {
        let identical = match == .bytes
        progress.currentName = src.lastPathComponent
        while !exists(landedAt) {
            guard let owner, let claims = sharedTargets, !claims.hasFinished(owner) else {
                skip(src, "Left in the source: the “\(landedAt.lastPathComponent)” it was \(match == .none ? "giving way to" : "being merged with") never arrived.")
                return
            }
            progress.currentName = "Waiting for “\(landedAt.lastPathComponent)” from another bar…"
            await report()
            try await gate()
            try? await Task.sleep(for: .seconds(2))
        }
        if match == .audioTwin {
            try await retireAudioTwin(src: src, landedAt: landedAt)
        } else if identical {
            // Compared again here, after it landed: this deletes, so nothing is assumed.
            guard try await bytesEqual(src, landedAt) else {
                throw EngineError(message: "“\(src.lastPathComponent)” is not byte-for-byte identical to the one that arrived, so it was NOT removed from the source.")
            }
            mergeMetadata(from: src, into: landedAt)
            try fm.removeItem(at: src)
            log.entries.append(.removedDuplicate(path: src.path, keptAt: landedAt.path))
            mergedCount += 1
        } else {
            if !isLocalVolume(src) { retiredToTrash = false }
            try dispose(src)
            retiredCount += 1
        }
        await report()
    }

    /// Build 88 — two MP3s holding the same music, differing only in their tags. His words:
    /// *"the larger one probably has meta data"* · *"it becomes, mergge all meta data"*.
    ///
    /// **The larger file is the one kept**, because the extra bytes ARE the metadata, and the
    /// other file's tags are folded into it so nothing is lost from either side. When the
    /// larger one is the source, it takes the target's place — the copy that already landed is
    /// the one removed.
    ///
    /// ⛔ The audio is compared again HERE, after the file landed, exactly as the byte-for-byte
    /// path does: this step deletes, so nothing is taken on trust from the planning phase.
    private func retireAudioTwin(src: URL, landedAt: URL) async throws {
        guard try await AudioContentCompare.sameAudio(src, landedAt) else {
            throw EngineError(message: "“\(src.lastPathComponent)” no longer holds the same audio as the one that arrived, so it was NOT removed from the source.")
        }
        let srcSize = facts(src).size, landedSize = facts(landedAt).size
        if srcSize > landedSize {
            // The source carries the fuller tags: it becomes the copy in the target.
            mergeAudioTags(from: landedAt, into: src)
            mergeMetadata(from: landedAt, into: src)
            let holding = landedAt.deletingLastPathComponent()
                .appendingPathComponent(".\(landedAt.lastPathComponent).ngc-twin-\(UUID().uuidString.prefix(8))")
            try fm.moveItem(at: landedAt, to: holding)
            do {
                try fm.copyItem(at: src, to: landedAt)
            } catch {
                try? fm.moveItem(at: holding, to: landedAt)   // put the landed copy back
                throw error
            }
            var arrivedIntact = try await AudioContentCompare.sameAudio(src, landedAt)
            if !arrivedIntact { arrivedIntact = try await bytesEqual(src, landedAt) }
            guard arrivedIntact else {
                try? fm.removeItem(at: landedAt)
                try? fm.moveItem(at: holding, to: landedAt)
                throw EngineError(message: "“\(src.lastPathComponent)” could not be verified in the target, so nothing was removed.")
            }
            try? fm.removeItem(at: holding)
            try fm.removeItem(at: src)
        } else {
            mergeAudioTags(from: src, into: landedAt)
            mergeMetadata(from: src, into: landedAt)
            try fm.removeItem(at: src)
        }
        log.entries.append(.removedDuplicate(path: src.path, keptAt: landedAt.path))
        mergedCount += 1
    }

    /// The tag union itself: every field the kept file is missing is taken from the other, and
    /// its own values are never overwritten. Artwork counts as a field. MP3 only — an MP4
    /// container (.m4a, .m4p, .m4r) never reaches here, because its audio is never compared
    /// apart from its tags.
    private func mergeAudioTags(from other: URL, into kept: URL) {
        guard AudioContentCompare.isMP3(kept), AudioContentCompare.isMP3(other) else { return }
        let mine = AudioTags.read(kept), theirs = AudioTags.read(other)
        guard let merged = AudioTags.fillingGaps(in: mine, from: theirs) else { return }
        do {
            try ID3TagWriter.write(metadata: merged, to: kept)
        } catch {
            summary.notes.append(.init(path: kept.path,
                reason: "Kept as the fuller copy, but the other file's tags could not be written into it: \(error.localizedDescription)"))
        }
    }

    /// His "merge the metadata but keeep one file": Finder tags from both, and the earlier
    /// creation date. The contents are already identical.
    private func mergeMetadata(from src: URL, into kept: URL) {
        let keys: Set<URLResourceKey> = [.tagNamesKey, .creationDateKey]
        guard let a = try? src.resourceValues(forKeys: keys),
              let b = try? kept.resourceValues(forKeys: keys) else { return }
        let before = b.tagNames ?? []
        let tags = Array(Set(before).union(a.tagNames ?? [])).sorted()
        if tags.count != before.count {
            try? (kept as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        if let ca = a.creationDate, let cb = b.creationDate, ca < cb {
            var values = URLResourceValues()
            values.creationDate = ca
            var k = kept
            try? k.setResourceValues(values)
        }
    }

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
        // Build 101: a quarantined file was moved — to the clash folder instead of its
        // intended name — so undo puts it back exactly the way it puts a move back. Mapping it
        // here rather than adding a second copy of the restore block keeps one path to test.
        let entries = undone.entries.reversed().map { entry -> LogEntry in
            if case let .quarantined(from, to, _) = entry { return .moved(from: from, to: to) }
            return entry
        }
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
                // Build 101: mapped to .moved above, so it never arrives here. Named rather
                // than swept into a `default:` so that adding a future entry still fails to
                // compile instead of being silently ignored by undo.
                case .quarantined:
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
            pausedSeconds += Date().timeIntervalSince(pausedAt)
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

    // Plan 8.4 — time left from TWO measured rates, not one.
    //
    // A transfer costs a fixed amount per file (open, create, fsync, rename, delete — each a
    // round trip on a network drive) PLUS time per byte. The old estimate divided the bytes
    // left by bytes-per-second overall, so on the 536,716 tiny files of 2026-09-18 it charged
    // every file's fixed cost as if it were data and said 174,121 hours; the measured truth
    // was about four files a second. Here the time spent actually moving data is timed on its
    // own, the rest is per-file overhead, and each is applied to what is left of its kind.
    //
    // ⚠️ SECOND FAULT, 2026-09-18 (build 60 → 61). Timing EVERY read as "data" still charged
    // the per-file round trip to the data rate: a 3 KB journal file's single read takes as
    // long as its open and fsync, so on the 9,209 tiny files at the top of a Photos library
    // the data rate came out at 459 bytes/s and the estimate said 357 hours for a job of
    // about two. Now only LARGE reads (≥ 1 MiB) teach the data rate; small files' time is
    // per-file overhead, which is what it is. Until a large read has been timed there is no
    // honest data rate, so the estimate is withheld ("estimating time left…").
    //
    // ⚠️ THIRD FAULT, 2026-09-18 (build 63 → 64). His screen: "about 4d 11h 25m left" on a
    // 10.79 GB move running at 6.5 MB/s — about 45 minutes. Only the READS were timed as data;
    // everything else in a big file — the flush to the drive, the read-back's open, the delete
    // — was charged as per-file overhead. The first 24 files of that library were multi-GB
    // Spotlight indexes, so "overhead" came out at minutes a file × 46,018 files = days.
    // Now each FILE is timed whole, pauses taken out: a large file's whole time teaches the
    // data rate, a small file's whole time teaches the per-file cost. Folder work and time
    // spent waiting on a question are in neither.
    private var dataSeconds: Double = 0
    private var dataBytes: Int64 = 0
    private var smallSeconds: Double = 0
    private var smallFiles = 0
    private var pausedSeconds: Double = 0
    private static let largeRead = 1 << 20

    private func noteFileTime(_ op: Op, seconds: Double) {
        let size: Int64, counted: Int64
        switch op {
        case let .transfer(src, _, move, _, s):
            size = s
            counted = (move && sameVolume(src)) ? 0 : (move ? s * 2 : s)
        case let .extract(_, _, move, format, _, s):
            size = s
            counted = (move && format == .original) ? s * 2 : s
        case .renameMove:
            size = 0; counted = 0
        default:
            return
        }
        let t = max(0, seconds)
        if size >= Int64(Self.largeRead) && counted > 0 {
            dataSeconds += t
            dataBytes += counted
        } else {
            smallSeconds += t
            smallFiles += 1
        }
    }

    private func estimate() -> Double? {
        guard progress.phase == .transferring, let since = runningSince else { return nil }
        let elapsed = Date().timeIntervalSince(since)
        guard elapsed > 5, progress.filesDone >= 10 else { return nil }
        let filesLeft = Double(max(0, progress.filesTotal - progress.filesDone))
        let bytesLeft = Double(max(0, progress.bytesTotal - progress.bytesDone))
        // A large file's own overhead is already inside the data rate; charging it again per
        // file overstates a little, never by days. An Undo is renames only and is not timed
        // file by file, so it keeps the plain wall-clock rate.
        let perFile: Double
        if smallFiles > 0 { perFile = smallSeconds / Double(smallFiles) }
        else if dataBytes == 0 { perFile = elapsed / Double(progress.filesDone) }
        else { perFile = 0 }
        var seconds = perFile * filesLeft
        if bytesLeft > Double(Self.largeRead) * Double(max(1, Int(filesLeft))) {
            // Real data still to come — needs a rate measured on whole large files.
            guard dataSeconds > 0.2, dataBytes > 0 else { return nil }
            seconds += bytesLeft / (Double(dataBytes) / dataSeconds)
        }
        return seconds
    }

    // His report on build 60: *"it fluctuates days 1 hour 50 minutes to 22 minutes."* A raw
    // estimate jumps whenever the mix of files changes. What he sees is steadied: a new reading
    // is re-computed at most every 5 seconds and moves the shown figure only a quarter of the
    // way toward it, so one odd stretch of files cannot swing it from days to minutes.
    private var shownEstimate: Double?
    private var lastEstimateAt = Date.distantPast

    private func steadiedEstimate(_ now: Date) -> Double? {
        guard now.timeIntervalSince(lastEstimateAt) >= 5 || shownEstimate == nil else { return shownEstimate }
        let sinceLast = lastEstimateAt == .distantPast ? 0 : now.timeIntervalSince(lastEstimateAt)
        lastEstimateAt = now
        guard let raw = estimate() else { return shownEstimate }
        if let shown = shownEstimate {
            // Count the shown figure down by the time that passed, then ease toward the new reading.
            shownEstimate = max(0, 0.75 * max(0, shown - sinceLast) + 0.25 * raw)
        } else {
            shownEstimate = raw
        }
        return shownEstimate
    }

    private func report(force: Bool = false) async {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.2 else { return }
        lastReport = now
        progress.secondsLeft = steadiedEstimate(now)
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
        case let .transfer(_, d, _, _, _), let .makeFolder(_, d), let .finishFolder(_, d), let .renameMove(_, d),
             let .extract(_, d, _, _, _, _):
            dst = d
        default:
            return nil
        }
        return failedFolders.contains { dst.path.hasPrefix($0 + "/") || dst.path == $0 } ? dst : nil
    }

    /// What a travelling step carries: source, destination, and whether the source leaves.
    /// Library originals (Extract) never leave through here.
    private func carried(_ op: Op) -> (URL, URL, Bool)? {
        switch op {
        case let .transfer(s, d, m, _, _): return (s, d, m)
        case let .renameMove(s, d): return (s, d, true)
        case let .extract(s, d, _, _, _, _): return (s, d, false)
        default: return nil
        }
    }

    private func pathOf(_ op: Op) -> String {
        switch op {
        case let .renameMove(s, _), let .makeFolder(s, _), let .finishFolder(s, _),
             let .transfer(s, _, _, _, _), let .removeDuplicate(s, _), let .extract(s, _, _, _, _, _),
             let .retire(s, _, _, _):
            return s.path
        case let .dispose(u), let .discardSourceDSStore(u), let .removeSourceFolderIfEmpty(u):
            return u.path
        }
    }

    /// `claimant` also claims the new name among sibling bars (build 76).
    /// Build 101 — where a name clash is parked, made only when something actually needs it.
    /// It sits in the target so it travels with the files it belongs to, and it is named to
    /// say what it is on sight, in Finder, without this app.
    private func quarantineFolder() throws -> URL {
        let home = targetDir.appendingPathComponent("_Name clashes — needs your attention")
        if !exists(home) {
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            log.entries.append(.createdFolder(path: home.path))
        }
        return home
    }

    private func uniqueName(for dst: URL, claimant: URL? = nil) -> URL {
        let folder = dst.deletingLastPathComponent()
        let ext = dst.pathExtension
        let base = ext.isEmpty ? dst.lastPathComponent : dst.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !exists(candidate) && !plannedTargets.contains(candidate.path)
                && (claimant.flatMap { sharedTargets?.claim(candidate.path, for: $0) } == nil) {
                if let c = claimant, sharedTargets != nil { claimedSources.insert(c.path) }
                plannedTargets.insert(candidate.path)
                return candidate
            }
            n += 1
        }
    }
    private var plannedTargets = Set<String>()

    /// A folder's own FILES first, then its subfolders — each group in Finder's order
    /// (2 before 10). His ask, 2026-09-18: "go in alpha numeric order for transferring the
    /// within folder to folder files this way i can see actual progress." Files-then-folders
    /// is what makes one folder's files contiguous; mixed together, a folder's files were
    /// split around every subfolder that sorted between them. Libraries count as files here —
    /// they travel as one item.
    private func children(of url: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [])) ?? []
        let byName: (URL, URL) -> Bool = {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        var files: [URL] = [], folders: [URL] = []
        for item in items {
            if isPlainFolder(facts(item)) { folders.append(item) } else { files.append(item) }
        }
        return files.sorted(by: byName) + folders.sorted(by: byName)
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
