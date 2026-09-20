//
//  DuplicateFinder.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 19
//
//  Build 92 — his ask: *"they are different names but are the exact same image"* → find the
//  duplicates a clash popup can never see.
//
//  ⛔ A clash is only noticed when two files would land under the SAME NAME. Two copies of one
//  photograph called `IMG_0042.jpg` and `2020-09-18 11.56.12.jpg` never meet, so both arrive
//  and the media folder quietly holds the same picture twice.
//
//  This sweep goes the other way round: it ignores names entirely and compares contents.
//
//  **How it avoids reading a terabyte.** Files are grouped by SIZE first — two files of
//  different sizes cannot be identical, and that test is free. Only inside a group of equal
//  size is anything read, and then the read is a streamed byte comparison against the group's
//  first member. A folder of 90,000 photographs with no duplicates reads almost nothing.
//

import Foundation

@MainActor
@Observable
final class DuplicateFinder {

    struct Group: Identifiable {
        let id = UUID()
        /// The copy that stays. See `keeper(of:)` for the rule and why.
        var keep: URL
        /// The copies that would be removed — never the keeper.
        var duplicates: [URL]
        var size: Int64
        var wasted: Int64 { size * Int64(duplicates.count) }
    }

    private(set) var groups: [Group] = []
    private(set) var isScanning = false
    private(set) var checkedCount = 0
    private(set) var comparedCount = 0
    private(set) var currentPath = ""
    /// Files that could not be read while comparing — named, never silently dropped.
    private(set) var unreadable: [URL] = []

    var duplicateCount: Int { groups.reduce(0) { $0 + $1.duplicates.count } }
    var wastedBytes: Int64 { groups.reduce(0) { $0 + $1.wasted } }

    private var cancelled = false
    func cancel() { cancelled = true }

    /// Walk `roots`, group by size, then byte-compare inside each group.
    /// `preferInside` is the folder whose copy is kept when a group spans folders — the media
    /// library, so a sweep never empties the library and leaves the loose copy behind.
    func scan(roots: [URL], preferInside: URL?, extensions: Set<String>) async {
        isScanning = true
        cancelled = false
        groups = []
        checkedCount = 0
        comparedCount = 0
        unreadable = []

        // 1. Walk, collecting sizes only.
        var bySize: [Int64: [URL]] = [:]
        for root in roots {
            guard !cancelled else { break }
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true })
            while let url = enumerator?.nextObject() as? URL {
                if cancelled { break }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true { continue }
                let ext = url.pathExtension.lowercased()
                guard extensions.isEmpty || extensions.contains(ext) else { continue }
                let size = Int64(values?.fileSize ?? 0)
                guard size > 0 else { continue }           // empty files are not "duplicates"
                bySize[size, default: []].append(url)
                checkedCount += 1
                if checkedCount % 200 == 0 {
                    currentPath = url.path
                    await Task.yield()
                }
            }
        }

        // 2. Only same-size files can match, so only those are read.
        for (size, files) in bySize where files.count > 1 {
            if cancelled { break }
            var remaining = files
            while remaining.count > 1 {
                if cancelled { break }
                let first = remaining.removeFirst()
                var same: [URL] = []
                var still: [URL] = []
                for other in remaining {
                    if cancelled { break }
                    currentPath = other.path
                    comparedCount += 1
                    switch await Self.equal(first, other) {
                    case .some(true): same.append(other)
                    case .some(false): still.append(other)
                    case nil:
                        unreadable.append(other)
                    }
                    await Task.yield()
                }
                if !same.isEmpty {
                    let all = [first] + same
                    let keep = Self.keeper(of: all, preferInside: preferInside)
                    groups.append(Group(keep: keep,
                                        duplicates: all.filter { $0 != keep },
                                        size: size))
                }
                remaining = still
            }
        }

        currentPath = ""
        isScanning = false
    }

    /// Which copy stays, in his terms: the one already in the media library if any is, then
    /// the one nearest the top of the tree, then the oldest. **Stated in the sheet** — a sweep
    /// that deletes without saying which copy it kept is not something to run on a library.
    static func keeper(of files: [URL], preferInside: URL?) -> URL {
        func inLibrary(_ u: URL) -> Bool {
            guard let p = preferInside?.standardizedFileURL.path else { return false }
            return u.standardizedFileURL.path.hasPrefix(p + "/")
        }
        func created(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
        }
        return files.sorted { a, b in
            if inLibrary(a) != inLibrary(b) { return inLibrary(a) }
            let da = a.pathComponents.count, db = b.pathComponents.count
            if da != db { return da < db }
            let ca = created(a), cb = created(b)
            if ca != cb { return ca < cb }
            return a.path < b.path
        }[0]
    }

    /// Streamed byte comparison. Nil when either file cannot be read — which is NOT "different"
    /// and NOT "the same": it is unknown, and an unknown must never lead to a deletion.
    nonisolated static func equal(_ a: URL, _ b: URL) async -> Bool? {
        let fa = open(a.path, O_RDONLY), fb = open(b.path, O_RDONLY)
        defer { if fa >= 0 { close(fa) }; if fb >= 0 { close(fb) } }
        guard fa >= 0, fb >= 0 else { return nil }
        let chunk = 1 << 20
        let ba = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        let bb = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { ba.deallocate(); bb.deallocate() }
        while true {
            let na = readFully(fa, ba, chunk), nb = readFully(fb, bb, chunk)
            if na < 0 || nb < 0 { return nil }
            if na != nb { return false }
            if na == 0 { return true }
            if memcmp(ba, bb, na) != 0 { return false }
        }
    }

    private nonisolated static func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var total = 0
        while total < count {
            let n = read(fd, buffer + total, count - total)
            if n < 0 { if errno == EINTR { continue }; return -1 }
            if n == 0 { break }
            total += n
        }
        return total
    }
}
