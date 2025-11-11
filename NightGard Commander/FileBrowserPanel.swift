//
//  FileBrowserPanel.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI

struct FileBrowserPanel: View {
    @Bindable var fileSystem: FileSystemService
    let isFocused: Bool
    let onFocus: () -> Void
    let onItemSelect: (FileItem) -> Void
    let onItemDoubleClick: (FileItem) -> Void
    @Binding var currentMedia: FileItem?
    @Binding var showMediaPlayer: Bool
    @Binding var autoPlayNext: Bool
    @Binding var autoPlayOpposite: Bool
    let onSwitchToOpposite: () -> Void
    let otherPanePath: String

    @State private var selectedItem: FileItem?
    @State private var isCreatingNewFolder = false
    @State private var isCreatingNewFile = false
    @State private var newItemName = "untitled"
    @State private var renamingItem: FileItem?
    @State private var renameText = ""
    @FocusState private var isNewItemFocused: Bool
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Path header with drive selector and up navigation
            HStack(spacing: 8) {
                // Drive selector
                Menu {
                    ForEach(fileSystem.mountedVolumes) { volume in
                        Button(action: {
                            fileSystem.navigateToFolder(volume.path)
                        }) {
                            HStack {
                                Image(systemName: "externaldrive.fill")
                                Text(volume.name)
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
                List(selection: $selectedItem) {
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
                        HStack(spacing: 8) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                .foregroundColor(item.isDirectory ? .blue : .secondary)
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
                        .tag(item)
                        .onTapGesture(count: 2) {
                            onItemDoubleClick(item)
                        }
                        .contextMenu {
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
                        }
                    .draggable(item.path) {
                        Label(item.name, systemImage: item.isDirectory ? "folder.fill" : "doc.fill")
                    }
                    .dropDestination(for: String.self) { droppedPaths, location in
                        // Only allow drop if this is a directory
                        guard item.isDirectory else { return false }

                        for sourcePath in droppedPaths {
                            do {
                                let sourceURL = URL(fileURLWithPath: sourcePath)
                                let fileName = sourceURL.lastPathComponent
                                let destURL = URL(fileURLWithPath: item.path).appendingPathComponent(fileName)
                                try FileManager.default.moveItem(at: sourceURL, to: destURL)
                            } catch {
                                print("Error moving file: \(error)")
                            }
                        }
                        fileSystem.loadFiles()
                        return true
                    }
                    }
                }
                .listStyle(.plain)
                .contextMenu {
                    Button("New Folder") {
                        startCreatingFolder()
                    }
                    Button("New File") {
                        startCreatingFile()
                    }
                }
                .onChange(of: selectedItem) { oldValue, newValue in
                    if let item = newValue {
                        onFocus()
                        onItemSelect(item)
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

    private func deleteItem(item: FileItem) {
        do {
            try fileSystem.deleteItem(at: item.path)
        } catch {
            print("Error deleting item: \(error)")
        }
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
}
