//
//  iTunesSearchService.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 19 1145
//

import SwiftUI
import AVFoundation

// iTunes Search API result
struct iTunesLookupResult {
    let filePath: String
    let fileName: String
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: String?
    var trackNumber: Int?
    var trackCount: Int?
    var artworkURL: String?
    var appleMusicID: String?  // Track ID from iTunes
    var matched: Bool
    var error: String?
}

// iTunes Search API service
@Observable
class iTunesSearchService {
    // Progress tracking
    var isProcessing = false
    var totalFiles = 0
    var processedFiles = 0
    var currentFile = ""
    var matchedCount = 0
    var unmatchedCount = 0

    // Results
    var results: [iTunesLookupResult] = []

    // Cancellation
    private var isCancelled = false

    // Callback when file metadata is updated
    var onFileUpdated: (() -> Void)?

    // Process all audio files in a folder
    // Priority: Use Apple ID if available, otherwise text search
    @MainActor
    func processFolder(path: String) async {
        isProcessing = true
        isCancelled = false
        results.removeAll()
        processedFiles = 0
        matchedCount = 0
        unmatchedCount = 0

        // Find all audio files in folder
        let audioFiles = findAudioFiles(in: path)
        totalFiles = audioFiles.count

        print("🎵 [ITUNES] Processing \(audioFiles.count) files...")

        for audioFile in audioFiles {
            if isCancelled { break }

            currentFile = (audioFile as NSString).lastPathComponent
            processedFiles += 1

            // === PRIORITY 1: Check for Apple Music ID ===
            var appleMusicID: String?
            let fileName = currentFile

            // Check stored database by exact path
            if let storedMeta = ShazamScannedDatabase.shared.getMetadata(for: audioFile),
               let storedID = storedMeta.appleMusicID, !storedID.isEmpty {
                appleMusicID = storedID
                print("🎯 [ITUNES] Found stored Apple ID (by path): \(storedID)")
            }

            // Check stored database by filename (in case file was renamed/moved)
            if appleMusicID == nil {
                if let storedMeta = ShazamScannedDatabase.shared.findByFilename(fileName),
                   let storedID = storedMeta.appleMusicID, !storedID.isEmpty {
                    appleMusicID = storedID
                    print("🎯 [ITUNES] Found stored Apple ID (by filename): \(storedID)")
                }
            }

            // Check embedded in file
            if appleMusicID == nil {
                appleMusicID = await readAppleMusicID(from: audioFile)
                if let id = appleMusicID {
                    print("🎯 [ITUNES] Found embedded Apple ID: \(id)")
                }
            }

            // === Use ID lookup if we have an ID ===
            if let id = appleMusicID {
                if let iTunesData = await lookupByID(appleMusicID: id) {
                    matchedCount += 1

                    // Rename file per format settings
                    await renameAndUpdateFile(
                        path: audioFile,
                        artist: iTunesData.artist,
                        title: iTunesData.title,
                        album: iTunesData.album,
                        genre: iTunesData.genre,
                        year: iTunesData.year,
                        appleMusicID: id
                    )

                    // Rate limit protection - 1 second between ID lookups
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
            }

            // === FALLBACK: Text search ===
            let result = await lookupFile(path: audioFile)
            results.append(result)

            if result.matched {
                matchedCount += 1
                await updateFileMetadata(result: result)

                // Rename file per format settings (using Apple Music ID if found)
                if let appleMusicID = result.appleMusicID {
                    await renameAndUpdateFile(
                        path: audioFile,
                        artist: result.artist,
                        title: result.title,
                        album: result.album,
                        genre: result.genre,
                        year: result.year,
                        appleMusicID: appleMusicID
                    )
                } else {
                    // No Apple Music ID - still rename based on format blocks
                    await renameFileOnly(
                        path: audioFile,
                        artist: result.artist,
                        title: result.title,
                        album: result.album,
                        genre: result.genre,
                        year: result.year
                    )
                }
            } else {
                unmatchedCount += 1
            }

            // Rate limit protection - 2 seconds between text searches
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        print("📊 [ITUNES] Done: \(matchedCount) matched, \(unmatchedCount) not found")
        isProcessing = false
    }

    // Lookup by Apple Music ID (direct, no searching)
    private func lookupByID(appleMusicID: String) async -> (artist: String?, title: String?, album: String?, genre: String?, year: String?)? {
        let urlString = "https://itunes.apple.com/lookup?id=\(appleMusicID)"
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let track = results.first else {
                print("❌ [ITUNES] No results for ID: \(appleMusicID)")
                return nil
            }

            let title = track["trackName"] as? String
            let artist = track["artistName"] as? String
            let album = track["collectionName"] as? String
            let genre = track["primaryGenreName"] as? String

            var year: String?
            if let releaseDate = track["releaseDate"] as? String {
                year = String(releaseDate.prefix(4))
            }

            print("✅ [ITUNES] ID Lookup: \(artist ?? "?") - \(title ?? "?")")
            return (artist, title, album, genre, year)
        } catch {
            print("❌ [ITUNES] ID Lookup error: \(error.localizedDescription)")
            return nil
        }
    }

    // Read Apple Music ID from file metadata
    private func readAppleMusicID(from path: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)

        do {
            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                let metadata = try await asset.loadMetadata(for: format)
                for item in metadata {
                    if let identifier = item.identifier?.rawValue {
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
        } catch {}
        return nil
    }

    // Rename file, write metadata/artwork, and update database
    private func renameAndUpdateFile(
        path: String,
        artist: String?,
        title: String?,
        album: String?,
        genre: String?,
        year: String?,
        appleMusicID: String
    ) async {
        let originalFilename = (path as NSString).lastPathComponent
        let fileURL = URL(fileURLWithPath: path)
        let directory = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension.lowercased()

        // === WRITE ID3 TAGS WITH ARTWORK FOR MP3 FILES ===
        if ext == "mp3" {
            print("🎵 [ITUNES] Writing ID3 tags to MP3...")

            var metadata = ID3TagWriter.Metadata()
            metadata.title = title
            metadata.artist = artist
            metadata.album = album
            metadata.genre = genre
            metadata.year = year

            // Fetch artwork from iTunes using the Apple Music ID
            let artworkAPIURL = "https://itunes.apple.com/lookup?id=\(appleMusicID)"
            if let url = URL(string: artworkAPIURL) {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let results = json["results"] as? [[String: Any]],
                       let track = results.first,
                       let artworkURLString = track["artworkUrl100"] as? String {
                        // Get higher resolution artwork (600x600)
                        let highResURL = artworkURLString.replacingOccurrences(of: "100x100", with: "600x600")
                        if let imageURL = URL(string: highResURL) {
                            let (imageData, _) = try await URLSession.shared.data(from: imageURL)
                            metadata.artworkData = imageData
                            metadata.artworkMimeType = highResURL.contains(".png") ? "image/png" : "image/jpeg"
                            print("🎨 [ITUNES] Downloaded artwork for MP3")
                        }
                    }
                } catch {
                    print("⚠️ [ITUNES] Could not fetch artwork: \(error)")
                }
            }

            do {
                try ID3TagWriter.write(metadata: metadata, to: fileURL)
            } catch {
                print("❌ [ITUNES] ID3 write error: \(error)")
            }
        }

        // Store in database
        ShazamScannedDatabase.shared.storeMetadata(
            filePath: path,
            artist: artist,
            title: title,
            album: album,
            genre: genre,
            year: year,
            shazamID: nil,
            appleMusicID: appleMusicID,
            wasRenamed: false,
            originalFilename: originalFilename,
            currentFilename: originalFilename
        )

        // Generate new filename using format settings
        let blocks = ShazamSettings.shared.formatBlocks
        var contentParts: [String] = []

        for block in blocks {
            switch block.field {
            case .title:
                if let t = title, !t.isEmpty { contentParts.append(t) }
            case .artist:
                if let a = artist, !a.isEmpty { contentParts.append(a) }
            case .albumName:
                if let a = album, !a.isEmpty { contentParts.append(a) }
            case .genres:
                if let g = genre, !g.isEmpty { contentParts.append(g) }
            case .year, .releaseDate:
                if let y = year, !y.isEmpty { contentParts.append(y) }
            case .separator:
                continue
            default:
                continue
            }
        }

        let newName = contentParts.joined(separator: " - ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-") + "." + ext
        let newURL = directory.appendingPathComponent(newName)

        print("📝 [ITUNES] Current: \(originalFilename)")
        print("📝 [ITUNES] New name: \(newName)")
        print("📝 [ITUNES] Same path? \(newURL.path == fileURL.path)")
        print("📝 [ITUNES] Already exists? \(FileManager.default.fileExists(atPath: newURL.path))")

        // Rename if different (delete existing duplicate if present)
        if newURL.path != fileURL.path {
            do {
                // Delete existing file with same name (eliminate duplicates)
                if FileManager.default.fileExists(atPath: newURL.path) {
                    print("🗑️ [ITUNES] Removing duplicate: \(newName)")
                    try FileManager.default.removeItem(at: newURL)
                }

                try FileManager.default.moveItem(at: fileURL, to: newURL)
                print("✅ [ITUNES] Renamed: \(originalFilename) → \(newName)")

                ShazamScannedDatabase.shared.updateFilename(
                    originalPath: path,
                    newFilename: newName,
                    newPath: newURL.path
                )

                await MainActor.run { onFileUpdated?() }
            } catch {
                print("❌ [ITUNES] Rename error: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        isCancelled = true
    }

    // Rename file only (no Apple Music ID - skip artwork fetch)
    private func renameFileOnly(
        path: String,
        artist: String?,
        title: String?,
        album: String?,
        genre: String?,
        year: String?
    ) async {
        let originalFilename = (path as NSString).lastPathComponent
        let fileURL = URL(fileURLWithPath: path)
        let directory = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension.lowercased()

        // Generate new filename using format settings
        let blocks = ShazamSettings.shared.formatBlocks
        var contentParts: [String] = []

        for block in blocks {
            switch block.field {
            case .title:
                if let t = title, !t.isEmpty { contentParts.append(t) }
            case .artist:
                if let a = artist, !a.isEmpty { contentParts.append(a) }
            case .albumName:
                if let a = album, !a.isEmpty { contentParts.append(a) }
            case .genres:
                if let g = genre, !g.isEmpty { contentParts.append(g) }
            case .year, .releaseDate:
                if let y = year, !y.isEmpty { contentParts.append(y) }
            case .separator:
                continue
            default:
                continue
            }
        }

        guard !contentParts.isEmpty else { return }

        let newName = contentParts.joined(separator: " - ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-") + "." + ext
        let newURL = directory.appendingPathComponent(newName)

        print("📝 [ITUNES] Current: \(originalFilename)")
        print("📝 [ITUNES] New name: \(newName)")

        // Rename if different (delete existing duplicate if present)
        if newURL.path != fileURL.path {
            do {
                // Delete existing file with same name (eliminate duplicates)
                if FileManager.default.fileExists(atPath: newURL.path) {
                    print("🗑️ [ITUNES] Removing duplicate: \(newName)")
                    try FileManager.default.removeItem(at: newURL)
                }

                try FileManager.default.moveItem(at: fileURL, to: newURL)
                print("✅ [ITUNES] Renamed: \(originalFilename) → \(newName)")

                await MainActor.run { onFileUpdated?() }
            } catch {
                print("❌ [ITUNES] Rename error: \(error.localizedDescription)")
            }
        }
    }

    // Single file lookup result
    struct SingleLookupResult {
        let success: Bool
        let title: String?
        let error: String?
    }

    // Lookup and rename a single file (for button tap)
    func lookupAndRenameFile(_ fileURL: URL) async -> SingleLookupResult {
        let path = fileURL.path
        let fileName = fileURL.lastPathComponent

        print("🍎 [ITUNES] Single file lookup: \(fileName)")

        // === PRIORITY 1: Check for Apple Music ID ===
        var appleMusicID: String?

        // Check stored database by exact path
        if let storedMeta = ShazamScannedDatabase.shared.getMetadata(for: path),
           let storedID = storedMeta.appleMusicID, !storedID.isEmpty {
            appleMusicID = storedID
            print("🎯 [ITUNES] Found stored Apple ID (by path): \(storedID)")
        }

        // Check stored database by filename (in case file was renamed/moved)
        if appleMusicID == nil {
            if let storedMeta = ShazamScannedDatabase.shared.findByFilename(fileName),
               let storedID = storedMeta.appleMusicID, !storedID.isEmpty {
                appleMusicID = storedID
                print("🎯 [ITUNES] Found stored Apple ID (by filename): \(storedID)")
            }
        }

        // Check embedded in file
        if appleMusicID == nil {
            appleMusicID = await readAppleMusicID(from: path)
            if let id = appleMusicID {
                print("🎯 [ITUNES] Found embedded Apple ID: \(id)")
            }
        }

        // === Use ID lookup if we have an ID ===
        if let id = appleMusicID {
            if let iTunesData = await lookupByID(appleMusicID: id) {
                // Rename file per format settings
                await renameAndUpdateFile(
                    path: path,
                    artist: iTunesData.artist,
                    title: iTunesData.title,
                    album: iTunesData.album,
                    genre: iTunesData.genre,
                    year: iTunesData.year,
                    appleMusicID: id
                )

                let displayTitle = [iTunesData.artist, iTunesData.title].compactMap { $0 }.joined(separator: " - ")
                return SingleLookupResult(success: true, title: displayTitle.isEmpty ? nil : displayTitle, error: nil)
            }
        }

        // === FALLBACK: Text search ===
        let result = await lookupFile(path: path)

        if result.matched {
            await updateFileMetadata(result: result)

            // Rename file with format settings
            let directory = fileURL.deletingLastPathComponent()
            let ext = fileURL.pathExtension

            let blocks = ShazamSettings.shared.formatBlocks
            var contentParts: [String] = []

            print("📝 [RENAME] Format blocks: \(blocks.map { $0.field })")
            print("📝 [RENAME] iTunes result - Artist: \(result.artist ?? "nil"), Title: \(result.title ?? "nil")")

            for block in blocks {
                switch block.field {
                case .title:
                    if let t = result.title, !t.isEmpty { contentParts.append(t) }
                case .artist:
                    if let a = result.artist, !a.isEmpty { contentParts.append(a) }
                case .albumName:
                    if let a = result.album, !a.isEmpty { contentParts.append(a) }
                case .genres:
                    if let g = result.genre, !g.isEmpty { contentParts.append(g) }
                case .year, .releaseDate:
                    if let y = result.year, !y.isEmpty { contentParts.append(y) }
                case .separator:
                    continue
                default:
                    continue
                }
            }

            print("📝 [RENAME] Content parts: \(contentParts)")

            if !contentParts.isEmpty {
                let newName = contentParts.joined(separator: " - ")
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-") + "." + ext
                let newURL = directory.appendingPathComponent(newName)
                print("📝 [RENAME] New name would be: \(newName)")

                if newURL.path != fileURL.path {
                    do {
                        // Delete existing file with same name (eliminate duplicates)
                        if FileManager.default.fileExists(atPath: newURL.path) {
                            print("🗑️ [ITUNES] Removing duplicate: \(newName)")
                            try FileManager.default.removeItem(at: newURL)
                        }
                        try FileManager.default.moveItem(at: fileURL, to: newURL)
                        print("✅ [ITUNES] Renamed: \(fileName) → \(newName)")
                    } catch {
                        print("❌ [ITUNES] Rename error: \(error.localizedDescription)")
                    }
                }
            }

            let displayTitle = [result.artist, result.title].compactMap { $0 }.joined(separator: " - ")
            return SingleLookupResult(success: true, title: displayTitle.isEmpty ? nil : displayTitle, error: nil)
        } else {
            return SingleLookupResult(success: false, title: nil, error: result.error ?? "No match found")
        }
    }

    // Find all audio files in directory (non-recursive), sorted alphabetically
    private func findAudioFiles(in path: String) -> [String] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else {
            return []
        }

        let audioExtensions = ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg"]
        return contents
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { filename in
                let ext = (filename as NSString).pathExtension.lowercased()
                if audioExtensions.contains(ext) {
                    return (path as NSString).appendingPathComponent(filename)
                }
                return nil
            }
    }

    // Lookup a single file using iTunes Search API
    private func lookupFile(path: String) async -> iTunesLookupResult {
        let fileName = (path as NSString).lastPathComponent
        let fileNameWithoutExt = (fileName as NSString).deletingPathExtension
        print("🎵 [ITUNES] Starting lookup for: \(fileName)")

        // === STEP 1: Parse filename for artist/title ===
        // Common patterns: "Genre - Artist - Title", "Artist - Title", "Title"
        let (fileArtist, fileTitle) = parseFilename(fileNameWithoutExt)

        // === STEP 2: Read embedded metadata ===
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)

        var metaTitle: String?
        var metaArtist: String?

        do {
            let metadata = try await asset.load(.metadata)

            for item in metadata {
                guard let commonKey = item.commonKey else { continue }

                if let value = try? await item.load(.stringValue) {
                    switch commonKey {
                    case .commonKeyTitle:
                        metaTitle = value
                    case .commonKeyArtist:
                        metaArtist = value
                    default:
                        break
                    }
                }
            }
        } catch {
            print("⚠️ [ITUNES] Could not read existing metadata: \(error)")
        }

        // === STEP 3: Cross-reference and determine best search terms ===
        let metaIsGarbage = isGarbageMetadata(title: metaTitle, artist: metaArtist)
        let fileHasInfo = fileArtist != nil || (fileTitle != nil && !isGarbageTitle(fileTitle))

        var searchArtist: String?
        var searchTitle: String?

        if metaIsGarbage && fileHasInfo {
            // Metadata is garbage but filename has info - use filename
            searchArtist = fileArtist
            searchTitle = fileTitle
            print("📋 [ITUNES] Using filename (metadata garbage): \(fileArtist ?? "?") - \(fileTitle ?? "?")")
        } else if !metaIsGarbage {
            // Metadata looks good
            if fileHasInfo && fileArtist != nil && metaArtist != nil {
                // Both have info - check if they agree
                let artistMatch = stringsMatch(fileArtist, metaArtist)
                if artistMatch {
                    // They agree - high confidence
                    searchArtist = metaArtist
                    searchTitle = metaTitle ?? fileTitle
                    print("✅ [ITUNES] Filename & metadata agree: \(searchArtist ?? "?") - \(searchTitle ?? "?")")
                } else {
                    // They disagree - prefer filename if it has artist-title pattern
                    searchArtist = fileArtist ?? metaArtist
                    searchTitle = fileTitle ?? metaTitle
                    print("⚠️ [ITUNES] Filename & metadata disagree, using: \(searchArtist ?? "?") - \(searchTitle ?? "?")")
                }
            } else {
                // Use metadata
                searchArtist = metaArtist
                searchTitle = metaTitle
                print("📋 [ITUNES] Using metadata: \(searchArtist ?? "?") - \(searchTitle ?? "?")")
            }
        } else if !fileHasInfo && metaIsGarbage {
            // Neither has good info - needs Shazam
            print("❌ [ITUNES] No confident search terms - needs Shazam")
            return iTunesLookupResult(
                filePath: path,
                fileName: fileName,
                matched: false,
                error: "Needs Shazam (no confident metadata)"
            )
        }

        // Build search query
        var searchTerms = ""
        if let title = searchTitle, !title.isEmpty {
            searchTerms = title
        }
        if let artist = searchArtist, !artist.isEmpty {
            searchTerms += " \(artist)"
        }

        guard !searchTerms.trimmingCharacters(in: .whitespaces).isEmpty else {
            return iTunesLookupResult(
                filePath: path,
                fileName: fileName,
                matched: false,
                error: "No search terms available"
            )
        }

        print("🔍 [ITUNES] Searching for: \(searchTerms)")

        // Query iTunes Search API
        guard let encodedSearch = searchTerms.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return iTunesLookupResult(
                filePath: path,
                fileName: fileName,
                matched: false,
                error: "Could not encode search terms"
            )
        }

        let urlString = "https://itunes.apple.com/search?term=\(encodedSearch)&media=music&entity=song&limit=1"
        guard let apiURL = URL(string: urlString) else {
            return iTunesLookupResult(
                filePath: path,
                fileName: fileName,
                matched: false,
                error: "Invalid API URL"
            )
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: apiURL)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let results = json?["results"] as? [[String: Any]],
                  let firstResult = results.first else {
                print("❌ [ITUNES] No results found")
                return iTunesLookupResult(
                    filePath: path,
                    fileName: fileName,
                    matched: false,
                    error: "No match found"
                )
            }

            // Extract metadata from result
            let title = firstResult["trackName"] as? String
            let artist = firstResult["artistName"] as? String
            let album = firstResult["collectionName"] as? String
            let genre = firstResult["primaryGenreName"] as? String
            let trackNumber = firstResult["trackNumber"] as? Int
            let trackCount = firstResult["trackCount"] as? Int
            let artworkURL = firstResult["artworkUrl100"] as? String

            // Extract Apple Music ID (trackId)
            var appleMusicID: String?
            if let trackId = firstResult["trackId"] as? Int {
                appleMusicID = String(trackId)
            }

            // Extract year from release date
            var year: String?
            if let releaseDate = firstResult["releaseDate"] as? String {
                year = String(releaseDate.prefix(4)) // "2023-01-01T12:00:00Z" -> "2023"
            }

            print("✅ [ITUNES] Found: \(title ?? "Unknown") - \(artist ?? "Unknown") [ID: \(appleMusicID ?? "none")]")

            return iTunesLookupResult(
                filePath: path,
                fileName: fileName,
                title: title,
                artist: artist,
                album: album,
                genre: genre,
                year: year,
                trackNumber: trackNumber,
                trackCount: trackCount,
                artworkURL: artworkURL,
                appleMusicID: appleMusicID,
                matched: true,
                error: nil
            )

        } catch {
            print("❌ [ITUNES] API error: \(error)")
            return iTunesLookupResult(
                filePath: path,
                fileName: fileName,
                matched: false,
                error: error.localizedDescription
            )
        }
    }

