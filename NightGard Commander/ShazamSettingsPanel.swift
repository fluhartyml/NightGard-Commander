//
//  ShazamSettingsPanel.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 18 1045
//

import SwiftUI

struct ShazamSettingsPanel: View {
    @Binding var isPresented: Bool
    @State private var settings = ShazamSettings.shared

    @State private var formatBlocks: [FormatBlock] = []
    @State private var autoRename: Bool = true
    @State private var queueUnmatched: Bool = true
    @State private var showFormatBuilder = false

    var body: some View {
        VStack(spacing: 20) {
            // Title
            HStack {
                Image(systemName: "shazam.logo.fill")
                    .font(.title)
                    .foregroundColor(.blue)
                Text("Shazam Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Text("Configure how Shazam detects and renames your music library")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            // Settings form
            Form {
                Section("Filename Format") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Files will be renamed using this format after detection:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(generatePreview())
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)

                        Button(action: {
                            showFormatBuilder = true
                        }) {
                            Label("Change Format", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Behavior") {
                    Toggle(isOn: $autoRename) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto-rename matched files")
                            Text("Automatically rename and save metadata after successful detection")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Toggle(isOn: $queueUnmatched) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Queue unmatched files")
                            Text("Add files that can't be identified to a review queue")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                if !settings.isConfigured {
                    Text("Complete setup to enable Shazam features")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Settings") {
                    saveSettings()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 600, height: 500)
        .onAppear {
            loadSettings()
        }
        .sheet(isPresented: $showFormatBuilder) {
            FilenameFormatBuilder(isPresented: $showFormatBuilder, formatBlocks: $formatBlocks)
        }
    }

    private func loadSettings() {
        formatBlocks = settings.formatBlocks
        autoRename = settings.autoRename
        queueUnmatched = settings.queueUnmatched
    }

    private func saveSettings() {
        settings.formatBlocks = formatBlocks
        settings.autoRename = autoRename
        settings.queueUnmatched = queueUnmatched
        settings.isConfigured = true
    }

    private func generatePreview() -> String {
        if formatBlocks.isEmpty {
            return "Artist - Title - Album.mp3 (default)"
        }

        let parts = formatBlocks.map { $0.field.sampleValue() }
        return parts.joined() + ".mp3"
    }
}

#Preview {
    @Previewable @State var isPresented = true
    ShazamSettingsPanel(isPresented: $isPresented)
}
