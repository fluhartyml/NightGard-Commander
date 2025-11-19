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
    var allGenres: [String]  // All available genres from Shazam
    var needsGenreReview: Bool  // True if user should manually pick genre
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
    var genreReviewCount = 0  // Files matched but need genre selection

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
        genreReviewCount = 0

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

                // Check if file needs genre review
                if result.needsGenreReview {
                    genreReviewCount += 1
                    // Add to genre review queue for user to choose
                    GenreReviewQueue.shared.add(result: result)
                    print("📝 [SHAZAM] Added to genre review queue: \(result.fileName)")
                } else {
                    // Auto-rename and save metadata (only for files with clear genre)
                    if ShazamSettings.shared.autoRename {
                        await renameAndSaveMetadata(result: result)
                    }
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

    // Deep dive detection - tries multiple positions in the song
    @MainActor
    func detectFileDeepDive(path: String) async -> ShazamResult {
        currentFile = (path as NSString).lastPathComponent
        print("🔍 [DEEP DIVE] Starting deep dive detection for: \(currentFile)")

        // Get file duration first
        let audioURL = URL(fileURLWithPath: path)
        guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
            return ShazamResult(
                filePath: path,
                fileName: currentFile,
                allGenres: [],
                needsGenreReview: false,
                matched: false,
                error: "Could not open audio file"
            )
        }

        let format = audioFile.processingFormat
        let totalDuration = Double(audioFile.length) / format.sampleRate
        print("🔍 [DEEP DIVE] File duration: \(totalDuration) seconds")

        // Try multiple positions: 30s, 60s, 90s, 120s (skip intros/outros)
        let samplePositions: [Double] = [30.0, 60.0, 90.0, 120.0, 0.0] // Try middle positions first, then beginning as fallback
        let sampleDuration = 15.0 // Use longer sample for deep dive

        for position in samplePositions {
            // Skip if position is beyond file length
            if position + sampleDuration > totalDuration {
                print("🔍 [DEEP DIVE] Skipping position \(position)s (beyond file length)")
                continue
            }

            print("🔍 [DEEP DIVE] Trying position: \(position)s")
            let result = await detectFile(path: path, startOffset: position, duration: sampleDuration)

            if result.matched {
                print("✅ [DEEP DIVE] Match found at position \(position)s!")
                return result
            } else {
                print("❌ [DEEP DIVE] No match at position \(position)s")
            }

            // Small delay between attempts to avoid rate limiting
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        print("❌ [DEEP DIVE] No matches found at any position")
        return ShazamResult(
            filePath: path,
            fileName: currentFile,
            allGenres: [],
            needsGenreReview: false,
            matched: false,
            error: "No match found (tried multiple positions)"
        )
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
    func detectFile(path: String, startOffset: Double = 0.0, duration: Double = 10.0) async -> ShazamResult {
        let fileName = (path as NSString).lastPathComponent
        print("🎵 [SHAZAM] Starting detection for: \(fileName)")

        do {
            let audioURL = URL(fileURLWithPath: path)
            print("🎵 [SHAZAM] Creating signature...")
            let signature = try await createSignature(from: audioURL, startOffset: startOffset, duration: duration)
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
                                    allGenres: [],
                                    needsGenreReview: false,
                                    matched: false,
                                    error: "No match found"
                                ))
                                return
                            }

                            // Extract all available metadata
                            print("✅ [SHAZAM] Matched: \(mediaItem.title ?? "Unknown") by \(mediaItem.artist ?? "Unknown")")

                            // Debug: Check what's available in mediaItem
                            print("   Genres array: \(mediaItem.genres)")
                            let allGenres = mediaItem.genres
                            let genre = allGenres.first
                            let year: String? = nil // ShazamKit doesn't provide year/release date

                            // Determine if user needs to manually pick genre
                            let needsGenreReview = allGenres.count > 1 || allGenres.isEmpty

                            if allGenres.isEmpty {
                                print("   ⚠️ No genre available - needs manual review")
                            } else if allGenres.count > 1 {
                                print("   ⚠️ Multiple genres available (\(allGenres.count)) - needs manual review: \(allGenres.joined(separator: ", "))")
                            } else if let genre = genre {
                                print("   Using Genre: \(genre)")
                            }

                            continuation.resume(returning: ShazamResult(
                                filePath: path,
                                fileName: fileName,
                                title: mediaItem.title,
                                artist: mediaItem.artist,
                                album: nil, // ShazamKit doesn't provide album
                                genre: genre,
                                allGenres: allGenres,
                                needsGenreReview: needsGenreReview,
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
                                allGenres: [],
                                needsGenreReview: false,
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
                                allGenres: [],
                                needsGenreReview: false,
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
                        allGenres: [],
                        needsGenreReview: false,
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
                        allGenres: [],
                        needsGenreReview: false,
                        matched: false,
                        error: "Unknown error"
                    )
                }

                return ShazamResult(
                    filePath: path,
                    fileName: fileName,
                    allGenres: [],
                    needsGenreReview: false,
                    matched: false,
                    error: "Task failed"
                )
            }
        } catch {
            print("❌ [SHAZAM] Exception caught: \(error.localizedDescription)")
            return ShazamResult(
                filePath: path,
                fileName: fileName,
                allGenres: [],
                needsGenreReview: false,
                matched: false,
                error: error.localizedDescription
            )
        }
    }

    private func createSignature(from url: URL, startOffset: Double = 0.0, duration: Double = 10.0) async throws -> SHSignature {
        print("🎵 [SHAZAM] Opening audio file...")
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        print("🎵 [SHAZAM] Audio format: \(format.sampleRate)Hz, \(format.channelCount) channels")

        // Calculate start frame and duration
        let startFrame = AVAudioFramePosition(format.sampleRate * startOffset)
        let maxFrames = AVAudioFrameCount(format.sampleRate * duration)
        let totalLength = audioFile.length

        // Ensure we don't read beyond file length
        let actualStartFrame = min(startFrame, totalLength - 1)
        let remainingFrames = AVAudioFrameCount(totalLength - actualStartFrame)
        let frameCount = min(maxFrames, remainingFrames)

        print("🎵 [SHAZAM] Starting at \(startOffset)s, reading \(duration)s (~\(Double(frameCount) / format.sampleRate) seconds actual)")

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            print("❌ [SHAZAM] Failed to create audio buffer")
            throw NSError(domain: "ShazamService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }

        // Seek to start position
        audioFile.framePosition = actualStartFrame

        // Read the needed frames
        buffer.frameLength = frameCount
        print("🎵 [SHAZAM] Reading audio data from \(actualStartFrame)...")
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

        do {
            // Step 1: Save metadata first (before renaming)
            print("💾 [SHAZAM] Saving metadata for: \(result.fileName)")
            try await saveMetadata(result: result, to: fileURL)
            print("✅ [SHAZAM] Metadata saved successfully")

            // Step 2: Generate new filename and rename
            let newName = generateFilename(from: result, extension: ext)
            let newURL = directory.appendingPathComponent(newName)

            // Check if file already exists
            if FileManager.default.fileExists(atPath: newURL.path) && newURL.path != fileURL.path {
                print("⚠️ [SHAZAM] File already exists, skipping rename: \(newName)")
                return
            }

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
            print("❌ [SHAZAM] Error saving metadata/renaming: \(error.localizedDescription)")
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

        // Prepare metadata items using common key format (same as MetadataEditor)
        var metadataItems: [AVMetadataItem] = []

        func addMetadata(key: AVMetadataKey, value: String) {
            guard !value.isEmpty else { return }
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = key as NSString
            item.value = value as NSString
            metadataItems.append(item)
        }

        if let title = result.title {
            addMetadata(key: .commonKeyTitle, value: title)
        }

        if let artist = result.artist {
            addMetadata(key: .commonKeyArtist, value: artist)
        }

        if let album = result.album {
            addMetadata(key: .commonKeyAlbumName, value: album)
        }

        if let genre = result.genre {
            addMetadata(key: .commonKeyType, value: genre)
        }

        if let year = result.year {
            addMetadata(key: .commonKeyCreationDate, value: year)
        }

        // Export with new metadata
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "ShazamService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        // Create temporary file with same extension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)

        exportSession.metadata = metadataItems

        // Determine output file type based on extension
        let ext = url.pathExtension.lowercased()
        let outputFileType: AVFileType
        switch ext {
        case "mp3":
            outputFileType = .mp3
        case "m4a", "m4b":
            outputFileType = .m4a
        case "mp4", "m4v":
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

        print("💾 [METADATA] Saving: Title=\(result.title ?? "nil"), Artist=\(result.artist ?? "nil"), Genre=\(result.genre ?? "nil")")

        try await exportSession.export(to: tempURL, as: outputFileType)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)

        print("✅ [METADATA] Saved successfully")
    }
}
