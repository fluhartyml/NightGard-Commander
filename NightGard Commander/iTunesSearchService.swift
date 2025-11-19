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

        for audioFile in audioFiles {
            if isCancelled {
                break
            }

            currentFile = (audioFile as NSString).lastPathComponent
            let result = await lookupFile(path: audioFile)
            results.append(result)

            if result.matched {
                matchedCount += 1

                // Auto-update metadata
                await updateFileMetadata(result: result)
            } else {
                unmatchedCount += 1
            }

            processedFiles += 1
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

    // Lookup a single file using iTunes Search API
    private func lookupFile(path: String) async -> iTunesLookupResult {
        let fileName = (path as NSString).lastPathComponent
        print("🎵 [ITUNES] Starting lookup for: \(fileName)")

        // First, read existing metadata to use as search terms
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)

        var existingTitle: String?
        var existingArtist: String?

        do {
            let metadata = try await asset.load(.metadata)

            for item in metadata {
                guard let commonKey = item.commonKey else { continue }

                if let value = try? await item.load(.stringValue) {
                    switch commonKey {
                    case .commonKeyTitle:
                        existingTitle = value
                    case .commonKeyArtist:
                        existingArtist = value
                    default:
                        break
                    }
                }
            }
        } catch {
            print("❌ [ITUNES] Could not read existing metadata: \(error)")
        }

        // If no metadata, use filename as title
        if existingTitle == nil {
            existingTitle = (fileName as NSString).deletingPathExtension
        }

        guard let searchTitle = existingTitle, !searchTitle.isEmpty else {
            return iTunesLookupResult(
                filePath: path,
                fileName: fileName,
                matched: false,
                error: "No title to search for"
            )
        }

        // Build search query
        var searchTerms = searchTitle
        if let artist = existingArtist, !artist.isEmpty {
            searchTerms += " \(artist)"
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

            // Extract year from release date
            var year: String?
            if let releaseDate = firstResult["releaseDate"] as? String {
                year = String(releaseDate.prefix(4)) // "2023-01-01T12:00:00Z" -> "2023"
            }

            print("✅ [ITUNES] Found: \(title ?? "Unknown") - \(artist ?? "Unknown")")

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

            // Notify that file was updated
            await MainActor.run {
                onFileUpdated?()
            }
        } catch {
            print("❌ [ITUNES] Error saving metadata: \(error)")
        }
    }

    private func saveMetadata(result: iTunesLookupResult, to url: URL) async throws {
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

        // Determine output file type
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

        try await exportSession.export(to: tempURL, as: outputFileType)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }
}