    // Update file metadata with iTunes results
    private func updateFileMetadata(result: iTunesLookupResult) async {
        guard result.matched else { return }

        let fileURL = URL(fileURLWithPath: result.filePath)

        do {
            print("💾 [ITUNES] Updating metadata for: \(result.fileName)")
            try await saveMetadata(result: result, to: fileURL)
            print("✅ [ITUNES] Metadata updated successfully")

            // Store Apple Music ID in database for future lookups
            if let appleMusicID = result.appleMusicID {
                ShazamScannedDatabase.shared.storeMetadata(
                    filePath: result.filePath,
                    artist: result.artist,
                    title: result.title,
                    album: result.album,
                    genre: result.genre,
                    year: result.year,
                    shazamID: nil,
                    appleMusicID: appleMusicID,
                    wasRenamed: false,
                    originalFilename: result.fileName,
                    currentFilename: result.fileName
                )
                print("💾 [ITUNES] Stored Apple Music ID: \(appleMusicID)")
            }

            // Notify that file was updated
            await MainActor.run {
                onFileUpdated?()
            }
        } catch {
            print("❌ [ITUNES] Error saving metadata: \(error)")
        }
    }

    private func saveMetadata(result: iTunesLookupResult, to url: URL) async throws {
        let ext = url.pathExtension.lowercased()

        // MP3 files: Use ID3TagWriter instead of AVAssetExportSession
        if ext == "mp3" {
            print("🎵 [ITUNES] Writing ID3 tags to MP3...")

            var metadata = ID3TagWriter.Metadata()
            metadata.title = result.title
            metadata.artist = result.artist
            metadata.album = result.album
            metadata.genre = result.genre
            metadata.year = result.year
            metadata.trackNumber = result.trackNumber

            // Download artwork if available
            if let artworkURLString = result.artworkURL,
               let artworkURL = URL(string: artworkURLString.replacingOccurrences(of: "100x100", with: "600x600")) {
                do {
                    let (imageData, _) = try await URLSession.shared.data(from: artworkURL)
                    metadata.artworkData = imageData
                    // Detect mime type from URL
                    if artworkURLString.contains(".png") {
                        metadata.artworkMimeType = "image/png"
                    } else {
                        metadata.artworkMimeType = "image/jpeg"
                    }
                    print("🎨 [ITUNES] Downloaded artwork for MP3")
                } catch {
                    print("⚠️ [ITUNES] Could not download artwork: \(error)")
                }
            }

            try ID3TagWriter.write(metadata: metadata, to: url)
            return
        }

        let asset = AVURLAsset(url: url)

        // Prepare metadata items
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

        // Download and embed artwork if available
        if let artworkURLString = result.artworkURL,
           let artworkURL = URL(string: artworkURLString.replacingOccurrences(of: "100x100", with: "600x600")) {
            do {
                let (imageData, _) = try await URLSession.shared.data(from: artworkURL)
                let artworkItem = AVMutableMetadataItem()
                artworkItem.keySpace = .common
                artworkItem.key = AVMetadataKey.commonKeyArtwork as NSString
                artworkItem.value = imageData as NSData
                metadataItems.append(artworkItem)
                print("🎨 [ITUNES] Downloaded artwork")
            } catch {
                print("⚠️ [ITUNES] Could not download artwork: \(error)")
            }
        }

        // Export with new metadata
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "iTunesSearchService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)

        exportSession.metadata = metadataItems

        // Determine output file type (ext already defined above)
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

        try await exportSession.export(to: tempURL, as: outputFileType)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    // MARK: - Filename Parsing Helpers

    /// Parse filename to extract artist and title
    /// Handles patterns: "Genre - Artist - Title", "Artist - Title", "01 Title", "Title"
    private func parseFilename(_ filename: String) -> (artist: String?, title: String?) {
        // Remove track numbers at start (e.g., "01 ", "01. ", "1 - ")
        var cleaned = filename
        let trackNumberPattern = #"^(\d{1,3}[\.\-\s]+)"#
        if let regex = try? NSRegularExpression(pattern: trackNumberPattern),
           let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) {
            cleaned = String(cleaned[Range(match.range, in: cleaned)!.upperBound...])
        }

        // Split by " - "
        let parts = cleaned.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }

