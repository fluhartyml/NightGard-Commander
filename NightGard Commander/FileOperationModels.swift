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

/// Plan section 7. A normal Copy/Move keeps the folder tree; the other two flatten it.
nonisolated enum FileOpMode: Sendable, Equatable {
    case standard
    /// 7.1 — every file anywhere under the source goes straight into the target folder.
    case flatten
    /// 7.6 — the originals inside a Photos library, under their REAL names and dates (7.7),
    /// optionally converted (7.9). Copy leaves the library as it was; Move empties it.
    case extract(ExtractFormat)
    /// Scan for Media (build 68): each scanned file goes into its own subfolder of the
    /// target, Photos libraries come out through Extract, and photos are only copied.
    case media(MediaPlan)

    var title: String {
        switch self {
        case .standard: return ""
        case .flatten: return "Flatten"
        case .extract: return "Extract"
        case .media: return "Media"
        }
    }
}

/// What Scan for Media hands the engine. Paths are compared as strings, so every one is
/// a standardized file path.
///
/// ⛔ PHOTOS ARE COPIED, NEVER MOVED — his rule, 2026-09-19: "photos copied not moved".
/// `copyOnly` holds every photo, whatever action was chosen.
/// ⭐ A PHOTOS LIBRARY COMES OUT THROUGH ITS OWN DATABASE — his rule, same morning: "the
/// photos should be copied using the enclosing photolibrarys database to reinstate name
/// and metadata". So a library is not walked file by file; it is Extracted.
nonisolated struct MediaPlan: Sendable, Equatable {
    /// Source file path → subfolder of the target it goes in ("" = the target itself).
    var folders: [String: String] = [:]
    /// Source paths that are copied even when the action is Move.
    var copyOnly: Set<String> = []
    /// Photos library path → subfolder of the target its photos are extracted into.
    var libraries: [String: String] = [:]

    /// The four shelvings Scan for Media offers.
    enum Sorting: Sendable { case flatten, byExtension, byType, byTypeThenExtension }

    /// Where everything goes. One place, used by the dialog AND the tests.
    ///
    /// ⭐ PHOTOS KEEP THEIR FOLDER — his rule, 2026-09-19: "if the photos are loose the
    /// containing folder should be copied too ( that would mean the [name] of the
    /// photolibrary in folder form and not the actual photolibrary". So a loose photo
    /// lands inside a folder named like the one it came from, and a library's photos land
    /// in a PLAIN folder named after the library ("2025 09 11", not a .photoslibrary).
    /// Audio and video are shelved as before.
    static func build(files: [URL], libraries: [URL], sorting: Sorting) -> MediaPlan {
        var plan = MediaPlan()
        func shelf(_ type: MediaScanner.MediaType, _ ext: String) -> String {
            switch sorting {
            case .flatten: return ""
            case .byExtension: return ext
            case .byType: return type.rawValue
            case .byTypeThenExtension: return "\(type.rawValue)/\(ext)"
            }
        }
        func join(_ a: String, _ b: String) -> String {
            a.isEmpty ? b : (b.isEmpty ? a : a + "/" + b)
        }
        // Photos are shelved by FOLDER, never by extension — his reason, 2026-09-19:
        // "there are usually so many photos vs other media types and they usually have
        // obscure names" — the folder is what tells them apart. A library's folder
        // also mixes JPG, HEIC and Live Photo videos; an extension layer would scatter it,
        // and loose photos follow the same rule so the two never disagree.
        let photoShelf: String
        switch sorting {
        case .flatten, .byExtension: photoShelf = ""
        case .byType, .byTypeThenExtension: photoShelf = MediaScanner.MediaType.photo.rawValue
        }
        for url in files {
            let path = url.standardizedFileURL.path
            let type = MediaScanner.mediaType(for: url)
            if type == .photo {
                plan.copyOnly.insert(path)
                let parent = url.deletingLastPathComponent().standardizedFileURL
                plan.folders[path] = parent.path == "/" ? photoShelf : join(photoShelf, parent.lastPathComponent)
            } else {
                plan.folders[path] = shelf(type, url.pathExtension.uppercased())
            }
        }
        for lib in libraries {
            let name = lib.pathExtension.lowercased() == "photoslibrary"
                ? lib.deletingPathExtension().lastPathComponent : lib.lastPathComponent
            plan.libraries[lib.standardizedFileURL.path] = join(photoShelf, name)
        }
        return plan
    }
}

