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
    var shazamID: String?       // Unique Shazam fingerprint database ID
    var appleMusicID: String?   // iTunes/Apple Music catalog ID
    var matched: Bool
    var error: String?
}

// Batch Shazam processor
@Observable
class ShazamService {
    static let shared = ShazamService()

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

    // iTunes API lookup result
    struct iTunesLookupResult {
        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
        var year: String?
        var trackNumber: Int?
    }

    // Fetch metadata from iTunes API using Apple Music ID (no fingerprinting needed!)
    func fetchFromiTunes(appleMusicID: String) async -> iTunesLookupResult? {
        let urlString = "https://itunes.apple.com/lookup?id=\(appleMusicID)"
        guard let url = URL(string: urlString) else {
            print("❌ [iTunes] Invalid URL")
            return nil
        }

        do {
            print("🎵 [iTunes] Fetching metadata for ID: \(appleMusicID)")
            let (data, _) = try await URLSession.shared.data(from: url)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let track = results.first else {
                print("❌ [iTunes] No results found")
                return nil
            }

            let title = track["trackName"] as? String
            let artist = track["artistName"] as? String
            let album = track["collectionName"] as? String
            let genre = track["primaryGenreName"] as? String
            let trackNumber = track["trackNumber"] as? Int

            // Extract year from release date (format: "2001-05-15T07:00:00Z")
            var year: String?
            if let releaseDate = track["releaseDate"] as? String {
                year = String(releaseDate.prefix(4))
            }

            print("✅ [iTunes] Found: \(artist ?? "?") - \(title ?? "?") [\(album ?? "?")]")
            print("   Genre: \(genre ?? "none"), Year: \(year ?? "none")")

            return iTunesLookupResult(
                title: title,
                artist: artist,
                album: album,
                genre: genre,
                year: year,
                trackNumber: trackNumber
            )
        } catch {
            print("❌ [iTunes] Error: \(error.localizedDescription)")
            return nil
        }
    }

