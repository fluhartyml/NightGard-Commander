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

            // Command button bar (MC/NC style)
            HStack(spacing: 0) {
                CommandButton(label: "View", shortcut: "⌘3") {
                    viewSelectedItem()
                }
                .disabled(activeSelectedItem == nil)
                .keyboardShortcut("3", modifiers: .command)

                CommandButton(label: "Edit", shortcut: "⌘4") {
                    editSelectedItem()
                }
                .disabled(activeSelectedItem == nil)
                .keyboardShortcut("4", modifiers: .command)

                CommandButton(label: "Copy", shortcut: "⌘5") {
                    copyToOtherPane()
                }
                .disabled(activeSelectedItem == nil)
                .keyboardShortcut("5", modifiers: .command)

                CommandButton(label: "Move", shortcut: "⌘6") {
                    moveToOtherPane()
                }
                .disabled(activeSelectedItem == nil)
                .keyboardShortcut("6", modifiers: .command)

                CommandButton(label: "New Folder", shortcut: "⌘7") {
                    createNewFolder()
                }
                .keyboardShortcut("7", modifiers: .command)

                CommandButton(label: "Delete", shortcut: "⌘8") {
                    deleteSelectedItem()
                }
                .disabled(activeSelectedItem == nil)
                .keyboardShortcut("8", modifiers: .command)

                CommandButton(label: "Rename", shortcut: "⌘9") {
                    renameSelectedItem()
                }
                .disabled(activeSelectedItem == nil)
                .keyboardShortcut("9", modifiers: .command)
            }
            .frame(height: 44)
            .background(Color.secondary.opacity(0.08))
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

        if fileType == .text {
            previewItem = item
            showTextEditor = true
        }
    }

    private func copyToOtherPane() {
        guard let item = activeSelectedItem else { return }
        let destinationPath = focusedPane == .left ? rightFileSystem.currentPath : leftFileSystem.currentPath

        do {
            let sourceURL = URL(fileURLWithPath: item.path)
            let fileName = sourceURL.lastPathComponent
            let destURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: sourceURL, to: destURL)

            // Reload both panes
            leftFileSystem.loadFiles()
            rightFileSystem.loadFiles()
        } catch {
            print("Error copying to other pane: \(error.localizedDescription)")
        }
    }

    private func moveToOtherPane() {
        guard let item = activeSelectedItem else { return }
        let destinationPath = focusedPane == .left ? rightFileSystem.currentPath : leftFileSystem.currentPath

        do {
            let sourceURL = URL(fileURLWithPath: item.path)
            let fileName = sourceURL.lastPathComponent
            let destURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(fileName)
            try FileManager.default.moveItem(at: sourceURL, to: destURL)

            // Clear selection and reload both panes
            if focusedPane == .left {
                selectedLeftItem = nil
            } else {
                selectedRightItem = nil
            }
            leftFileSystem.loadFiles()
            rightFileSystem.loadFiles()
        } catch {
            print("Error moving to other pane: \(error.localizedDescription)")
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
    case folder, text, audio, video, image, other
}

#Preview {
    ContentView()
}
