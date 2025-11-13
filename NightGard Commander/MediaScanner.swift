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

    // Media file extensions
    private let audioExtensions = ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg"]
    private let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv"]

    var allMediaExtensions: [String] {
        audioExtensions + videoExtensions
    }

    // Scan folder recursively for media files
    func scanFolder(at url: URL) async -> [URL] {
        isScanning = true
        foundFiles = []
        currentPath = url.path
        isCancelled = false

        await scanRecursive(url: url)

        isScanning = false
        return foundFiles
    }

    private func scanRecursive(url: URL) async {
        guard !isCancelled else { return }

        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .nameKey]) else {
            return
        }

        for case let fileURL as URL in enumerator {
            guard !isCancelled else { return }

            // Update current path for UI
            await MainActor.run {
                currentPath = fileURL.path
            }

            // Check if it's a media file
            let ext = fileURL.pathExtension.lowercased()
            if allMediaExtensions.contains(ext) {
                await MainActor.run {
                    foundFiles.append(fileURL)
                }
            }
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

    enum MediaType: String {
        case audio = "Audio"
        case video = "Video"
        case other = "Other"
    }
}