    // SMART SCAN: Use every shortcut before fingerprinting
    // 1. Has iTunes ID? → iTunes API → done
    // 2. Has Artist + Title in ID3? → rename directly → done
    // 3. LAST RESORT: Shazam fingerprint
    @MainActor
    func processFolder(path: String) async {
        isProcessing = true
        isCancelled = false
        results.removeAll()
        processedFiles = 0
        matchedCount = 0
        queuedCount = 0
        genreReviewCount = 0

        let audioFiles = findAudioFiles(in: path)
        totalFiles = audioFiles.count

        print("🔍 [SMART SCAN] Scanning \(audioFiles.count) files...")

        for audioFile in audioFiles {
            if isCancelled { break }

            currentFile = (audioFile as NSString).lastPathComponent
            processedFiles += 1

            // === STEP 1: Already done? ===
            if let storedMeta = ShazamScannedDatabase.shared.getMetadata(for: audioFile),
               storedMeta.wasRenamed {
                print("⏭️ Already done: \(currentFile)")
                continue
            }

            // === STEP 2: Do we have an iTunes ID anywhere? ===
            var appleMusicID: String?
            var embeddedArtist: String?
            var embeddedTitle: String?
            var embeddedAlbum: String?
            var embeddedGenre: String?
            var embeddedYear: String?

            // Check stored database first
            if let storedMeta = ShazamScannedDatabase.shared.getMetadata(for: audioFile),
               let storedID = storedMeta.appleMusicID, !storedID.isEmpty {
                appleMusicID = storedID
                print("🎯 Found stored iTunes ID: \(storedID)")
            }

            // Read embedded file metadata (ID3 tags)
            if let embedded = await readFullEmbeddedMetadata(from: audioFile) {
                if appleMusicID == nil, let embeddedID = embedded.appleMusicID, !embeddedID.isEmpty {
                    appleMusicID = embeddedID
                    print("🎯 Found embedded iTunes ID: \(embeddedID)")
                }
                embeddedArtist = embedded.artist
                embeddedTitle = embedded.title
                embeddedAlbum = embedded.album
                embeddedGenre = embedded.genre
                embeddedYear = embedded.year
            }

            // === STEP 3: Got iTunes ID? Use iTunes API ===
            if let id = appleMusicID {
                if let iTunesData = await fetchFromiTunes(appleMusicID: id) {
                    await processWithMetadata(
                        path: audioFile,
                        artist: iTunesData.artist,
                        title: iTunesData.title,
                        album: iTunesData.album,
                        genre: iTunesData.genre,
                        year: iTunesData.year,
                        shazamID: nil,
                        appleMusicID: id,
                        source: "iTunes API"
                    )
                    matchedCount += 1
                    continue
                }
            }

            // === STEP 4: Has Artist + Title in ID3 tags? Rename directly! ===
            if let artist = embeddedArtist, !artist.isEmpty,
               let title = embeddedTitle, !title.isEmpty {
                print("📝 Using ID3 tags: \(artist) - \(title)")
                await processWithMetadata(
                    path: audioFile,
                    artist: artist,
                    title: title,
                    album: embeddedAlbum,
                    genre: embeddedGenre,
                    year: embeddedYear,
                    shazamID: nil,
                    appleMusicID: nil,
                    source: "ID3 Tags"
                )
                matchedCount += 1
                continue
            }

            // === STEP 5: Skip if in review queue ===
            if GenreReviewQueue.shared.items.contains(where: { $0.filePath == audioFile }) {
                print("⏭️ In review queue: \(currentFile)")
                continue
            }

            // === STEP 6: LAST RESORT - Shazam fingerprint ===
            print("🎵 No metadata - Shazaming: \(currentFile)")
            let result = await detectFile(path: audioFile)
            results.append(result)

            // Handle rate limiting
            if let error = result.error, error.contains("201") {
                print("⚠️ Rate limited - waiting 30 seconds...")
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            if result.matched {
                // Got iTunes ID from Shazam! Now use iTunes API for full metadata
                if let newAppleMusicID = result.appleMusicID, !newAppleMusicID.isEmpty {
                    print("✅ Shazam found iTunes ID: \(newAppleMusicID)")

                    if let iTunesData = await fetchFromiTunes(appleMusicID: newAppleMusicID) {
                        await processWithMetadata(
                            path: audioFile,
                            artist: iTunesData.artist,
                            title: iTunesData.title,
                            album: iTunesData.album,
                            genre: iTunesData.genre,
                            year: iTunesData.year,
                            shazamID: result.shazamID,
                            appleMusicID: newAppleMusicID,
                            source: "iTunes API (via Shazam)"
                        )
                        matchedCount += 1
                        continue
                    }
                }

                // Fallback: use Shazam metadata directly if iTunes API fails
                matchedCount += 1
                let originalFilename = (audioFile as NSString).lastPathComponent

                ShazamScannedDatabase.shared.storeMetadata(
                    filePath: audioFile,
                    artist: result.artist,
                    title: result.title,
                    album: result.album,
                    genre: result.genre,
                    year: result.year,
                    shazamID: result.shazamID,
                    appleMusicID: result.appleMusicID,
                    wasRenamed: false,
                    originalFilename: originalFilename,
                    currentFilename: originalFilename
                )

                if result.needsGenreReview {
                    genreReviewCount += 1
                    GenreReviewQueue.shared.add(result: result)
                } else if ShazamSettings.shared.autoRename {
                    await renameAndSaveMetadata(result: result)
                }
            } else {
                queuedCount += 1
                if ShazamSettings.shared.queueUnmatched {
                    ShazamQueue.shared.add(
                        filePath: result.filePath,
                        fileName: result.fileName,
                        error: result.error
                    )
                }
            }
        }

        print("📊 [SMART SCAN] Done: \(matchedCount) matched, \(queuedCount) unknown")
        isProcessing = false
    }

    // Process a single file (for button tap) - returns success and title
    struct SingleFileResult {
        let success: Bool
        let title: String?
        let error: String?
    }

    func processSingleFile(_ fileURL: URL) async -> SingleFileResult {
        let path = fileURL.path
        let fileName = fileURL.lastPathComponent

        print("🔵 [SHAZAM] Processing single file: \(fileName)")

        // === STEP 1: Already done? ===
        if let storedMeta = ShazamScannedDatabase.shared.getMetadata(for: path),
           storedMeta.wasRenamed {
            let title = [storedMeta.artist, storedMeta.title].compactMap { $0 }.joined(separator: " - ")
            return SingleFileResult(success: true, title: title.isEmpty ? fileName : title, error: nil)
        }

        // === STEP 2: Do we have an iTunes ID anywhere? ===
        var appleMusicID: String?
        var embeddedArtist: String?
        var embeddedTitle: String?
        var embeddedAlbum: String?
        var embeddedGenre: String?
        var embeddedYear: String?

        // Check stored database first
        if let storedMeta = ShazamScannedDatabase.shared.getMetadata(for: path),
           let storedID = storedMeta.appleMusicID, !storedID.isEmpty {
            appleMusicID = storedID
            print("🎯 Found stored iTunes ID: \(storedID)")
        }

        // Read embedded file metadata (ID3 tags)
        if let embedded = await readFullEmbeddedMetadata(from: path) {
            if appleMusicID == nil, let embeddedID = embedded.appleMusicID, !embeddedID.isEmpty {
                appleMusicID = embeddedID
                print("🎯 Found embedded iTunes ID: \(embeddedID)")
            }
            embeddedArtist = embedded.artist
            embeddedTitle = embedded.title
            embeddedAlbum = embedded.album
            embeddedGenre = embedded.genre
            embeddedYear = embedded.year
        }

        // === STEP 3: Got iTunes ID? Use iTunes API ===
        if let id = appleMusicID {
            if let iTunesData = await fetchFromiTunes(appleMusicID: id) {
                await processWithMetadata(
                    path: path,
                    artist: iTunesData.artist,
                    title: iTunesData.title,
                    album: iTunesData.album,
                    genre: iTunesData.genre,
                    year: iTunesData.year,
                    shazamID: nil,
                    appleMusicID: id,
                    source: "iTunes API"
                )
                let title = [iTunesData.artist, iTunesData.title].compactMap { $0 }.joined(separator: " - ")
                return SingleFileResult(success: true, title: title.isEmpty ? nil : title, error: nil)
            }
        }

        // === STEP 4: Has Artist + Title in ID3 tags? Rename directly! ===
        if let artist = embeddedArtist, !artist.isEmpty,
           let title = embeddedTitle, !title.isEmpty {
            print("📝 Using ID3 tags: \(artist) - \(title)")
            await processWithMetadata(
                path: path,
                artist: artist,
                title: title,
                album: embeddedAlbum,
                genre: embeddedGenre,
                year: embeddedYear,
                shazamID: nil,
                appleMusicID: nil,
                source: "ID3 Tags"
            )
            let displayTitle = "\(artist) - \(title)"
            return SingleFileResult(success: true, title: displayTitle, error: nil)
        }

        // === STEP 5: LAST RESORT - Shazam fingerprint ===
        print("🎵 No metadata - Shazaming: \(fileName)")
        let result = await detectFile(path: path)

        if result.matched {
            // Got iTunes ID from Shazam! Now use iTunes API for full metadata
            if let newAppleMusicID = result.appleMusicID, !newAppleMusicID.isEmpty {
                print("✅ Shazam found iTunes ID: \(newAppleMusicID)")

                if let iTunesData = await fetchFromiTunes(appleMusicID: newAppleMusicID) {
                    await processWithMetadata(
                        path: path,
                        artist: iTunesData.artist,
                        title: iTunesData.title,
                        album: iTunesData.album,
                        genre: iTunesData.genre,
                        year: iTunesData.year,
                        shazamID: result.shazamID,
                        appleMusicID: newAppleMusicID,
                        source: "iTunes API (via Shazam)"
                    )
                    let title = [iTunesData.artist, iTunesData.title].compactMap { $0 }.joined(separator: " - ")
                    return SingleFileResult(success: true, title: title.isEmpty ? nil : title, error: nil)
                }
            }

            // Fallback: use Shazam metadata directly
            let originalFilename = fileName

            ShazamScannedDatabase.shared.storeMetadata(
                filePath: path,
                artist: result.artist,
                title: result.title,
                album: result.album,
                genre: result.genre,
                year: result.year,
                shazamID: result.shazamID,
                appleMusicID: result.appleMusicID,
                wasRenamed: false,
                originalFilename: originalFilename,
                currentFilename: originalFilename
            )

            if result.needsGenreReview {
                GenreReviewQueue.shared.add(result: result)
            } else if ShazamSettings.shared.autoRename {
                await renameAndSaveMetadata(result: result)
            }

            let title = [result.artist, result.title].compactMap { $0 }.joined(separator: " - ")
            return SingleFileResult(success: true, title: title.isEmpty ? nil : title, error: nil)
        } else {
            // No match
            if ShazamSettings.shared.queueUnmatched {
                ShazamQueue.shared.add(
                    filePath: result.filePath,
                    fileName: result.fileName,
                    error: result.error
                )
            }
            return SingleFileResult(success: false, title: nil, error: result.error ?? "No match found")
        }
    }

    // Quick check for Apple Music ID in file metadata
    private func readAppleMusicID(from path: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)

        do {
            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                let metadata = try await asset.loadMetadata(for: format)
                for item in metadata {
                    if let identifier = item.identifier?.rawValue {
                        // iTunes catalog ID keys
                        if identifier.contains("itunes") || identifier.contains("cnID") || identifier.contains("plID") {
                            if let value = try? await item.load(.stringValue), !value.isEmpty {
                                return value
                            } else if let numValue = try? await item.load(.numberValue) {
                                return String(describing: numValue)
                            }
                        }
                    }
                }
            }
        } catch {
            // Silent fail - just means no ID found
        }
        return nil
    }

    // Full embedded metadata read (ID3 tags)
    struct EmbeddedFileMetadata {
        var artist: String?
        var title: String?
        var album: String?
        var genre: String?
        var year: String?
        var appleMusicID: String?
    }

    private func readFullEmbeddedMetadata(from path: String) async -> EmbeddedFileMetadata? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)

        var result = EmbeddedFileMetadata()
        var foundAny = false

        do {
            let metadata = try await asset.load(.commonMetadata)

            for item in metadata {
                guard let key = item.commonKey?.rawValue else { continue }

                switch key {
                case "artist":
                    result.artist = try? await item.load(.stringValue)
                    if result.artist != nil { foundAny = true }
                case "title":
                    result.title = try? await item.load(.stringValue)
                    if result.title != nil { foundAny = true }
                case "albumName":
                    result.album = try? await item.load(.stringValue)
                    if result.album != nil { foundAny = true }
                case "type":
                    result.genre = try? await item.load(.stringValue)
                    if result.genre != nil { foundAny = true }
                case "creationDate":
                    result.year = try? await item.load(.stringValue)
                    if result.year != nil { foundAny = true }
                default:
                    break
                }
            }

            // Check for iTunes ID in format-specific metadata
            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                let formatMetadata = try await asset.loadMetadata(for: format)
                for item in formatMetadata {
                    if let identifier = item.identifier?.rawValue {
                        if identifier.contains("itunes") || identifier.contains("cnID") || identifier.contains("plID") {
                            if let value = try? await item.load(.stringValue), !value.isEmpty {
                                result.appleMusicID = value
                                foundAny = true
                            } else if let numValue = try? await item.load(.numberValue) {
                                result.appleMusicID = String(describing: numValue)
                                foundAny = true
                            }
                        }
                    }
                }
            }
        } catch {
            // Silent fail
        }

        return foundAny ? result : nil
    }

    // Read embedded metadata from audio file (ID3 tags, etc.)
    private func readEmbeddedMetadata(path: String) async -> (artist: String?, title: String?, album: String?, genre: String?, year: String?, appleMusicID: String?)? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)

        do {
            let metadata = try await asset.load(.commonMetadata)

            var artist: String?
            var title: String?
            var album: String?
            var genre: String?
            var year: String?
            var appleMusicID: String?

            for item in metadata {
                guard let key = item.commonKey?.rawValue else { continue }

                switch key {
                case "artist":
                    artist = try? await item.load(.stringValue)
                case "title":
                    title = try? await item.load(.stringValue)
                case "albumName":
                    album = try? await item.load(.stringValue)
                case "type": // genre
                    genre = try? await item.load(.stringValue)
                case "creationDate":
                    year = try? await item.load(.stringValue)
                default:
                    break
                }
            }

            // Also check iTunes-specific metadata for Apple Music ID
            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                let formatMetadata = try await asset.loadMetadata(for: format)
                for item in formatMetadata {
                    if let identifier = item.identifier?.rawValue {
                        // Look for iTunes catalog ID
                        if identifier.contains("itunes") || identifier.contains("cnID") || identifier.contains("plID") {
                            if let value = try? await item.load(.stringValue) {
                                appleMusicID = value
                                print("   Found iTunes ID in metadata: \(value)")
                            } else if let numValue = try? await item.load(.numberValue) {
                                appleMusicID = String(describing: numValue)
                                print("   Found iTunes ID (number) in metadata: \(appleMusicID ?? "")")
                            }
                        }
                    }
                }
            }

            // Only return if we found something useful
            if artist != nil || title != nil || appleMusicID != nil {
                print("   📖 Embedded: Artist=\(artist ?? "nil"), Title=\(title ?? "nil"), Album=\(album ?? "nil"), AppleID=\(appleMusicID ?? "nil")")
                return (artist, title, album, genre, year, appleMusicID)
            }

            return nil
        } catch {
            print("   ⚠️ Error reading metadata: \(error.localizedDescription)")
            return nil
        }
    }

    // Process a file with known metadata (from any source)
    private func processWithMetadata(
        path: String,
        artist: String?,
        title: String?,
        album: String?,
        genre: String?,
        year: String?,
        shazamID: String?,
        appleMusicID: String?,
        source: String
    ) async {
        let originalFilename = (path as NSString).lastPathComponent

        // Store in database
        ShazamScannedDatabase.shared.storeMetadata(
            filePath: path,
            artist: artist,
            title: title,
            album: album,
            genre: genre,
            year: year,
            shazamID: shazamID,
            appleMusicID: appleMusicID,
            wasRenamed: false,
            originalFilename: originalFilename,
            currentFilename: originalFilename
        )

        // Rename file
        if ShazamSettings.shared.autoRename,
           let metadata = ShazamScannedDatabase.shared.getMetadata(for: path) {
            let fileURL = URL(fileURLWithPath: path)
            let directory = fileURL.deletingLastPathComponent()
            let ext = fileURL.pathExtension

            let newName = generateFilenameFromMetadata(metadata, extension: ext)
            let newURL = directory.appendingPathComponent(newName)

            if newURL.path != fileURL.path && !FileManager.default.fileExists(atPath: newURL.path) {
                do {
                    try FileManager.default.moveItem(at: fileURL, to: newURL)
                    print("✅ [\(source)] Renamed: \(originalFilename) → \(newName)")

                    ShazamScannedDatabase.shared.updateFilename(
                        originalPath: path,
                        newFilename: newName,
                        newPath: newURL.path
                    )

                    await MainActor.run { onFileRenamed?() }
                } catch {
                    print("❌ [\(source)] Rename error: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancel() {
        isCancelled = true
    }

    // Process files using iTunes API instead of Shazam fingerprinting
    // For files that already have an Apple Music ID stored
    @MainActor
    func processWithiTunesAPI(path: String) async -> (processed: Int, renamed: Int, skipped: Int, errors: Int) {
        isProcessing = true
        isCancelled = false
        processedFiles = 0
        matchedCount = 0

        // Find audio files
        let audioFiles = findAudioFiles(in: path)
        totalFiles = audioFiles.count

        var processed = 0
        var renamed = 0
        var skipped = 0
        var errors = 0

        print("🎵 [iTunes API] Processing \(audioFiles.count) files...")

        for audioFile in audioFiles {
            if isCancelled { break }

            currentFile = (audioFile as NSString).lastPathComponent
            processedFiles += 1

            // Check if file has stored metadata with Apple Music ID
            if let metadata = ShazamScannedDatabase.shared.getMetadata(for: audioFile),
               let appleMusicID = metadata.appleMusicID, !appleMusicID.isEmpty {

                print("🎵 [iTunes API] Found Apple Music ID for: \(currentFile)")

                // Fetch fresh metadata from iTunes
                if let iTunesData = await fetchFromiTunes(appleMusicID: appleMusicID) {
                    processed += 1

                    // Update stored metadata with fresh iTunes data
                    ShazamScannedDatabase.shared.storeMetadata(
                        filePath: audioFile,
                        artist: iTunesData.artist ?? metadata.artist,
                        title: iTunesData.title ?? metadata.title,
                        album: iTunesData.album ?? metadata.album,
                        genre: iTunesData.genre ?? metadata.genre,
                        year: iTunesData.year ?? metadata.year,
                        shazamID: metadata.shazamID,
                        appleMusicID: appleMusicID,
                        wasRenamed: false,
                        originalFilename: metadata.originalFilename,
                        currentFilename: metadata.currentFilename
                    )

                    // Get updated metadata and rename
                    if let updatedMetadata = ShazamScannedDatabase.shared.getMetadata(for: audioFile) {
                        let fileURL = URL(fileURLWithPath: audioFile)
                        let directory = fileURL.deletingLastPathComponent()
                        let ext = fileURL.pathExtension

                        let newName = generateFilenameFromMetadata(updatedMetadata, extension: ext)
                        let newURL = directory.appendingPathComponent(newName)

                        if newURL.path != fileURL.path {
                            if FileManager.default.fileExists(atPath: newURL.path) {
                                print("⚠️ [iTunes API] Destination exists: \(newName)")
                                skipped += 1
                            } else {
                                do {
                                    try FileManager.default.moveItem(at: fileURL, to: newURL)
                                    print("✅ [iTunes API] Renamed: \(currentFile) → \(newName)")

                                    ShazamScannedDatabase.shared.updateFilename(
                                        originalPath: audioFile,
                                        newFilename: newName,
                                        newPath: newURL.path
                                    )
                                    renamed += 1
                                    matchedCount += 1
                                } catch {
                                    print("❌ [iTunes API] Rename error: \(error.localizedDescription)")
                                    errors += 1
                                }
                            }
                        } else {
                            print("⏭️ [iTunes API] Already named correctly: \(currentFile)")
                            skipped += 1
                        }
                    }
                } else {
                    print("⚠️ [iTunes API] Could not fetch data for ID: \(appleMusicID)")
                    errors += 1
                }

                // Small delay to be nice to iTunes API
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            } else {
                // No Apple Music ID - skip
                skipped += 1
            }
        }

        print("📊 [iTunes API] Complete: \(processed) processed, \(renamed) renamed, \(skipped) skipped, \(errors) errors")

        isProcessing = false
        onFileRenamed?()

        return (processed, renamed, skipped, errors)
    }

    // Fetch metadata from iTunes API for all files with Apple Music IDs in database
    // No fingerprinting - bypasses Shazam rate limits entirely
    @MainActor
    func refreshAllfromITunes() async -> (processed: Int, renamed: Int, skipped: Int, errors: Int) {
        let allMetadata = ShazamScannedDatabase.shared.getAllWithAppleMusicID()

        var processed = 0
        var renamed = 0
        var skipped = 0
        var errors = 0

        print("🎵 [iTunes API] Processing \(allMetadata.count) files with Apple Music IDs...")

        for (path, metadata) in allMetadata {
            guard let appleMusicID = metadata.appleMusicID, !appleMusicID.isEmpty else {
                skipped += 1
                continue
            }

            // Check file exists
            guard FileManager.default.fileExists(atPath: path) else {
                print("⏭️ [iTunes API] File not found: \(path)")
                skipped += 1
                continue
            }

            // Fetch from iTunes API
            if let iTunesData = await fetchFromiTunes(appleMusicID: appleMusicID) {
                processed += 1

                // Update stored metadata with fresh iTunes data (album, year, etc.)
                ShazamScannedDatabase.shared.storeMetadata(
                    filePath: path,
                    artist: iTunesData.artist ?? metadata.artist,
                    title: iTunesData.title ?? metadata.title,
                    album: iTunesData.album ?? metadata.album,
                    genre: iTunesData.genre ?? metadata.genre,
                    year: iTunesData.year ?? metadata.year,
                    shazamID: metadata.shazamID,
                    appleMusicID: appleMusicID,
                    wasRenamed: false,
                    originalFilename: metadata.originalFilename,
                    currentFilename: metadata.currentFilename
                )

                // Get updated metadata and rename
                if let updatedMetadata = ShazamScannedDatabase.shared.getMetadata(for: path) {
                    let fileURL = URL(fileURLWithPath: path)
                    let directory = fileURL.deletingLastPathComponent()
                    let ext = fileURL.pathExtension

                    let newName = generateFilenameFromMetadata(updatedMetadata, extension: ext)
                    let newURL = directory.appendingPathComponent(newName)

                    if newURL.path != fileURL.path {
                        if FileManager.default.fileExists(atPath: newURL.path) {
                            print("⚠️ [iTunes API] Destination exists: \(newName)")
                            skipped += 1
                        } else {
                            do {
                                try FileManager.default.moveItem(at: fileURL, to: newURL)
                                print("✅ [iTunes API] Renamed: \(metadata.currentFilename) → \(newName)")

                                ShazamScannedDatabase.shared.updateFilename(
                                    originalPath: path,
                                    newFilename: newName,
                                    newPath: newURL.path
                                )
                                renamed += 1
                            } catch {
                                print("❌ [iTunes API] Rename error: \(error.localizedDescription)")
                                errors += 1
                            }
                        }
                    } else {
                        print("⏭️ [iTunes API] Already named correctly: \(metadata.currentFilename)")
                        skipped += 1
                    }
                }
            } else {
                print("⚠️ [iTunes API] Could not fetch data for ID: \(appleMusicID)")
                errors += 1
            }

            // Small delay to be nice to iTunes API
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
        }

        print("📊 [iTunes API] Complete: \(processed) fetched, \(renamed) renamed, \(skipped) skipped, \(errors) errors")
        onFileRenamed?()

        return (processed, renamed, skipped, errors)
    }

    // Reformat all files with stored metadata using current format
    // This lets users change filename format and apply it without re-scanning
    @MainActor
    func reformatAllFromDatabase() async -> (renamed: Int, skipped: Int, errors: Int) {
        let allMetadata = ShazamScannedDatabase.shared.getReformattableFiles()
        var renamed = 0
        var skipped = 0
        var errors = 0

        print("🔄 [REFORMAT] Starting batch reformat of \(allMetadata.count) files")

        for (path, metadata) in allMetadata {
            // Skip if file doesn't exist at stored path
            guard FileManager.default.fileExists(atPath: path) else {
                print("⏭️ [REFORMAT] File not found, skipping: \(path)")
                skipped += 1
                continue
            }

            let fileURL = URL(fileURLWithPath: path)
            let directory = fileURL.deletingLastPathComponent()
            let ext = fileURL.pathExtension

            // Generate new filename using current format and stored metadata
            let newName = generateFilenameFromMetadata(metadata, extension: ext)
            let newURL = directory.appendingPathComponent(newName)

            // Skip if filename unchanged
            if newURL.path == fileURL.path {
                print("⏭️ [REFORMAT] Already correctly named: \(metadata.currentFilename)")
                skipped += 1
                continue
            }

            // Check if destination already exists
            if FileManager.default.fileExists(atPath: newURL.path) {
                print("⚠️ [REFORMAT] Destination exists, skipping: \(newName)")
                skipped += 1
                continue
            }

            do {
                try FileManager.default.moveItem(at: fileURL, to: newURL)
                print("✅ [REFORMAT] Renamed: \(metadata.currentFilename) → \(newName)")

                // Update database with new path
                ShazamScannedDatabase.shared.updateFilename(
                    originalPath: path,
                    newFilename: newName,
                    newPath: newURL.path
                )

                renamed += 1
            } catch {
                print("❌ [REFORMAT] Error renaming \(metadata.currentFilename): \(error.localizedDescription)")
                errors += 1
            }
        }

        print("📊 [REFORMAT] Complete: \(renamed) renamed, \(skipped) skipped, \(errors) errors")

        // Notify that files were renamed
        await MainActor.run {
            onFileRenamed?()
        }

        return (renamed, skipped, errors)
    }

    // Generate filename from stored metadata
    private func generateFilenameFromMetadata(_ metadata: ShazamStoredMetadata, extension ext: String) -> String {
        let blocks = ShazamSettings.shared.formatBlocks
        var contentParts: [String] = []

        for block in blocks {
            switch block.field {
            case .title:
                if let title = metadata.title, !title.isEmpty { contentParts.append(title) }
            case .artist:
                if let artist = metadata.artist, !artist.isEmpty { contentParts.append(artist) }
            case .albumName:
                if let album = metadata.album, !album.isEmpty { contentParts.append(album) }
            case .genres:
                if let genre = metadata.genre, !genre.isEmpty { contentParts.append(genre) }
            case .year, .releaseDate:
                if let year = metadata.year, !year.isEmpty { contentParts.append(year) }
            case .separator:
                continue
            default:
                continue
            }
        }

        let name = contentParts.joined(separator: " - ")
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
                            .replacingOccurrences(of: ":", with: "-")

        return sanitized + "." + ext
    }

    // Rename a single file using stored metadata (called during scan for unrenamed files)
    private func renameFromStoredMetadata(path: String, metadata: ShazamStoredMetadata) async {
        let fileURL = URL(fileURLWithPath: path)
        let directory = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension

        let newName = generateFilenameFromMetadata(metadata, extension: ext)
        let newURL = directory.appendingPathComponent(newName)

        // Skip if filename unchanged
        if newURL.path == fileURL.path {
            print("⏭️ [SHAZAM] Already correctly named: \(metadata.currentFilename)")
            return
        }

        // Check if destination already exists
        if FileManager.default.fileExists(atPath: newURL.path) {
            print("⚠️ [SHAZAM] Destination exists, skipping: \(newName)")
            return
        }

        do {
            try FileManager.default.moveItem(at: fileURL, to: newURL)
            print("✅ [SHAZAM] Renamed from stored metadata: \(metadata.currentFilename) → \(newName)")

            // Update database with new path
            ShazamScannedDatabase.shared.updateFilename(
                originalPath: path,
                newFilename: newName,
                newPath: newURL.path
            )

            // Notify that file was renamed
            await MainActor.run {
                onFileRenamed?()
            }
        } catch {
            print("❌ [SHAZAM] Error renaming from stored metadata: \(error.localizedDescription)")
        }
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
                shazamID: nil,
                appleMusicID: nil,
                matched: false,
                error: "Could not open audio file"
            )
        }

        let format = audioFile.processingFormat
        let totalDuration = Double(audioFile.length) / format.sampleRate
        print("🔍 [DEEP DIVE] File duration: \(totalDuration) seconds")

        // Skip files that are too short to be real music (sound effects, alerts, etc.)
        if totalDuration < 30.0 {
            print("⏭️ [DEEP DIVE] Skipping - too short (\(Int(totalDuration))s, likely sound effect)")
            return ShazamResult(
                filePath: path,
                fileName: currentFile,
                allGenres: [],
                needsGenreReview: false,
                shazamID: nil,
                appleMusicID: nil,
                matched: false,
                error: "File too short (likely sound effect)"
            )
        }

        // Use longer samples and more random positions like phone Shazam
        let sampleDuration = 25.0 // Longer samples for better matching (like phone app)

        // Generate random positions throughout the song
        // Skip first/last 10% to avoid intros/outros
        let skipStart = totalDuration * 0.1
        let skipEnd = totalDuration * 0.9
        let usableRange = skipEnd - skipStart

        var samplePositions: [Double] = []

        // Add some fixed strategic positions first
        if totalDuration > 40 { samplePositions.append(20.0) }  // After intro
        if totalDuration > 70 { samplePositions.append(45.0) }  // Verse/Chorus
        if totalDuration > 100 { samplePositions.append(70.0) } // Middle

        // Add random positions throughout the song
        // Use fewer positions to avoid rate limiting (Error 201)
        for _ in 0..<4 {  // Reduced from 7 to 4 random positions
            let randomOffset = Double.random(in: 0...usableRange)
            let position = skipStart + randomOffset
            if position + sampleDuration <= totalDuration {
                samplePositions.append(position)
            }
        }

        // Shuffle to randomize order
        samplePositions.shuffle()

        print("🔍 [DEEP DIVE] Will try \(samplePositions.count) positions with \(sampleDuration)s samples (3s delay between attempts)")

        for position in samplePositions {
            // Skip if position is beyond file length
            if position + sampleDuration > totalDuration {
                print("🔍 [DEEP DIVE] Skipping position \(Int(position))s (beyond file length)")
                continue
            }

            print("🔍 [DEEP DIVE] Trying position: \(Int(position))s")
            let result = await detectFile(path: path, startOffset: position, duration: sampleDuration)

            if result.matched {
                print("✅ [DEEP DIVE] Match found at position \(Int(position))s!")
                return result
            } else {
                print("❌ [DEEP DIVE] No match at position \(Int(position))s")
            }

            // Check for rate limiting (error 201) and back off significantly
            if let error = result.error, error.contains("201") {
                print("⚠️ [DEEP DIVE] Rate limited (error 201) - waiting 30 seconds...")
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 second backoff
            } else {
                // Normal delay between attempts to avoid rate limiting
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds (increased from 3)
            }
        }

        print("❌ [DEEP DIVE] No matches found at any position")
        return ShazamResult(
            filePath: path,
            fileName: currentFile,
            allGenres: [],
            needsGenreReview: false,
            shazamID: nil,
            appleMusicID: nil,
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

                // Capture settings value before entering async context
                let formatUsesGenre = await MainActor.run { ShazamSettings.shared.formatUsesGenre }

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
                                    shazamID: nil,
                                    appleMusicID: nil,
                                    matched: false,
                                    error: "No match found"
                                ))
                                return
                            }

                            // Extract all available metadata
                            print("✅ [SHAZAM] Matched: \(mediaItem.title ?? "Unknown") by \(mediaItem.artist ?? "Unknown")")

                            // Debug: Check what's available in mediaItem
                            print("   Genres array: \(mediaItem.genres)")
                            let allGenres = mediaItem.genres.filter { $0 != "Music" }
                            let genre = allGenres.first
                            let year: String? = nil // ShazamKit doesn't provide year/release date

                            // Check if filename already has genre prefix (e.g., "Pop - Artist - Title.mp3")
                            // If so, skip genre review since user already chose it
                            // Must have non-empty genre prefix (not starting with " - ")
                            let parts = fileName.split(separator: " - ", omittingEmptySubsequences: false)
                            let fileHasGenrePrefix = parts.count >= 2 &&
                                                     !parts[0].isEmpty &&
                                                     !fileName.hasPrefix("Track ") // Avoid false positives

                            // Determine if user needs to manually pick genre
                            // ONLY require review if format actually uses genre
                            var needsGenreReview = false

                            if formatUsesGenre {
                                // Format includes genre - check if we need user input
                                needsGenreReview = allGenres.count > 1 || allGenres.isEmpty

                                if fileHasGenrePrefix {
                                    // File already has "Genre - Artist - Title" format
                                    // Extract genre from filename
                                    if let filenameGenre = parts.first {
                                        print("   ℹ️ File already has genre prefix: \(filenameGenre) - skipping review")
                                        needsGenreReview = false
                                    }
                                } else if allGenres.isEmpty {
                                    print("   ⚠️ No genre available - needs manual review")
                                } else if allGenres.count > 1 {
                                    print("   ⚠️ Multiple genres available (\(allGenres.count)) - needs manual review: \(allGenres.joined(separator: ", "))")
                                } else if let genre = genre {
                                    print("   Using Genre: \(genre)")
                                }
                            } else {
                                // Format doesn't use genre - skip review entirely
                                print("   ℹ️ Format doesn't use genre - skipping genre review")
                                if let genre = genre {
                                    print("   Genre (for metadata only): \(genre)")
                                }
                            }

                            // Get Shazam and Apple Music IDs
                            let shazamID = mediaItem.shazamID
                            let appleMusicID = mediaItem.appleMusicID
                            print("   Shazam ID: \(shazamID ?? "nil")")
                            print("   Apple Music ID: \(appleMusicID ?? "nil")")

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
                                shazamID: shazamID,
                                appleMusicID: appleMusicID,
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
                                shazamID: nil,
                                appleMusicID: nil,
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
                                shazamID: nil,
                                appleMusicID: nil,
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
                        shazamID: nil,
                        appleMusicID: nil,
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
                        shazamID: nil,
                        appleMusicID: nil,
                        matched: false,
                        error: "Unknown error"
                    )
                }

                return ShazamResult(
                    filePath: path,
                    fileName: fileName,
                    allGenres: [],
                    needsGenreReview: false,
                    shazamID: nil,
                    appleMusicID: nil,
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
                shazamID: nil,
                appleMusicID: nil,
                matched: false,
                error: error.localizedDescription
            )
        }
    }

    private func createSignature(from url: URL, startOffset: Double = 0.0, duration: Double = 10.0) async throws -> SHSignature {
        print("🎵 [SHAZAM] Opening audio file...")
        let audioFile = try AVAudioFile(forReading: url)
        let sourceFormat = audioFile.processingFormat
        print("🎵 [SHAZAM] Source format: \(sourceFormat.sampleRate)Hz, \(sourceFormat.channelCount) channels")

        // Use standard format that ShazamKit expects (like iPhone microphone)
        let targetSampleRate: Double = 44100.0
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1) else {
            throw NSError(domain: "ShazamService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create target format"])
        }
        print("🎵 [SHAZAM] Target format: \(targetFormat.sampleRate)Hz, \(targetFormat.channelCount) channel (mono)")

        // Calculate frames in source format
        let startFrame = AVAudioFramePosition(sourceFormat.sampleRate * startOffset)
        let maxFrames = AVAudioFrameCount(sourceFormat.sampleRate * duration)
        let totalLength = audioFile.length

        // Ensure we don't read beyond file length
        let actualStartFrame = min(startFrame, totalLength - 1)
        let remainingFrames = AVAudioFrameCount(totalLength - actualStartFrame)
        let frameCount = min(maxFrames, remainingFrames)

        print("🎵 [SHAZAM] Starting at \(startOffset)s, reading \(duration)s")

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            print("❌ [SHAZAM] Failed to create source buffer")
            throw NSError(domain: "ShazamService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }

        // Seek to start position
        audioFile.framePosition = actualStartFrame

        // Read the needed frames
        print("🎵 [SHAZAM] Reading audio data...")
        try audioFile.read(into: sourceBuffer, frameCount: frameCount)
        print("🎵 [SHAZAM] Audio data read successfully")

        // Convert to target format (44.1kHz mono - like iPhone microphone)
        let targetFrameCount = AVAudioFrameCount(Double(frameCount) * targetSampleRate / sourceFormat.sampleRate)
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCount) else {
            print("❌ [SHAZAM] Failed to create target buffer")
            throw NSError(domain: "ShazamService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create target buffer"])
        }

        // Use converter to resample and convert to mono
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            print("⚠️ [SHAZAM] Could not create converter, using source format")
            // Fall back to source format
            let signatureGenerator = SHSignatureGenerator()
            try signatureGenerator.append(sourceBuffer, at: nil)
            return signatureGenerator.signature()
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        converter.convert(to: targetBuffer, error: &error, withInputFrom: inputBlock)
        if let error = error {
            print("⚠️ [SHAZAM] Conversion error: \(error), using source format")
            let signatureGenerator = SHSignatureGenerator()
            try signatureGenerator.append(sourceBuffer, at: nil)
            return signatureGenerator.signature()
        }

        print("🎵 [SHAZAM] Converted to 44.1kHz mono, generating signature...")
        let signatureGenerator = SHSignatureGenerator()
        try signatureGenerator.append(targetBuffer, at: nil)
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

                // Update database with new filename/path
                ShazamScannedDatabase.shared.updateFilename(
                    originalPath: fileURL.path,
                    newFilename: newName,
                    newPath: newURL.path
                )

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

                // Update database with new filename/path
                ShazamScannedDatabase.shared.updateFilename(
                    originalPath: fileURL.path,
                    newFilename: newName,
                    newPath: newURL.path
                )

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
        var contentParts: [String] = []  // Only actual content, no separators

        for block in blocks {
            switch block.field {
            case .title:
                if let title = result.title, !title.isEmpty { contentParts.append(title) }
            case .artist:
                if let artist = result.artist, !artist.isEmpty { contentParts.append(artist) }
            case .albumName:
                if let album = result.album, !album.isEmpty { contentParts.append(album) }
            case .genres:
                if let genre = result.genre, !genre.isEmpty { contentParts.append(genre) }
            case .year, .releaseDate:
                if let year = result.year, !year.isEmpty { contentParts.append(year) }
            case .separator:
                // Separators are handled by joining, skip here
                continue
            default:
                continue
            }
        }

        // Join non-empty parts with " - " separator
        let name = contentParts.joined(separator: " - ")
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
                            .replacingOccurrences(of: ":", with: "-")

        return sanitized + "." + ext
    }

    private func saveMetadata(result: ShazamResult, to url: URL) async throws {
        let ext = url.pathExtension.lowercased()

        // MP3 files: Use ID3TagWriter instead of AVAssetExportSession
        if ext == "mp3" {
            print("🎵 [METADATA] Writing ID3 tags to MP3...")

            var metadata = ID3TagWriter.Metadata()
            metadata.title = result.title
            metadata.artist = result.artist
            metadata.album = result.album
            metadata.genre = result.genre
            metadata.year = result.year

            // If we have an Apple Music ID, fetch artwork from iTunes
            if let appleMusicID = result.appleMusicID {
                let artworkURL = "https://itunes.apple.com/lookup?id=\(appleMusicID)"
                if let url = URL(string: artworkURL) {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: url)
                        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let results = json["results"] as? [[String: Any]],
                           let track = results.first,
                           let artworkURLString = track["artworkUrl100"] as? String {
                            // Get higher resolution artwork
                            let highResURL = artworkURLString.replacingOccurrences(of: "100x100", with: "600x600")
                            if let imageURL = URL(string: highResURL) {
                                let (imageData, _) = try await URLSession.shared.data(from: imageURL)
                                metadata.artworkData = imageData
                                metadata.artworkMimeType = highResURL.contains(".png") ? "image/png" : "image/jpeg"
                                print("🎨 [METADATA] Downloaded artwork for MP3")
                            }
                        }
                    } catch {
                        print("⚠️ [METADATA] Could not fetch artwork: \(error)")
                    }
                }
            }

            try ID3TagWriter.write(metadata: metadata, to: url)
            return
        }

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
        let outputFileType: AVFileType
        switch ext {
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
