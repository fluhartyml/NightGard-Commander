//
//  ScanForMediaDialog.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 13 1210
//

import SwiftUI

struct ScanForMediaDialog: View {
    let sourceFolder: FileItem
    let destinationPath: String
    let playlistManager: PlaylistManager?
    @Binding var isPresented: Bool

    @State private var scanner = MediaScanner()
    @State private var phase: ScanPhase = .scanning
    @State private var selectedAction: ScanAction = .addToPlaylist
    @State private var selectedOrganization: Organization = .flatten
    @State private var processedCount = 0
    @State private var totalCount = 0
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    enum ScanPhase {
        case scanning
        case review
        case executing
        case complete
    }

    enum ScanAction: String, CaseIterable {
        case addToPlaylist = "Add to Playlist"
        case copyToOtherPane = "Copy to Other Pane"
        case moveToOtherPane = "Move to Other Pane"
    }

    enum Organization: String, CaseIterable {
        case flatten = "Flatten (all in one folder)"
        case byExtension = "By Extension (MP3/, M4A/, MP4/...)"
        case byMediaType = "By Media Type (Audio/, Video/)"
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Text("Scan for Media Files")
                .font(.title2)
                .fontWeight(.bold)

            switch phase {
            case .scanning:
                scanningView
            case .review:
                reviewView
            case .executing:
                executingView
            case .complete:
                completeView
            }

            // Buttons
            HStack {
                if phase == .review {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .keyboardShortcut(.escape)

                    Spacer()

                    Button("Execute") {
                        executeOperation()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scanner.foundFiles.isEmpty)
                } else if phase == .executing {
                    Button("Cancel") {
                        scanner.cancel()
                        isPresented = false
                    }
                } else if phase == .complete {
                    Button("Done") {
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top)
        }
        .padding()
        .frame(width: 600, height: 500)
        .task {
            await startScanning()
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") {
                showErrorAlert = false
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
    }

    // MARK: - Scanning View
    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Scanning...")
                .font(.headline)

            Text(scanner.currentPath)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            Text("Found: \(scanner.foundFiles.count) files")
                .font(.title3)
                .fontWeight(.semibold)
        }
    }

    // MARK: - Review View
    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Found \(scanner.foundFiles.count) media files")
                .font(.headline)

            // Size and space info
            HStack {
                Text("Total size: \(scanner.formatBytes(scanner.totalSize))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if selectedAction != .addToPlaylist, let available = scanner.availableSpace(at: destinationPath) {
                    Spacer()
                    let hasSpace = available > scanner.totalSize
                    HStack(spacing: 4) {
                        Image(systemName: hasSpace ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(hasSpace ? .green : .orange)
                        Text("Available: \(scanner.formatBytes(available))")
                            .font(.subheadline)
                            .foregroundColor(hasSpace ? .secondary : .orange)
                    }
                }
            }

            // Space warning
            if selectedAction != .addToPlaylist, let available = scanner.availableSpace(at: destinationPath), available < scanner.totalSize {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Warning: Insufficient disk space. Some files may not copy.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(4)
            }

            // File list
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(scanner.foundFiles, id: \.self) { url in
                        HStack {
                            Image(systemName: iconForExtension(url.pathExtension))
                                .foregroundColor(colorForMediaType(url))
                            Text(url.lastPathComponent)
                                .font(.caption)
                            Spacer()
                            Text(url.deletingLastPathComponent().lastPathComponent)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
            .border(Color.gray.opacity(0.3))

            Divider()

            // Action selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Action:")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Picker("Action", selection: $selectedAction) {
                    ForEach(ScanAction.allCases, id: \.self) { action in
                        Text(action.rawValue).tag(action)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Organization selection (only for copy/move)
            if selectedAction != .addToPlaylist {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Organization:")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Picker("Organization", selection: $selectedOrganization) {
                        ForEach(Organization.allCases, id: \.self) { org in
                            Text(org.rawValue).tag(org)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }
        }
    }

    // MARK: - Executing View
    private var executingView: some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(processedCount), total: Double(totalCount))
                .progressViewStyle(.linear)

            Text("\(selectedAction.rawValue)...")
                .font(.headline)

            Text("\(processedCount) of \(totalCount) files")
                .font(.title3)
                .fontWeight(.semibold)
        }
    }

    // MARK: - Complete View
    private var completeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Complete!")
                .font(.title2)
                .fontWeight(.bold)

