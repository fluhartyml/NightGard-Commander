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

    // Reformat state
    @State private var isReformatting = false
    @State private var reformatResult: (renamed: Int, skipped: Int, errors: Int)?

    // iTunes API state
    @State private var isiTunesProcessing = false
    @State private var iTunesResult: (processed: Int, renamed: Int, skipped: Int, errors: Int)?

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

                Section("Database") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scanned Files Database")
                            Text("\(ShazamScannedDatabase.shared.count()) files tracked")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive, action: {
                            ShazamScannedDatabase.shared.clearAll()
                            reformatResult = nil
                        }) {
                            Label("Reset Database", systemImage: "trash")
                        }
                        .disabled(ShazamScannedDatabase.shared.count() == 0)
                    }

                    // Reformat All button
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reformat Files")
                            Text("Rename all tracked files using current format (no re-scan)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            reformatAll()
                        }) {
                            if isReformatting {
                                Label("Reformatting...", systemImage: "hourglass")
                            } else {
                                Label("Reformat All", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isReformatting || ShazamScannedDatabase.shared.count() == 0)
                    }

                    // Show reformat result if available
                    if let result = reformatResult {
                        HStack(spacing: 12) {
                            Label("\(result.renamed) renamed", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Label("\(result.skipped) skipped", systemImage: "minus.circle.fill")
                                .foregroundColor(.secondary)
                            if result.errors > 0 {
                                Label("\(result.errors) errors", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                        .font(.caption)
                    }

                    Divider()

                    // iTunes API section
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("iTunes API Lookup")
                            Text("Fetch fresh metadata using stored Apple Music IDs (no fingerprinting)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            processiTunesAPI()
                        }) {
                            if isiTunesProcessing {
                                Label("Processing...", systemImage: "hourglass")
                            } else {
                                Label("Fetch & Rename", systemImage: "music.note.list")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(isiTunesProcessing || ShazamScannedDatabase.shared.count() == 0)
                    }

                    // Show iTunes result if available
                    if let result = iTunesResult {
                        HStack(spacing: 12) {
                            Label("\(result.processed) fetched", systemImage: "arrow.down.circle.fill")
                                .foregroundColor(.blue)
                            Label("\(result.renamed) renamed", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            if result.errors > 0 {
                                Label("\(result.errors) errors", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                        .font(.caption)
                    }

                    Text("iTunes API bypasses Shazam rate limits. Only works for files with stored Apple Music IDs.")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
        .frame(width: 600, height: 580)
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

    private func reformatAll() {
        guard !isReformatting else { return }
        isReformatting = true
        reformatResult = nil

        Task {
            let result = await ShazamService.shared.reformatAllFromDatabase()
            await MainActor.run {
                reformatResult = result
                isReformatting = false
            }
        }
    }

    private func processiTunesAPI() {
        guard !isiTunesProcessing else { return }
        isiTunesProcessing = true
        iTunesResult = nil

        Task {
            let result = await ShazamService.shared.refreshAllfromITunes()
            await MainActor.run {
                iTunesResult = result
                isiTunesProcessing = false
            }
        }
    }
}

#Preview {
    @Previewable @State var isPresented = true
    ShazamSettingsPanel(isPresented: $isPresented)
}
