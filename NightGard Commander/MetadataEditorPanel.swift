//
//  MetadataEditorPanel.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 15 1245
//

import SwiftUI
import AVFoundation
import ShazamKit

struct MetadataEditorPanel: View {
    let selectedFile: FileItem?
    let isFocused: Bool
    let onFocus: () -> Void

    @State private var fileName: String = ""
    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var album: String = ""
    @State private var year: String = ""
    @State private var genre: String = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var lastLoadedPath: String?

    // Shazam detection
    @State private var isDetecting = false
    @State private var detectionError: String?

    // Filename format builder
    @State private var showFormatBuilder = false
    @State private var formatBlocks: [FormatBlock] = []

    var body: some View {
        VStack(spacing: 0) {
            if let file = selectedFile {
                // Toolbar with Shazam and Format buttons
                HStack(spacing: 12) {
                    Button(action: {
                        detectWithShazam(file: file)
                    }) {
                        if isDetecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Shazam", systemImage: "shazam.logo.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(isDetecting)
                    .help("Auto-detect song metadata with Shazam")

                    Button(action: {
                        showFormatBuilder = true
                    }) {
                        Label("Set Format", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .help("Configure filename format")

                    Spacer()

                    if let error = detectionError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.05))

                Divider()

                // Filename editor at top
                VStack(spacing: 8) {
                    Text("File Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TextField("Filename", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                }
                .padding()
                .background(Color.secondary.opacity(0.1))

                Divider()

                // Metadata fields
                if isLoading {
                    VStack {
                        Spacer()
                        ProgressView("Loading metadata...")
                        Spacer()
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            MetadataFieldSimple(label: "Title", text: $title)
                            MetadataFieldSimple(label: "Artist", text: $artist)
                            MetadataFieldSimple(label: "Album", text: $album)
                            MetadataFieldSimple(label: "Year", text: $year)
                            MetadataFieldSimple(label: "Genre", text: $genre)
                        }
                        .padding()
                    }
                }

                Divider()

                // Save button
                HStack {
                    Spacer()
                    Button(action: {
                        saveAllMetadata(file: file)
                    }) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.horizontal, 20)
                        } else {
                            Text("Save Metadata")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .padding()
                }
            } else {
                // No file selected
                VStack {
                    Spacer()
                    Image(systemName: "info.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a media file")
                        .foregroundColor(.secondary)
                        .padding()
                    Text("in the opposite pane")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .border(isFocused ? Color.accentColor : Color.clear, width: 2)
        .onTapGesture {
            onFocus()
        }
        .onChange(of: selectedFile) { oldValue, newValue in
            // Auto-save when switching files
            if let oldFile = oldValue, oldFile.path == lastLoadedPath {
                saveAllMetadata(file: oldFile)
            }

            // Load new file
            if let newFile = newValue, newFile.path != lastLoadedPath {
                loadMetadata(for: newFile)
            }
        }
        .onAppear {
            if let file = selectedFile {
                loadMetadata(for: file)
            }
        }
        .sheet(isPresented: $showFormatBuilder) {
            FilenameFormatBuilder(isPresented: $showFormatBuilder, formatBlocks: $formatBlocks)
        }
    }

    private func loadMetadata(for file: FileItem) {
        isLoading = true
        lastLoadedPath = file.path
        fileName = file.name

        let url = URL(fileURLWithPath: file.path)
        let asset = AVURLAsset(url: url)

        Task {
            do {
                let metadata = try await asset.load(.metadata)

                var loadedTitle = ""
                var loadedArtist = ""
                var loadedAlbum = ""
                var loadedYear = ""
                var loadedGenre = ""

                for item in metadata {
                    guard let commonKey = item.commonKey else { continue }

                    if let value = try? await item.load(.stringValue) {
                        switch commonKey {
                        case .commonKeyTitle:
                            loadedTitle = value
                        case .commonKeyArtist:
                            loadedArtist = value
                        case .commonKeyAlbumName:
                            loadedAlbum = value
                        case .commonKeyCreationDate:
                            loadedYear = value
                        case .commonKeyType:
                            loadedGenre = value
                        default:
                            break
                        }
                    }
                }

                await MainActor.run {
                    self.title = loadedTitle.isEmpty ? (file.name as NSString).deletingPathExtension : loadedTitle
                    self.artist = loadedArtist
                    self.album = loadedAlbum
                    self.year = loadedYear
                    self.genre = loadedGenre
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    print("Error loading metadata: \(error)")
                    self.isLoading = false
                }
            }
        }
    }

    private func saveAllMetadata(file: FileItem) {
        isSaving = true

        Task.detached {
            // Step 1: Rename file if needed
            let oldURL = URL(fileURLWithPath: file.path)
            let newFileName = await MainActor.run { fileName }
            var currentURL = oldURL

            if !newFileName.isEmpty && newFileName != file.name {
                let parentURL = oldURL.deletingLastPathComponent()
                let newURL = parentURL.appendingPathComponent(newFileName)

                do {
                    try FileManager.default.moveItem(at: oldURL, to: newURL)
                    currentURL = newURL
                } catch {
                    print("Error renaming file: \(error)")
                }
            }

            // Step 2: Save metadata to file
            let titleValue = await MainActor.run { title }
            let artistValue = await MainActor.run { artist }
            let albumValue = await MainActor.run { album }
            let yearValue = await MainActor.run { year }
            let genreValue = await MainActor.run { genre }

            let asset = AVURLAsset(url: currentURL)

            do {
                var newMetadata: [AVMetadataItem] = []

                func addMetadata(key: AVMetadataKey, value: String) {
                    guard !value.isEmpty else { return }
                    let item = AVMutableMetadataItem()
                    item.keySpace = .common
                    item.key = key as NSString
                    item.value = value as NSString
                    newMetadata.append(item)
                }

                addMetadata(key: .commonKeyTitle, value: titleValue)
                addMetadata(key: .commonKeyArtist, value: artistValue)
                addMetadata(key: .commonKeyAlbumName, value: albumValue)
                addMetadata(key: .commonKeyCreationDate, value: yearValue)
                addMetadata(key: .commonKeyType, value: genreValue)

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(currentURL.pathExtension)

                guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                    print("Could not create export session")
                    await MainActor.run { isSaving = false }
                    return
                }

                exportSession.metadata = newMetadata

                let fileExtension = currentURL.pathExtension.lowercased()
                let outputFileType: AVFileType
                switch fileExtension {
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
                try FileManager.default.removeItem(at: currentURL)
                try FileManager.default.moveItem(at: tempURL, to: currentURL)

                await MainActor.run { isSaving = false }
            } catch {
                print("Error saving metadata: \(error)")
                await MainActor.run { isSaving = false }
            }
        }
    }

    private func detectWithShazam(file: FileItem) {
        isDetecting = true
        detectionError = nil

        Task {
            do {
                // Create audio file URL
                let audioURL = URL(fileURLWithPath: file.path)

                // Read audio file and create signature
                let signature = try await createSignature(from: audioURL)

                // Use delegate pattern for ShazamKit
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let delegate = ShazamSessionDelegate()
                    let session = SHSession()
                    session.delegate = delegate

                    delegate.onMatch = { match in
                        guard let mediaItem = match.mediaItems.first else {
                            Task { @MainActor in
                                detectionError = "No match found"
                                isDetecting = false
                            }
                            continuation.resume()
                            return
                        }

                        // Update fields on main thread
                        Task { @MainActor in
                            if let songTitle = mediaItem.title {
                                title = songTitle
                            }
                            if let songArtist = mediaItem.artist {
                                artist = songArtist
                            }
                            // Note: SHMatchedMediaItem doesn't have albumName or releaseDate properties
                            // These would need to be fetched from Apple Music API separately
                            // For now, we only auto-fill title and artist

                            // Apply filename format if blocks configured
                            applyFilenameFormat()

                            isDetecting = false
                        }
                        continuation.resume()
                    }

                    delegate.onNoMatch = {
                        Task { @MainActor in
                            detectionError = "No match found"
                            isDetecting = false
                        }
                        continuation.resume()
                    }

                    delegate.onError = { error in
                        Task { @MainActor in
                            detectionError = "Detection failed: \(error.localizedDescription)"
                            isDetecting = false
                        }
                        continuation.resume()
                    }

                    // Start matching
                    session.match(signature)
                }
            } catch {
                await MainActor.run {
                    detectionError = "Detection failed: \(error.localizedDescription)"
                    isDetecting = false
                }
            }
        }
    }

    private func createSignature(from url: URL) async throws -> SHSignature {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "MetadataEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }

        try audioFile.read(into: buffer)

        let signatureGenerator = SHSignatureGenerator()
        try signatureGenerator.append(buffer, at: nil)

        return signatureGenerator.signature()
    }

    private func applyFilenameFormat() {
        guard !formatBlocks.isEmpty else { return }

        var parts: [String] = []

        for block in formatBlocks {
            switch block.field {
            case .title:
                if !title.isEmpty { parts.append(title) }
            case .artist:
                if !artist.isEmpty { parts.append(artist) }
            case .albumName:
                if !album.isEmpty { parts.append(album) }
            case .genres:
                if !genre.isEmpty { parts.append(genre) }
            case .year:
                if !year.isEmpty { parts.append(year) }
            case .releaseDate:
                if !year.isEmpty { parts.append(year) }
            case .trackNumber:
                // Track number not provided by Shazam, skip
                continue
            case .separator:
                parts.append("-")
            default:
                // Skip fields not relevant for filename
                continue
            }
        }

        // Construct filename with extension
        if let selectedFile = selectedFile {
            let ext = (selectedFile.name as NSString).pathExtension
            let newName = parts.joined(separator: " ") + "." + ext

            // Sanitize filename (remove invalid characters)
            let sanitized = newName.replacingOccurrences(of: "/", with: "-")
                                    .replacingOccurrences(of: ":", with: "-")

            fileName = sanitized
        }
    }
}

// Simple text field - no auto-save, persists values
struct MetadataFieldSimple: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
