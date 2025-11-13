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
    @State private var leftPlaylistManager = PlaylistManager()
    @State private var rightPlaylistManager = PlaylistManager()
    @State private var focusedPane: FocusedPane = .left
    @State private var selectedLeftItem: FileItem?
    @State private var selectedRightItem: FileItem?
    @State private var selectedLeftItems: Set<FileItem.ID> = []
    @State private var selectedRightItems: Set<FileItem.ID> = []
    @State private var showTextEditor = false
    @State private var showImagePreview = false
    @State private var showMetadataEditor = false
    @State private var previewItem: FileItem?
    @State private var showPlaylistInLeftPane = false
    @State private var showPlaylistInRightPane = false

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

    var isPlaylistMode: Bool {
        (focusedPane == .left && showPlaylistInLeftPane) || (focusedPane == .right && showPlaylistInRightPane)
    }

    var copyTooltip: String {
        isPlaylistMode ? "Copy song to other playlist" : "Copy file to other pane"
    }

    var moveTooltip: String {
        isPlaylistMode ? "Move song to other playlist" : "Move file to other pane"
    }

    var deleteTooltip: String {
        isPlaylistMode ? "Remove from playlist" : "Delete file"
    }

    var isEditEnabled: Bool {
        guard let item = activeSelectedItem else { return false }
        let fileType = getFileType(for: item)

        if isPlaylistMode {
            return fileType == .audio || fileType == .video
        } else {
            return fileType == .text
        }
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

    func toggleLeftPane() {
        if !showPlaylistInLeftPane {
            // Switching FROM files TO playlist - populate with media files
            leftPlaylistManager.clear()
            let mediaFiles = leftFileSystem.files.filter { file in
                let type = getFileType(for: file)
                return type == .audio || type == .video
            }
            for file in mediaFiles {
                leftPlaylistManager.addItem(file)
            }
        }
        showPlaylistInLeftPane.toggle()
    }

    func toggleRightPane() {
        if !showPlaylistInRightPane {
            // Switching FROM files TO playlist - populate with media files
            rightPlaylistManager.clear()
            let mediaFiles = rightFileSystem.files.filter { file in
                let type = getFileType(for: file)
                return type == .audio || type == .video
            }
            for file in mediaFiles {
                rightPlaylistManager.addItem(file)
            }
        }
        showPlaylistInRightPane.toggle()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Playlist toggle toolbar
            HStack {
                // Left pane toggle
                Button(action: { toggleLeftPane() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showPlaylistInLeftPane ? "folder.fill" : "music.note.list")
                        Text(showPlaylistInLeftPane ? "Left: Files" : "Left: Playlist")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .padding(8)

                Spacer()

                // Right pane toggle
                Button(action: { toggleRightPane() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showPlaylistInRightPane ? "folder.fill" : "music.note.list")
                        Text(showPlaylistInRightPane ? "Right: Files" : "Right: Playlist")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .padding(8)
            }
            .background(Color.secondary.opacity(0.05))

            Divider()

            // Dual-pane layout
            HStack(spacing: 0) {
                // Left pane - either file browser or playlist
                if showPlaylistInLeftPane {
                    PlaylistPanel(
                        playlistManager: leftPlaylistManager,
                        isFocused: focusedPane == .left,
                        onFocus: { focusedPane = .left },
                        onItemSelect: { item in
                            selectedLeftItem = item
                        }
                    )
                } else {
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
                        onAddToPlaylist: { item in
                            leftPlaylistManager.addItem(item)
                        },
                        currentMedia: $leftCurrentMedia,
                        showMediaPlayer: $showLeftMediaPlayer,
                        autoPlayNext: $autoPlayNextLeft,
                        autoPlayOpposite: $autoPlayOppositeLeft,
                        onSwitchToOpposite: switchLeftToRight,
                        otherPanePath: rightFileSystem.currentPath,
                        selectedItems: $selectedLeftItems,
                        playlistManager: leftPlaylistManager
                    )
                }

                Divider()

                // Right pane - either file browser or playlist
                if showPlaylistInRightPane {
                    PlaylistPanel(
                        playlistManager: rightPlaylistManager,
                        isFocused: focusedPane == .right,
                        onFocus: { focusedPane = .right },
                        onItemSelect: { item in
                            selectedRightItem = item
                        }
                    )
                } else {
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
                        onAddToPlaylist: { item in
                            rightPlaylistManager.addItem(item)
                        },
                        currentMedia: $rightCurrentMedia,
                        showMediaPlayer: $showRightMediaPlayer,
                        autoPlayNext: $autoPlayNextRight,
                        autoPlayOpposite: $autoPlayOppositeRight,
                        onSwitchToOpposite: switchRightToLeft,
                        otherPanePath: leftFileSystem.currentPath,
                        selectedItems: $selectedRightItems,
                        playlistManager: rightPlaylistManager
                    )
                }
            }

            Divider()

            // Command button bar (MC/NC style)
            HStack(spacing: 0) {
                CommandButton(label: "View", shortcut: "⌘3") {
                    viewSelectedItem()
                }
                .disabled(activeSelectedItem == nil)
                .keyboardShortcut("3", modifiers: .command)
                .help(isPlaylistMode ? "Preview media file" : "Preview file")

                CommandButton(label: "Edit", shortcut: "⌘4") {
                    editSelectedItem()
                }
                .disabled(!isEditEnabled)
                .keyboardShortcut("4", modifiers: .command)
                .help(isPlaylistMode ? "Edit metadata" : "Edit text file")

                CommandButton(label: "Copy", shortcut: "⌘5") {
                    copyToOtherPane()
                }
                .disabled(activeSelectedItem == nil)
                .keyboardShortcut("5", modifiers: .command)
                .help(copyTooltip)

                CommandButton(label: "Move", shortcut: "⌘6") {
                    moveToOtherPane()
                }
                .disabled(activeSelectedItem == nil)
                .keyboardShortcut("6", modifiers: .command)
                .help(moveTooltip)

                CommandButton(label: "New Folder", shortcut: "⌘7") {
                    createNewFolder()
                }
                .keyboardShortcut("7", modifiers: .command)
                .help("Create new folder")
                .disabled(isPlaylistMode)

                CommandButton(label: "Delete", shortcut: "⌘8") {
                    deleteSelectedItem()
                }
                .help(deleteTooltip)
                .disabled(activeSelectedItem == nil)
                .keyboardShortcut("8", modifiers: .command)

                CommandButton(label: "Rename", shortcut: "⌘9") {
                    renameSelectedItem()
                }
                .disabled(activeSelectedItem == nil)
                .keyboardShortcut("9", modifiers: .command)
                .help(isPlaylistMode ? "Rename song display name" : "Rename file")
            }
            .frame(height: 44)
            .background(Color.secondary.opacity(0.08))
        }
        // Standard Mac keyboard shortcuts (invisible buttons)
        .background(
            Group {
                Button("Copy") { copyToOtherPane() }
                    .keyboardShortcut("c", modifiers: .command)
                    .hidden()
                Button("Move") { moveToOtherPane() }
                    .keyboardShortcut("x", modifiers: .command)
                    .hidden()
                Button("Delete") { deleteSelectedItem() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .hidden()
            }
        )
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
        .sheet(isPresented: $showMetadataEditor) {
            if let item = previewItem {
                MetadataEditor(
                    filePath: item.path,
                    fileName: item.name,
                    onClose: {
                        showMetadataEditor = false
                    }
                )
            }
        }
    }

    private func deleteSelectedItem() {
        let selectedIDs = focusedPane == .left ? selectedLeftItems : selectedRightItems
        let itemsToDelete = activeFocusedFileSystem.files.filter { selectedIDs.contains($0.id) }
        guard !itemsToDelete.isEmpty else { return }

        for item in itemsToDelete {
            do {
                try activeFocusedFileSystem.deleteItem(at: item.path)
            } catch {
                print("Error deleting \(item.name): \(error.localizedDescription)")
            }
        }

        // Clear selection
        if focusedPane == .left {
            selectedLeftItem = nil
            selectedLeftItems.removeAll()
        } else {
            selectedRightItem = nil
            selectedRightItems.removeAll()
        }
    }

    // MARK: - Command Button Actions

    private func viewSelectedItem() {
        guard let item = activeSelectedItem else { return }
        previewItem = item

        let fileType = getFileType(for: item)
        switch fileType {
        case .image:
            showImagePreview = true
        case .text:
            showTextEditor = true
        case .audio, .video:
            startPlayingMedia(item: item)
        default:
            break
        }
    }

    private func editSelectedItem() {
        guard let item = activeSelectedItem else { return }
        let fileType = getFileType(for: item)

        if isPlaylistMode {
            // In playlist mode, edit metadata for media files
            if fileType == .audio || fileType == .video {
                previewItem = item
                showMetadataEditor = true
            }
        } else {
            // In file mode, edit text files
            if fileType == .text {
                previewItem = item
                showTextEditor = true
            }
        }
    }

    private func copyToOtherPane() {
        let selectedIDs = focusedPane == .left ? selectedLeftItems : selectedRightItems
        let sourceFiles = activeFocusedFileSystem.files.filter { selectedIDs.contains($0.id) }
        guard !sourceFiles.isEmpty else { return }

        let destinationPath = focusedPane == .left ? rightFileSystem.currentPath : leftFileSystem.currentPath

        for item in sourceFiles {
            do {
                let sourceURL = URL(fileURLWithPath: item.path)
                let fileName = sourceURL.lastPathComponent
                let destURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(fileName)
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            } catch {
                print("Error copying \(item.name) to other pane: \(error.localizedDescription)")
            }
        }

        // Reload both panes
        leftFileSystem.loadFiles()
        rightFileSystem.loadFiles()
    }

    private func moveToOtherPane() {
        let selectedIDs = focusedPane == .left ? selectedLeftItems : selectedRightItems
        let sourceFiles = activeFocusedFileSystem.files.filter { selectedIDs.contains($0.id) }
        guard !sourceFiles.isEmpty else { return }

        let destinationPath = focusedPane == .left ? rightFileSystem.currentPath : leftFileSystem.currentPath

        for item in sourceFiles {
            do {
                let sourceURL = URL(fileURLWithPath: item.path)
                let fileName = sourceURL.lastPathComponent
                let destURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(fileName)
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
            } catch {
                print("Error moving \(item.name) to other pane: \(error.localizedDescription)")
            }
        }

        // Clear selection and reload both panes
        if focusedPane == .left {
            selectedLeftItem = nil
            selectedLeftItems.removeAll()
        } else {
            selectedRightItem = nil
            selectedRightItems.removeAll()
        }
        leftFileSystem.loadFiles()
        rightFileSystem.loadFiles()
    }

    private func createNewFolder() {
        // Trigger folder creation in the active pane
        // This will be handled by FileBrowserPanel's inline creation
        print("New folder creation - handled by panel")
    }

    private func renameSelectedItem() {
        // Trigger rename in the active pane
        // This will be handled by FileBrowserPanel's rename functionality
        print("Rename - handled by panel context menu")
    }
}


enum FileType {
    case folder, text, audio, video, image, other
}

#Preview {
    ContentView()
}
