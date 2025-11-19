//
//  UnifiedQueueReviewPanel.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 19 1115
//

import SwiftUI
import AVFoundation

// Unified review item that can be either unmatched or needs genre selection
enum ReviewItemType {
    case unmatched(QueuedItem)
    case genreSelection(GenreReviewItem)
}

struct UnifiedQueueReviewPanel: View {
    @Binding var isPresented: Bool
    @State private var unmatchedQueue = ShazamQueue.shared
    @State private var genreQueue = GenreReviewQueue.shared
    @State private var selectedTab = 0
    let onFileRenamed: (() -> Void)?

    var unmatchedCount: Int {
        unmatchedQueue.count()
    }

    var genreReviewCount: Int {
        genreQueue.count()
    }

    var totalCount: Int {
        unmatchedCount + genreReviewCount
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet.clipboard")
                    .font(.title2)
                    .foregroundColor(.orange)
                Text("Review Queue")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(totalCount) files")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
            }
            .padding()

            Divider()

            // Tab selector
            Picker("Queue Type", selection: $selectedTab) {
                Text("Genre Selection (\(genreReviewCount))").tag(0)
                Text("Unmatched (\(unmatchedCount))").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Content based on selected tab
            if selectedTab == 0 {
                // Genre selection queue
                if genreQueue.items.isEmpty {
                    emptyState(
                        icon: "checkmark.circle.fill",
                        title: "No files need genre selection",
                        subtitle: "All matched files have clear genres"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(genreQueue.items) { item in
                                GenreSelectionRow(
                                    item: item,
                                    onApply: { selectedGenre in
                                        applyGenreSelection(item: item, genre: selectedGenre)
                                    },
                                    onRemove: {
                                        genreQueue.remove(id: item.id)
                                    }
                                )
                            }
                        }
                        .padding()
                    }
                }
            } else {
                // Unmatched queue
                if unmatchedQueue.items.isEmpty {
                    emptyState(
                        icon: "checkmark.circle.fill",
                        title: "Queue is empty",
                        subtitle: "All files have been processed"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(unmatchedQueue.items) { item in
                                UnmatchedItemRow(
                                    item: item,
                                    onRetry: {
                                        retryShazam(item: item, deepDive: false)
                                    },
                                    onDeepDive: {
                                        retryShazam(item: item, deepDive: true)
                                    },
                                    onRemove: {
                                        unmatchedQueue.remove(id: item.id)
                                    }
                                )
                            }
                        }
                        .padding()
                    }
                }
            }

            Divider()

            // Footer actions
            HStack {
                if selectedTab == 0 && !genreQueue.items.isEmpty {
                    Button(action: {
                        genreQueue.removeAll()
                    }) {
                        Label("Clear Genre Queue", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else if selectedTab == 1 && !unmatchedQueue.items.isEmpty {
                    Button(action: {
                        unmatchedQueue.removeAll()
                    }) {
                        Label("Clear Unmatched Queue", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                Spacer()

                Button("Close") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 700, height: 600)
    }

    @ViewBuilder
    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func retryShazam(item: QueuedItem, deepDive: Bool) {
        Task {
            let service = ShazamService()
            let result: ShazamResult

            if deepDive {
                print("🔍 [RETRY] Starting deep dive for: \(item.fileName)")
                result = await service.detectFileDeepDive(path: item.filePath)
            } else {
                print("🔄 [RETRY] Starting quick retry for: \(item.fileName)")
                result = await service.detectFile(path: item.filePath)
            }

            await MainActor.run {
                if result.matched {
                    // Success! Remove from unmatched queue
                    unmatchedQueue.remove(id: item.id)

                    if result.needsGenreReview {
                        // Add to genre review queue
                        genreQueue.add(result: result)
                        print("✅ [RETRY] Matched! Added to genre review queue")
                        // Switch to genre tab
                        selectedTab = 0
                    } else {
                        // Auto-rename and save metadata if genre is clear
                        print("✅ [RETRY] Matched with clear genre!")
                        Task {
                            let reviewItem = GenreReviewItem(
                                filePath: result.filePath,
                                fileName: result.fileName,
                                title: result.title,
                                artist: result.artist,
                                album: result.album,
                                allGenres: result.allGenres,
                                selectedGenre: result.genre
                            )
                            await renameFileWithGenre(item: reviewItem, genre: result.genre ?? "Unknown")
                            onFileRenamed?()
                        }
                    }
                } else {
                    print("❌ [RETRY] Still no match")
                    // Update error message in queue
                    if let index = unmatchedQueue.items.firstIndex(where: { $0.id == item.id }) {
                        var updatedItem = unmatchedQueue.items[index]
                        updatedItem.attemptCount += 1
                        updatedItem.lastError = result.error
                        // Can't directly modify - need to use queue's add method
                        unmatchedQueue.add(
                            filePath: updatedItem.filePath,
                            fileName: updatedItem.fileName,
                            error: result.error
                        )
                    }
                }
            }
        }
    }

    private func applyGenreSelection(item: GenreReviewItem, genre: String) {
        Task {
            // Update the queue with selected genre
            genreQueue.updateGenre(id: item.id, genre: genre)

            // Rename the file with selected genre
            await renameFileWithGenre(item: item, genre: genre)

            // Remove from queue
            await MainActor.run {
                genreQueue.remove(id: item.id)

                // Notify file was renamed
                onFileRenamed?()
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
        let ext = url.pathExtension.lowercased()
        let outputFileType: AVFileType
        switch ext {
        case "mp3":
            outputFileType = .mp3
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

// Row for genre selection items
struct GenreSelectionRow: View {
    let item: GenreReviewItem
    let onApply: (String) -> Void
    let onRemove: () -> Void

    @State private var selectedGenre: String
    @State private var isExpanded = false
    @State private var customGenre = ""
    @State private var isProcessing = false

    init(item: GenreReviewItem, onApply: @escaping (String) -> Void, onRemove: @escaping () -> Void) {
        self.item = item
        self.onApply = onApply
        self.onRemove = onRemove
        _selectedGenre = State(initialValue: item.selectedGenre ?? item.allGenres.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack(spacing: 12) {
                // Music icon
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundColor(.purple)
                    .frame(width: 32)

                // Song info
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title ?? "Unknown Title")
                        .font(.headline)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let artist = item.artist {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        if item.allGenres.count > 0 {
                            Text("• \(item.allGenres.count) genres")
                                .font(.caption)
                                .foregroundColor(.purple)
                        }
                    }

                    Text(item.fileName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Expand/collapse button
                Button(action: {
                    withAnimation {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Expanded content
            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    if item.allGenres.isEmpty {
                        // No genres - manual entry
                        Text("No genres detected - enter manually:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("Enter genre", text: $customGenre)
                            .textFieldStyle(.roundedBorder)
                    } else if item.allGenres.count == 1 {
                        // Single genre - just show it
                        Text("Genre:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(item.allGenres[0])
                            .font(.body)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.purple.opacity(0.1))
                            .cornerRadius(6)
                    } else {
                        // Multiple genres - picker
                        Text("Select genre (\(item.allGenres.count) options):")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("Genre", selection: $selectedGenre) {
                            ForEach(item.allGenres, id: \.self) { genre in
                                Text(genre).tag(genre)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Show all options
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(item.allGenres, id: \.self) { genre in
                                    Button(action: {
                                        selectedGenre = genre
                                    }) {
                                        Text(genre)
                                            .font(.caption)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(selectedGenre == genre ? Color.purple : Color.secondary.opacity(0.2))
                                            .foregroundColor(selectedGenre == genre ? .white : .primary)
                                            .cornerRadius(12)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Action buttons
                    HStack {
                        Button(action: onRemove) {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        Spacer()

                        Button(action: {
                            isProcessing = true
                            let genreToUse = item.allGenres.isEmpty ? customGenre : selectedGenre
                            onApply(genreToUse)
                        }) {
                            if isProcessing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Apply & Rename", systemImage: "checkmark.circle")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(
                            (item.allGenres.isEmpty && customGenre.isEmpty) ||
                            (!item.allGenres.isEmpty && selectedGenre.isEmpty) ||
                            isProcessing
                        )
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isExpanded ? Color.purple.opacity(0.3) : Color.clear, lineWidth: 2)
        )
    }
}

// Row for unmatched items
struct UnmatchedItemRow: View {
    let item: QueuedItem
    let onRetry: () -> Void
    let onDeepDive: () -> Void
    let onRemove: () -> Void

    @State private var isExpanded = false
    @State private var isProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack(spacing: 12) {
                // Warning icon
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundColor(.orange)
                    .frame(width: 32)

                // File info
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.fileName)
                        .font(.body)
                        .lineLimit(1)

                    if let error = item.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(1)
                    }

                    if item.attemptCount > 1 {
                        Text("Attempts: \(item.attemptCount)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Expand/collapse button
                Button(action: {
                    withAnimation {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Expanded content
            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("File Path:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(item.filePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    // Explanation
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Detection Options:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                                .foregroundColor(.orange)
                            Text("Quick Retry: Samples first 10 seconds")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.purple)
                            Text("Deep Dive: Samples 30s, 60s, 90s, 120s positions (skips intros/DJs)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                    // Action buttons
                    HStack {
                        Button(action: onRemove) {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(isProcessing)

                        Spacer()

                        Button(action: {
                            isProcessing = true
                            onRetry()
                        }) {
                            if isProcessing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Quick Retry", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(isProcessing)

                        Button(action: {
                            isProcessing = true
                            onDeepDive()
                        }) {
                            Label("Deep Dive", systemImage: "magnifyingglass.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(isProcessing)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isExpanded ? Color.orange.opacity(0.3) : Color.clear, lineWidth: 2)
        )
    }
}

#Preview {
    @Previewable @State var isPresented = true
    UnifiedQueueReviewPanel(
        isPresented: $isPresented,
        onFileRenamed: nil
    )
}
