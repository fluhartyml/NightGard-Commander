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
    @State private var audioPlayer: AVAudioPlayer?
    @State private var currentlyPlayingPath: String?
    @State private var isPlaying = false
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
                                    currentlyPlayingPath: currentlyPlayingPath,
                                    isPlaying: isPlaying,
                                    onApply: { selectedGenre in
                                        applyGenreSelection(item: item, genre: selectedGenre)
                                    },
                                    onRemove: {
                                        genreQueue.remove(id: item.id)
                                    },
                                    onPlay: { filePath in
                                        playAudioFile(path: filePath)
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
                                    currentlyPlayingPath: currentlyPlayingPath,
                                    isPlaying: isPlaying,
                                    onRetry: {
                                        retryShazam(item: item, deepDive: false)
                                    },
                                    onDeepDive: {
                                        retryShazam(item: item, deepDive: true)
                                    },
                                    onRemove: {
                                        unmatchedQueue.remove(id: item.id)
                                    },
                                    onPlay: { filePath in
                                        playAudioFile(path: filePath)
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
                        autoSelectFirstGenreForAll()
                    }) {
                        Label("Use First Genre for All (\(genreQueue.items.count))", systemImage: "bolt.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .help("Automatically select the first genre from each list and rename all files")

                    Button(action: {
                        genreQueue.removeAll()
                    }) {
                        Label("Clear Genre Queue", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else if selectedTab == 1 && !unmatchedQueue.items.isEmpty {
                    Button(action: {
                        deepDiveAll()
                    }) {
                        Label("Deep Dive All (\(unmatchedQueue.items.count))", systemImage: "magnifyingglass.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .help("Sample multiple positions in all files (30s, 60s, 90s, 120s)")

                    Button(action: {
                        moveUnmatchedToFolder()
                    }) {
                        Label("Move All to Folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)

                    Button(action: {
                        unmatchedQueue.removeAll()
                    }) {
                        Label("Clear Queue", systemImage: "trash")
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

    private func playAudioFile(path: String) {
        let url = URL(fileURLWithPath: path)

        // If this is the same file
        if currentlyPlayingPath == path {
            if isPlaying {
                // Pause it
                audioPlayer?.pause()
                isPlaying = false
                print("⏸️ [PLAY] Paused: \(url.lastPathComponent)")
            } else {
                // Resume it
                audioPlayer?.play()
                isPlaying = true
                print("▶️ [PLAY] Resumed: \(url.lastPathComponent)")
            }
            return
        }

        // Different file - stop current and play new
        do {
            // Stop current playback if any
            audioPlayer?.stop()

            // Create new player
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            currentlyPlayingPath = path
            isPlaying = true

            print("▶️ [PLAY] Playing: \(url.lastPathComponent)")
        } catch {
            print("❌ [PLAY] Error playing audio: \(error)")
            currentlyPlayingPath = nil
            isPlaying = false
        }
    }

    private func moveUnmatchedToFolder() {
        guard !unmatchedQueue.items.isEmpty else { return }

        // Get the directory from the first file
        guard let firstFile = unmatchedQueue.items.first else { return }
        let sourceURL = URL(fileURLWithPath: firstFile.filePath)
        let parentDirectory = sourceURL.deletingLastPathComponent()

        // Create "Quarantine" folder for problem files
        let unmatchedFolderURL = parentDirectory.appendingPathComponent("Quarantine")

        do {
            // Create folder if it doesn't exist
            if !FileManager.default.fileExists(atPath: unmatchedFolderURL.path) {
                try FileManager.default.createDirectory(at: unmatchedFolderURL, withIntermediateDirectories: false)
                print("📁 [MOVE] Created folder: \(unmatchedFolderURL.path)")
            }

            var movedCount = 0
            var failedCount = 0

            // Move all unmatched files
            for item in unmatchedQueue.items {
                let fileURL = URL(fileURLWithPath: item.filePath)
                let fileName = fileURL.lastPathComponent
                let destinationURL = unmatchedFolderURL.appendingPathComponent(fileName)

                // Check if file exists at destination
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    print("⚠️ [MOVE] File already exists at destination: \(fileName)")
                    failedCount += 1
                    continue
                }

                do {
                    try FileManager.default.moveItem(at: fileURL, to: destinationURL)
                    movedCount += 1
                    print("✅ [MOVE] Moved: \(fileName)")
                } catch {
                    print("❌ [MOVE] Failed to move \(fileName): \(error)")
                    failedCount += 1
                }
            }

            print("📊 [MOVE] Complete: \(movedCount) moved, \(failedCount) failed")

            // Clear the queue after successful moves
            if movedCount > 0 {
                unmatchedQueue.removeAll()
                onFileRenamed?() // Refresh the file browser
            }

        } catch {
            print("❌ [MOVE] Failed to create folder: \(error)")
        }
    }

    private func autoSelectFirstGenreForAll() {
        Task {
            print("⚡ [AUTO GENRE] Starting auto-selection for \(genreQueue.items.count) files...")

            let itemsToProcess = genreQueue.items
            var processedCount = 0

            for item in itemsToProcess {
                // Get first genre from the list
                guard let firstGenre = item.allGenres.first else {
                    print("⚠️ [AUTO GENRE] No genres available for: \(item.fileName)")
                    continue
                }

                print("⚡ [AUTO GENRE] Processing: \(item.fileName) → Genre: \(firstGenre)")

                // Update the queue with selected genre
                genreQueue.updateGenre(id: item.id, genre: firstGenre)

                // Rename the file with selected genre
                await renameFileWithGenre(item: item, genre: firstGenre)

                // Remove from queue
                await MainActor.run {
                    genreQueue.remove(id: item.id)
                }

                processedCount += 1
            }

            await MainActor.run {
                print("✅ [AUTO GENRE] Complete: Processed \(processedCount) files")
                onFileRenamed?() // Refresh file browser
            }
        }
    }

    private func deepDiveAll() {
        Task {
            print("🔍 [DEEP DIVE ALL] Starting deep dive for \(unmatchedQueue.items.count) files...")

            let itemsToProcess = unmatchedQueue.items
            var successCount = 0
            var stillFailedCount = 0

            for item in itemsToProcess {
                print("🔍 [DEEP DIVE ALL] Processing: \(item.fileName)")
                let service = ShazamService()
                let result = await service.detectFileDeepDive(path: item.filePath)

                await MainActor.run {
                    if result.matched {
                        successCount += 1
                        unmatchedQueue.remove(id: item.id)

                        if result.needsGenreReview {
                            genreQueue.add(result: result)
                            print("✅ [DEEP DIVE ALL] Matched! Added to genre review")
                        } else {
                            print("✅ [DEEP DIVE ALL] Matched with clear genre!")
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
                            }
                        }
                    } else {
                        stillFailedCount += 1
                        print("❌ [DEEP DIVE ALL] Still no match for: \(item.fileName)")
                        // Update error in queue (add method auto-increments attempt count)
                        unmatchedQueue.add(
                            filePath: item.filePath,
                            fileName: item.fileName,
                            error: "Deep dive failed: No match at any position"
                        )
                    }
                }

                // Longer delay between files to avoid rate limiting (Error 201)
                // Each file tries up to 10 positions with 3s delays = ~30s per file
                // Add extra 5s between files to be safe
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            }

            await MainActor.run {
                print("📊 [DEEP DIVE ALL] Complete: \(successCount) matched, \(stillFailedCount) still unmatched")
                if successCount > 0 {
                    onFileRenamed?() // Refresh file browser
                    // Switch to genre tab if we added any genre review items
                    if genreQueue.items.count > 0 {
                        selectedTab = 0
                    }
                }
            }
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
                    // Update error message in queue (add method auto-increments attempt count)
                    unmatchedQueue.add(
                        filePath: item.filePath,
                        fileName: item.fileName,
                        error: result.error
                    )
                }
            }
        }
    }

    private func applyGenreSelection(item: GenreReviewItem, genre: String) {
        Task {
            print("🎯 [GENRE APPLY] Starting for: \(item.fileName) with genre: \(genre)")

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

            print("✅ [GENRE APPLY] Complete")
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
            // Check if file exists first
            guard FileManager.default.fileExists(atPath: item.filePath) else {
                print("❌ [GENRE] File doesn't exist: \(item.filePath)")
                return
            }

            // Step 1: Save metadata to the file with selected genre
            print("💾 [GENRE] Saving metadata with genre '\(genre)' to: \(item.fileName)")
            try await saveMetadataToFile(result: result, url: fileURL)
            print("✅ [GENRE] Metadata saved successfully")

            // Step 2: Rename file
            let newName = generateFilename(from: result, extension: ext)
            let newURL = directory.appendingPathComponent(newName)

            print("📝 [GENRE] Generated filename: \(newName)")

            // Check if file already exists
            if FileManager.default.fileExists(atPath: newURL.path) && newURL.path != fileURL.path {
                print("⚠️ [GENRE] File already exists, skipping rename: \(newName)")
                return
            }

            if newURL.path != fileURL.path {
                try FileManager.default.moveItem(at: fileURL, to: newURL)
                print("✅ [GENRE] Renamed to: \(newName)")
            } else {
                print("ℹ️ [GENRE] Filename unchanged: \(newName)")
            }
        } catch {
            print("❌ [GENRE] Error: \(error.localizedDescription)")
            print("❌ [GENRE] Full error: \(error)")
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

// Row for genre selection items
struct GenreSelectionRow: View {
    let item: GenreReviewItem
    let currentlyPlayingPath: String?
    let isPlaying: Bool
    let onApply: (String) -> Void
    let onRemove: () -> Void
    let onPlay: (String) -> Void

    @State private var selectedGenre: String
    @State private var isExpanded = false
    @State private var customGenre = ""
    @State private var isProcessing = false

    init(item: GenreReviewItem, currentlyPlayingPath: String?, isPlaying: Bool, onApply: @escaping (String) -> Void, onRemove: @escaping () -> Void, onPlay: @escaping (String) -> Void) {
        self.item = item
        self.currentlyPlayingPath = currentlyPlayingPath
        self.isPlaying = isPlaying
        self.onApply = onApply
        self.onRemove = onRemove
        self.onPlay = onPlay
        _selectedGenre = State(initialValue: item.selectedGenre ?? item.allGenres.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row - make entire row clickable
            Button(action: {
                withAnimation {
                    isExpanded.toggle()
                }
            }) {
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
                            .foregroundColor(.primary)

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

                    // Play/Pause button (always visible)
                    Button(action: {
                        onPlay(item.filePath)
                    }) {
                        Image(systemName: (currentlyPlayingPath == item.filePath && isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundColor((currentlyPlayingPath == item.filePath && isPlaying) ? .orange : .blue)
                    }
                    .buttonStyle(.plain)
                    .help((currentlyPlayingPath == item.filePath && isPlaying) ? "Pause" : "Play")

                    // Expand/collapse chevron
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
            }
            .buttonStyle(.plain)

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
    let currentlyPlayingPath: String?
    let isPlaying: Bool
    let onRetry: () -> Void
    let onDeepDive: () -> Void
    let onRemove: () -> Void
    let onPlay: (String) -> Void

    @State private var isExpanded = false
    @State private var isProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row - make entire row clickable
            Button(action: {
                withAnimation {
                    isExpanded.toggle()
                }
            }) {
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
                            .foregroundColor(.primary)

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

                    // Play/Pause button (always visible)
                    Button(action: {
                        onPlay(item.filePath)
                    }) {
                        Image(systemName: (currentlyPlayingPath == item.filePath && isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundColor((currentlyPlayingPath == item.filePath && isPlaying) ? .orange : .blue)
                    }
                    .buttonStyle(.plain)
                    .help((currentlyPlayingPath == item.filePath && isPlaying) ? "Pause" : "Play")

                    // Expand/collapse chevron
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
            }
            .buttonStyle(.plain)

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
