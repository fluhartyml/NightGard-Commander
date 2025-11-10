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

    var activeFocusedFileSystem: FileSystemService {
        focusedPane == .left ? leftFileSystem : rightFileSystem
    }

    var activeSelectedItem: FileItem? {
        focusedPane == .left ? selectedLeftItem : selectedRightItem
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
                        if item.isDirectory {
                            leftFileSystem.navigateToFolder(item.path)
                        }
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
                        if item.isDirectory {
                            rightFileSystem.navigateToFolder(item.path)
                        }
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

                Button("Refresh") {
                    activeFocusedFileSystem.loadFiles()
                }
                .buttonStyle(.bordered)

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
