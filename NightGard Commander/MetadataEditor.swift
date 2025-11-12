//
//  MetadataEditor.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 12 0920
//

import SwiftUI
import AVFoundation

struct MetadataEditor: View {
    let filePath: String
    let fileName: String
    let onClose: () -> Void

    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var album: String = ""
    @State private var year: String = ""
    @State private var genre: String = ""
    @State private var composer: String = ""
    @State private var comments: String = ""
    @State private var trackNumber: String = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit Metadata")
                        .font(.headline)
                    Text(fileName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Close") {
                    onClose()
                }
                .keyboardShortcut(.escape, modifiers: [])
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
                        MetadataField(label: "Title", text: $title)
                        MetadataField(label: "Artist", text: $artist)
                        MetadataField(label: "Album", text: $album)
                        MetadataField(label: "Year", text: $year)
                        MetadataField(label: "Genre", text: $genre)
                        MetadataField(label: "Composer", text: $composer)
                        MetadataField(label: "Track #", text: $trackNumber)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Comments")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextEditor(text: $comments)
                                .frame(height: 80)
                                .font(.body)
                                .border(Color.secondary.opacity(0.3))
                        }

                        if let error = errorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Footer buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Changes") {
                    Task {
                        await saveMetadata()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
        }
        .frame(width: 500, height: 600)
        .onAppear {
            loadMetadata()
        }
    }

    private func loadMetadata() {
        let url = URL(fileURLWithPath: filePath)
        let asset = AVAsset(url: url)

        Task {
            do {
                let metadata = try await asset.load(.metadata)

                // Load all values first (async)
                var loadedTitle = ""
                var loadedArtist = ""
                var loadedAlbum = ""
                var loadedYear = ""
                var loadedGenre = ""
                var loadedComposer = ""
                var loadedComments = ""

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
                        case .commonKeyCreator:
                            loadedComposer = value
                        case .commonKeyDescription:
                            loadedComments = value
                        default:
                            break
                        }
                    }
                }

                // Update state on main actor
                await MainActor.run {
                    self.title = loadedTitle.isEmpty ? (fileName as NSString).deletingPathExtension : loadedTitle
                    self.artist = loadedArtist
                    self.album = loadedAlbum
                    self.year = loadedYear
                    self.genre = loadedGenre
                    self.composer = loadedComposer
                    self.comments = loadedComments
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Error loading metadata: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func saveMetadata() async {
        await MainActor.run {
            isSaving = true
            errorMessage = nil
        }

        // Capture values on main actor before entering background task
        let filePath = self.filePath
        let titleValue = self.title
        let artistValue = self.artist
        let albumValue = self.album
        let yearValue = self.year
        let genreValue = self.genre
        let composerValue = self.composer
        let commentsValue = self.comments
        let closeAction = self.onClose

        let result = await Task.detached {
            let url = URL(fileURLWithPath: filePath)
            let asset = AVAsset(url: url)

            do {
                // Create new metadata items
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
                addMetadata(key: .commonKeyCreator, value: composerValue)
                addMetadata(key: .commonKeyDescription, value: commentsValue)

                // Create temporary file for export
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)

                // Export with new metadata
                guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                    throw NSError(domain: "MetadataEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create export session"])
                }

                exportSession.outputURL = tempURL
                exportSession.outputFileType = .mp3
                exportSession.metadata = newMetadata

                await exportSession.export()

                if exportSession.status == .completed {
                    // Replace original file with updated one
                    try FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: tempURL, to: url)
                    return Result<Void, Error>.success(())
                } else {
                    throw NSError(domain: "MetadataEditor", code: 2, userInfo: [NSLocalizedDescriptionKey: exportSession.error?.localizedDescription ?? "Export failed"])
                }
            } catch {
                return Result<Void, Error>.failure(error)
            }
        }.value

        await MainActor.run {
            switch result {
            case .success:
                isSaving = false
                closeAction()
            case .failure(let error):
                errorMessage = "Error saving metadata: \(error.localizedDescription)"
                isSaving = false
            }
        }
    }
}

struct MetadataField: View {
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
