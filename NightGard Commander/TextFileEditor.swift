//
//  TextFileEditor.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI

struct TextFileEditor: View {
    let filePath: String
    let fileName: String
    let onClose: () -> Void

    @State private var fileContents: String = ""
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    @State private var hasChanges: Bool = false

    private let fileManager = FileManager.default

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(fileName)
                    .font(.headline)

                Spacer()

                if hasChanges {
                    Text("• Edited")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Button("Close") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))

            Divider()

            // Editor area
            if isLoading {
                ProgressView("Loading file...")
                    .padding()
                Spacer()
            } else if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
                Spacer()
            } else {
                TextEditor(text: $fileContents)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .onChange(of: fileContents) {
                        hasChanges = true
                    }
            }

            Divider()

            // Footer with save button
            HStack {
                Text(filePath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Save") {
                    saveFile()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasChanges)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            loadFile()
        }
    }

    private func loadFile() {
        isLoading = true
        errorMessage = nil

        do {
            let contents = try String(contentsOfFile: filePath, encoding: .utf8)
            fileContents = contents
            isLoading = false
        } catch {
            errorMessage = "Error loading file: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func saveFile() {
        do {
            try fileContents.write(toFile: filePath, atomically: true, encoding: .utf8)
            hasChanges = false
        } catch {
            errorMessage = "Error saving file: \(error.localizedDescription)"
        }
    }
}
