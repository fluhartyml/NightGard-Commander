//
//  FileBrowserPanel.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI

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
    let onSwitchToOpposite: () -> Void
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
    @State private var showMultiFolderScan = false
    @State private var selectedFoldersForScan: [FileItem] = []
    @State private var showPlaylistsOnly = false
    @State private var isMovingCurrentMedia = false
    @State private var showDuplicateAlert = false
    @State private var pendingMoveItem: FileItem?
    @State private var showTradingCardCreator = false
    @FocusState private var isNewItemFocused: Bool
    @FocusState private var isRenameFocused: Bool

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

                Text(fileSystem.currentPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                Spacer()
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
                List(selection: $selectedItems) {
                    // Inline new item creation
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
                        .padding(.vertical, 4)
                    }

                    // Regular file list
                    ForEach(displayedFiles) { item in
                        let icon = iconForFile(item)
                        HStack(spacing: 8) {
                            Image(systemName: icon.name)
                                .foregroundColor(icon.color)
                                .frame(width: 20)

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

                            if renamingItem?.id != item.id {
                                Text(item.displaySize)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 60, alignment: .trailing)

                                Text(item.displayDate)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 120, alignment: .trailing)
                            }
                        }
                        .tag(item.id)
                        .onTapGesture(count: 2) {
                            // Double tap - open/navigate
                            onItemDoubleClick(item)
                        }
                        .simultaneousGesture(
                            TapGesture()
                                .modifiers(.command)
                                .onEnded {
                                    // Command+Click - toggle selection
                                    if selectedItems.contains(item.id) {
                                        selectedItems.remove(item.id)
                                    } else {
                                        selectedItems.insert(item.id)
                                        lastSelectedItem = item
                                    }
                                    onItemSelect(item)
                                    onFocus()
                                }
                        )
                        .simultaneousGesture(
                            TapGesture()
                                .modifiers(.shift)
                                .onEnded {
                                    // Shift+Click - range selection
                                    selectRange(to: item)
                                    onFocus()
                                }
                        )
                        .contextMenu {
                            if selectedItems.count > 1 {
                                Button("Delete \(selectedItems.count) Items") {
                                    deleteSelectedItems()
                                }
                                Button("Move \(selectedItems.count) Items to Other Pane") {
                                    moveSelectedToOtherPane()
                                }

                                // Scan for media if all selected items are directories
                                let allFolders = fileSystem.files.filter { selectedItems.contains($0.id) }.allSatisfy { $0.isDirectory }
                                if allFolders {
                                    Divider()
                                    Button("Scan \(selectedItems.count) Folders for Media...") {
                                        scanSelectedFolders()
                                    }
                                }
                            } else {
                                Button("Rename") {
                                    startRenaming(item: item)
                                }
                                Button("Delete") {
                                    deleteItem(item: item)
                                }
                                Divider()
                                Button("Move to Other Pane") {
                                    moveToOtherPane(item: item)
                                }

                                // Scan for media (directories only)
                                if item.isDirectory {
                                    Divider()
                                    Button("Scan for Media...") {
                                        folderToScan = item
                                    }
                                }

                                // Add to playlist for media files
                                if isMediaFile(item), let addAction = onAddToPlaylist {
                                    Divider()
                                    Button("Add to Playlist") {
                                        addAction(item)
                                    }
                                }
                            }
                        }
                        .onDrag {
                            let url = URL(fileURLWithPath: item.path)
                            let provider = NSItemProvider()
                            provider.registerObject(item.path as NSString, visibility: .all)
                            provider.registerObject(url as NSURL, visibility: .all)
                            return provider
                        }
                        .dropDestination(for: String.self) { droppedPaths, location in
                        // Only allow drop if this is a directory
                        guard item.isDirectory else { return false }

                        for sourcePath in droppedPaths {
                            do {
                                let sourceURL = URL(fileURLWithPath: sourcePath)
                                let fileName = sourceURL.lastPathComponent
                                let destURL = URL(fileURLWithPath: item.path).appendingPathComponent(fileName)
                                // Always copy on drag (use Move button ⌘6 for actual moves)
                                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                            } catch {
                                print("Error copying file: \(error)")
                            }
                        }
                        fileSystem.loadFiles()
                        return true
                    }
                    }
                }
                .listStyle(.plain)
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
                .contextMenu {
                    Button("New Folder") {
                        startCreatingFolder()
                    }
                    Button("New File") {
                        startCreatingFile()
                    }
                }
                .onChange(of: selectedItems) { oldValue, newValue in
                    if let firstID = newValue.first,
                       let item = fileSystem.files.first(where: { $0.id == firstID }) {
                        lastSelectedItem = item
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
            }

            // In-pane media player (shows only when playing)
            InPaneMediaPlayer(
                currentMedia: $currentMedia,
                isVisible: $showMediaPlayer,
                autoPlayNext: $autoPlayNext,
                autoPlayOpposite: $autoPlayOpposite,
                fileSystem: fileSystem,
                onSwitchToOpposite: onSwitchToOpposite
            )

            // Breadcrumbs footer
            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
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
                        // File was moved - auto-advance to next track if auto-play is enabled
                        isMovingCurrentMedia = false

                        // Force stop current player before advancing
                        currentMedia = nil
                        showMediaPlayer = false

                        if autoPlayNext {
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
    }

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
        guard let lastItem = lastSelectedItem,
              let startIndex = fileSystem.files.firstIndex(where: { $0.id == lastItem.id }),
              let endIndex = fileSystem.files.firstIndex(where: { $0.id == item.id }) else {
            selectedItems = [item.id]
            lastSelectedItem = item
            return
        }

        let range = startIndex < endIndex ? startIndex...endIndex : endIndex...startIndex
        selectedItems = Set(fileSystem.files[range].map { $0.id })
        lastSelectedItem = item
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
            // Show alert asking user what to do
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

                while fileManager.fileExists(atPath: destURL.path) {
                    let newName = ext.isEmpty ? "\(nameWithoutExt)-\(counter)" : "\(nameWithoutExt)-\(counter).\(ext)"
                    destURL = URL(fileURLWithPath: otherPanePath).appendingPathComponent(newName)
                    counter += 1
                }
            }

            try fileManager.moveItem(at: sourceURL, to: destURL)
            fileSystem.loadFiles()
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

    private func moveSelectedToOtherPane() {
        let itemsToMove = fileSystem.files.filter { selectedItems.contains($0.id) }
        for item in itemsToMove {
            moveToOtherPane(item: item)
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