            Text("Processed \(processedCount) files")
                .font(.headline)
        }
    }

    // MARK: - Operations
    private func startScanning() async {
        let sourceURL = URL(fileURLWithPath: sourceFolder.path)
        _ = await scanner.scanFolder(at: sourceURL)
        phase = .review
    }

    private func executeOperation() {
        phase = .executing
        totalCount = scanner.foundFiles.count
        processedCount = 0

        Task {
            switch selectedAction {
            case .addToPlaylist:
                await addToPlaylist()
            case .copyToOtherPane:
                await copyFiles()
            case .moveToOtherPane:
                await moveFiles()
            }
            phase = .complete
        }
    }

    private func addToPlaylist() async {
        guard let playlistManager = playlistManager else { return }

        for url in scanner.foundFiles {
            guard !scanner.isCancelled else { break }

            await MainActor.run {
                let fileItem = FileItem(
                    name: url.lastPathComponent,
                    path: url.path,
                    isDirectory: false,
                    size: 0,
                    modificationDate: Date()
                )
                playlistManager.addItem(fileItem)
                processedCount += 1
            }
        }
    }

    private func copyFiles() async {
        await processFiles(move: false)
    }

    private func moveFiles() async {
        await processFiles(move: true)
    }

    private func processFiles(move: Bool) async {
        let fileManager = FileManager.default
        let destURL = URL(fileURLWithPath: destinationPath)

        for sourceURL in scanner.foundFiles {
            guard !scanner.isCancelled else { break }

            do {
                let fileName = sourceURL.lastPathComponent
                var destFileURL: URL

                // Determine destination based on organization
                switch selectedOrganization {
                case .flatten:
                    destFileURL = destURL.appendingPathComponent(fileName)

                case .byExtension:
                    let ext = sourceURL.pathExtension.uppercased()
                    let extFolder = destURL.appendingPathComponent(ext)
                    try? fileManager.createDirectory(at: extFolder, withIntermediateDirectories: true)
                    destFileURL = extFolder.appendingPathComponent(fileName)

                case .byMediaType:
                    let mediaType = scanner.getMediaType(for: sourceURL).rawValue
                    let typeFolder = destURL.appendingPathComponent(mediaType)
                    try? fileManager.createDirectory(at: typeFolder, withIntermediateDirectories: true)
                    destFileURL = typeFolder.appendingPathComponent(fileName)
                }

                // Handle duplicates
                destFileURL = getUniqueFileURL(destFileURL)

                // Copy or move
                if move {
                    try fileManager.moveItem(at: sourceURL, to: destFileURL)
                } else {
                    try fileManager.copyItem(at: sourceURL, to: destFileURL)
                }

                await MainActor.run {
                    processedCount += 1
                }
            } catch {
                // Check for disk space error
                let nsError = error as NSError
                let isDiskFull = nsError.code == NSFileWriteOutOfSpaceError ||
                                 nsError.domain == NSCocoaErrorDomain && nsError.code == 640

                await MainActor.run {
                    if isDiskFull {
                        errorMessage = "Disk full: Could not copy \(sourceURL.lastPathComponent). \(processedCount) of \(totalCount) files copied."
                        showErrorAlert = true
                        scanner.cancel()
                    } else {
                        // Log other errors but continue
                        print("Error processing file \(sourceURL.lastPathComponent): \(error)")
                    }
                }

                if isDiskFull {
                    break
                }
            }
        }
    }

    private func getUniqueFileURL(_ url: URL) -> URL {
        let fileManager = FileManager.default
        var uniqueURL = url
        var counter = 2

        while fileManager.fileExists(atPath: uniqueURL.path) {
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let newName = "\(name)-\(counter).\(ext)"
            uniqueURL = url.deletingLastPathComponent().appendingPathComponent(newName)
            counter += 1
        }

        return uniqueURL
    }

    // MARK: - Helpers
    private func iconForExtension(_ ext: String) -> String {
        let lowercased = ext.lowercased()
        if scanner.getMediaType(for: URL(fileURLWithPath: "file.\(ext)")) == .audio {
            return "music.note"
        } else {
            return "film"
        }
    }

    private func colorForMediaType(_ url: URL) -> Color {
        let type = scanner.getMediaType(for: url)
        switch type {
        case .audio:
            return Color(red: 0.85, green: 0.65, blue: 0.13) // Mustard yellow
        case .video:
            return Color(red: 0.61, green: 0.35, blue: 0.71) // Purple
        case .other:
            return .gray
        }
    }
}
