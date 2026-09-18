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
    enum Phase: Sendable { case checking, transferring, finishing }

    var phase: Phase = .checking
    var currentName: String = ""
    var itemsChecked: Int = 0
    var filesDone: Int = 0
    var filesTotal: Int = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var bytesPerSecond: Double = 0
    var isPaused: Bool = false

    var fraction: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal))
                       : (filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0)
    }

    var secondsLeft: Double? {
        guard bytesPerSecond > 1, bytesTotal > bytesDone else { return nil }
        return Double(bytesTotal - bytesDone) / bytesPerSecond
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
