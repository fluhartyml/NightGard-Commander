//
//  FileBrowserPanel.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI
import AppKit

// Track modifier keys at mouseDown time (before SwiftUI gesture fires)
// NOTE: Shift+click is unreliable due to SwiftUI gesture timing - Command+click works
class ModifierKeyTracker {
    static let shared = ModifierKeyTracker()
    private var shiftAtLastClick = false
    private var commandAtLastClick = false
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let flags = event.modifierFlags
            self?.shiftAtLastClick = flags.contains(.shift)
            self?.commandAtLastClick = flags.contains(.command)
            return event
        }
    }

    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func checkModifiers() -> (command: Bool, shift: Bool) {
        return (command: commandAtLastClick, shift: shiftAtLastClick)
    }
}

struct FileBrowserPanel: View {
    @Bindable var fileSystem: FileSystemService
    @Bindable var serverManager: ServerManager
    let isFocused: Bool
    let onFocus: () -> Void
    let onItemSelect: (FileItem) -> Void
    let onItemDoubleClick: (FileItem) -> Void
    let onAddToPlaylist: ((FileItem) -> Void)?
    @Binding var currentMedia: FileItem?
    @Binding var showMediaPlayer: Bool
    @Binding var autoPlayNext: Bool
    @Binding var autoPlayOpposite: Bool
    @Binding var shouldAutoPlay: Bool  // Controls if media auto-plays on load
    @Binding var isCurrentlyPlaying: Bool  // Current playback state
    let onSwitchToOpposite: () -> Void
    var getOppositeFirstMediaURL: (() -> URL?)? = nil  // For crossfade to opposite pane
    let otherPanePath: String
    let onRefreshOtherPane: () -> Void
    let onNavigateOtherPane: (String) -> Void
    @Binding var selectedItems: Set<FileItem.ID>

    @State private var lastSelectedItem: FileItem?
    @State private var isCreatingNewFolder = false
    @State private var isCreatingNewFile = false
    @State private var newItemName = "untitled"
    @State private var renamingItem: FileItem?
    @State private var renameText = ""
    @State private var showAddServerSheet = false
    @State private var mountingServer: ServerConfig?
    @State private var folderToScan: FileItem?
    // Mirrors ShazamSettings.musicLibraryPath so the context menu and the pane
    // header redraw the moment a folder is designated or cleared.
    @State private var musicLibraryTarget: String = ShazamSettings.shared.musicLibraryPath
    @State private var showMultiFolderScan = false
    @State private var selectedFoldersForScan: [FileItem] = []
    @State private var showPlaylistsOnly = false
    @State private var isMovingCurrentMedia = false
    @State private var expandedFolders: Set<String> = []  // Track which folders are expanded
    @State private var folderChildren: [String: [FileItem]] = [:]  // Cache loaded children
    @State private var showDuplicateAlert = false
    @State private var pendingMoveItem: FileItem?
    @State private var showTradingCardCreator = false
    @Binding var showShazamSettings: Bool
    @State private var showBatchShazam = false
    @State private var showBatchITunes = false
    @State private var showQueueReview = false
    @State private var showUnifiedQueue = false
    @FocusState private var isNewItemFocused: Bool
    @FocusState private var isRenameFocused: Bool

    // Nuclear mode state
    @State private var nuclearModeEnabled = false
    @State private var showNuclearToast = false
    @State private var nuclearToastMessage = ""
    @State private var lastMovedFile: (source: String, destination: String, fileName: String)? = nil

    let playlistManager: PlaylistManager?

    // Filter files to show only playlists if enabled
    private var displayedFiles: [FileItem] {
        if showPlaylistsOnly {
            return fileSystem.files.filter { item in
                let ext = (item.name as NSString).pathExtension.lowercased()
                return ext == "m3u" || ext == "m3u8"
            }
        }
        return fileSystem.files
    }

