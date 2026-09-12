//
//  ScanForMediaDialog.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 13 1210
//

import SwiftUI
import AppKit

struct ScanForMediaDialog: View {
    let sourceFolders: [FileItem]
    let playlistManager: PlaylistManager?
    let onComplete: () -> Void
    let onNavigateOtherPane: (String) -> Void
    @Binding var isPresented: Bool

    // Convenience init for single folder
    init(sourceFolder: FileItem, destinationPath: String, playlistManager: PlaylistManager?, onComplete: @escaping () -> Void, onNavigateOtherPane: @escaping (String) -> Void, isPresented: Binding<Bool>) {
        self.sourceFolders = [sourceFolder]
        self._destinationPath = State(initialValue: destinationPath)
        self.playlistManager = playlistManager
        self.onComplete = onComplete
        self.onNavigateOtherPane = onNavigateOtherPane
        self._isPresented = isPresented
    }

    // Init for multiple folders
    init(sourceFolders: [FileItem], destinationPath: String, playlistManager: PlaylistManager?, onComplete: @escaping () -> Void, onNavigateOtherPane: @escaping (String) -> Void, isPresented: Binding<Bool>) {
        self.sourceFolders = sourceFolders
        self._destinationPath = State(initialValue: destinationPath)
        self.playlistManager = playlistManager
        self.onComplete = onComplete
        self.onNavigateOtherPane = onNavigateOtherPane
        self._isPresented = isPresented
    }

    @State private var scanner = MediaScanner()
    @State private var phase: ScanPhase = .scanning
    @State private var selectedAction: ScanAction = .addToPlaylist
    @State private var selectedOrganization: Organization = .flatten
    @State private var processedCount = 0
    @State private var totalCount = 0
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var destinationPath: String

    /// The media library designated in Settings, offered as a one-click destination.
    /// Read live rather than captured at init, so designating one while this dialog
    /// is open still offers it.
    private var mediaLibraryPath: String { ShazamSettings.shared.musicLibraryPath }

    /// The designated folder can sit on a drive that is not mounted. Offering it as a
    /// destination in that state would fail at Execute, after the scan.
    private var mediaLibraryIsReachable: Bool {
        var isDir: ObjCBool = false
        let p = mediaLibraryPath
        guard !p.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }

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
        // His wording, 2026-09-11. The designated folder is named in the action
        // itself so it does not hide behind a destination row he never reached.
        case copyToMediaLibrary = "Copy to Designated Media Folder"
        case moveToMediaLibrary = "Move to Designated Media Folder"

        /// True for the two actions that write to the folder designated in Settings.
        var usesMediaLibrary: Bool {
            self == .copyToMediaLibrary || self == .moveToMediaLibrary
        }

