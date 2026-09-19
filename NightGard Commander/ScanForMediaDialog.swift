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
    /// Copies and moves go to the same job system as ⌘5 / ⌘6 (build 68): the sheet closes,
    /// a progress bar takes over, and the window stays usable. His report, 2026-09-19:
    /// "it has that popup and wouldnt allow me to do anything else. it wasnt like last
    /// night where i was able to have four different status bars" — and a beach ball,
    /// because the old copy loop ran on the main thread.
    let fileOps: FileOperationController?
    let onComplete: () -> Void
    let onNavigateOtherPane: (String) -> Void
    @Binding var isPresented: Bool

    // Convenience init for single folder
    init(sourceFolder: FileItem, destinationPath: String, playlistManager: PlaylistManager?, fileOps: FileOperationController? = nil, onComplete: @escaping () -> Void, onNavigateOtherPane: @escaping (String) -> Void, isPresented: Binding<Bool>) {
        self.sourceFolders = [sourceFolder]
        self._destinationPath = State(initialValue: destinationPath)
        self.playlistManager = playlistManager
        self.fileOps = fileOps
        self.onComplete = onComplete
        self.onNavigateOtherPane = onNavigateOtherPane
        self._isPresented = isPresented
    }

    // Init for multiple folders
    init(sourceFolders: [FileItem], destinationPath: String, playlistManager: PlaylistManager?, fileOps: FileOperationController? = nil, onComplete: @escaping () -> Void, onNavigateOtherPane: @escaping (String) -> Void, isPresented: Binding<Bool>) {
        self.sourceFolders = sourceFolders
        self._destinationPath = State(initialValue: destinationPath)
        self.playlistManager = playlistManager
        self.fileOps = fileOps
        self.onComplete = onComplete
        self.onNavigateOtherPane = onNavigateOtherPane
        self._isPresented = isPresented
    }

    @State private var scanner = MediaScanner()
    @State private var phase: ScanPhase = .scanning
    @State private var selectedAction: ScanAction = .addToPlaylist
    @State private var selectedOrganization: Organization = .flatten
    /// Build 83 — ONE MEDIA TYPE PER SCAN. His words, 2026-09-19: "i think we're going to have
    /// to split up the Media searches to audio vidio and photo" · "i think it would be best to
    /// do one media type at a time". Only this type is sorted, and only its folders are made.
    @State private var selectedType: MediaScanner.MediaType = .audio

    private var typeFiles: [URL] { scanner.foundFiles.filter { scanner.getMediaType(for: $0) == selectedType } }
    /// Libraries hold photos, so they belong to a Photos scan only.
    private var typeLibraries: [URL] { selectedType == .photo ? scanner.foundLibraries : [] }
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

    /// Build 89 — where the chosen action actually writes. ⛔ The space check used to read
    /// `destinationPath` whatever the action was, so a designated-folder Move reported the
    /// free space of the OTHER PANE. His right pane sat at `/Volumes`, which is the Mac's own
    /// disk: the sheet said 144.99 GB available while the real target, Cold Storage, had 10 TiB.
    /// A space warning measured against the wrong drive is worse than none — it can refuse a
    /// move that fits and wave through one that does not.
    private var writeTargetPath: String {
        selectedAction.usesMediaLibrary ? mediaLibraryPath : destinationPath
    }

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
        case flatten = "Flatten (all in one folder — photos keep their folder)"
        case byExtension = "Folders by Extension (MP3/, M4A/, MP4/... — photos keep their folder)"
        case byMediaType = "Folders by Media Type (Audio/, Video/, Photos/)"
        // His ask, 2026-09-11: media type first, then extension inside it.
        case byMediaTypeThenExtension = "Folders by Media Type then Extension (Audio/MP3/, Video/MP4/, Photos/<folder>/)"
        // Build 87, his: "sub folders of resolution 780 1080 4K etc and within those
        // resolutions pidgeon hole codexes". Video scans only.
        case byResolutionThenCodec = "Video/ then Resolution then Codec (Video/1080p/H.264/)"
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
                // Scrolls, so the buttons below keep their place and their margin. His
                // screen, 2026-09-19: with Organization showing, a whole-drive scan's
                // review ran out of room — Cancel and Execute sat on the sheet's bottom
                // edge and the title was pushed against its top.
                ScrollView {
                    reviewView
                        .padding(.horizontal, 2)
                }
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
                    .disabled(nothingToDo
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
            .padding(.top, 8)
        }
        .padding(20)
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

            if !scanner.foundLibraries.isEmpty {
                Text("and \(scanner.foundLibraries.count) Photos \(scanner.foundLibraries.count == 1 ? "library" : "libraries")")
                    .font(.subheadline)
            }
            Text("\(scanner.checkedCount.formatted()) items looked at")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Stop Scanning") { scanner.cancel() }
        }
    }

    /// Add to Playlist takes files only; the copy and move actions also take libraries.
    private var nothingToDo: Bool {
        typeFiles.isEmpty && (typeLibraries.isEmpty || selectedAction == .addToPlaylist)
    }

    // MARK: - Review View
    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Found \(scanner.foundFiles.count) media files")
                .font(.headline)
                .padding(.leading, 4)

            // His rule, 2026-09-19: "the photos should be copied using the enclosing
            // photolibrarys database to reinstate name and metadata" · "photos copied not
            // moved". Said here, before Execute, not only in the summary afterwards.
            if !typeLibraries.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("and \(typeLibraries.count) Photos \(typeLibraries.count == 1 ? "library" : "libraries") — their photos come out under their real names and dates, read from each library's own database, flat into Photos/, and are copied, never moved:")
                        .font(.caption)
                    ForEach(typeLibraries, id: \.self) { lib in
                        Text("• \(lib.lastPathComponent)  —  \(lib.deletingLastPathComponent().path)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.leading, 4)
            }
            if selectedType == .photo {
                Text("Photos inside a Photos library are always copied. Loose photos follow Move or Copy. All go flat into Photos/ — no subfolders.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }

            // Size and space info
            HStack {
                Text("Total size: \(scanner.formatBytes(scanner.totalSize))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if selectedAction != .addToPlaylist, let available = scanner.availableSpace(at: writeTargetPath) {
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
            if selectedAction != .addToPlaylist, let available = scanner.availableSpace(at: writeTargetPath), available < scanner.totalSize {
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
                    let photoCount = scanner.foundFiles.filter { scanner.getMediaType(for: $0) == .photo }.count

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
                        if photoCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "photo")
                                    .foregroundColor(.teal)
                                Text("\(photoCount) Photos")
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

            // Build 83: which media type this scan sorts.
            VStack(alignment: .leading, spacing: 8) {
                Text("Media type:")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Picker("Media type", selection: $selectedType) {
                    Text("Audio (\(count(.audio).formatted()) files)").tag(MediaScanner.MediaType.audio)
                    Text("Video (\(count(.video).formatted()) files)").tag(MediaScanner.MediaType.video)
                    Text("Photos (\(count(.photo).formatted()) files\(scanner.foundLibraries.isEmpty ? "" : " + \(scanner.foundLibraries.count) \(scanner.foundLibraries.count == 1 ? "library" : "libraries")"))").tag(MediaScanner.MediaType.photo)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .help("One media type per scan. Only this type is sorted, and only its folders are made in the target.")
            }

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

                    if selectedType == .photo {
                        // Build 83: photos have one shelf — flat, in Photos/.
                        Text("Photos go flat into Photos/ in the target — no subfolders.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Organization", selection: $selectedOrganization) {
                            ForEach(Organization.allCases.filter { $0 != .byResolutionThenCodec || selectedType == .video }, id: \.self) { org in
                                Text(organizationLabel(org)).tag(org)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        // The heading above already says it — his screen showed it twice.
                        .labelsHidden()
                    }
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

            // Build 68: the job system does the work, off the main thread, with its own
            // bar, Pause, clash questions and read-back check. This sheet just closes.
            guard let fileOps else {
                errorMessage = "Copying is not available from here right now."
                showErrorAlert = true
                return
            }
            let kind: FileOpKind = (selectedAction == .moveToOtherPane || selectedAction == .moveToMediaLibrary) ? .move : .copy
            // Build 76: one bar per top-level folder, all started at once, each with its
            // own Pause and Cancel — his spec: "i want to see individual status bars so i
            // can pause or cancel individual status bars" · "all at once but i can pause
            // them". They share one name registry, so two bars never claim one name.
            let roots = sourceFolders.map { URL(fileURLWithPath: $0.path) }
            let libraries = Set(typeLibraries.map { $0.standardizedFileURL.path })
            let group = UUID()
            let claims = TargetClaims()
            let target = URL(fileURLWithPath: destinationPath)
            for part in MediaPlan.groups(of: typeLibraries + typeFiles, roots: roots) {
                let libs = part.sources.filter { libraries.contains($0.standardizedFileURL.path) }
                let files = part.sources.filter { !libraries.contains($0.standardizedFileURL.path) }
                fileOps.start(kind, sources: libs + files, target: target,
                              mode: .media(mediaPlan(files: files, libraries: libs)),
                              title: part.name, group: group, sharedTargets: claims) { _ in onComplete() }
            }
            isPresented = false
            return
        }

        phase = .executing
        totalCount = typeFiles.count
        processedCount = 0

        Task {
            // Only Add to Playlist runs here now; copies and moves returned above.
            if selectedAction == .addToPlaylist {
                await addToPlaylist()
            }
            await MainActor.run {
                phase = .complete
                onComplete()
            }
        }
    }

    /// Where each scanned file goes — the rules live in `MediaPlan.build`, shared with the tests.
    private func count(_ type: MediaScanner.MediaType) -> Int {
        scanner.foundFiles.filter { scanner.getMediaType(for: $0) == type }.count
    }

    /// The Organization choices, worded for the type being sorted.
    private func organizationLabel(_ org: Organization) -> String {
        let t = selectedType.rawValue
        let ext = selectedType == .video ? "MP4/, MOV/…" : "MP3/, M4A/…"
        switch org {
        case .flatten: return "Flatten (all in one folder)"
        case .byExtension: return "Folders by Extension (\(ext))"
        case .byMediaType: return "One \(t)/ folder"
        case .byMediaTypeThenExtension: return "\(t)/ then Extension (\(t)/\(ext))"
        case .byResolutionThenCodec: return "Video/ then Resolution then Codec (Video/1080p/H.264/, Video/4K/HEVC/…)"
        }
    }

    private func mediaPlan(files: [URL], libraries: [URL]) -> MediaPlan {
        // Build 83: a Photos scan always shelves into Photos/, flat.
        if selectedType == .photo {
            return MediaPlan.build(files: files, libraries: libraries, sorting: .byType)
        }
        let sorting: MediaPlan.Sorting
        switch selectedOrganization {
        case .flatten: sorting = .flatten
        case .byExtension: sorting = .byExtension
        case .byMediaType: sorting = .byType
        case .byMediaTypeThenExtension: sorting = .byTypeThenExtension
        case .byResolutionThenCodec: sorting = selectedType == .video ? .byResolutionCodec : .byType
        }
        return MediaPlan.build(files: files, libraries: libraries, sorting: sorting)
    }

    private func addToPlaylist() async {
        guard let playlistManager = playlistManager else { return }

        for url in typeFiles {
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

    // MARK: - Helpers
    private func iconForExtension(_ ext: String) -> String {
        switch scanner.getMediaType(for: URL(fileURLWithPath: "file.\(ext)")) {
        case .audio: return "music.note"
        case .photo: return "photo"
        default: return "film"
        }
    }

    private func colorForMediaType(_ url: URL) -> Color {
        let type = scanner.getMediaType(for: url)
        switch type {
        case .audio:
            return Color(red: 0.85, green: 0.65, blue: 0.13) // Mustard yellow
        case .video:
            return Color(red: 0.61, green: 0.35, blue: 0.71) // Purple
        case .photo:
            return .teal
        case .other:
            return .gray
        }
    }
}
