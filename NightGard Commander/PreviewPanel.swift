//
//  PreviewPanel.swift
//  NightGard Commander
//
//  Created by Claude on 2025-11-22.
//  Preview panel for opposite pane view (Command-3 feature)
//

import SwiftUI
import AVFoundation

enum PreviewMode {
    case none
    case image
    case audio
    case video
    case text
    case other
}

struct PreviewPanel: View {
    let fileItem: FileItem
    let previewMode: PreviewMode
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header with file name and close button
            HStack {
                Text(fileItem.name)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close preview (⌘3)")
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Preview content - full width, anchored to top
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch previewMode {
                    case .image:
                        ImagePreviewContent(filePath: fileItem.path)
                    case .audio:
                        AudioPreviewContent(filePath: fileItem.path, fileName: fileItem.name)
                    case .video:
                        VideoPreviewContent(filePath: fileItem.path)
                    case .text:
                        TextPreviewContent(filePath: fileItem.path)
                    case .other:
                        QuickLookPreviewContent(filePath: fileItem.path)
                    case .none:
                        Text("No preview available")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

// MARK: - Image Preview

struct ImagePreviewContent: View {
    let filePath: String

    var body: some View {
        if let nsImage = NSImage(contentsOfFile: filePath) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .top)
        } else {
            Text("Cannot load image")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Audio Preview (Metadata + Album Art)

struct AudioPreviewContent: View {
    let filePath: String
    let fileName: String

    @State private var metadata: AudioMetadata?
    @State private var editableTitle: String = ""
    @State private var editableArtist: String = ""
    @State private var editableAlbum: String = ""
    @State private var editableYear: String = ""
    @State private var editableGenre: String = ""
    @State private var editableTrackNumber: String = ""
    @State private var isSaving = false
    @State private var saveMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Album Art - scaled to ~3 inches (250 points), anchored to top-left
            if let artworkData = metadata?.artwork,
               let nsImage = NSImage(data: artworkData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 250, height: 250)
                    .cornerRadius(8)
                    .shadow(radius: 4)
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 250, height: 250)
                    .foregroundColor(.secondary)
            }

            // Editable Metadata (always show all fields)
            VStack(alignment: .leading, spacing: 12) {
                EditableMetadataRow(label: "Title", value: $editableTitle)
                EditableMetadataRow(label: "Artist", value: $editableArtist)
                EditableMetadataRow(label: "Album", value: $editableAlbum)
                EditableMetadataRow(label: "Year", value: $editableYear)
                EditableMetadataRow(label: "Genre", value: $editableGenre)
                EditableMetadataRow(label: "Track", value: $editableTrackNumber)

                Divider()

                MetadataRow(label: "File", value: fileName)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

            // Save button
            HStack {
                if let message = saveMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(message.contains("✅") ? .green : .red)
                }
                Spacer()
                Button(action: { Task { await saveMetadata() } }) {
                    HStack {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Save Changes")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
            .padding(.horizontal)
        }
        .padding()
        .task(id: filePath) {
            await loadAudioMetadata()
        }
        .onChange(of: metadata) { oldValue, newValue in
            // Update editable fields when metadata loads
            editableTitle = newValue?.title ?? ""
            editableArtist = newValue?.artist ?? ""
            editableAlbum = newValue?.album ?? ""
            editableYear = newValue?.year ?? ""
            editableGenre = newValue?.genre ?? ""
            editableTrackNumber = newValue?.trackNumber != nil ? String(newValue!.trackNumber!) : ""
        }
    }

    private func loadAudioMetadata() async {
        let url = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: url)

        var meta = AudioMetadata()

        do {
            let metadata = try await asset.load(.commonMetadata)

            for item in metadata {
                guard let key = item.commonKey?.rawValue else { continue }

                let value = try? await item.load(.value)

                switch key {
                case "title":
                    meta.title = value as? String
                case "artist":
                    meta.artist = value as? String
                case "albumName":
                    meta.album = value as? String
                case "creationDate":
                    if let dateString = value as? String {
                        meta.year = String(dateString.prefix(4))
                    }
                case "type":
                    meta.genre = value as? String
                case "artwork":
                    if let data = value as? Data {
                        meta.artwork = data
                    }
                default:
                    break
                }
            }

            // Try track number from metadata
            let allMetadata = try await asset.load(.metadata)
            if let trackItem = allMetadata.first(where: { $0.commonKey?.rawValue == "trackNumber" }),
               let trackValue = try? await trackItem.load(.value) as? Int {
                meta.trackNumber = trackValue
            }

            await MainActor.run {
                self.metadata = meta
            }
        } catch {
            print("Error loading audio metadata: \(error)")
        }
    }

    private func saveMetadata() async {
        isSaving = true
        saveMessage = nil

        do {
            let url = URL(fileURLWithPath: filePath)
            let asset = AVURLAsset(url: url)

            // Create metadata items for each field
            var metadataItems: [AVMutableMetadataItem] = []

            // Title
            if !editableTitle.isEmpty {
                let item = AVMutableMetadataItem()
                item.keySpace = .common
                item.key = AVMetadataKey.commonKeyTitle as any NSCopying & NSObjectProtocol
                item.value = editableTitle as NSString
                metadataItems.append(item)
            }

            // Artist
            if !editableArtist.isEmpty {
                let item = AVMutableMetadataItem()
                item.keySpace = .common
                item.key = AVMetadataKey.commonKeyArtist as any NSCopying & NSObjectProtocol
                item.value = editableArtist as NSString
                metadataItems.append(item)
            }

            // Album
            if !editableAlbum.isEmpty {
                let item = AVMutableMetadataItem()
                item.keySpace = .common
                item.key = AVMetadataKey.commonKeyAlbumName as any NSCopying & NSObjectProtocol
                item.value = editableAlbum as NSString
                metadataItems.append(item)
            }

            // Year
            if !editableYear.isEmpty {
                let item = AVMutableMetadataItem()
                item.keySpace = .common
                item.key = AVMetadataKey.commonKeyCreationDate as any NSCopying & NSObjectProtocol
                item.value = editableYear as NSString
                metadataItems.append(item)
            }

            // Genre
            if !editableGenre.isEmpty {
                let item = AVMutableMetadataItem()
                item.keySpace = .common
                item.key = AVMetadataKey.commonKeyType as any NSCopying & NSObjectProtocol
                item.value = editableGenre as NSString
                metadataItems.append(item)
            }

            // Export to temp file with updated metadata
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)

            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw NSError(domain: "PreviewPanel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
            }

            exportSession.outputURL = tempURL
            exportSession.outputFileType = .m4a
            exportSession.metadata = metadataItems

            // Use modern async API
            try await exportSession.export(to: tempURL, as: .m4a)

            // Replace original file with updated file
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tempURL, to: url)

            await MainActor.run {
                saveMessage = "✅ Saved successfully"
                isSaving = false
            }

            // Clear message after 3 seconds
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                saveMessage = nil
            }

        } catch {
            await MainActor.run {
                saveMessage = "❌ Save failed: \(error.localizedDescription)"
                isSaving = false
            }
            print("Error saving metadata: \(error)")
        }
    }
}

struct AudioMetadata: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var year: String?
    var genre: String?
    var trackNumber: Int?
    var artwork: Data?
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

struct EditableMetadataRow: View {
    let label: String
    @Binding var value: String

    var body: some View {
        HStack(alignment: .center) {
            Text(label + ":")
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            TextField("Empty", text: $value)
                .textFieldStyle(.roundedBorder)
            Spacer()
        }
    }
}

// MARK: - Video Preview

struct VideoPreviewContent: View {
    let filePath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .foregroundColor(.secondary)

            Text("Video preview")
                .font(.headline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Double-click to play in media player")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Text Preview

struct TextPreviewContent: View {
    let filePath: String

    @State private var content: String = ""

    var body: some View {
        TextEditor(text: .constant(content))
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: filePath) {
            loadTextContent()
        }
    }

    private func loadTextContent() {
        do {
            content = try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            content = "Error loading file: \(error.localizedDescription)"
        }
    }
}

// MARK: - QuickLook Preview

struct QuickLookPreviewContent: View {
    let filePath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .foregroundColor(.secondary)

            Text("Preview not available")
                .font(.headline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Use Command-4 to edit")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
