//
//  ContentView.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI
import AppKit

enum FocusedPane {
    case left, right
}

enum PaneMode {
    case files, playlist, metadata, preview
}

struct ContentView: View {
    // STATE PERSISTENCE - Remember last directories
    @AppStorage("leftPanePath") private var savedLeftPath: String = NSHomeDirectory()
    @AppStorage("rightPanePath") private var savedRightPath: String = NSHomeDirectory()

    @State private var leftFileSystem: FileSystemService
    @State private var rightFileSystem: FileSystemService
    @State private var serverManager = ServerManager()
    @State private var leftPlaylistManager = PlaylistManager()
    @State private var rightPlaylistManager = PlaylistManager()
    @State private var mediaKeyHandler = MediaKeyHandler()
    @State private var focusedPane: FocusedPane = .left
    @State private var selectedLeftItem: FileItem?
    @State private var selectedRightItem: FileItem?
    @State private var selectedLeftItems: Set<FileItem.ID> = []
    @State private var selectedRightItems: Set<FileItem.ID> = []
    @State private var showTextEditor = false
    @State private var showImagePreview = false
    @State private var showMetadataEditor = false
    @State private var previewItem: FileItem?
    @State private var leftPaneMode: PaneMode = .files
    @State private var rightPaneMode: PaneMode = .files
    @State private var leftPreviewMode: PreviewMode = .none
    @State private var rightPreviewMode: PreviewMode = .none
    @State private var leftPreviewItem: FileItem?
    @State private var rightPreviewItem: FileItem?
    @State private var showShazamSettings = false

    init() {
        // Initialize FileSystemServices with saved paths
        let leftPath = UserDefaults.standard.string(forKey: "leftPanePath") ?? NSHomeDirectory()
        let rightPath = UserDefaults.standard.string(forKey: "rightPanePath") ?? NSHomeDirectory()

        _leftFileSystem = State(initialValue: FileSystemService(startPath: leftPath))
        _rightFileSystem = State(initialValue: FileSystemService(startPath: rightPath))
    }

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
        (focusedPane == .left && leftPaneMode == .playlist) || (focusedPane == .right && rightPaneMode == .playlist)
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

        // Check for any webloc files (Safari bookmarks, Apple Music links, etc.)
        if ext == "webloc" {
            return .webloc
        } else if ["txt", "md", "rb", "json", "swift", "log", "xml", "yaml", "yml"].contains(ext) {
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
            // Clear media player when navigating to a different folder
            if focusedPane == .left {
                leftCurrentMedia = nil
                showLeftMediaPlayer = false
            } else {
                rightCurrentMedia = nil
                showRightMediaPlayer = false
            }
        case .text:
            showTextEditor = true
        case .audio, .video:
            startPlayingMedia(item: item)
        case .image:
            showImagePreview = true
        case .webloc:
            // Check if this is an Apple Music audio link (.media.webloc)
            let filename = item.name.lowercased()
            if filename.hasSuffix(".media.webloc") {
                // Apple Music song/album - play in InPaneMediaPlayer with MusicKit
                startPlayingMedia(item: item)
            } else {
                // Video webloc or regular Safari webloc - open externally
                let url = URL(fileURLWithPath: item.path)
                NSWorkspace.shared.open(url)
            }
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
        switch leftPaneMode {
        case .files:
            // Switching FROM files TO playlist - populate with media files
            leftPlaylistManager.clear()
            let mediaFiles = leftFileSystem.files.filter { file in
                let type = getFileType(for: file)
                return type == .audio || type == .video
            }
            for file in mediaFiles {
                leftPlaylistManager.addItem(file)
            }
            leftPaneMode = .playlist
        case .playlist:
            leftPaneMode = .metadata
        case .metadata:
            leftPaneMode = .files
        case .preview:
            // Close preview and return to files
            leftPaneMode = .files
            leftPreviewItem = nil
            leftPreviewMode = .none
        }
    }

    func toggleRightPane() {
        switch rightPaneMode {
        case .files:
            // Switching FROM files TO playlist - populate with media files
            rightPlaylistManager.clear()
            let mediaFiles = rightFileSystem.files.filter { file in
                let type = getFileType(for: file)
                return type == .audio || type == .video
            }
            for file in mediaFiles {
                rightPlaylistManager.addItem(file)
            }
            rightPaneMode = .playlist
        case .playlist:
            rightPaneMode = .metadata
        case .metadata:
            rightPaneMode = .files
        case .preview:
            // Close preview and return to files
            rightPaneMode = .files
            rightPreviewItem = nil
            rightPreviewMode = .none
        }
    }

