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

    @State private var selectedItem: FileItem?

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
                Text("Empty folder")
                    .foregroundColor(.secondary)
                    .padding()
                Spacer()
            } else {
                List(fileSystem.files, selection: $selectedItem) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundColor(item.isDirectory ? .blue : .secondary)
                            .frame(width: 20)

                        Text(item.name)
                            .lineLimit(1)

                        Spacer()

                        Text(item.displaySize)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)

                        Text(item.displayDate)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 120, alignment: .trailing)
                    }
                    .tag(item)
                    .onTapGesture(count: 2) {
                        onItemDoubleClick(item)
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
                .listStyle(.plain)
                .onChange(of: selectedItem) { newValue in
                    if let item = newValue {
                        onFocus()
                        onItemSelect(item)
                    }
                }
            }

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
}
