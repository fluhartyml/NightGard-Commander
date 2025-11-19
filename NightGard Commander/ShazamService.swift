//
//  ShazamService.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 18 1050
//

import SwiftUI
import ShazamKit
import AVFoundation
import os

// Result of a single Shazam detection
struct ShazamResult {
    let filePath: String
    let fileName: String
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: String?
    var matched: Bool
    var error: String?
}

// Batch Shazam processor
@Observable
class ShazamService {
    // Progress tracking
    var isProcessing = false
    var totalFiles = 0
    var processedFiles = 0
    var currentFile = ""
    var matchedCount = 0
    var queuedCount = 0

    // Results
    var results: [ShazamResult] = []

    // Cancellation
    private var isCancelled = false

    // Callback when file is renamed
    var onFileRenamed: (() -> Void)?

    // Process all audio files in a folder
    @MainActor
    func processFolder(path: String) async {
        isProcessing = true
        isCancelled = false
        results.removeAll()
        processedFiles = 0
        matchedCount = 0
        queuedCount = 0

        // Find all audio files in folder
        let audioFiles = findAudioFiles(in: path)
        totalFiles = audioFiles.count

        // Process ALL files in folder (internal batching for progress saving)
        let internalBatchSize = 10  // Save progress every 10 files
        var batchCount = 0

        for audioFile in audioFiles {
            if isCancelled {
                break
            }

            currentFile = (audioFile as NSString).lastPathComponent
            let result = await detectFile(path: audioFile)
            results.append(result)

            if result.matched {
                matchedCount += 1

                // Auto-rename if enabled
                // TODO: Metadata saving disabled - AVAssetExportSession doesn't support MP3 on macOS
                if ShazamSettings.shared.autoRename {
                    await renameFile(result: result)
                }
            } else {
                queuedCount += 1

                // Add to queue if enabled
                if ShazamSettings.shared.queueUnmatched {
                    ShazamQueue.shared.add(
                        filePath: result.filePath,
                        fileName: result.fileName,
                        error: result.error
                    )
                }
            }

            processedFiles += 1
            batchCount += 1

            // Save progress every 10 files (internal batch checkpoint)
            if batchCount >= internalBatchSize {
                batchCount = 0
                // Progress is auto-saved via settings and queue persistence
            }
        }

        isProcessing = false
    }

    func cancel() {
        isCancelled = true
    }

    // Find all audio files in directory (non-recursive)
    private func findAudioFiles(in path: String) -> [String] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else {
            return []
        }

