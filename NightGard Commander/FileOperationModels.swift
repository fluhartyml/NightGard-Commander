//
//  FileOperationModels.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 18
//
//  The vocabulary of a copy or move: what the engine asks, what Michael answers, what
//  it reports back. No UI and no actor in here, so the engine can use all of it off the
//  main thread.
//
//  ⭐ SOURCE AND TARGET, NEVER LEFT AND RIGHT. His rule, 2026-09-18: "DO NOT USE LEFT OR
//  RIGHT SIDE AGNOSTIC." The source is what is moving; the target is where it goes.
//
//  Spec: NIGHTGARD-COMMANDER-NOTES.md › MOVE / COPY COLLISIONS, and the plan he locked
//  line by line (apartment Workshop/NG-Commander-File-Ops-Plan-DRAFT-2026-09-18.html).
//

import Foundation

nonisolated enum FileOpKind: String, Sendable, Codable {
    case copy, move

    var verb: String { self == .copy ? "Copy" : "Move" }
    var gerund: String { self == .copy ? "Copying" : "Moving" }
    var pastTense: String { self == .copy ? "copied" : "moved" }
}

/// What the engine knows about one side of a collision.
nonisolated struct FileFacts: Sendable {
    let url: URL
    let isDirectory: Bool
    let isPackage: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date?

    var name: String { url.lastPathComponent }
}

// MARK: - Questions

/// "A folder with this name is already there." Merge · Replace · Skip · Cancel.
nonisolated struct FolderQuestion: Sendable {
    let kind: FileOpKind
    let source: FileFacts
    let target: FileFacts
    /// Other folder conflicts still to come — what "Apply to all" would cover.
    let remainingLikeThis: Int
}

nonisolated enum FolderChoice: Sendable { case merge, replace, skip, cancel }

/// The second confirm on a folder Replace (his 5.2): names the folder and exactly what
/// goes. Never skipped — Replace removes a whole tree.
nonisolated struct ReplaceConfirm: Sendable {
    let targets: [URL]
    let fileCount: Int
    let byteCount: Int64
    /// False on a network drive: there is no Trash, so it is deleted immediately (5.3).
    let goesToTrash: Bool
}

/// Two files (or a package, or a file meeting a folder) with the same name.
nonisolated struct FileQuestion: Sendable {
    enum Sameness: Sendable {
        case differs
        /// Not used for new questions any more — every same-size pair is compared byte for
        /// byte (see FileOperationEngine.compare). Kept so the popup can still say exactly
        /// what was checked if a cheaper test is ever reintroduced.
        case sameSizeAndDate
        /// Same size and every byte compared equal.
        case sameContents
        /// Commander itself wrote or byte-compared this pair earlier, and neither file's size
        /// or date has changed since — so it is not read again (plan 8.5: a resumed Copy must
        /// not re-read everything it already copied over the network).
        case verifiedEarlier
    }

    let kind: FileOpKind
    let source: FileFacts
    let target: FileFacts
    let sameness: Sameness
    /// Packages and file-vs-folder clashes offer only Replace · Skip · Keep Both (3.7).
    let unitOnly: Bool
    let remainingLikeThis: Int
    /// False on a network drive — the file already there is deleted immediately.
    let targetGoesToTrash: Bool

    var isIdentical: Bool { sameness != .differs }
}

nonisolated enum FileChoice: Sendable {
    case replace, skip, keepBoth, replaceIfNewer, replaceIfSizeDiffers
    /// Identical files on a Move only: the copy already in the target stays, the source
    /// duplicate is removed. Asked, never assumed (his 3.6).
    case removeFromSource
    case cancel
}

nonisolated struct ErrorQuestion: Sendable {
    let path: String
    let message: String
}

nonisolated enum ErrorChoice: Sendable { case retry, skip, skipAll, cancel }

nonisolated struct Answer<Choice: Sendable>: Sendable {
    let choice: Choice
    let applyToAll: Bool
}

// MARK: - Progress

nonisolated struct FileOpProgress: Sendable {
    /// `.buildingFolders` is plan 8.2: the whole target folder tree is made before any file
    /// moves, so a stopped transfer can be picked up by running it again (8.3).
    enum Phase: Sendable { case checking, buildingFolders, transferring, finishing }

    var phase: Phase = .checking
    var currentName: String = ""
    var itemsChecked: Int = 0
    var filesDone: Int = 0
    var filesTotal: Int = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var bytesPerSecond: Double = 0
    var isPaused: Bool = false

    // Plan 8.4 — progress by folder. "Folder 12 of 340 — name — file 88 of 412".
    var foldersMade: Int = 0
    var foldersToMake: Int = 0
    var folderIndex: Int = 0
    var folderCount: Int = 0
    /// Relative to the target, e.g. "2025 SEP 02 Photos/2019".
    var folderName: String = ""
    var fileInFolder: Int = 0
    var filesInFolder: Int = 0

    /// Set by the engine from two measured rates (see FileOperationEngine.estimate). The
    /// old figure divided bytes by bytes-per-second alone, and on 536,716 tiny files it said
    /// 174,121 hours — every file's fixed cost was being charged as if it were data.
    var secondsLeft: Double?

    var fraction: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal))
                       : (filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0)
    }
}