    // Count playlist files in current directory
    private var playlistCount: Int {
        fileSystem.files.filter { item in
            let ext = (item.name as NSString).pathExtension.lowercased()
            return ext == "m3u" || ext == "m3u8"
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Path header with drive selector and up navigation
            HStack(spacing: 8) {
                // Drive selector
                Menu {
                    Section("Local Drives") {
                        ForEach(fileSystem.mountedVolumes) { volume in
                            Button(action: {
                                fileSystem.navigateToFolder(volume.path)
                                currentMedia = nil
                                showMediaPlayer = false
                            }) {
                                HStack {
                                    Image(systemName: "internaldrive.fill")
                                    Text(volume.name)
                                }
                            }
                        }
                    }

                    Section("Servers") {
                        ForEach(serverManager.servers) { server in
                            Button(action: {
                                Task {
                                    await mountAndNavigate(server)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "server.rack")
                                    Text(server.name)
                                    Spacer()
                                    if ServerMountService.shared.isServerMounted(server) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }

                        Divider()

                        Button(action: {
                            showAddServerSheet = true
                        }) {
                            HStack {
                                Image(systemName: "plus.circle")
                                Text("Add Server...")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "externaldrive.fill")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .padding(.leading, 8)
                .help("Switch drive or volume")

                // Sort method selector
                Menu {
                    ForEach(FileSortMethod.allCases, id: \.self) { method in
                        Button(action: {
                            fileSystem.sortMethod = method
                            fileSystem.loadFiles()
                        }) {
                            HStack {
                                Image(systemName: method.icon)
                                Text(method.rawValue)
                                Spacer()
                                if fileSystem.sortMethod == method {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: fileSystem.sortMethod.icon)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .help("Sort files by: \(fileSystem.sortMethod.rawValue)")

                // Playlist filter button
                Button(action: {
                    showPlaylistsOnly.toggle()
                }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "music.note.list")
                            .foregroundColor(showPlaylistsOnly ? .accentColor : .secondary)

                        if playlistCount > 0 {
                            Text("\(playlistCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(2)
                                .background(Circle().fill(Color.red))
                                .offset(x: 8, y: -8)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .frame(width: 30)
                .help(showPlaylistsOnly ? "Show All Files" : "Show Playlists Only (\(playlistCount))")

                // Trading card creator button
                Button(action: {
                    showTradingCardCreator = true
                }) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: 30)
                .help("Create Apple Music Link File")

                // Shazam button - tap for selected file, right-click for folder
                Button(action: {
                    triggerShazamSelectedOrFolder()
                }) {
                    Image(systemName: "shazam.logo.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .contextMenu {
                    Button(action: {
                        showBatchShazam = true
                    }) {
                        Label("Shazam All in Folder", systemImage: "folder.fill")
                    }

                    Button(action: {
                        showQueueReview = true
                    }) {
                        Label("Unmatched Queue (\(ShazamQueue.shared.items.count))", systemImage: "list.bullet")
                    }
                    .disabled(ShazamQueue.shared.items.isEmpty)

                    Button(action: {
                        showUnifiedQueue = true
                    }) {
                        Label("Genre Review Queue (\(GenreReviewQueue.shared.items.count))", systemImage: "music.note.list")
                    }
                    .disabled(GenreReviewQueue.shared.items.isEmpty)

                    Divider()

                    Button(action: {
                        ShazamScannedDatabase.shared.clearAll()
                    }) {
                        Label("Reset Scan Database (\(ShazamScannedDatabase.shared.count()) files)", systemImage: "trash.circle")
                    }
                    .disabled(ShazamScannedDatabase.shared.count() == 0)

                    Button(action: {
                        showShazamSettings = true
                    }) {
                        Label("Shazam Settings...", systemImage: "gear")
                    }
                }
                .help("Click to Shazam selected file | Right-click for folder scan")

                // iTunes Lookup button - tap for selected file, right-click for folder
                Button(action: {
                    triggerITunesLookup()
                }) {
                    Image(systemName: "apple.logo")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .contextMenu {
                    Button(action: {
                        triggerITunesFolderLookup()
                    }) {
                        Label("iTunes Lookup All in Folder", systemImage: "folder.fill")
                    }

                    Button(action: {
                        showQueueReview = true
                    }) {
                        Label("Unmatched Queue (\(ShazamQueue.shared.items.count))", systemImage: "list.bullet")
                    }
                    .disabled(ShazamQueue.shared.items.isEmpty)

                    Button(action: {
                        showUnifiedQueue = true
                    }) {
                        Label("Genre Review Queue (\(GenreReviewQueue.shared.items.count))", systemImage: "music.note.list")
                    }
                    .disabled(GenreReviewQueue.shared.items.isEmpty)
                }
                .help("Click to iTunes lookup selected file | Right-click for folder scan")

                if fileSystem.canNavigateUp() {
                    Button(action: {
                        fileSystem.navigateUp()
                        currentMedia = nil
                        showMediaPlayer = false
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("..")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Go up one folder")
                }

                TickerText(text: fileSystem.currentPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                Spacer()

                // Nuclear mode compass rose
                ZStack {
                    // Center - Nuclear glyph (clickable toggle)
                    Button(action: {
                        nuclearModeEnabled.toggle()
                        nuclearToastMessage = nuclearModeEnabled ? "Nuclear Mode ON" : "Nuclear Mode OFF"
                        showNuclearToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            showNuclearToast = false
                        }
                    }) {
                        Text("☢️")
                            .font(.system(size: 20))
                            .opacity(nuclearModeEnabled ? 1.0 : 0.3)
                    }
                    .buttonStyle(.borderless)
                    .help(nuclearModeEnabled ? "Nuclear Mode: ON (← copy, → move, ↑ prev, ↓ next)" : "Nuclear Mode: OFF (tap to enable)")

                    // North - Up arrow (previous)
                    Text("↑")
                        .font(.system(size: 10))
                        .foregroundColor(nuclearModeEnabled ? .yellow : .clear)
                        .offset(x: 0, y: -15)

                    // South - Down arrow (next)
                    Text("↓")
                        .font(.system(size: 10))
                        .foregroundColor(nuclearModeEnabled ? .yellow : .clear)
                        .offset(x: 0, y: 15)

                    // East - Right arrow (move)
                    Text("→")
                        .font(.system(size: 10))
                        .foregroundColor(nuclearModeEnabled ? .yellow : .clear)
                        .offset(x: 15, y: 0)

                    // West - Left arrow (copy)
                    Text("←")
                        .font(.system(size: 10))
                        .foregroundColor(nuclearModeEnabled ? .yellow : .clear)
                        .offset(x: -15, y: 0)
                }
                .frame(width: 40, height: 40)
                .padding(.trailing, 8)
            }
            .frame(height: 32)
            .background(Color.secondary.opacity(0.1))

            Divider()

            // File list
            if let error = fileSystem.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
                Spacer()
            } else if fileSystem.files.isEmpty {
                VStack {
                    Text("Empty folder")
                        .foregroundColor(.secondary)
                        .padding()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("New Folder") {
                        startCreatingFolder()
                    }
                    Button("New File") {
                        startCreatingFile()
                    }
                }
            } else {
                VStack(spacing: 0) {
                    // Inline new item creation row (above table)
                    if isCreatingNewFolder || isCreatingNewFile {
                        HStack(spacing: 8) {
                            Image(systemName: isCreatingNewFolder ? "folder.fill" : "doc.fill")
                                .foregroundColor(isCreatingNewFolder ? .blue : .secondary)
                                .frame(width: 20)

                            TextField("Name", text: $newItemName)
                                .textFieldStyle(.plain)
                                .focused($isNewItemFocused)
                                .onSubmit {
                                    createInlineItem()
                                }
                                .onKeyPress(.escape) {
                                    cancelInlineCreation()
                                    return .handled
                                }
                                .onAppear {
                                    isNewItemFocused = true
                                }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.1))
                    }

                    // File list with ScrollView for full gesture control
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(displayedFiles) { item in
                                let icon = iconForFile(item)
                                let isSelected = selectedItems.contains(item.id)

                                HStack(spacing: 8) {
                                    Image(systemName: icon.name)
                                        .foregroundColor(icon.color)
                                        .frame(width: 20)

                                    // Play button for media files
                                    if isMediaFile(item) {
                                        Button(action: {
                                            shouldAutoPlay = true
                                            onItemDoubleClick(item)
                                        }) {
                                            Image(systemName: "play.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundColor(.accentColor)
                                        }
                                        .buttonStyle(.borderless)
                                    }

                                    // Open button for folders
                                    if item.isDirectory {
                                        Button(action: {
                                            fileSystem.navigateToFolder(item.path)
                                            currentMedia = nil
                                            showMediaPlayer = false
                                        }) {
                                            Image(systemName: "arrow.right.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundColor(.blue)
                                        }
                                        .buttonStyle(.borderless)
                                    }

                                    if renamingItem?.id == item.id {
                                        TextField("Name", text: $renameText)
                                            .textFieldStyle(.plain)
                                            .focused($isRenameFocused)
                                            .onSubmit {
                                                commitRename(item: item)
                                            }
                                            .onKeyPress(.escape) {
                                                cancelRename()
                                                return .handled
                                            }
                                            .onAppear {
                                                isRenameFocused = true
                                            }
                                    } else {
                                        Text(item.name)
                                            .lineLimit(1)
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    // Double-click: play media or open folder
                                    if item.isDirectory {
                                        fileSystem.navigateToFolder(item.path)
                                        currentMedia = nil
                                        showMediaPlayer = false
                                    } else if isMediaFile(item) {
                                        shouldAutoPlay = true
                                        onItemDoubleClick(item)
                                    }
                                }
                                .onTapGesture(count: 1) {
                                    // Single click: select with modifier key support
                                    let modifiers = ModifierKeyTracker.shared.checkModifiers()

                                    if modifiers.command {
                                        // Command+click: toggle selection
                                        if selectedItems.contains(item.id) {
                                            selectedItems.remove(item.id)
                                        } else {
                                            selectedItems.insert(item.id)
                                        }
                                        lastSelectedItem = item
                                    } else if modifiers.shift {
                                        // Shift+click: range selection
                                        selectRange(to: item)
                                    } else {
                                        // Plain click: single selection
                                        selectedItems = [item.id]
                                        lastSelectedItem = item
                                    }
                                }
                            }
                        }
                    }
                    .focusable()
                    .contextMenu {
                        if selectedItems.count > 1 {
                            Button("Open") {
                                if let firstItem = fileSystem.files.first(where: { selectedItems.contains($0.id) }) {
                                    onItemDoubleClick(firstItem)
                                }
                            }
                            Divider()
                            Button("Copy \(selectedItems.count) Items to Other Pane") {
                                copySelectedToOtherPane()
                            }
                            Button("Move \(selectedItems.count) Items to Other Pane") {
                                moveSelectedToOtherPane()
                            }
                            Divider()
                            Button("Delete \(selectedItems.count) Items") {
                                deleteSelectedItems()
                            }

                            let selectedFiles = fileSystem.files.filter { selectedItems.contains($0.id) }
                            let hasMedia = selectedFiles.contains { isMediaFile($0) }
                            if hasMedia, onAddToPlaylist != nil {
                                Divider()
                                Button("Add \(selectedItems.count) Items to Playlist") {
                                    addSelectedToPlaylist()
                                }
                            }

                            let allFolders = selectedFiles.allSatisfy { $0.isDirectory }
                            if allFolders {
                                Divider()
                                Button("Scan \(selectedItems.count) Folders for Media...") {
                                    scanSelectedFolders()
                                }
                            }
                        } else if let itemID = selectedItems.first,
                                  let item = fileSystem.files.first(where: { $0.id == itemID }) {
                            Button("Rename") {
                                startRenaming(item: item)
                            }
                            Divider()
                            Button("Copy to Other Pane") {
                                copyToOtherPane(item: item)
                            }
                            Button("Move to Other Pane") {
                                moveToOtherPane(item: item)
                            }
                            Divider()
                            Button("Delete") {
                                deleteItem(item: item)
                            }

                            if item.isDirectory {
                                Divider()
                                Button("Scan for Media...") {
                                    folderToScan = item
                                }

                                // Designate this folder as the target music library
                                // parent directory. Saved in Settings, so it survives
                                // a relaunch and does not have to be re-picked.
                                // Standardised on both sides so the interface and the
                                // --set-music-library verb compare equal. This check is
                                // a plain string comparison.
                                let itemPath = URL(fileURLWithPath: item.path).standardizedFileURL.path
                                if ShazamSettings.shared.musicLibraryPath == itemPath {
                                    Button("Clear Target Music Library") {
                                        ShazamSettings.shared.musicLibraryPath = ""
                                        musicLibraryTarget = ""
                                    }
                                } else {
                                    Button("Designate as Target Music Library") {
                                        ShazamSettings.shared.musicLibraryPath = itemPath
                                        musicLibraryTarget = itemPath
                                    }
                                }
                            }

                            if isMediaFile(item), let addAction = onAddToPlaylist {
                                Divider()
                                Button("Add to Playlist") {
                                    addAction(item)
                                }
                            }
                        } else {
                            Button("New Folder") {
                                startCreatingFolder()
                            }
                            Button("New File") {
                                startCreatingFile()
                            }
                        }
                    }
                    .dropDestination(for: String.self) { droppedPaths, location in
                        // Drop onto pane copies to current directory (internal drags)
                        for sourcePath in droppedPaths {
                            do {
                                let sourceURL = URL(fileURLWithPath: sourcePath)
                                let fileName = sourceURL.lastPathComponent
                                let destURL = URL(fileURLWithPath: fileSystem.currentPath).appendingPathComponent(fileName)
                                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                            } catch {
                                print("Error copying file: \(error)")
                            }
                        }
                        fileSystem.loadFiles()
                        return true
                    }
                    .onChange(of: selectedItems) { oldValue, newValue in
                        if let firstID = newValue.first,
                           let item = fileSystem.files.first(where: { $0.id == firstID }) {
                            // Don't update lastSelectedItem here - it's set in tap gesture
                            // and changing it here breaks Shift+click range selection
                            onFocus()
                            onItemSelect(item)
                        }
                    }
                    .onChange(of: fileSystem.files) { oldValue, newValue in
                        // Restore selection to the folder we came from
                        if let lastFolder = fileSystem.lastVisitedFolder,
                           let item = newValue.first(where: { $0.name == lastFolder }) {
                            selectedItems = [item.id]
                            lastSelectedItem = item
                            fileSystem.lastVisitedFolder = nil // Clear after use
                        }
                    }
                    // DJ CURATION KEYBOARD SHORTCUTS
                    .onKeyPress(.return) {
                        // Enter/Return = Open folder or play media
                        if let firstID = selectedItems.first,
                           let item = fileSystem.files.first(where: { $0.id == firstID }) {
                            if item.isDirectory {
                                fileSystem.navigateToFolder(item.path)
                                currentMedia = nil
                                showMediaPlayer = false
                            } else if isMediaFile(item) {
                                shouldAutoPlay = true
                                onItemDoubleClick(item)
                            }
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.init("m")) {
                        // M = Move selected file to other pane + play next
                        if let firstID = selectedItems.first,
                           let item = fileSystem.files.first(where: { $0.id == firstID }) {
                            moveToOtherPane(item: item)
                        }
                        return .handled
                    }
                    // NUCLEAR MODE ARROW KEYS
                    .onKeyPress(.leftArrow) {
                        if nuclearModeEnabled {
                            // ← = Undo last move (nuclear mode)
                            undoLastMove()
                            return .handled
                        }
                        return .ignored  // Let table handle arrow navigation
                    }
                    .onKeyPress(.rightArrow) {
                        if nuclearModeEnabled {
                            // → = Move to other pane + auto-play next (nuclear mode)
                            nuclearModeMove()
                            return .handled
                        }
                        return .ignored  // Let table handle arrow navigation
                    }
                    .onKeyPress(.upArrow) {
                        if nuclearModeEnabled {
                            // ↑ = Previous track + auto-play (nuclear mode)
                            playPreviousTrack()
                            return .handled
                        } else if isCurrentlyPlaying {
                            // ↑ = Previous track when playing
                            playPreviousTrack()
                            return .handled
                        } else {
                            // Navigate selection up
                            navigateSelection(direction: -1)
                            return .handled
                        }
                    }
                    .onKeyPress(.downArrow) {
                        if nuclearModeEnabled {
                            // ↓ = Next track + auto-play (nuclear mode)
                            advanceToNextTrack()
                            return .handled
                        } else if isCurrentlyPlaying {
                            // ↓ = Next track when playing
                            advanceToNextTrack()
                            return .handled
                        } else {
                            // Navigate selection down
                            navigateSelection(direction: 1)
                            return .handled
                        }
                    }
                    .onKeyPress(.space) {
                        // Space = Play/Pause
                        if currentMedia != nil {
                            if showMediaPlayer {
                                // Player is visible - toggle play/pause
                                if isCurrentlyPlaying {
                                    // Currently playing - pause it
                                    shouldAutoPlay = false
                                    isCurrentlyPlaying = false
                                } else {
                                    // Currently paused - start playing
                                    shouldAutoPlay = true
                                    isCurrentlyPlaying = true
                                }
                                // Force refresh by toggling media
                                let media = currentMedia
                                currentMedia = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    currentMedia = media
                                }
                            } else {
                                // Player not visible - show it and auto-play
                                showMediaPlayer = true
                                shouldAutoPlay = true
                            }
                        } else {
                            // No media playing - play the highlighted/selected file
                            if let selectedFile = fileSystem.files.first(where: { selectedItems.contains($0.id) }),
                               isMediaFile(selectedFile) {
                                // Play the selected media file
                                currentMedia = selectedFile
                                showMediaPlayer = true
                                shouldAutoPlay = true
                            } else {
                                // No selection or not a media file - play first track in folder
                                playNextTrack()
                            }
                        }
                        return .handled
                    }
                }
            }

            // Selected file metadata footer
            if let selectedID = selectedItems.first,
               let selectedFile = fileSystem.files.first(where: { $0.id == selectedID }) {
                Divider()
                HStack(spacing: 12) {
                    // File type icon
                    let icon = iconForFile(selectedFile)
                    Image(systemName: icon.name)
                        .foregroundColor(icon.color)

                    // File name
                    Text(selectedFile.name)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    // Size
                    Text(selectedFile.displaySize)
                        .foregroundColor(.secondary)

                    // Date
                    Text(selectedFile.displayDate)
                        .foregroundColor(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
            }

            // In-pane media player (shows only when playing)
            InPaneMediaPlayer(
                currentMedia: $currentMedia,
                isVisible: $showMediaPlayer,
                autoPlayNext: $autoPlayNext,
                autoPlayOpposite: $autoPlayOpposite,
                shouldAutoPlay: $shouldAutoPlay,
                isCurrentlyPlaying: $isCurrentlyPlaying,
                fileSystem: fileSystem,
                onSwitchToOpposite: onSwitchToOpposite,
                getOppositeFirstMediaURL: getOppositeFirstMediaURL
            )

            // Breadcrumbs footer
            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // File count
                    Text("\(displayedFiles.count) items")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 8)

                    Text("›")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(Array(fileSystem.breadcrumbs.enumerated()), id: \.element.id) { index, breadcrumb in
                        Button(action: {
                            fileSystem.navigateToFolder(breadcrumb.path)
                            currentMedia = nil
                            showMediaPlayer = false
                        }) {
                            Text(breadcrumb.name)
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)

                        if index < fileSystem.breadcrumbs.count - 1 {
                            Text("›")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(height: 24)
            .background(Color.secondary.opacity(0.05))
        }
        .border(isFocused ? Color.accentColor : Color.clear, width: 2)
        .onTapGesture {
            // Clicking empty space clears selection
            selectedItems.removeAll()
            onFocus()
        }
        .onAppear {
            fileSystem.loadFiles()
        }
        .onChange(of: fileSystem.files) { oldFiles, newFiles in
            // Check if currently playing media file still exists
            if let media = currentMedia {
                let fileStillExists = newFiles.contains { $0.path == media.path }
                if !fileStillExists {
                    // File was removed - check if it was moved or deleted
                    if isMovingCurrentMedia {
                        // File was moved - auto-advance to next track if auto-play is enabled OR nuclear mode is on
                        isMovingCurrentMedia = false

                        // Force stop current player before advancing
                        currentMedia = nil
                        showMediaPlayer = false

                        if autoPlayNext || nuclearModeEnabled {
                            // Small delay to let player fully stop before loading next track
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                // Find the media files (audio/video only)
                                let mediaFiles = newFiles.filter { !$0.isDirectory && isMediaFile($0) }
                                // Find what would have been the next file after the moved one
                                let oldMediaFiles = oldFiles.filter { !$0.isDirectory && isMediaFile($0) }
                                if let oldIndex = oldMediaFiles.firstIndex(where: { $0.id == media.id }) {
                                    if oldIndex < mediaFiles.count {
                                        // Play the file that's now at the same position
                                        currentMedia = mediaFiles[oldIndex]
                                        showMediaPlayer = true
                                    } else if !mediaFiles.isEmpty {
                                        // Past the end, play first file
                                        currentMedia = mediaFiles[0]
                                        showMediaPlayer = true
                                    }
                                } else if !mediaFiles.isEmpty {
                                    // If we can't find the position, play the first file
                                    currentMedia = mediaFiles[0]
                                    showMediaPlayer = true
                                }
                            }
                        }
                    } else {
                        // File was deleted (not moved) - stop playback
                        currentMedia = nil
                        showMediaPlayer = false
                    }
                }
            }
        }
        .onChange(of: currentMedia) { _, newMedia in
            // Update selection highlight when media changes (e.g., auto-play)
            if let media = newMedia {
                selectedItems.removeAll()
                selectedItems.insert(media.id)
                onItemSelect(media)
            }
        }
        .sheet(isPresented: $showAddServerSheet) {
            ServerConfigSheet(serverManager: serverManager) { server, password in
                handleAddServer(server, password: password)
            }
        }
        .sheet(item: $folderToScan) { folder in
            ScanForMediaDialog(
                sourceFolder: folder,
                destinationPath: otherPanePath,
                playlistManager: playlistManager,
                onComplete: {
                    onRefreshOtherPane()
                },
                onNavigateOtherPane: onNavigateOtherPane,
                isPresented: Binding(
                    get: { folderToScan != nil },
                    set: { if !$0 { folderToScan = nil } }
                )
            )
        }
        .sheet(isPresented: $showMultiFolderScan) {
            ScanForMediaDialog(
                sourceFolders: selectedFoldersForScan,
                destinationPath: otherPanePath,
                playlistManager: playlistManager,
                onComplete: {
                    onRefreshOtherPane()
                },
                onNavigateOtherPane: onNavigateOtherPane,
                isPresented: $showMultiFolderScan
            )
        }
        .sheet(isPresented: $showTradingCardCreator) {
            TradingCardCreatorDialog(
                isPresented: $showTradingCardCreator,
                currentPath: fileSystem.currentPath,
                onRefresh: {
                    fileSystem.loadFiles()
                }
            )
        }
        .sheet(isPresented: $showShazamSettings) {
            ShazamSettingsPanel(isPresented: $showShazamSettings)
        }
        .sheet(isPresented: $showBatchShazam) {
            BatchShazamDialog(
                isPresented: $showBatchShazam,
                folderPath: fileSystem.currentPath,
                folderName: (fileSystem.currentPath as NSString).lastPathComponent,
                onFileRenamed: {
                    fileSystem.loadFiles()
                }
            )
        }
        .sheet(isPresented: $showBatchITunes) {
            BatchITunesDialog(
                isPresented: $showBatchITunes,
                folderPath: fileSystem.currentPath,
                folderName: (fileSystem.currentPath as NSString).lastPathComponent,
                onFileUpdated: {
                    fileSystem.loadFiles()
                }
            )
        }
        .sheet(isPresented: $showQueueReview) {
            QueueReviewPanel(
                isPresented: $showQueueReview,
                onSelectFile: { filePath in
                    // Navigate to file and select it
                    let folderPath = (filePath as NSString).deletingLastPathComponent
                    fileSystem.navigateToFolder(folderPath)
                }
            )
        }
        .sheet(isPresented: $showUnifiedQueue) {
            UnifiedQueueReviewPanel(
                isPresented: $showUnifiedQueue,
                onFileRenamed: onRefreshOtherPane
            )
        }
        .alert("File Already Exists", isPresented: $showDuplicateAlert) {
            Button("Replace", role: .destructive) {
                if let item = pendingMoveItem {
                    executeMoveToOtherPane(item: item, replace: true)
                }
                pendingMoveItem = nil
            }
            Button("Keep Both") {
                if let item = pendingMoveItem {
                    executeMoveToOtherPane(item: item, replace: false)
                }
                pendingMoveItem = nil
            }
            Button("Cancel", role: .cancel) {
                pendingMoveItem = nil
                isMovingCurrentMedia = false
            }
        } message: {
            if let item = pendingMoveItem {
                Text("A file named \"\(item.name)\" already exists in the destination. Do you want to replace it or keep both?")
            }
        }
        .overlay(alignment: .top) {
            if showNuclearToast {
                Text(nuclearToastMessage)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.8))
                    )
                    .padding(.top, 50)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: showNuclearToast)
        .onChange(of: selectedItems) { oldValue, newValue in
            // When selection changes, update player if it's a media file
            // BUT don't interfere with nuclear mode or active playback navigation
            if let selectedID = newValue.first,
               let selectedFile = fileSystem.files.first(where: { $0.id == selectedID }),
               isMediaFile(selectedFile) {

                // In nuclear mode, don't reset autoplay - keyboard navigation handles it
                if nuclearModeEnabled {
                    return
                }

                // If player is showing (visible but maybe paused), update the media
                // If player is not showing and not playing, show it paused
                if showMediaPlayer || currentMedia != nil {
                    // Update the current media to show new file's info
                    currentMedia = selectedFile
                    if !isCurrentlyPlaying {
                        // Keep it paused, just update the display
                        shouldAutoPlay = false
                    } else {
                        // Currently playing - keep playing the new track
                        shouldAutoPlay = true
                    }
                } else if !isCurrentlyPlaying {
                    // No player showing and nothing playing - show player paused for selected media file
                    currentMedia = selectedFile
                    showMediaPlayer = true
                    shouldAutoPlay = false
                }
            }
        }
    }

    // MARK: - Shazam Integration

    private func triggerShazamFolder() {
        print("🔵 [SHAZAM BUTTON] Clicked!")
        // Check if user has configured Shazam settings (first-run check)
        if !ShazamSettings.shared.isConfigured {
            print("⚙️ [SHAZAM] Not configured, showing settings")
            // Show settings panel first
            showShazamSettings = true
        } else {
            print("▶️ [SHAZAM] Starting batch scan")
            // Start batch Shazam
            showBatchShazam = true
        }
    }

    private func triggerShazamSelectedOrFolder() {
        // Check if a media file is selected
        if let selectedID = selectedItems.first,
           let selectedFile = fileSystem.files.first(where: { $0.id == selectedID }),
           isMediaFile(selectedFile) {

            // BEFORE scanning: find the NEXT file's name (in case current file gets renamed)
            var nextFileName: String? = nil
            if autoPlayNext {
                let mediaFiles = fileSystem.files.filter { isMediaFile($0) }
                if let currentIndex = mediaFiles.firstIndex(where: { $0.id == selectedID }),
                   currentIndex + 1 < mediaFiles.count {
                    nextFileName = mediaFiles[currentIndex + 1].name
                    print("📋 Next file will be: \(nextFileName!)")
                }
            }

            // Scan the selected file
            print("🔵 [SHAZAM] Scanning selected file: \(selectedFile.name)")
            Task {
                let result = await ShazamService.shared.processSingleFile(URL(fileURLWithPath: selectedFile.path))
                await MainActor.run {
                    // Refresh file list to show renamed file
                    fileSystem.loadFiles()

                    // Show toast with result
                    if result.success {
                        nuclearToastMessage = "✅ \(result.title ?? selectedFile.name)"
                    } else {
                        nuclearToastMessage = "❌ No match found"
                    }
                    showNuclearToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        showNuclearToast = false
                    }

                    // Follow "Next" toggle - advance and continue scanning if enabled
                    if autoPlayNext, let nextName = nextFileName {
                        // Find and select the next file by name
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let mediaFiles = self.fileSystem.files.filter { self.isMediaFile($0) }
                            if let nextFile = mediaFiles.first(where: { $0.name == nextName }) {
                                self.selectedItems = [nextFile.id]
                                self.lastSelectedItem = nextFile
                                self.onItemSelect(nextFile)
                                print("➡️ Advanced to: \(nextFile.name)")

                                // Continue scanning the next file
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    self.triggerShazamSelectedOrFolder()
                                }
                            } else {
                                print("⏹️ Next file not found or reached end")
                            }
                        }
                    } else if autoPlayNext {
                        print("⏹️ Reached end of folder")
                    }
                }
            }
        } else {
            // No file selected - show hint
            nuclearToastMessage = "Select a file to scan"
            showNuclearToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showNuclearToast = false
            }
        }
    }

    // Advance selection to next media file (without playing)
    // Uses filename matching since IDs change after file list refresh
    private func advanceSelectionToNextMedia() {
        let mediaFiles = fileSystem.files.filter { isMediaFile($0) }
        guard !mediaFiles.isEmpty else {
            print("⏹️ No media files in folder")
            selectedItems.removeAll()
            return
        }

        // Find currently selected file by ID first, then by lastSelectedItem name
        var currentIndex: Int? = nil

        if let currentID = selectedItems.first {
            currentIndex = mediaFiles.firstIndex(where: { $0.id == currentID })
        }

        // If ID not found (after refresh), try matching by filename
        if currentIndex == nil, let lastName = lastSelectedItem?.name {
            currentIndex = mediaFiles.firstIndex(where: { $0.name == lastName })
            print("🔄 Found by filename: \(lastName)")
        }

        guard let index = currentIndex else {
            print("⚠️ Could not find current file, selecting first")
            if let firstFile = mediaFiles.first {
                selectedItems = [firstFile.id]
                lastSelectedItem = firstFile
                onItemSelect(firstFile)
            }
            return
        }

        // Go to next
        let nextIndex = index + 1
        if nextIndex < mediaFiles.count {
            let nextFile = mediaFiles[nextIndex]
            selectedItems = [nextFile.id]
            lastSelectedItem = nextFile
            onItemSelect(nextFile)
            print("➡️ Advanced to: \(nextFile.name)")
        } else {
            print("⏹️ Reached end of folder")
            // Clear selection to stop the chain
            selectedItems.removeAll()
            lastSelectedItem = nil
        }
    }

    private func triggerITunesLookup() {
        print("🍎 [ITUNES BUTTON] Clicked! selectedItems count: \(selectedItems.count)")
        print("🍎 [ITUNES BUTTON] selectedItems: \(selectedItems)")

        // Check if a media file is selected
        if let selectedID = selectedItems.first,
           let selectedFile = fileSystem.files.first(where: { $0.id == selectedID }),
           isMediaFile(selectedFile) {

            // BEFORE scanning: find the NEXT file's name (in case current file gets renamed)
            var nextFileName: String? = nil
            if autoPlayNext {
                let mediaFiles = fileSystem.files.filter { isMediaFile($0) }
                if let currentIndex = mediaFiles.firstIndex(where: { $0.id == selectedID }),
                   currentIndex + 1 < mediaFiles.count {
                    nextFileName = mediaFiles[currentIndex + 1].name
                    print("📋 Next file will be: \(nextFileName!)")
                }
            }

            // Lookup the selected file via iTunes API
            print("🍎 [ITUNES] Looking up selected file: \(selectedFile.name)")
            Task {
                let service = iTunesSearchService()
                let result = await service.lookupAndRenameFile(URL(fileURLWithPath: selectedFile.path))
                await MainActor.run {
                    // Refresh file list to show renamed file
                    fileSystem.loadFiles()

                    // Show toast with result
                    if result.success {
                        nuclearToastMessage = "✅ \(result.title ?? selectedFile.name)"
                    } else {
                        nuclearToastMessage = "❌ \(result.error ?? "No match")"
                    }
                    showNuclearToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        showNuclearToast = false
                    }

                    // Follow "Next" toggle - advance and continue scanning if enabled
                    if autoPlayNext, let nextName = nextFileName {
                        // Find and select the next file by name
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let mediaFiles = self.fileSystem.files.filter { self.isMediaFile($0) }
                            if let nextFile = mediaFiles.first(where: { $0.name == nextName }) {
                                self.selectedItems = [nextFile.id]
                                self.lastSelectedItem = nextFile
                                self.onItemSelect(nextFile)
                                print("➡️ Advanced to: \(nextFile.name)")

                                // Continue scanning the next file
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    self.triggerITunesLookup()
                                }
                            } else {
                                print("⏹️ Next file not found or reached end")
                            }
                        }
                    } else if autoPlayNext {
                        print("⏹️ Reached end of folder")
                    }
                }
            }
        } else {
            // No file selected - show hint
            nuclearToastMessage = "Select a file to search"
            showNuclearToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showNuclearToast = false
            }
        }
    }

    private func triggerITunesFolderLookup() {
        // Start batch iTunes lookup for folder
        print("🍎 [ITUNES FOLDER] triggerITunesFolderLookup called - starting batch scan")
        showBatchITunes = true
    }

    // MARK: - Helper Functions

    private func iconForFile(_ item: FileItem) -> (name: String, color: Color) {
        if item.isDirectory {
            return ("folder.fill", .blue)
        }

        let filename = item.name.lowercased()
        let ext = (item.name as NSString).pathExtension.lowercased()

        // Apple Music video link (.video.webloc) - lime green tribute to LimeWire
        if filename.hasSuffix(".video.webloc") {
            return ("video.fill", Color(red: 0.5, green: 1.0, blue: 0.0))
        }
        // Apple Music audio link (.media.webloc) - lime green tribute to LimeWire
        else if filename.hasSuffix(".media.webloc") {
            return ("music.note", Color(red: 0.5, green: 1.0, blue: 0.0))
        }
        // Audio files
        else if ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg"].contains(ext) {
            return ("music.note", Color(red: 0.85, green: 0.75, blue: 0.20))
        }
        // Video files
        else if ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext) {
            return ("video.fill", .purple)
        }
        // Image files
        else if ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp"].contains(ext) {
            return ("photo.fill", .blue)
        }
        // Text files
        else if ["txt", "md", "rb", "json", "swift", "log", "xml", "yaml", "yml"].contains(ext) {
            return ("doc.text.fill", .secondary)
        }
        // Generic file
        else {
            return ("doc.fill", .secondary)
        }
    }

    private func startCreatingFolder() {
        onFocus()
        newItemName = "untitled folder"
        isCreatingNewFolder = true
        isCreatingNewFile = false
    }

    private func startCreatingFile() {
        onFocus()
        newItemName = "untitled.txt"
        isCreatingNewFile = true
        isCreatingNewFolder = false
    }

    private func createInlineItem() {
        guard !newItemName.isEmpty else {
            cancelInlineCreation()
            return
        }

        do {
            if isCreatingNewFolder {
                try fileSystem.createFolder(name: newItemName)
            } else if isCreatingNewFile {
                try fileSystem.createFile(name: newItemName)
            }
            cancelInlineCreation()
        } catch {
            print("Error creating item: \(error)")
        }
    }

    private func cancelInlineCreation() {
        isCreatingNewFolder = false
        isCreatingNewFile = false
        newItemName = "untitled"
    }

    private func startRenaming(item: FileItem) {
        renamingItem = item
        renameText = item.name
    }

    private func commitRename(item: FileItem) {
        guard !renameText.isEmpty, renameText != item.name else {
            cancelRename()
            return
        }

        do {
            let oldURL = URL(fileURLWithPath: item.path)
            let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(renameText)
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            fileSystem.loadFiles()
            cancelRename()
        } catch {
            print("Error renaming item: \(error)")
        }
    }

    private func cancelRename() {
        renamingItem = nil
        renameText = ""
    }

    private func selectRange(to item: FileItem) {
        let files = displayedFiles

        guard let lastItem = lastSelectedItem,
              let startIndex = files.firstIndex(where: { $0.id == lastItem.id }),
              let endIndex = files.firstIndex(where: { $0.id == item.id }) else {
            // No anchor or anchor not found - single select
            selectedItems = [item.id]
            lastSelectedItem = item
            return
        }

        let range = startIndex < endIndex ? startIndex...endIndex : endIndex...startIndex
        selectedItems = Set(files[range].map { $0.id })
        // Don't update lastSelectedItem - keep the anchor for continued shift-clicks
    }

    private func deleteItem(item: FileItem) {
        do {
            try fileSystem.deleteItem(at: item.path)
        } catch {
            print("Error deleting item: \(error)")
        }
    }

    private func deleteSelectedItems() {
        let itemsToDelete = fileSystem.files.filter { selectedItems.contains($0.id) }
        for item in itemsToDelete {
            deleteItem(item: item)
        }
        selectedItems.removeAll()
    }

    private func moveToOtherPane(item: FileItem) {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: item.path)
        let fileName = sourceURL.lastPathComponent
        let destURL = URL(fileURLWithPath: otherPanePath).appendingPathComponent(fileName)

        // Check if file exists at destination
        if fileManager.fileExists(atPath: destURL.path) {
            // Nuclear mode: auto-replace without asking
            if nuclearModeEnabled {
                executeMoveToOtherPane(item: item, replace: true)
                return
            }
            // Normal mode: Show alert asking user what to do
            pendingMoveItem = item
            showDuplicateAlert = true
            return
        }

        // No conflict - proceed with move
        executeMoveToOtherPane(item: item, replace: false)
    }

    private func executeMoveToOtherPane(item: FileItem, replace: Bool) {
        // Check if we're moving the currently playing file
        if let media = currentMedia, media.path == item.path {
            isMovingCurrentMedia = true
        }

        do {
            let fileManager = FileManager.default
            let sourceURL = URL(fileURLWithPath: item.path)
            let fileName = sourceURL.lastPathComponent
            var destURL = URL(fileURLWithPath: otherPanePath).appendingPathComponent(fileName)

            if replace && fileManager.fileExists(atPath: destURL.path) {
                // Replace existing file
                try fileManager.removeItem(at: destURL)
            } else if !replace && fileManager.fileExists(atPath: destURL.path) {
                // Keep both - add suffix
                let nameWithoutExt = (fileName as NSString).deletingPathExtension
                let ext = (fileName as NSString).pathExtension
                var counter = 2

                // SAFETY: Prevent infinite loop with max 1000 attempts
                while fileManager.fileExists(atPath: destURL.path) && counter < 1000 {
                    let newName = ext.isEmpty ? "\(nameWithoutExt)-\(counter)" : "\(nameWithoutExt)-\(counter).\(ext)"
                    destURL = URL(fileURLWithPath: otherPanePath).appendingPathComponent(newName)
                    counter += 1
                }

                // If we hit the limit, bail out with error
                if counter >= 1000 {
                    throw NSError(domain: "FileBrowserPanel", code: 999, userInfo: [
                        NSLocalizedDescriptionKey: "Too many duplicate files - unable to find unique name"
                    ])
                }
            }

            // DJ CURATION: Check if we're moving the currently playing file
            let wasPlayingThis = (currentMedia?.path == item.path)

            // Before moving, capture what the next track should be
            var nextTrackName: String? = nil
            if wasPlayingThis {
                let mediaFiles = fileSystem.files.filter { isMediaFile($0) }
                if let currentIndex = mediaFiles.firstIndex(where: { $0.path == item.path }) {
                    let nextIndex = currentIndex + 1
                    if nextIndex < mediaFiles.count {
                        nextTrackName = mediaFiles[nextIndex].name
                    }
                }
            }

            // Stop playback before moving to prevent errors
            if wasPlayingThis {
                currentMedia = nil
                showMediaPlayer = false
            }

            try fileManager.moveItem(at: sourceURL, to: destURL)

            // Track this move for undo functionality
            lastMovedFile = (
                source: sourceURL.deletingLastPathComponent().path,
                destination: destURL.path,
                fileName: destURL.lastPathComponent
            )

            fileSystem.loadFiles()
            onRefreshOtherPane()

            // Auto-play next track after move
            if wasPlayingThis {
                // Give the file system a moment to update, then play next
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    playNextTrack(preferredTrackName: nextTrackName)
                }
            }

        } catch let error as NSError {
            // Check if error is due to duplicate file
            if error.domain == NSCocoaErrorDomain && error.code == 516 {
                // File already exists - show alert
                pendingMoveItem = item
                showDuplicateAlert = true
            } else {
                print("Error moving to other pane: \(error)")
            }
            isMovingCurrentMedia = false
        }
    }

