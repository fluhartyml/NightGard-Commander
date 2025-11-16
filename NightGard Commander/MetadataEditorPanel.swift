//
//  MetadataEditorPanel.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 15 1245
//

import SwiftUI
import AVFoundation

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

    var body: some View {
        VStack(spacing: 0) {
            if let file = selectedFile {
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