// MARK: - Summary and log

nonisolated struct FileOpSummary: Sendable {
    struct Item: Sendable, Identifiable {
        let id = UUID()
        let path: String
        let reason: String
    }

    let kind: FileOpKind
    var cancelled = false
    var filesTransferred = 0
    var bytesTransferred: Int64 = 0
    var skipped: [Item] = []
    var failed: [Item] = []
    /// Things he should know that are not failures — e.g. copied instead of moved because
    /// it lives inside a library an app is using right now.
    var notes: [Item] = []
    var logURL: URL?
    var canUndo = false
    var wasUndo = false
}

/// One line of the operation log. Written to disk so a whole Move can be undone later —
/// the old undo covered a single file only.
nonisolated enum LogEntry: Codable, Sendable {
    case moved(from: String, to: String)
    case copied(from: String, to: String)
    case trashed(original: String, trashPath: String)
    case deleted(original: String)
    /// An identical duplicate removed from the source (he chose it; plan 3.6). The copy
    /// that was already in the target is where the content lives now.
    case removedDuplicate(path: String, keptAt: String)
    case createdFolder(path: String)
    case removedSourceFolder(path: String)
    case skipped(path: String, reason: String)
    case failed(path: String, message: String)
}

nonisolated struct OperationLog: Codable, Sendable {
    var id = UUID()
    var date = Date()
    var kind: FileOpKind
    var sources: [String]
    var target: String
    var entries: [LogEntry] = []
    var cancelled = false
    var undone = false

    static var folder: URL {
        // The engine's self-test points this at a scratch folder so it never writes into
        // the app's real operation logs.
        if let override = ProcessInfo.processInfo.environment["NGC_OPLOG_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NightGard Commander/Operations", isDirectory: true)
    }
}

/// Plan 8.5 — pairs Commander has already proven equal: a file it copied (the size read
/// back matched) or a pair it compared byte for byte. Keyed by the TARGET path; valid only
/// while the source path, both sizes and both dates are exactly what they were. A resumed
/// Copy then skips re-reading everything it already put on a network drive.
///
/// Append-only text, one line per pair, so recording costs one short write and a crash
/// loses at most the last line. Later lines win on load.
nonisolated final class VerifiedCopies: @unchecked Sendable {
    struct Entry: Equatable {
        let sourcePath: String
        let size: Int64
        let sourceModified: Double
        let targetModified: Double
    }

    static var file: URL {
        if let override = ProcessInfo.processInfo.environment["NGC_OPLOG_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("verified-copies.tsv")
        }
        return OperationLog.folder.deletingLastPathComponent().appendingPathComponent("Verified copies.tsv")
    }

    private let lock = NSLock()
    private var entries: [String: Entry]?

    func matches(source: FileFacts, target: FileFacts) -> Bool {
        guard let s = source.modified, let t = target.modified,
              let e = load()[target.url.path] else { return false }
        return e == Entry(sourcePath: source.url.path, size: source.size,
                          sourceModified: Self.round(s), targetModified: Self.round(t))
            && target.size == source.size
    }

    func record(source: FileFacts, target: FileFacts) {
        guard let s = source.modified, let t = target.modified, source.size == target.size else { return }
        let e = Entry(sourcePath: source.url.path, size: source.size,
                      sourceModified: Self.round(s), targetModified: Self.round(t))
        lock.lock(); defer { lock.unlock() }
        _ = loadLocked()
        entries?[target.url.path] = e
        // Tabs and newlines cannot be written into a line-per-pair file; such names are
        // simply not remembered (they are compared again next time, which is still correct).
        let fields = [target.url.path, e.sourcePath]
        guard !fields.contains(where: { $0.contains("\t") || $0.contains("\n") }) else { return }
        let line = "\(target.url.path)\t\(e.sourcePath)\t\(e.size)\t\(e.sourceModified)\t\(e.targetModified)\n"
        let url = Self.file
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func load() -> [String: Entry] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> [String: Entry] {
        if let entries { return entries }
        var map: [String: Entry] = [:]
        if let text = try? String(contentsOf: Self.file, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard f.count == 5, let size = Int64(f[2]), let sm = Double(f[3]), let tm = Double(f[4]) else { continue }
                map[String(f[0])] = Entry(sourcePath: String(f[1]), size: size, sourceModified: sm, targetModified: tm)
            }
        }
        entries = map
        return map
    }

    /// Milliseconds: SMB and APFS store different precisions, and a date read back through
    /// a network share can differ below that.
    private static func round(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() / 1000 }
}

/// Pause and Cancel, readable from the engine's background task without waiting on it.
nonisolated final class FileOpControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _paused = false
    private var _cancelled = false

    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return _paused }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    func setPaused(_ value: Bool) { lock.lock(); _paused = value; lock.unlock() }
    func cancel() { lock.lock(); _cancelled = true; _paused = false; lock.unlock() }
}

nonisolated struct FileOpCancelled: Error {}
