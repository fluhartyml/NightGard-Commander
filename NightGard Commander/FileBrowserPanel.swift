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
    @FocusState private var isNewItemFocused: Bool
    @FocusState private var isRenameFocused: Bool

    let playlistManager: PlaylistManager?

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

                if fileSystem.canNavigateUp() {
                    Button(action: { fileSystem.navigateUp() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("..")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .buttonStyle(.bordered)
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
                    ForEach(fileSystem.files) { item in
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
                        .simultaneousGesture(
                            TapGesture()
                                .onEnded {
                                    // Plain click - only fires if no modifiers
                                    let event = NSApp.currentEvent
                                    let hasModifiers = event?.modifierFlags.contains(.command) == true ||
                                                     event?.modifierFlags.contains(.shift) == true
                                    if !hasModifiers {
                                        selectedItems.removeAll()
                                        selectedItems.insert(item.id)
                                        lastSelectedItem = item
                                        onItemSelect(item)
                                        onFocus()
                                    }
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
            onFocus()
        }
        .onAppear {
            fileSystem.loadFiles()
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
                isPresented: $showMultiFolderScan
            )
        }
    }

    private func iconForFile(_ item: FileItem) -> (name: String, color: Color) {
        if item.isDirectory {
            return ("folder.fill", .blue)
        }

        let ext = (item.name as NSString).pathExtension.lowercased()

        // Audio files
        if ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg"].contains(ext) {
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
        do {
            let sourceURL = URL(fileURLWithPath: item.path)
            let fileName = sourceURL.lastPathComponent
            let destURL = URL(fileURLWithPath: otherPanePath).appendingPathComponent(fileName)
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
            fileSystem.loadFiles()
        } catch {
            print("Error moving to other pane: \(error)")
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
        let ext = (item.name as NSString).pathExtension.lowercased()
        return ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg", "mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }
}
