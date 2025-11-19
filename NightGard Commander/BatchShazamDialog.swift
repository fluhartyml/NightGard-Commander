//
//  BatchShazamDialog.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 18 1055
//

import SwiftUI

struct BatchShazamDialog: View {
    @Binding var isPresented: Bool
    let folderPath: String
    let folderName: String
    let onFileRenamed: (() -> Void)?
    @State private var service = ShazamService()
    @State private var showResults = false

    var body: some View {
        VStack(spacing: 20) {
            // Title with spinner
            HStack {
                Image(systemName: "shazam.logo.fill")
                    .font(.title)
                    .foregroundColor(.blue)
                Text("Shazaming Folder")
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
                    Text("Currently detecting:")
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
                    StatView(icon: "exclamationmark.triangle.fill", color: .orange, label: "Queued", value: service.queuedCount)

                    if service.totalFiles > 0 {
                        let remaining = service.totalFiles - service.processedFiles
                        let estimatedMinutes = remaining * 7 / 60 // ~7 seconds per file
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
            ShazamResultsDialog(
                isPresented: $showResults,
                matchedCount: service.matchedCount,
                queuedCount: service.queuedCount,
                onViewQueue: {
                    showResults = false
                    isPresented = false
                    // TODO: Open queue review panel
                }
            )
        }
    }

    private func startProcessing() {
        // Set up file rename callback
        service.onFileRenamed = onFileRenamed

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

// Stat display view
struct StatView: View {
    let icon: String
    let color: Color
    let label: String
    let value: Int
    var suffix: String = ""

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title2)

            if suffix.isEmpty {
                Text("\(value)")
                    .font(.title3)
                    .fontWeight(.semibold)
            } else {
                Text("\(value) \(suffix)")
                    .font(.title3)
                    .fontWeight(.semibold)
            }

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    @Previewable @State var isPresented = true
    BatchShazamDialog(
        isPresented: $isPresented,
        folderPath: "/Users/test/Music",
        folderName: "My Music",
        onFileRenamed: nil
    )
}