        /// True for every action that writes files anywhere.
        var writesFiles: Bool { self != .addToPlaylist }
    }

    enum Organization: String, CaseIterable {
        case flatten = "Flatten (all in one folder)"
        case byExtension = "Folders by Extension (MP3/, M4A/, MP4/...)"
        case byMediaType = "Folders by Media Type (Audio/, Video/)"
        // His ask, 2026-09-11: media type first, then extension inside it.
        case byMediaTypeThenExtension = "Folders by Media Type then Extension (Audio/MP3/, Video/MP4/...)"
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
                    // Cannot execute a designated-folder action with nothing
                    // designated, or with its drive unmounted. Refusing here beats
                    // failing after the scan.
                    .disabled(scanner.foundFiles.isEmpty
                              || (selectedAction.usesMediaLibrary && !mediaLibraryIsReachable))
                    .help(actionHelpText)
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
        .frame(width: 600, height: 700)
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
                .padding(.leading, 4)

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

            // File list or summary
            if scanner.foundFiles.count <= 50 {
                // Show full file list for small batches
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
            } else {
                // Show summary for large batches
                VStack(alignment: .leading, spacing: 12) {
                    let audioCount = scanner.foundFiles.filter { scanner.getMediaType(for: $0) == .audio }.count
                    let videoCount = scanner.foundFiles.filter { scanner.getMediaType(for: $0) == .video }.count

                    HStack(spacing: 16) {
                        if audioCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "music.note")
                                    .foregroundColor(Color(red: 0.85, green: 0.65, blue: 0.13))
                                Text("\(audioCount) Audio")
                                    .font(.subheadline)
                            }
                        }
                        if videoCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "film")
                                    .foregroundColor(Color(red: 0.61, green: 0.35, blue: 0.71))
                                Text("\(videoCount) Video")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }

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
                // Stacked, not segmented. His call, 2026-09-11: five labels this long
                // overflowed a 600-point window and clipped the first and last option
                // off both edges.
                .pickerStyle(.radioGroup)
                .labelsHidden()
                // His ask, 2026-09-11: the "select designated folder in settings"
                // prompt belongs in the hover text, not as another line on screen.
                .help(actionHelpText)
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

                // Destination folder picker.
                // Hidden for the two designated-folder actions: those name their
                // destination in the action itself, so offering a second, editable
                // destination beside them would be two answers to one question.
                if !selectedAction.usesMediaLibrary {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Destination:")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    HStack {
                        Text(destinationPath.isEmpty ? "No destination selected" : destinationPath)
                            .font(.caption)
                            .foregroundColor(destinationPath.isEmpty ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        // Third destination: the media library designated in Settings.
                        // His ask, 2026-09-11 — the whole point of designating it is
                        // not having to go and find it again in a file picker.
                        if !mediaLibraryPath.isEmpty {
                            Button("Media Library") {
                                destinationPath = mediaLibraryPath
                            }
                            .buttonStyle(.bordered)
                            .disabled(destinationPath == mediaLibraryPath || !mediaLibraryIsReachable)
                            .help(mediaLibraryIsReachable
                                  ? "Send to the designated media library: \(mediaLibraryPath)"
                                  : "Designated media library is not reachable right now: \(mediaLibraryPath)")
                        }

                        Button("Choose Folder...") {
                            chooseDestinationFolder()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                }
                } else {
                    // Show what the designated action will actually write to, or say
                    // plainly that nothing is designated yet.
                    HStack(spacing: 6) {
                        Image(systemName: mediaLibraryIsReachable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(mediaLibraryIsReachable ? .green : .orange)
                        Text(mediaLibraryPath.isEmpty
                             ? "No designated media folder. Choose one in Settings, or right-click a folder."
                             : mediaLibraryPath)
                            .font(.caption)
                            .foregroundColor(mediaLibraryIsReachable ? .secondary : .orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                    .help(actionHelpText)
                }
            }
        }
    }

    /// Hover text for the action picker. Names the designated folder when there is
    /// one, and tells him where to set it when there is not.
    private var actionHelpText: String {
        guard selectedAction.usesMediaLibrary else {
            return "Add to Playlist, or copy/move to the other pane"
        }
        if mediaLibraryPath.isEmpty {
            return "Select designated folder in Settings"
        }
        if !mediaLibraryIsReachable {
            return "Designated folder is not reachable right now: \(mediaLibraryPath)"
        }
        return "Designated media folder: \(mediaLibraryPath)"
    }

    // MARK: - Executing View
    private var executingView: some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(processedCount), total: Double(max(totalCount, 1)))
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
        let sourceURLs = sourceFolders.map { URL(fileURLWithPath: $0.path) }
        _ = await scanner.scanFolders(at: sourceURLs)
        phase = .review
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Destination"
        panel.message = "Select the folder where files will be copied or moved"

        if !destinationPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: destinationPath)
        }

        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }

    private func executeOperation() {
        // The two "Designated Media Folder" actions ignore whatever the destination
        // row says and write to the folder chosen in Settings. One source for it.
        if selectedAction.usesMediaLibrary {
            destinationPath = mediaLibraryPath
        }

        // Validate destination path for copy/move operations
        if selectedAction.writesFiles {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: destinationPath) {
                errorMessage = "Destination folder does not exist: \(destinationPath)"
                showErrorAlert = true
                return
            }

            // Navigate other pane to destination before starting operation
            onNavigateOtherPane(destinationPath)
        }

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
            case .copyToMediaLibrary:
                await copyFiles()
            case .moveToMediaLibrary:
                await moveFiles()
            }
            await MainActor.run {
                phase = .complete
                onComplete()
            }
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
                    modificationDate: Date(),
                    creationDate: Date()
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

                case .byMediaTypeThenExtension:
                    // Audio/MP3/, Audio/M4A/, Video/MP4/, Video/MOV/ — media type is
                    // the shelf, extension is the row on it.
                    let mediaType = scanner.getMediaType(for: sourceURL).rawValue
                    let ext = sourceURL.pathExtension.uppercased()
                    let nested = destURL
                        .appendingPathComponent(mediaType)
                        .appendingPathComponent(ext)
                    try? fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
                    destFileURL = nested.appendingPathComponent(fileName)
                }

                // Handle duplicates
                destFileURL = getUniqueFileURL(destFileURL)

                // ⛔ GUARDRAIL — a file that belongs to another app is ALWAYS copied,
                // even when Move is the selected action. His instruction, 2026-09-11:
                // "it should have a guardrail to only copy from mail attachments no
                // matter if move is selected or not."
                //
                // Moving a Mail attachment out of its container breaks the message it
                // belongs to, and the same is true of Messages and of the originals
                // inside a Photos library. The user cannot see that damage until they
                // open the message, which is far too late for an undo.
                if move && !MoveGuard.mustCopyNotMove(sourceURL) {
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
                        // Show error for first failure, then continue
                        if errorMessage == nil {
                            errorMessage = "Failed to copy \(sourceURL.lastPathComponent): \(error.localizedDescription)\n\nContinuing with remaining files..."
                            showErrorAlert = true
                        }
                        // Silently continue - first error already shown to user
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
