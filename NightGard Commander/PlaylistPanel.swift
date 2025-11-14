//
//  PlaylistPanel.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 12 0852
//

import SwiftUI
import UniformTypeIdentifiers

struct PlaylistPanel: View {
    @Bindable var playlistManager: PlaylistManager
    let isFocused: Bool
    let onFocus: () -> Void
    let onItemSelect: (FileItem) -> Void
    @State private var showSavePanel = false
    @State private var showLoadPanel = false
    @State private var selectedItem: PlaylistItem?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "music.note.list")
                    .font(.title3)
                Text("Playlist")
                    .font(.headline)
                Spacer()
                Text("\(playlistManager.items.count) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))

            Divider()

            // Playlist items
            if playlistManager.items.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No items in playlist")
                        .foregroundColor(.secondary)
                    Text("Right-click media files and select \"Add to Playlist\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(playlistManager.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "music.note")
                                .foregroundColor(.blue)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .lineLimit(1)
                                Text(item.path)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()
                        }
                        .listRowBackground(rowBackground(for: item))
                        .onTapGesture {
                            selectedItem = item
                            // Convert PlaylistItem to FileItem for ContentView
                            let fileItem = FileItem(
                                name: item.name,
                                path: item.path,
                                isDirectory: false,
                                size: 0,
                                modificationDate: Date(),
                                creationDate: Date()
                            )
                            onItemSelect(fileItem)
                            onFocus()
                        }
                        .contextMenu {
                            Button("Remove from Playlist") {
                                if let index = playlistManager.items.firstIndex(where: { $0.id == item.id }) {
                                    playlistManager.removeItem(at: IndexSet(integer: index))
                                }
                            }
                        }
                        .onDrag {
                            // Provide both String path (internal) and URL (external/desktop)
                            let url = URL(fileURLWithPath: item.path)
                            let provider = NSItemProvider()
                            provider.registerObject(item.path as NSString, visibility: .all)
                            provider.registerObject(url as NSURL, visibility: .all)
                            return provider
                        }
                    }
                    .onMove { from, to in
                        playlistManager.moveItem(from: from, to: to)
                    }
                }
                .listStyle(.plain)
                .dropDestination(for: String.self) { droppedPaths, location in
                    // Accept files from file browser - always copy, never delete original
                    for path in droppedPaths {
                        let url = URL(fileURLWithPath: path)
                        let fileItem = FileItem(
                            name: url.lastPathComponent,
                            path: path,
                            isDirectory: false,
                            size: 0,
                            modificationDate: Date(),
                            creationDate: Date()
                        )
                        playlistManager.addItem(fileItem)
                    }
                    return true
                }
            }

            Divider()

            // Controls
            HStack(spacing: 8) {
                Button("Load M3U") {
                    showLoadPanel = true
                }
                .buttonStyle(.bordered)

                Button("Save M3U") {
                    showSavePanel = true
                }
                .buttonStyle(.bordered)
                .disabled(playlistManager.items.isEmpty)

                Spacer()

                Button("Clear") {
                    playlistManager.clear()
                }
                .buttonStyle(.bordered)
                .disabled(playlistManager.items.isEmpty)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
        }
        .fileImporter(
            isPresented: $showLoadPanel,
            allowedContentTypes: [UTType(filenameExtension: "m3u") ?? .plainText, UTType(filenameExtension: "m3u8") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                do {
                    try playlistManager.loadFromM3U(at: url)
                } catch {
                    print("Error loading M3U: \(error)")
                }
            }
        }
        .fileExporter(
            isPresented: $showSavePanel,
            document: M3UDocument(playlist: playlistManager),
            contentType: UTType(filenameExtension: "m3u")!,
            defaultFilename: "playlist.m3u"
        ) { result in
            if case .success(let url) = result {
                print("Saved playlist to: \(url.path)")
            } else if case .failure(let error) = result {
                print("Error saving playlist: \(error)")
            }
        }
    }

    private func rowBackground(for item: PlaylistItem) -> Color {
        if selectedItem?.id == item.id && isFocused {
            return Color.accentColor.opacity(0.3)
        } else if selectedItem?.id == item.id {
            return Color.secondary.opacity(0.2)
        } else {
            return Color.clear
        }
    }
}

// Helper document type for file exporter
struct M3UDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "m3u")!] }

    var playlistManager: PlaylistManager

    init(playlist: PlaylistManager) {
        self.playlistManager = playlist
    }

    init(configuration: ReadConfiguration) throws {
        playlistManager = PlaylistManager()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp.m3u")
        try playlistManager.saveToM3U(at: tempURL)
        let data = try Data(contentsOf: tempURL)
        return FileWrapper(regularFileWithContents: data)
    }
}