        let audioExtensions = ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg"]
        return contents.compactMap { filename in
            let ext = (filename as NSString).pathExtension.lowercased()
            if audioExtensions.contains(ext) {
                return (path as NSString).appendingPathComponent(filename)
            }
            return nil
        }
    }

    // Detect a single file
    private func detectFile(path: String) async -> ShazamResult {
        let fileName = (path as NSString).lastPathComponent
        print("🎵 [SHAZAM] Starting detection for: \(fileName)")

        do {
            let audioURL = URL(fileURLWithPath: path)
            print("🎵 [SHAZAM] Creating signature...")
            let signature = try await createSignature(from: audioURL)
            print("🎵 [SHAZAM] Signature created successfully")

            // Use delegate pattern for ShazamKit with timeout
            return await withTaskGroup(of: ShazamResult?.self) { group in
                let delegate = ShazamSessionDelegate()
                let session = SHSession()

                // Keep strong reference to delegate
                let delegateRef: ShazamSessionDelegate? = delegate

                session.delegate = delegate

                // Add detection task
                group.addTask {
                    await withCheckedContinuation { continuation in
                        let hasResumed = OSAllocatedUnfairLock(initialState: false)

                        delegate.onMatch = { match in
                            print("✅ [SHAZAM] Match callback fired!")
                            guard !hasResumed.withLock({ resumed in
                                if resumed { return true }
                                resumed = true
                                return false
                            }) else { return }

                            guard let mediaItem = match.mediaItems.first else {
                                print("⚠️ [SHAZAM] Match has no media items")
                                continuation.resume(returning: ShazamResult(
                                    filePath: path,
                                    fileName: fileName,
                                    matched: false,
                                    error: "No match found"
                                ))
                                return
                            }

                            // Extract all available metadata
                            print("✅ [SHAZAM] Matched: \(mediaItem.title ?? "Unknown") by \(mediaItem.artist ?? "Unknown")")

                            // Debug: Check what's available in mediaItem
                            print("   Genres array: \(mediaItem.genres)")
                            let genre = mediaItem.genres.first
                            let year: String? = nil // ShazamKit doesn't provide year/release date

                            if let genre = genre {
                                print("   Using Genre: \(genre)")
                            } else {
                                print("   ⚠️ No genre available")
                            }

                            continuation.resume(returning: ShazamResult(
                                filePath: path,
                                fileName: fileName,
                                title: mediaItem.title,
                                artist: mediaItem.artist,
                                album: nil, // ShazamKit doesn't provide album
                                genre: genre,
                                year: year,
                                matched: true,
                                error: nil
                            ))
                        }

                        delegate.onNoMatch = {
                            print("❌ [SHAZAM] No match callback fired")
                            guard !hasResumed.withLock({ resumed in
                                if resumed { return true }
                                resumed = true
                                return false
                            }) else { return }
                            continuation.resume(returning: ShazamResult(
                                filePath: path,
                                fileName: fileName,
                                matched: false,
                                error: "No match found"
                            ))
                        }

                        delegate.onError = { error in
                            print("❌ [SHAZAM] Error callback fired: \(error.localizedDescription)")
                            guard !hasResumed.withLock({ resumed in
                                if resumed { return true }
                                resumed = true
                                return false
                            }) else { return }
                            continuation.resume(returning: ShazamResult(
                                filePath: path,
                                fileName: fileName,
                                matched: false,
                                error: error.localizedDescription
                            ))
                        }

                        // Start matching
                        print("🎵 [SHAZAM] Calling session.match()...")
                        session.match(signature)
                    }
                }

                // Add timeout task (10 seconds)
                group.addTask {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    print("⏱️ [SHAZAM] Timeout reached (10 seconds)")
                    return ShazamResult(
                        filePath: path,
                        fileName: fileName,
                        matched: false,
                        error: "Detection timeout"
                    )
                }

                // Return first result (either match or timeout)
                if let result = await group.next() {
                    group.cancelAll()
                    _ = delegateRef // Keep delegate alive
                    return result ?? ShazamResult(
                        filePath: path,
                        fileName: fileName,
                        matched: false,
                        error: "Unknown error"
                    )
                }

                return ShazamResult(
                    filePath: path,
                    fileName: fileName,
                    matched: false,
                    error: "Task failed"
                )
            }
        } catch {
            print("❌ [SHAZAM] Exception caught: \(error.localizedDescription)")
            return ShazamResult(
                filePath: path,
                fileName: fileName,
                matched: false,
                error: error.localizedDescription
            )
        }
    }

    private func createSignature(from url: URL) async throws -> SHSignature {
        print("🎵 [SHAZAM] Opening audio file...")
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        print("🎵 [SHAZAM] Audio format: \(format.sampleRate)Hz, \(format.channelCount) channels")

        // ShazamKit only needs ~3-5 seconds of audio for recognition
        // Limit to first 10 seconds to avoid overflow and improve performance
        let maxSeconds: Double = 10.0
        let maxFrames = AVAudioFrameCount(format.sampleRate * maxSeconds)
        let frameCount = min(AVAudioFrameCount(audioFile.length), maxFrames)
        print("🎵 [SHAZAM] Using \(frameCount) frames (~\(Double(frameCount) / format.sampleRate) seconds)")

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            print("❌ [SHAZAM] Failed to create audio buffer")
            throw NSError(domain: "ShazamService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }

        // Read only the needed frames
        buffer.frameLength = frameCount
        print("🎵 [SHAZAM] Reading audio data...")
        try audioFile.read(into: buffer, frameCount: frameCount)
        print("🎵 [SHAZAM] Audio data read successfully")

        print("🎵 [SHAZAM] Generating signature...")
        let signatureGenerator = SHSignatureGenerator()
        try signatureGenerator.append(buffer, at: nil)
        let signature = signatureGenerator.signature()
        print("🎵 [SHAZAM] Signature generated successfully")

        return signature
    }

    // Rename file only (no metadata saving)
    private func renameFile(result: ShazamResult) async {
        guard result.matched else { return }

        let fileURL = URL(fileURLWithPath: result.filePath)
        let directory = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension

        // Generate new filename
        let newName = generateFilename(from: result, extension: ext)
        let newURL = directory.appendingPathComponent(newName)

        // Check if file already exists
        if FileManager.default.fileExists(atPath: newURL.path) && newURL.path != fileURL.path {
            print("⚠️ [SHAZAM] File already exists, skipping rename: \(newName)")
            return
        }

        do {
            // Rename file
            if newURL.path != fileURL.path {
                try FileManager.default.moveItem(at: fileURL, to: newURL)
                print("✅ [SHAZAM] Renamed to: \(newName)")

                // Notify that file was renamed
                await MainActor.run {
                    onFileRenamed?()
                }
            }
        } catch {
            print("❌ [SHAZAM] Error renaming: \(error)")
        }
    }

    // Rename file and save metadata
    private func renameAndSaveMetadata(result: ShazamResult) async {
        guard result.matched else { return }

        let fileURL = URL(fileURLWithPath: result.filePath)
        let directory = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension

        // Generate new filename
        let newName = generateFilename(from: result, extension: ext)
        let newURL = directory.appendingPathComponent(newName)

        // Check if file already exists
        if FileManager.default.fileExists(atPath: newURL.path) && newURL.path != fileURL.path {
            // File exists, skip rename
            return
        }

        do {
            // Save metadata first
            try await saveMetadata(result: result, to: fileURL)

            // Then rename file
            if newURL.path != fileURL.path {
                try FileManager.default.moveItem(at: fileURL, to: newURL)
            }
        } catch {
            print("Error renaming/saving: \(error)")
        }
    }

    private func generateFilename(from result: ShazamResult, extension ext: String) -> String {
        let blocks = ShazamSettings.shared.formatBlocks
        var parts: [String] = []

        for block in blocks {
            switch block.field {
            case .title:
                if let title = result.title { parts.append(title) }
            case .artist:
                if let artist = result.artist { parts.append(artist) }
            case .albumName:
                if let album = result.album { parts.append(album) }
            case .genres:
                if let genre = result.genre { parts.append(genre) }
            case .year, .releaseDate:
                if let year = result.year { parts.append(year) }
            case .separator:
                // Only add separator if there's already content
                if !parts.isEmpty {
                    parts.append(" - ")
                }
            default:
                continue
            }
        }

        let name = parts.joined(separator: "")
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
                            .replacingOccurrences(of: ":", with: "-")

        return sanitized + "." + ext
    }

    private func saveMetadata(result: ShazamResult, to url: URL) async throws {
        let asset = AVURLAsset(url: url)

        // Prepare metadata items
        var metadataItems: [AVMutableMetadataItem] = []

        if let title = result.title {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = title as NSString
            metadataItems.append(item)
        }

        if let artist = result.artist {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtist
            item.value = artist as NSString
            metadataItems.append(item)
        }

        if let album = result.album {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierAlbumName
            item.value = album as NSString
            metadataItems.append(item)
        }

        // Export with new metadata
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "ShazamService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        exportSession.metadata = metadataItems
        exportSession.outputURL = tempURL

        // Determine output file type based on extension
        let ext = url.pathExtension.lowercased()
        let outputFileType: AVFileType
        switch ext {
        case "mp3":
            outputFileType = .mp3
        case "m4a":
            outputFileType = .m4a
        case "mp4":
            outputFileType = .mp4
        case "mov":
            outputFileType = .mov
        case "wav":
            outputFileType = .wav
        case "aiff", "aif":
            outputFileType = .aiff
        default:
            outputFileType = .mp4
        }

        exportSession.outputFileType = outputFileType

        try await exportSession.export(to: tempURL, as: outputFileType)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }
}