    // Play next track in the current folder
    private func playNextTrack(preferredTrackName: String? = nil) {
        let mediaFiles = fileSystem.files.filter { isMediaFile($0) }

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
            self.selectedItems = [track.id]
            self.lastSelectedItem = track
            self.onItemSelect(track)
            self.onItemDoubleClick(track)
        }
    }

    // Navigate selection up or down in the file list
    private func navigateSelection(direction: Int) {
        let files = displayedFiles
        guard !files.isEmpty else { return }

        if let currentID = selectedItems.first,
           let currentIndex = files.firstIndex(where: { $0.id == currentID }) {
            let newIndex = max(0, min(files.count - 1, currentIndex + direction))
            selectedItems = [files[newIndex].id]
            lastSelectedItem = files[newIndex]
            onItemSelect(files[newIndex])
        } else {
            // Nothing selected, select first or last based on direction
            let item = direction > 0 ? files.first! : files.last!
            selectedItems = [item.id]
            lastSelectedItem = item
            onItemSelect(item)
        }
    }

    // Advance to next track in the current folder (nuclear mode)
    private func advanceToNextTrack() {
        let mediaFiles = fileSystem.files.filter { isMediaFile($0) }
        guard !mediaFiles.isEmpty else {
            print("No tracks to play")
            return
        }

        // Find currently playing track
        var trackToPlay: FileItem? = nil
        if let current = currentMedia,
           let currentIndex = mediaFiles.firstIndex(where: { $0.path == current.path }) {
            // Go to next track
            let nextIndex = currentIndex + 1
            if nextIndex < mediaFiles.count {
                trackToPlay = mediaFiles[nextIndex]
                print("Playing next track: \(trackToPlay!.name)")
            } else {
                print("Already at last track")
                return
            }
        } else {
            // No current track - play first track
            trackToPlay = mediaFiles.first
            print("Playing first track: \(trackToPlay!.name)")
        }

        guard let track = trackToPlay else { return }

        // Select and play
        shouldAutoPlay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.selectedItems = [track.id]
            self.lastSelectedItem = track
            self.onItemSelect(track)
            self.onItemDoubleClick(track)
        }
    }

    // Play previous track in the current folder (nuclear mode)
    private func playPreviousTrack() {
        let mediaFiles = fileSystem.files.filter { isMediaFile($0) }
        guard !mediaFiles.isEmpty else {
            print("No tracks to play")
            return
        }

        // Find currently playing track
        var trackToPlay: FileItem? = nil
        if let current = currentMedia,
           let currentIndex = mediaFiles.firstIndex(where: { $0.path == current.path }) {
            // Go to previous track
            if currentIndex > 0 {
                trackToPlay = mediaFiles[currentIndex - 1]
                print("Playing previous track: \(trackToPlay!.name)")
            } else {
                print("Already at first track")
                return
            }
        } else {
            // No current track - play last track
            trackToPlay = mediaFiles.last
            print("Playing last track: \(trackToPlay!.name)")
        }

        guard let track = trackToPlay else { return }

        // Select and play
        shouldAutoPlay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.selectedItems = [track.id]
            self.lastSelectedItem = track
            self.onItemSelect(track)
            self.onItemDoubleClick(track)
        }
    }

    // Nuclear mode: Undo last move operation
    private func undoLastMove() {
        guard let lastMove = lastMovedFile else {
            nuclearToastMessage = "⚠️ No move to undo"
            showNuclearToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showNuclearToast = false
            }
            return
        }

        do {
            let fileManager = FileManager.default
            let currentLocation = URL(fileURLWithPath: lastMove.destination)
            let originalLocation = URL(fileURLWithPath: lastMove.source).appendingPathComponent(lastMove.fileName)

            // Check if file still exists at destination
            guard fileManager.fileExists(atPath: currentLocation.path) else {
                nuclearToastMessage = "⚠️ File no longer exists"
                showNuclearToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    showNuclearToast = false
                }
                lastMovedFile = nil
                return
            }

            // Move file back to original location
            try fileManager.moveItem(at: currentLocation, to: originalLocation)

            // Clear the undo history
            lastMovedFile = nil

            // Refresh both panes
            fileSystem.loadFiles()
            onRefreshOtherPane()

            nuclearToastMessage = "↩️ Undone: \(lastMove.fileName)"
            showNuclearToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showNuclearToast = false
            }
            print("☢️ Undid move: \(lastMove.fileName)")

        } catch {
            print("Error undoing move: \(error)")
            nuclearToastMessage = "⚠️ Undo failed"
            showNuclearToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showNuclearToast = false
            }
        }
    }

    // Nuclear mode: Move current track to other pane + auto-play next
    private func nuclearModeMove() {
        guard let current = currentMedia else {
            print("No track currently playing to move")
            return
        }

        moveToOtherPane(item: current)
        print("☢️ Moved: \(current.name)")
    }

    private func copyToOtherPane(item: FileItem) {
        let fileManager = FileManager.default

        do {
            let sourceURL = URL(fileURLWithPath: item.path)
            let fileName = sourceURL.lastPathComponent
            var destURL = URL(fileURLWithPath: otherPanePath).appendingPathComponent(fileName)

            // Handle duplicates by auto-incrementing
            var counter = 2
            // SAFETY: Prevent infinite loop with max 1000 attempts
            while fileManager.fileExists(atPath: destURL.path) && counter < 1000 {
                let fileExtension = sourceURL.pathExtension
                let baseName = sourceURL.deletingPathExtension().lastPathComponent
                let newName = fileExtension.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(fileExtension)"
                destURL = URL(fileURLWithPath: otherPanePath).appendingPathComponent(newName)
                counter += 1
            }

            // If we hit the limit, bail out with error
            guard counter < 1000 else {
                print("Error: Too many duplicate files - unable to find unique name for \(fileName)")
                return
            }

            try fileManager.copyItem(at: sourceURL, to: destURL)
            fileSystem.loadFiles()
        } catch {
            print("Error copying to other pane: \(error)")
        }
    }

    private func copySelectedToOtherPane() {
        let itemsToCopy = fileSystem.files.filter { selectedItems.contains($0.id) }
        for item in itemsToCopy {
            copyToOtherPane(item: item)
        }
        selectedItems.removeAll()
    }

    private func moveSelectedToOtherPane() {
        let itemsToMove = fileSystem.files.filter { selectedItems.contains($0.id) }

        // DJ CURATION: Check if we're moving the currently playing file
        var wasPlayingMovedFile = false
        var nextTrackName: String? = nil

        for item in itemsToMove {
            if let media = currentMedia, media.path == item.path {
                wasPlayingMovedFile = true

                // Before moving, capture what the next track should be
                let mediaFiles = fileSystem.files.filter { isMediaFile($0) }
                if let currentIndex = mediaFiles.firstIndex(where: { $0.path == item.path }) {
                    let nextIndex = currentIndex + 1
                    if nextIndex < mediaFiles.count {
                        nextTrackName = mediaFiles[nextIndex].name
                    }
                }

                // Stop playback before moving
                currentMedia = nil
                showMediaPlayer = false
                break
            }
        }

        // Move all files
        for item in itemsToMove {
            // Move without auto-play (we'll handle it once at the end)
            let fileManager = FileManager.default
            let sourceURL = URL(fileURLWithPath: item.path)
            let fileName = sourceURL.lastPathComponent
            let destURL = URL(fileURLWithPath: otherPanePath).appendingPathComponent(fileName)

            do {
                try fileManager.moveItem(at: sourceURL, to: destURL)
            } catch {
                print("Error moving file: \(error)")
            }
        }

        selectedItems.removeAll()
        fileSystem.loadFiles()
        onRefreshOtherPane()

        // Auto-play next track after moving if we moved the playing file
        if wasPlayingMovedFile {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                playNextTrack(preferredTrackName: nextTrackName)
            }
        }
    }

    private func addSelectedToPlaylist() {
        guard let addAction = onAddToPlaylist else { return }

        let itemsToAdd = fileSystem.files.filter { selectedItems.contains($0.id) && isMediaFile($0) }
        for item in itemsToAdd {
            addAction(item)
        }
        selectedItems.removeAll()
    }

    private func scanSelectedFolders() {
        // Get all selected folders
        let selectedFolders = fileSystem.files.filter { selectedItems.contains($0.id) && $0.isDirectory }
        guard !selectedFolders.isEmpty else { return }

        // Store all folders and show multi-folder scan dialog
        selectedFoldersForScan = selectedFolders
        showMultiFolderScan = true
    }

    private func mountAndNavigate(_ server: ServerConfig) async {
        mountingServer = server

        do {
            let mountPath = try await ServerMountService.shared.mountServer(server)
            fileSystem.navigateToFolder(mountPath)
            mountingServer = nil
        } catch {
            print("Error mounting server: \(error.localizedDescription)")
            mountingServer = nil
        }
    }

    private func handleAddServer(_ server: ServerConfig, password: String) {
        print("🔑 [FileBrowser] handleAddServer() called")
        print("🔑 [FileBrowser] Server: \(server.name)")

        // Save password to Keychain
        let saved = KeychainService.shared.savePassword(password, for: server.id)
        print("🔑 [FileBrowser] Keychain save result: \(saved)")

        // Add server to manager
        print("🔑 [FileBrowser] Adding server to manager")
        serverManager.addServer(server)
        print("🔑 [FileBrowser] Server count: \(serverManager.servers.count)")
    }

    private func isMediaFile(_ item: FileItem) -> Bool {
        guard !item.isDirectory else { return false }
        let filename = item.name.lowercased()
        let ext = (item.name as NSString).pathExtension.lowercased()

        // Check for webloc files (Apple Music links)
        if filename.hasSuffix(".media.webloc") || filename.hasSuffix(".video.webloc") {
            return true
        }

        // Check for regular media files
        return ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg", "mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }
}

// MARK: - Ticker Text View

struct TickerText: View {
    let text: String
    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            Text(text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .background(
                    GeometryReader { textGeometry in
                        Color.clear
                            .onAppear {
                                textWidth = textGeometry.size.width
                                containerWidth = geometry.size.width
                                if textWidth > containerWidth {
                                    startTicker()
                                }
                            }
                            .onChange(of: text) {
                                textWidth = textGeometry.size.width
                                containerWidth = geometry.size.width
                                offset = 0
                                if textWidth > containerWidth {
                                    startTicker()
                                }
                            }
                    }
                )
        }
        .clipped()
    }

    private func startTicker() {
        // Wait 2 seconds, then scroll to end, wait 2 seconds, scroll back, repeat
        let scrollDistance = textWidth - containerWidth + 20 // Extra padding

        withAnimation(.linear(duration: 0)) {
            offset = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.linear(duration: Double(scrollDistance / 30))) { // 30 pixels per second
                offset = -scrollDistance
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + Double(scrollDistance / 30) + 2.0) {
                withAnimation(.linear(duration: Double(scrollDistance / 30))) {
                    offset = 0
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + Double(scrollDistance / 30) + 2.0) {
                    startTicker() // Loop
                }
            }
        }
    }
}

