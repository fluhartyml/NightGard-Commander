//
//  MediaScanner.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 13 1205
//
//  ── BUILD 68 (2026-09-19) — HIS REPORT, AND WHAT CHANGED ───────────────────────
//  "i wanted to just select a drive and have it scan the whole drive for media but the
//  selected folder aparmtly didnt get scanned" — and the window beach-balled.
//
//  1. PHOTOS ARE MEDIA. The scanner only knew audio and video, so a folder of pictures
//     came back empty and looked skipped.
//  2. THE WALK IS OFF THE MAIN THREAD. It enumerated on the main actor, one file at a
//     time — over the network, a whole drive froze the window. The walk now runs
//     `@concurrent` and hands batches back to the screen.
//  3. IT DOES NOT WALK INTO PACKAGES OR HIDDEN FOLDERS. A whole-drive scan would
//     otherwise pour out the thousands of thumbnails inside every Photos library, and
//     `.Trashes` / `.Spotlight-V100`. A Photos library's originals come out through
//     Extract (⌥⌘E), under their real names — not through a scan.
//

import Foundation
import SwiftUI

@Observable
class MediaScanner {
    var isScanning = false
    var foundFiles: [URL] = []
    /// Photos libraries met on the way. Not walked — their photos come out through the
    /// library's own database (Extract), with real names and dates.
    var foundLibraries: [URL] = []
    var currentPath: String = ""
    var totalSize: Int64 = 0
    /// Items looked at so far, media or not — so a long scan visibly moves even through
    /// stretches with nothing to find.
    var checkedCount = 0

    var isCancelled: Bool { flag.isSet }
    @ObservationIgnored private let flag = CancelFlag()

    // Media file extensions
    nonisolated static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "aac", "flac", "ogg", "alac"]
    nonisolated static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "mpg", "mpeg", "3gp"]
    nonisolated static let photoExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "gif", "tif", "tiff", "bmp", "webp", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"]

    var allMediaExtensions: [String] {
        Array(Self.audioExtensions) + Array(Self.videoExtensions) + Array(Self.photoExtensions)
    }

    // Scan folder recursively for media files
    func scanFolder(at url: URL) async -> [URL] {
        await scanFolders(at: [url])
    }

    // Scan multiple folders recursively for media files
    func scanFolders(at urls: [URL]) async -> [URL] {
        isScanning = true
        foundFiles = []
        foundLibraries = []
        totalSize = 0
        checkedCount = 0
        flag.reset()

        for url in urls {
            guard !flag.isSet else { break }
            currentPath = url.path
            // Scanning a library directly: it IS the library, so extract it rather than
            // walk it.
            if PhotosLibraryReader.isPhotosLibrary(url) {
                foundLibraries.append(url)
                continue
            }
            await Self.walk(url, flag: flag) { [weak self] batch in
                guard let self else { return }
                self.foundFiles.append(contentsOf: batch.files)
                self.foundLibraries.append(contentsOf: batch.libraries)
                self.totalSize += batch.bytes
                self.checkedCount += batch.checked
                if !batch.lastPath.isEmpty { self.currentPath = batch.lastPath }
            }
        }

        isScanning = false
        return foundFiles
    }

    nonisolated struct Batch: Sendable {
        var files: [URL] = []
        var libraries: [URL] = []
        var bytes: Int64 = 0
        var checked = 0
        var lastPath = ""
    }

    /// ⛔ `@concurrent` IS LOAD-BEARING — the same lesson as FileOperationEngine.run().
    /// Without it this runs on the caller's actor, the main one, and the window freezes
    /// for as long as the walk takes.
    @concurrent
    nonisolated private static func walk(_ root: URL, flag: CancelFlag,
                                         deliver: @escaping @MainActor (Batch) -> Void) async {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }   // an unreadable folder is skipped, not fatal
        ) else { return }

        // The Mac's own drive starts at "/", which also holds /Volumes — every OTHER drive,
        // network ones included — and the system. Scanning it means his files, not those.
        let skipOnStartupDrive: Set<String> = ["/Volumes", "/System", "/Library", "/Applications",
                                               "/private", "/dev", "/cores", "/bin", "/sbin",
                                               "/usr", "/opt", "/etc", "/var", "/tmp"]
        let isStartupRoot = root.standardizedFileURL.path == "/"

        var batch = Batch()
        var lastFlush = Date()
        while let url = enumerator.nextObject() as? URL {
            if flag.isSet { break }
            if isStartupRoot && enumerator.level == 1 && skipOnStartupDrive.contains(url.path) {
                enumerator.skipDescendants()
                continue
            }
            batch.checked += 1
            batch.lastPath = url.path
            let name = url.lastPathComponent.lowercased()
            let ext = url.pathExtension.lowercased()
            let isWebloc = name.hasSuffix(".media.webloc") || name.hasSuffix(".video.webloc")
            // A Photos library — a .photoslibrary package, or a backup copied out by hand as
            // a plain folder. Either way it is extracted, never walked: walking it would
            // pour out its thumbnails under code names.
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if PhotosLibraryReader.isPhotosLibrary(url) {
                    batch.libraries.append(url)
                    enumerator.skipDescendants()
                }
            } else if isWebloc || audioExtensions.contains(ext) || videoExtensions.contains(ext) || photoExtensions.contains(ext) {
                batch.files.append(url)
                batch.bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            if batch.files.count + batch.libraries.count >= 200 || Date().timeIntervalSince(lastFlush) >= 0.3 {
                let ready = batch
                await deliver(ready)
                batch = Batch()
                lastFlush = Date()
            }
        }
        if batch.checked > 0 { await deliver(batch) }
    }

    func cancel() {
        flag.set()
    }

    // Get file extension category
    func getMediaType(for url: URL) -> MediaType {
        Self.mediaType(for: url)
    }

    nonisolated static func mediaType(for url: URL) -> MediaType {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if photoExtensions.contains(ext) { return .photo }
        return .other
    }

    // Check available disk space at path
    func availableSpace(at path: String) -> Int64? {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: path) else {
            return nil
        }
        return attributes[.systemFreeSize] as? Int64
    }

    // Format bytes to human-readable string
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useTB, .useGB, .useMB, .useKB]
        return formatter.string(fromByteCount: bytes)
    }

    enum MediaType: String {
        case audio = "Audio"
        case video = "Video"
        case photo = "Photos"
        case other = "Other"
    }
}

/// Cancel, readable from the walk's thread and settable from the screen's.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}
