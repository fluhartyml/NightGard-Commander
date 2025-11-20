//
//  GenreReviewDialog.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 19 1110
//

import SwiftUI
import AVFoundation

struct GenreReviewDialog: View {
    @Binding var isPresented: Bool
    @State private var queue = GenreReviewQueue.shared
    @State private var currentIndex = 0
    @State private var selectedGenre: String?
    @State private var isProcessing = false

    var onFileRenamed: (() -> Void)?

    var currentItem: GenreReviewItem? {
        guard currentIndex < queue.items.count else { return nil }
        return queue.items[currentIndex]
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "pencil.circle.fill")
                    .font(.title)
                    .foregroundColor(.purple)
                Text("Select Genre")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                // Progress indicator
                Text("\(currentIndex + 1) of \(queue.items.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
            }

            Divider()

            if let item = currentItem {
                // File info
                VStack(alignment: .leading, spacing: 12) {
                    // Song details
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title ?? "Unknown Title")
                            .font(.headline)
                        Text(item.artist ?? "Unknown Artist")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // File name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(item.fileName)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)

                // Genre selection
                VStack(alignment: .leading, spacing: 12) {
                    if item.allGenres.isEmpty {
                        // No genres available - allow manual entry
                        Text("No genres detected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("Enter genre manually", text: Binding(
                            get: { selectedGenre ?? "" },
                            set: { selectedGenre = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    } else {
                        // Multiple genres - let user pick
                        Text("Select a genre (\(item.allGenres.count) available):")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(item.allGenres, id: \.self) { genre in
                                    Button(action: {
                                        selectedGenre = genre
                                    }) {
                                        HStack {
                                            Image(systemName: selectedGenre == genre ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(selectedGenre == genre ? .purple : .secondary)
                                            Text(genre)
                                                .foregroundColor(.primary)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(selectedGenre == genre ? Color.purple.opacity(0.1) : Color.clear)
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                }

                Divider()

                // Actions
                HStack(spacing: 12) {
                    // Skip button
                    Button(action: {
                        skipCurrent()
                    }) {
                        Label("Skip", systemImage: "forward.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isProcessing)

                    Spacer()

                    // Cancel button
                    Button("Cancel") {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .disabled(isProcessing)

                    // Apply & Next button
                    Button(action: {
                        applyGenreAndNext()
                    }) {
                        if isProcessing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                        } else {
                            Label(currentIndex < queue.items.count - 1 ? "Apply & Next" : "Apply & Done",
                                  systemImage: "checkmark")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(selectedGenre == nil || selectedGenre?.isEmpty == true || isProcessing)
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)

                    Text("All genres reviewed!")
                        .font(.headline)

                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .padding(24)
        .frame(width: 550, height: 500)
        .onAppear {
            loadFirstPendingItem()
        }
    }

    private func loadFirstPendingItem() {
        // Find first item that hasn't been reviewed yet
        if let index = queue.items.firstIndex(where: { $0.selectedGenre == nil }) {
            currentIndex = index
        }

        // Set initial selection to first genre if available
        if let item = currentItem {
            selectedGenre = item.selectedGenre ?? item.allGenres.first
        }
    }

    private func skipCurrent() {
        // Move to next item
        currentIndex += 1

        if currentIndex >= queue.items.count {
            // Done reviewing
            isPresented = false
        } else {
            // Load next item's default selection
            if let item = currentItem {
                selectedGenre = item.selectedGenre ?? item.allGenres.first
            }
        }
    }

    private func applyGenreAndNext() {
        guard let item = currentItem, let genre = selectedGenre, !genre.isEmpty else { return }

        isProcessing = true

        Task {
            // Update the queue with selected genre
            queue.updateGenre(id: item.id, genre: genre)

            // Rename the file with selected genre
            await renameFileWithGenre(item: item, genre: genre)

            // Remove from queue
            queue.remove(id: item.id)

            await MainActor.run {
                isProcessing = false

                // Notify file was renamed
                onFileRenamed?()

                // Check if there are more items
                if queue.items.isEmpty {
                    // All done!
                    isPresented = false
                } else {
                    // Stay at same index (since we removed the current item)
                    // but load the new item at this position
                    if currentIndex >= queue.items.count {
                        currentIndex = queue.items.count - 1
                    }

                    if let nextItem = currentItem {
                        selectedGenre = nextItem.selectedGenre ?? nextItem.allGenres.first
                    } else {
                        isPresented = false
                    }
                }
            }
        }
    }

    private func renameFileWithGenre(item: GenreReviewItem, genre: String) async {
        let fileURL = URL(fileURLWithPath: item.filePath)
        let directory = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension

        // Create ShazamResult with selected genre
        let result = ShazamResult(
            filePath: item.filePath,
            fileName: item.fileName,
            title: item.title,
            artist: item.artist,
            album: item.album,
            genre: genre,
            allGenres: item.allGenres,
            needsGenreReview: false,
            year: nil,
            matched: true,
            error: nil
        )

        do {
            // Step 1: Save metadata to the file with selected genre
            print("💾 [GENRE] Saving metadata with genre '\(genre)'")
            try await saveMetadataToFile(result: result, url: fileURL)
            print("✅ [GENRE] Metadata saved successfully")

            // Step 2: Rename file
            let newName = generateFilename(from: result, extension: ext)
            let newURL = directory.appendingPathComponent(newName)

            // Check if file already exists
            if FileManager.default.fileExists(atPath: newURL.path) && newURL.path != fileURL.path {
                print("⚠️ [GENRE] File already exists, skipping rename: \(newName)")
                return
            }

            if newURL.path != fileURL.path {
                try FileManager.default.moveItem(at: fileURL, to: newURL)
                print("✅ [GENRE] Renamed to: \(newName)")
            }
        } catch {
            print("❌ [GENRE] Error: \(error)")
        }
    }

    private func saveMetadataToFile(result: ShazamResult, url: URL) async throws {
        let ext = url.pathExtension.lowercased()

        // MP3 files: Skip metadata writing (AVAssetExportSession doesn't support MP3 output)
        // Genre is already in filename, so just return success
        if ext == "mp3" {
            print("💾 [GENRE] Skipping metadata write for MP3 (not supported by AVAssetExportSession)")
            return
        }

        let asset = AVURLAsset(url: url)

        // Prepare metadata items
        var metadataItems: [AVMetadataItem] = []

        func addMetadata(key: AVMetadataKey, value: String) {
            guard !value.isEmpty else { return }
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = key as NSString
            item.value = value as NSString
            metadataItems.append(item)
        }

        if let title = result.title {
            addMetadata(key: .commonKeyTitle, value: title)
        }

        if let artist = result.artist {
            addMetadata(key: .commonKeyArtist, value: artist)
        }

        if let album = result.album {
            addMetadata(key: .commonKeyAlbumName, value: album)
        }

        if let genre = result.genre {
            addMetadata(key: .commonKeyType, value: genre)
        }

        if let year = result.year {
            addMetadata(key: .commonKeyCreationDate, value: year)
        }

        // Export with new metadata
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "GenreReview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)

        exportSession.metadata = metadataItems

        // Determine output file type
        let outputFileType: AVFileType
        switch ext {
        case "m4a", "m4b":
            outputFileType = .m4a
        case "mp4", "m4v":
            outputFileType = .mp4
        case "mov":
            outputFileType = .mov
        case "wav":
            outputFileType = .wav
        case "aiff", "aif":
            outputFileType = .aiff
        default:
            outputFileType = .mp4
        }

        try await exportSession.export(to: tempURL, as: outputFileType)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    private func generateFilename(from result: ShazamResult, extension ext: String) -> String {
        let blocks = ShazamSettings.shared.formatBlocks
        var parts: [String] = []

        for block in blocks {
            switch block.field {
            case .title:
                if let title = result.title { parts.append(title) }
            case .artist:
                if let artist = result.artist { parts.append(artist) }
            case .albumName:
                if let album = result.album { parts.append(album) }
            case .genres:
                if let genre = result.genre { parts.append(genre) }
            case .year, .releaseDate:
                if let year = result.year { parts.append(year) }
            case .separator:
                // Only add separator if there's already content
                if !parts.isEmpty {
                    parts.append(" - ")
                }
            default:
                continue
            }
        }

        let name = parts.joined(separator: "")
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
                            .replacingOccurrences(of: ":", with: "-")

        return sanitized + "." + ext
    }
}

#Preview {
    @Previewable @State var isPresented = true
    GenreReviewDialog(isPresented: $isPresented)
}