/// 7.9 — his ask: "i would choose jpg but maybe a printshop uses png or another format".
nonisolated enum ExtractFormat: Sendable, Equatable, Hashable {
    /// Exactly as stored (usually HEIC). Fastest, nothing lost.
    case original
    /// Quality 0…1.
    case jpeg(quality: Double)
    case png
    case tiff

    var fileExtension: String? {
        switch self {
        case .original: return nil
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }

    var label: String {
        switch self {
        case .original: return "Original"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        }
    }
}

/// How much a folder holds — shown on both cards of the folder question (plan 6.2), so a
/// partial copy (750 items, 191 KB) is obvious next to the complete one (32,808 items,
/// 6.2 GB). The date alone called the partial one "newer" and said nothing about which was
/// complete.
nonisolated struct FolderTally: Sendable {
    let items: Int
    let bytes: Int64
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
    /// Plan 6.2. Nil only if counting was impossible (e.g. unreadable).
    var sourceTally: FolderTally? = nil
    var targetTally: FolderTally? = nil
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
    /// Flatten and Extract (7.2): only Skip or Keep Both. His words: "skip or keep both and
    /// apply to all checkbox". Nothing already there is ever replaced by a flatten.
    var flattenOnly = false
    /// Two INCOMING files with the same name (a flatten brings IMG_0001.jpg in from many
    /// folders) — the "already here" side is another source file, not something in the target.
    var targetIsIncoming = false

    var isIdentical: Bool { sameness != .differs }
}

nonisolated enum FileChoice: Sendable {
    case replace, skip, keepBoth, replaceIfNewer, replaceIfSizeDiffers
    /// Identical files on a Move only: the copy already in the target stays, the source
    /// duplicate is removed. Asked, never assumed (his 3.6).
    case removeFromSource
    case cancel
}

/// 7.5 — after a Flatten Move. His words: "leave the folders but ask the user what to do."
/// Leave is the default. Only folders left completely empty are offered.
nonisolated struct EmptyFoldersQuestion: Sendable {
    let folders: [URL]
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
    /// What was copied or moved, and where to — shown on the summary. His question on
    /// 2026-09-18, with three jobs running: "its done moving but what folder to what folder
    /// was moved?" The popup said "15 items moved" and nothing else.
    var sources: [String] = []
    var target: String?
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
    /// ⚠️ THE INODES ARE LOAD-BEARING. Without them a file that was DELETED AND RE-CREATED
    /// with the same size and date still matched its old record and was called identical
    /// without being read — caught by the self-test on 2026-09-18 (build 60), where the test
    /// re-creates the same files on every run. A re-created file gets a new inode.
    struct Entry: Equatable {
        let sourcePath: String
        let size: Int64
        let sourceModified: Double
        let targetModified: Double
        let sourceInode: UInt64
        let targetInode: UInt64
    }

    private static func inode(_ url: URL) -> UInt64? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? UInt64(st.st_ino) : nil
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
              let si = Self.inode(source.url), let ti = Self.inode(target.url),
              let e = load()[target.url.path] else { return false }
        return e == Entry(sourcePath: source.url.path, size: source.size,
                          sourceModified: Self.round(s), targetModified: Self.round(t),
                          sourceInode: si, targetInode: ti)
            && target.size == source.size
    }

    func record(source: FileFacts, target: FileFacts) {
        guard let s = source.modified, let t = target.modified, source.size == target.size,
              let si = Self.inode(source.url), let ti = Self.inode(target.url) else { return }
        let e = Entry(sourcePath: source.url.path, size: source.size,
                      sourceModified: Self.round(s), targetModified: Self.round(t),
                      sourceInode: si, targetInode: ti)
        lock.lock(); defer { lock.unlock() }
        _ = loadLocked()
        entries?[target.url.path] = e
        // Tabs and newlines cannot be written into a line-per-pair file; such names are
        // simply not remembered (they are compared again next time, which is still correct).
        let fields = [target.url.path, e.sourcePath]
        guard !fields.contains(where: { $0.contains("\t") || $0.contains("\n") }) else { return }
        let line = "\(target.url.path)\t\(e.sourcePath)\t\(e.size)\t\(e.sourceModified)\t\(e.targetModified)\t\(e.sourceInode)\t\(e.targetInode)\n"
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
                // Lines from build 59 (five fields, no inodes) are ignored: those pairs are
                // simply compared again once, which is always safe.
                guard f.count == 7, let size = Int64(f[2]), let sm = Double(f[3]), let tm = Double(f[4]),
                      let si = UInt64(f[5]), let ti = UInt64(f[6]) else { continue }
                map[String(f[0])] = Entry(sourcePath: String(f[1]), size: size, sourceModified: sm,
                                          targetModified: tm, sourceInode: si, targetInode: ti)
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
