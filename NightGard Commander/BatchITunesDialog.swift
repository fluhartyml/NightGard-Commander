//
//  BatchITunesDialog.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 19 1150
//

import SwiftUI

struct BatchITunesDialog: View {
    @Binding var isPresented: Bool
    let folderPath: String
    let folderName: String
    let onFileUpdated: (() -> Void)?
    @State private var service = iTunesSearchService()
    @State private var showResults = false

    var body: some View {
        VStack(spacing: 20) {
            // Title with spinner
            HStack {
                Image(systemName: "music.note.list")
                    .font(.title)
                    .foregroundColor(.purple)
                Text("iTunes Metadata Lookup")
                    .font(.title2)
                    .fontWeight(.semibold)

                if service.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 8)
                }
            }

            Text(folderName)
                .font(.headline)
                .foregroundColor(.secondary)

            Divider()

            // Progress bar
            if service.isProcessing {
                VStack(spacing: 12) {
                    ProgressView(value: Double(service.processedFiles), total: Double(service.totalFiles))
                        .progressViewStyle(.linear)

                    Text("\(service.processedFiles) / \(service.totalFiles)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Currently processing
                VStack(alignment: .leading, spacing: 8) {
                    Text("Currently looking up:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(service.currentFile)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Stats
                HStack(spacing: 24) {
                    StatView(icon: "checkmark.circle.fill", color: .green, label: "Matched", value: service.matchedCount)
                    StatView(icon: "exclamationmark.triangle.fill", color: .orange, label: "Not Found", value: service.unmatchedCount)

                    if service.totalFiles > 0 {
                        let remaining = service.totalFiles - service.processedFiles
                        let estimatedSeconds = remaining * 2 // ~2 seconds per file (API calls)
                        let estimatedMinutes = estimatedSeconds / 60
                        StatView(icon: "clock.fill", color: .blue, label: "Remaining", value: estimatedMinutes, suffix: "min")
                    }
                }

                Divider()

                // Cancel button
                Button("Cancel") {
                    service.cancel()
                    isPresented = false
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(width: 500, height: 400)
        .onAppear {
            startProcessing()
        }
        .sheet(isPresented: $showResults) {
            ITunesResultsDialog(
                isPresented: $showResults,
                matchedCount: service.matchedCount,
                unmatchedCount: service.unmatchedCount
            )
        }
    }

    private func startProcessing() {
        // Set up file update callback
        service.onFileUpdated = onFileUpdated

        Task {
            await service.processFolder(path: folderPath)

            // Show results when complete
            if !service.results.isEmpty {
                await MainActor.run {
                    showResults = true
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var isPresented = true
    BatchITunesDialog(
        isPresented: $isPresented,
        folderPath: "/Users/test/Music",
        folderName: "My Music",
        onFileUpdated: nil
    )
}
