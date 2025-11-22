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

            // Preview content
            ScrollView {
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
                .frame(maxWidth: .infinity)
        } else {
            Text("Cannot load image")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Audio Preview (Metadata + Album Art)

struct AudioPreviewContent: View {
    let filePath: String
    let fileName: String

    @State private var metadata: AudioMetadata?

    var body: some View {
        VStack(spacing: 20) {
            // Album Art
            if let artworkData = metadata?.artwork,
               let nsImage = NSImage(data: artworkData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 300)
                    .cornerRadius(8)
                    .shadow(radius: 4)
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 200)
                    .foregroundColor(.secondary)
            }

            // Metadata
            VStack(alignment: .leading, spacing: 12) {
                if let title = metadata?.title {
                    MetadataRow(label: "Title", value: title)
                }
                if let artist = metadata?.artist {
                    MetadataRow(label: "Artist", value: artist)
                }
                if let album = metadata?.album {
                    MetadataRow(label: "Album", value: album)
                }
                if let year = metadata?.year {
                    MetadataRow(label: "Year", value: year)
                }
                if let genre = metadata?.genre {
                    MetadataRow(label: "Genre", value: genre)
                }
                if let trackNumber = metadata?.trackNumber {
                    MetadataRow(label: "Track", value: String(trackNumber))
                }

                Divider()

                MetadataRow(label: "File", value: fileName)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .task {
            loadAudioMetadata()
        }
    }

    private func loadAudioMetadata() {
        let url = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: url)

        var meta = AudioMetadata()

        for item in asset.commonMetadata {
            guard let key = item.commonKey?.rawValue,
                  let value = item.value else { continue }

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
        if let trackItem = asset.metadata.first(where: { $0.commonKey?.rawValue == "trackNumber" }),
           let trackValue = trackItem.value as? Int {
            meta.trackNumber = trackValue
        }

        self.metadata = meta
    }
}

struct AudioMetadata {
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

// MARK: - Video Preview

struct VideoPreviewContent: View {
    let filePath: String

    var body: some View {
        VStack {
            Image(systemName: "play.rectangle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
                .foregroundColor(.secondary)

            Text("Video preview")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Double-click to play in media player")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Text Preview

struct TextPreviewContent: View {
    let filePath: String

    @State private var content: String = ""

    var body: some View {
        TextEditor(text: .constant(content))
            .font(.system(.body, design: .monospaced))
            .padding()
        .task {
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
        VStack {
            Image(systemName: "doc.text.magnifyingglass")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
                .foregroundColor(.secondary)

            Text("Preview not available")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Use Command-4 to edit")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
