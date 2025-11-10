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
    @State private var focusedPane: FocusedPane = .left
    @State private var selectedLeftItem: FileItem?
    @State private var selectedRightItem: FileItem?
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var showTextEditor = false
    @State private var showAudioPlayer = false
    @State private var showImagePreview = false
    @State private var previewItem: FileItem?

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
        case .audio:
            showAudioPlayer = true
        case .image:
            showImagePreview = true
        case .other:
            break // Do nothing for unknown file types
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Dual-pane layout
            HStack(spacing: 0) {
                // Left pane
                FileBrowserPanel(
                    fileSystem: leftFileSystem,
                    isFocused: focusedPane == .left,
                    onFocus: { focusedPane = .left },
                    onItemSelect: { item in
                        selectedLeftItem = item
                    },
                    onItemDoubleClick: { item in
                        focusedPane = .left
                        selectedLeftItem = item
                        handleDoubleClick(item: item)
                    }
                )

                Divider()

                // Right pane
                FileBrowserPanel(
                    fileSystem: rightFileSystem,
                    isFocused: focusedPane == .right,
                    onFocus: { focusedPane = .right },
                    onItemSelect: { item in
                        selectedRightItem = item
                    },
                    onItemDoubleClick: { item in
                        focusedPane = .right
                        selectedRightItem = item
                        handleDoubleClick(item: item)
                    }
                )
            }

            Divider()

            // Footer with file operations
            HStack(spacing: 12) {
                Button("New Folder") {
                    newFolderName = ""
                    showNewFolderSheet = true
                }
                .buttonStyle(.bordered)

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
        .sheet(isPresented: $showNewFolderSheet) {
            NewFolderSheet(
                folderName: $newFolderName,
                onCreate: {
                    createNewFolder()
                    showNewFolderSheet = false
                },
                onCancel: {
                    showNewFolderSheet = false
                }
            )
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
        .sheet(isPresented: $showAudioPlayer) {
            if let item = previewItem {
                AudioPlayer(
                    filePath: item.path,
                    fileName: item.name,
                    onClose: {
                        showAudioPlayer = false
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

    private func createNewFolder() {
        guard !newFolderName.isEmpty else { return }

        do {
            try activeFocusedFileSystem.createFolder(name: newFolderName)
        } catch {
            print("Error creating folder: \(error.localizedDescription)")
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
    case folder, text, audio, image, other
}

struct NewFolderSheet: View {
    @Binding var folderName: String
    let onCreate: () -> Void
    let onCancel: () -> Void
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Folder")
                .font(.headline)

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
                .onSubmit {
                    if !folderName.isEmpty {
                        onCreate()
                    }
                }

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onCreate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            isTextFieldFocused = true
        }
    }
}

#Preview {
    ContentView()
}
