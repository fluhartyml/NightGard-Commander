//
//  MediaScanner.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 13 1205
//

import Foundation
import SwiftUI

@Observable
class MediaScanner {
    var isScanning = false
    var foundFiles: [URL] = []
    var currentPath: String = ""
    var isCancelled = false
    var totalSize: Int64 = 0

    // Media file extensions
    private let audioExtensions = ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg"]
    private let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv"]

    var allMediaExtensions: [String] {
        audioExtensions + videoExtensions
    }

    // Scan folder recursively for media files
    func scanFolder(at url: URL) async -> [URL] {
        await scanFolders(at: [url])
    }

    // Scan multiple folders recursively for media files
    func scanFolders(at urls: [URL]) async -> [URL] {
        isScanning = true
        foundFiles = []
        totalSize = 0
        isCancelled = false

        print("MediaScanner: Starting scan of \(urls.count) folders")
        for url in urls {
            guard !isCancelled else { break }
            print("MediaScanner: Scanning folder: \(url.path)")
            currentPath = url.path
            await scanRecursive(url: url)
        }

        print("MediaScanner: Scan complete - found \(foundFiles.count) files")
        isScanning = false
        return foundFiles
    }

    private func scanRecursive(url: URL) async {
        guard !isCancelled else { return }

        let fileManager = FileManager.default

        // Create enumerator with explicit recursive options and error handling
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [],  // Empty options = descend into subdirectories
            errorHandler: { url, error in
                print("MediaScanner error at \(url.path): \(error.localizedDescription)")
                return true  // Continue enumeration despite errors
            }
        ) else {
            print("MediaScanner: Failed to create enumerator for \(url.path)")
            return
        }

        var batchFiles: [URL] = []
        var batchSize: Int64 = 0
        var lastPath = ""
        var lastUpdateTime = Date()
        let updateInterval: TimeInterval = 0.3 // Update UI every 0.3 seconds
        let batchLimit = 50 // Or every 50 files
        var totalFilesChecked = 0
        var mediaFilesFound = 0

        while let fileURL = enumerator.nextObject() as? URL {
            guard !isCancelled else { return }
            totalFilesChecked += 1

            lastPath = fileURL.path

            // Check if it's a media file
            let ext = fileURL.pathExtension.lowercased()
            if allMediaExtensions.contains(ext) {
                mediaFilesFound += 1
                // Get file size
                let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

                batchFiles.append(fileURL)
                batchSize += Int64(fileSize)

                // Update UI in batches
                let timeSinceUpdate = Date().timeIntervalSince(lastUpdateTime)
                if batchFiles.count >= batchLimit || timeSinceUpdate >= updateInterval {
                    await flushBatch(files: batchFiles, size: batchSize, path: lastPath)
                    batchFiles.removeAll()
                    batchSize = 0
                    lastUpdateTime = Date()
                }
            }
        }

        // Flush remaining files
        if !batchFiles.isEmpty {
            await flushBatch(files: batchFiles, size: batchSize, path: lastPath)
        }

        print("MediaScanner: Checked \(totalFilesChecked) items, found \(mediaFilesFound) media files in \(url.path)")
    }

    private func flushBatch(files: [URL], size: Int64, path: String) async {
        await MainActor.run {
            foundFiles.append(contentsOf: files)
            totalSize += size
            currentPath = path
        }
    }

    func cancel() {
        isCancelled = true
    }

    // Get file extension category
    func getMediaType(for url: URL) -> MediaType {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) {
            return .audio
        } else if videoExtensions.contains(ext) {
            return .video
        }
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
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        return formatter.string(fromByteCount: bytes)
    }

    enum MediaType: String {
        case audio = "Audio"
        case video = "Video"
        case other = "Other"
    }
}