    // Helper computed properties to reduce type-checking complexity
    private var leftPaneIcon: String {
        switch leftPaneMode {
        case .files: return "music.note.list"
        case .playlist: return "info.circle"
        case .metadata: return "folder.fill"
        case .preview: return "folder.fill"
        }
    }

    private var leftPaneLabel: String {
        switch leftPaneMode {
        case .files: return "Playlist"
        case .playlist: return "Metadata"
        case .metadata: return "Files"
        case .preview: return "Files"
        }
    }

    private var rightPaneIcon: String {
        switch rightPaneMode {
        case .files: return "music.note.list"
        case .playlist: return "info.circle"
        case .metadata: return "folder.fill"
        case .preview: return "folder.fill"
        }
    }

    private var rightPaneLabel: String {
        switch rightPaneMode {
        case .files: return "Playlist"
        case .playlist: return "Metadata"
        case .metadata: return "Files"
        case .preview: return "Files"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Playlist toggle toolbar
            HStack {
                // Left pane toggle
                Button(action: { toggleLeftPane() }) {
                    HStack(spacing: 4) {
                        Image(systemName: leftPaneIcon)
                        Text("Left: \(leftPaneLabel)")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .padding(8)

                Spacer()

                // Right pane toggle
                Button(action: { toggleRightPane() }) {
                    HStack(spacing: 4) {
                        Image(systemName: rightPaneIcon)
                        Text("Right: \(rightPaneLabel)")
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
                // Left pane - file browser, playlist, metadata, or preview
                switch leftPaneMode {
                case .playlist:
                    PlaylistPanel(
                        playlistManager: leftPlaylistManager,
                        isFocused: focusedPane == .left,
                        onFocus: { focusedPane = .left },
                        onItemSelect: { item in
                            selectedLeftItem = item
                        }
                    )
                case .metadata:
                    // Metadata editor showing info for selected file in RIGHT pane
                    MetadataEditorPanel(
                        selectedFile: selectedRightItem,
                        isFocused: focusedPane == .left,
                        onFocus: { focusedPane = .left }
                    )
                case .preview:
                    // Preview panel showing file from RIGHT pane
                    if let item = leftPreviewItem {
                        PreviewPanel(
                            fileItem: item,
                            previewMode: leftPreviewMode,
                            onClose: {
                                leftPaneMode = .files
                                leftPreviewItem = nil
                                leftPreviewMode = .none
                            }
                        )
                    }
                case .files:
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
                        onRefreshOtherPane: {
                            leftFileSystem.loadFiles()
                            rightFileSystem.loadFiles()
                        },
                        onNavigateOtherPane: { path in
                            rightFileSystem.navigateToFolder(path)
                        },
                        selectedItems: $selectedLeftItems,
                        showShazamSettings: $showShazamSettings,
                        playlistManager: leftPlaylistManager
                    )
                }

                Divider()

                // Right pane - file browser, playlist, metadata, or preview
                switch rightPaneMode {
                case .playlist:
                    PlaylistPanel(
                        playlistManager: rightPlaylistManager,
                        isFocused: focusedPane == .right,
                        onFocus: { focusedPane = .right },
                        onItemSelect: { item in
                            selectedRightItem = item
                        }
                    )
                case .metadata:
                    // Metadata editor showing info for selected file in LEFT pane
                    MetadataEditorPanel(
                        selectedFile: selectedLeftItem,
                        isFocused: focusedPane == .right,
                        onFocus: { focusedPane = .right }
                    )
                case .preview:
                    // Preview panel showing file from LEFT pane
                    if let item = rightPreviewItem {
                        PreviewPanel(
                            fileItem: item,
                            previewMode: rightPreviewMode,
                            onClose: {
                                rightPaneMode = .files
                                rightPreviewItem = nil
                                rightPreviewMode = .none
                            }
                        )
                    }
                case .files:
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
                        onRefreshOtherPane: {
                            leftFileSystem.loadFiles()
                            rightFileSystem.loadFiles()
                        },
                        onNavigateOtherPane: { path in
                            leftFileSystem.navigateToFolder(path)
                        },
                        selectedItems: $selectedRightItems,
                        showShazamSettings: $showShazamSettings,
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

                CommandButton(label: "New", shortcut: "⌘7") {
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
        // STATE PERSISTENCE - Save paths whenever they change
        .onChange(of: leftFileSystem.currentPath) { oldValue, newValue in
            savedLeftPath = newValue
        }
        .onChange(of: rightFileSystem.currentPath) { oldValue, newValue in
            savedRightPath = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .openShazamSettings)) { _ in
            showShazamSettings = true
        }
        .onAppear {
            // Wire up hardware media key controls
            mediaKeyHandler.onPlayPause = {
                // Toggle play/pause for whichever pane is currently playing
                if self.showLeftMediaPlayer {
                    self.showLeftMediaPlayer.toggle()
                } else if self.showRightMediaPlayer {
                    self.showRightMediaPlayer.toggle()
                }
            }

            mediaKeyHandler.onNext = {
                // Play next track in focused pane
                // This will be similar to Space key behavior
                if self.focusedPane == .left {
                    // TODO: Add next track function for left pane
                } else {
                    // TODO: Add next track function for right pane
                }
            }

            mediaKeyHandler.onPrevious = {
                // Play previous track in focused pane
                if self.focusedPane == .left {
                    // TODO: Add previous track function for left pane
                } else {
                    // TODO: Add previous track function for right pane
                }
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

        let fileType = getFileType(for: item)
        let previewMode: PreviewMode

        // Determine preview mode based on file type
        switch fileType {
        case .image:
            previewMode = .image
        case .text:
            previewMode = .text
        case .audio:
            previewMode = .audio
        case .video:
            previewMode = .video
        default:
            previewMode = .other
        }

        // Toggle opposite pane to preview mode
        if focusedPane == .left {
            // Active pane is left, show preview in right pane
            rightPreviewMode = previewMode
            rightPreviewItem = item
            rightPaneMode = .preview
        } else {
            // Active pane is right, show preview in left pane
            leftPreviewMode = previewMode
            leftPreviewItem = item
            leftPaneMode = .preview
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

        // DJ CURATION: Check if we're moving the currently playing file
        let currentMedia = focusedPane == .left ? leftCurrentMedia : rightCurrentMedia
        var wasPlayingMovedFile = false
        var nextTrackName: String? = nil

        for item in sourceFiles {
            // Check if this item is currently playing
            if let media = currentMedia, media.path == item.path {
                wasPlayingMovedFile = true

                // Before moving, capture what the next track should be
                let mediaFiles = activeFocusedFileSystem.files.filter { file in
                    let type = getFileType(for: file)
                    return type == .audio || type == .video
                }
                if let currentIndex = mediaFiles.firstIndex(where: { $0.path == item.path }) {
                    let nextIndex = currentIndex + 1
                    if nextIndex < mediaFiles.count {
                        nextTrackName = mediaFiles[nextIndex].name
                    }
                }

                // Stop playback before moving
                if focusedPane == .left {
                    leftCurrentMedia = nil
                    showLeftMediaPlayer = false
                } else {
                    rightCurrentMedia = nil
                    showRightMediaPlayer = false
                }
            }

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

        // DJ CURATION: Auto-play next track after move
        if wasPlayingMovedFile {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                playNextTrackInFocusedPane(preferredTrackName: nextTrackName)
            }
        }
    }

    private func playNextTrackInFocusedPane(preferredTrackName: String? = nil) {
        let mediaFiles = activeFocusedFileSystem.files.filter { file in
            let type = getFileType(for: file)
            return type == .audio || type == .video
        }

        // Try to find the preferred track first (the one that was next before the move)
        var trackToPlay: FileItem? = nil
        if let preferredName = preferredTrackName {
            trackToPlay = mediaFiles.first { $0.name == preferredName }
            if trackToPlay != nil {
                print("Playing preferred next track: \(preferredName)")
            }
        }

        // If no preferred track or it wasn't found, play the first available
        if trackToPlay == nil {
            trackToPlay = mediaFiles.first
            if let first = trackToPlay {
                print("Playing first available track: \(first.name)")
            }
        }

        guard let track = trackToPlay else {
            print("No more tracks to play")
            return
        }

        // Select and play the track with slight delay to let file list update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if self.focusedPane == .left {
                self.selectedLeftItem = track
                self.selectedLeftItems = [track.id]
            } else {
                self.selectedRightItem = track
                self.selectedRightItems = [track.id]
            }
            self.handleDoubleClick(item: track)
        }
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
    case folder, text, audio, video, image, webloc, other
}

#Preview {
    ContentView()
}
