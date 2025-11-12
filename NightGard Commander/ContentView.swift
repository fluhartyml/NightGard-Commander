//
//  ContentView.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI

enum FocusedPane {
    case left, right
}

struct ContentView: View {
    @State private var leftFileSystem = FileSystemService()
    @State private var rightFileSystem = FileSystemService()
    @State private var serverManager = ServerManager()
    @State private var focusedPane: FocusedPane = .left
    @State private var selectedLeftItem: FileItem?
    @State private var selectedRightItem: FileItem?
    @State private var showTextEditor = false
    @State private var showImagePreview = false
    @State private var previewItem: FileItem?

    // Left pane media player state
    @State private var leftCurrentMedia: FileItem?
    @State private var showLeftMediaPlayer = false
    @State private var autoPlayNextLeft = true
    @State private var autoPlayOppositeLeft = false

    // Right pane media player state
    @State private var rightCurrentMedia: FileItem?
    @State private var showRightMediaPlayer = false
    @State private var autoPlayNextRight = true
    @State private var autoPlayOppositeRight = false

    var activeFocusedFileSystem: FileSystemService {
        focusedPane == .left ? leftFileSystem : rightFileSystem
    }

    var activeSelectedItem: FileItem? {
        focusedPane == .left ? selectedLeftItem : selectedRightItem
    }

    func getFileType(for item: FileItem) -> FileType {
        guard !item.isDirectory else { return .folder }
        let ext = (item.name as NSString).pathExtension.lowercased()

        if ["txt", "md", "rb", "json", "swift", "log", "xml", "yaml", "yml"].contains(ext) {
            return .text
        } else if ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg"].contains(ext) {
            return .audio
        } else if ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext) {
            return .video
        } else if ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp"].contains(ext) {
            return .image
        } else {
            return .other
        }
    }

    func handleDoubleClick(item: FileItem) {
        let fileType = getFileType(for: item)
        previewItem = item

        switch fileType {
        case .folder:
            activeFocusedFileSystem.navigateToFolder(item.path)
        case .text:
            showTextEditor = true
        case .audio, .video:
            startPlayingMedia(item: item)
        case .image:
            showImagePreview = true
        case .other:
            break // Do nothing for unknown file types
        }
    }

    func startPlayingMedia(item: FileItem) {
        // Set media for the appropriate pane
        if focusedPane == .left {
            leftCurrentMedia = item
            showLeftMediaPlayer = true
        } else {
            rightCurrentMedia = item
            showRightMediaPlayer = true
        }
    }

    func switchLeftToRight() {
        // Start playing first media file in right pane
        let rightMedia = rightFileSystem.files.filter { file in
            let type = getFileType(for: file)
            return type == .audio || type == .video
        }
        if let first = rightMedia.first {
            rightCurrentMedia = first
            showRightMediaPlayer = true
        }
    }

    func switchRightToLeft() {
        // Start playing first media file in left pane
        let leftMedia = leftFileSystem.files.filter { file in
            let type = getFileType(for: file)
            return type == .audio || type == .video
        }
        if let first = leftMedia.first {
            leftCurrentMedia = first
            showLeftMediaPlayer = true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Dual-pane layout
            HStack(spacing: 0) {
                // Left pane
                FileBrowserPanel(
                    fileSystem: leftFileSystem,
                    serverManager: serverManager,
                    isFocused: focusedPane == .left,
                    onFocus: { focusedPane = .left },
                    onItemSelect: { item in
                        selectedLeftItem = item
                    },
                    onItemDoubleClick: { item in
                        focusedPane = .left
                        selectedLeftItem = item
                        handleDoubleClick(item: item)
                    },
                    currentMedia: $leftCurrentMedia,
                    showMediaPlayer: $showLeftMediaPlayer,
                    autoPlayNext: $autoPlayNextLeft,
                    autoPlayOpposite: $autoPlayOppositeLeft,
                    onSwitchToOpposite: switchLeftToRight,
                    otherPanePath: rightFileSystem.currentPath
                )

                Divider()

                // Right pane
                FileBrowserPanel(
                    fileSystem: rightFileSystem,
                    serverManager: serverManager,
                    isFocused: focusedPane == .right,
                    onFocus: { focusedPane = .right },
                    onItemSelect: { item in
                        selectedRightItem = item
                    },
                    onItemDoubleClick: { item in
                        focusedPane = .right
                        selectedRightItem = item
                        handleDoubleClick(item: item)
                    },
                    currentMedia: $rightCurrentMedia,
                    showMediaPlayer: $showRightMediaPlayer,
                    autoPlayNext: $autoPlayNextRight,
                    autoPlayOpposite: $autoPlayOppositeRight,
                    onSwitchToOpposite: switchRightToLeft,
                    otherPanePath: leftFileSystem.currentPath
                )
            }

            Divider()

            // Footer with file operations
            HStack(spacing: 12) {
                Button("Delete") {
                    deleteSelectedItem()
                }
                .buttonStyle(.bordered)
                .disabled(activeSelectedItem == nil)

                Spacer()

                Text(focusedPane == .left ? "Left Pane Active" : "Right Pane Active")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
        }
        .sheet(isPresented: $showTextEditor) {
            if let item = previewItem {
                TextFileEditor(
                    filePath: item.path,
                    fileName: item.name,
                    onClose: {
                        showTextEditor = false
                    }
                )
            }
        }
        .sheet(isPresented: $showImagePreview) {
            if let item = previewItem {
                ImagePreview(
                    filePath: item.path,
                    fileName: item.name,
                    onClose: {
                        showImagePreview = false
                    }
                )
            }
        }
    }

    private func deleteSelectedItem() {
        guard let item = activeSelectedItem else { return }

        do {
            try activeFocusedFileSystem.deleteItem(at: item.path)

            // Clear selection
            if focusedPane == .left {
                selectedLeftItem = nil
            } else {
                selectedRightItem = nil
            }
        } catch {
            print("Error deleting item: \(error.localizedDescription)")
        }
    }
}

enum FileType {
    case folder, text, audio, video, image, other
}

#Preview {
    ContentView()
}
