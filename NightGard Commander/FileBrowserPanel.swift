//
//  FileBrowserPanel.swift
//  NightGard Commander
//
//  Created by Claude on 11/10/25.
//

import SwiftUI

struct FileBrowserPanel: View {
    @Bindable var fileSystem: FileSystemService
    let isFocused: Bool
    let onFocus: () -> Void
    let onItemSelect: (FileItem) -> Void

    @State private var selectedItem: FileItem?

    var body: some View {
        VStack(spacing: 0) {
            // Path header
            HStack {
                Text(fileSystem.currentPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                Spacer()

                if fileSystem.canNavigateUp() {
                    Button(action: { fileSystem.navigateUp() }) {
                        Image(systemName: "arrow.up")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 8)
                }
            }
            .frame(height: 24)
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedItem = item
                        onFocus()
                        onItemSelect(item)
                    }
                }
                .listStyle(.plain)
            }
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