        switch parts.count {
        case 3...:
            // "Genre - Artist - Title" or more parts
            // Skip first part (genre), use second as artist, rest as title
            let artist = parts[1]
            let title = parts[2...].joined(separator: " - ")
            return (artist, title)
        case 2:
            // "Artist - Title"
            return (parts[0], parts[1])
        case 1:
            // Just title
            return (nil, parts[0])
        default:
            return (nil, nil)
        }
    }

    /// Check if metadata looks like garbage (Track 01, AudioTrack, etc.)
    private func isGarbageMetadata(title: String?, artist: String?) -> Bool {
        let garbageTitle = isGarbageTitle(title)
        let garbageArtist = isGarbageArtist(artist)

        // If both are garbage or missing, it's garbage
        if (title == nil || garbageTitle) && (artist == nil || garbageArtist) {
            return true
        }

        return false
    }

    private func isGarbageTitle(_ title: String?) -> Bool {
        guard let title = title else { return true }

        let lowered = title.lowercased().trimmingCharacters(in: .whitespaces)

        // Check for common garbage patterns
        let garbagePatterns = [
            #"^track\s*\d+"#,           // "Track 01", "Track01"
            #"^audiotrack\s*\d*"#,      // "AudioTrack 16"
            #"^audio\s*\d+"#,           // "Audio 01"
            #"^\d{1,3}$"#,              // Just a number
            #"^untitled"#,              // "Untitled"
            #"^unknown"#,               // "Unknown"
            #"^m\d{5,}"#,               // "M02503" (ripped track IDs)
        ]

        for pattern in garbagePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) != nil {
                return true
            }
        }

        // Too short to be meaningful
        if lowered.count < 2 {
            return true
        }

        return false
    }

    private func isGarbageArtist(_ artist: String?) -> Bool {
        guard let artist = artist else { return true }

        let lowered = artist.lowercased().trimmingCharacters(in: .whitespaces)

        let garbagePatterns = [
            #"^unknown"#,
            #"^no artist"#,
            #"^artist"#,
            #"^--$"#,
            #"^\-$"#,
        ]

        for pattern in garbagePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) != nil {
                return true
            }
        }

        // Too short
        if lowered.count < 2 {
            return true
        }

        return false
    }

    /// Check if two strings roughly match (case-insensitive, ignoring minor differences)
    private func stringsMatch(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.lowercased().trimmingCharacters(in: .whitespaces),
              let b = b?.lowercased().trimmingCharacters(in: .whitespaces) else {
            return false
        }

        // Exact match
        if a == b { return true }

        // One contains the other
        if a.contains(b) || b.contains(a) { return true }

        // Remove common variations and compare
        let cleanA = a.replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "the ", with: "")
        let cleanB = b.replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "the ", with: "")

        if cleanA == cleanB { return true }

        return false
    }
}
