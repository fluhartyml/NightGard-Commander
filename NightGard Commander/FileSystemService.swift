//
//  FileSystemService.swift
//  NightGard Commander
//
//  Created by Claude on 11/10/25.
//

import Foundation

enum FileSortMethod: String, CaseIterable {
    case none = "No Sort"
    case name = "Name"
    case dateModified = "Date Modified"
    case dateCreated = "Date Created"
    case size = "Size"

    var icon: String {
        switch self {
        case .none: return "line.3.horizontal"
        case .name: return "textformat.abc"
        case .dateModified: return "clock"
        case .dateCreated: return "calendar"
        case .size: return "chart.bar"
        }
    }
}

@Observable
class FileSystemService {
    var currentPath: String
    var files: [FileItem] = []
    var errorMessage: String?
    var mountedVolumes: [VolumeItem] = []
    var lastVisitedFolder: String? = nil // Track folder we came from for scroll restoration
    var sortMethod: FileSortMethod = .none

    // MARK: - Virtual listing (build 101)

    /// A pane showing a SET of files that do NOT share a folder — the skipped list from a
    /// run. His design, 2026-09-20, after a night of "already in the target" prompts:
    /// *"open a list of them in commander where you can show what iformation you know, why it
    /// was skipped and a view in finder for each file … maybe it id a commander pane where the
    /// user can move them wherer they want to."*
    ///
    /// ⭐ **Move needed no change for this.** `moveToOtherPane` builds its sources from each
    /// selected item's own absolute path, not from the pane's folder, so a listing whose items
    /// live in a hundred different folders moves correctly as it stands. That is why this is a
    /// listing and not a folder of symlinks — nothing is written to disk to make it work.
    struct VirtualListing: Equatable {
        var title: String
        /// Source of truth. `files` is rebuilt from these, so anything he moves away simply
        /// leaves the list on the next refresh.
        var paths: [String]
        /// path → why it was skipped, shown under the name.
        var reasons: [String: String] = [:]
    }

    /// Non-nil while this pane is showing a listing instead of a folder.
    var virtualListing: VirtualListing?

    /// Show a set of files in this pane. Navigating anywhere returns it to an ordinary folder.
    func showVirtualListing(title: String, paths: [String], reasons: [String: String] = [:]) {
        virtualListing = VirtualListing(title: title, paths: paths, reasons: reasons)
        loadFiles()
    }

    /// Why a given row is in the list — nil for an ordinary folder.
    func listingReason(for path: String) -> String? { virtualListing?.reasons[path] }

    /// Rebuild `files` from the listing's paths, dropping anything that is no longer there.
    /// **A file he has moved away disappears from the list, which is the whole point** — the
    /// list shrinks as he deals with it, and an empty list means he is done.
    private func loadVirtualFiles() {
        guard let listing = virtualListing else { return }
        errorMessage = nil
        files = listing.paths.compactMap { path -> FileItem? in
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
            let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
            return FileItem(name: url.lastPathComponent,
                            path: path,
                            isDirectory: isDir.boolValue,
                            size: rv?.fileSize ?? 0,
                            modificationDate: rv?.contentModificationDate ?? Date(),
                            creationDate: rv?.creationDate ?? Date())
        }
    }

    private let fileManager = FileManager.default

    init(startPath: String = NSHomeDirectory()) {
        self.currentPath = startPath
        loadMountedVolumes()
        loadFiles()
    }

    func loadMountedVolumes() {
        guard let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) else {
            mountedVolumes = []
            return
        }

        mountedVolumes = urls.compactMap { url in
            let volumeName = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
            return VolumeItem(name: volumeName, path: url.path)
        }
    }

    var breadcrumbs: [BreadcrumbItem] {
        let components = currentPath.split(separator: "/").map(String.init)
        var breadcrumbs: [BreadcrumbItem] = [BreadcrumbItem(name: "/", path: "/")]

        var buildPath = ""
        for component in components {
            buildPath += "/" + component
            breadcrumbs.append(BreadcrumbItem(name: component, path: buildPath))
        }

        return breadcrumbs
    }

    func loadChildren(for folderPath: String) -> [FileItem] {
        do {
            let url = URL(fileURLWithPath: folderPath)
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )

            return contents.compactMap { url -> FileItem? in
                guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey]) else {
                    return nil
                }

                var targetIsDir: ObjCBool = false
                let actualIsDirectory = fileManager.fileExists(atPath: url.path, isDirectory: &targetIsDir) && targetIsDir.boolValue

                return FileItem(
                    name: url.lastPathComponent,
                    path: url.path,
                    isDirectory: actualIsDirectory,
                    size: resourceValues.fileSize ?? 0,
                    modificationDate: resourceValues.contentModificationDate ?? Date(),
                    creationDate: resourceValues.creationDate ?? Date()
                )
            }.sorted { item1, item2 in
                if item1.isDirectory != item2.isDirectory {
                    return item1.isDirectory
                }
                return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
            }
        } catch {
            return []
        }
    }

    func loadFiles() {
        // Build 101: a listing is not a folder — rebuild it from its own paths instead.
        if virtualListing != nil { loadVirtualFiles(); return }
        files = []
        errorMessage = nil

        do {
            let url = URL(fileURLWithPath: currentPath)
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )

            files = contents.compactMap { url -> FileItem? in
                guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey]) else {
                    return nil
                }

                // Check if it's a directory (handles both regular directories and symlinks to directories)
                var targetIsDir: ObjCBool = false
                let actualIsDirectory = fileManager.fileExists(atPath: url.path, isDirectory: &targetIsDir) && targetIsDir.boolValue

                return FileItem(
                    name: url.lastPathComponent,
                    path: url.path,
                    isDirectory: actualIsDirectory,
                    size: resourceValues.fileSize ?? 0,
                    modificationDate: resourceValues.contentModificationDate ?? Date(),
                    creationDate: resourceValues.creationDate ?? Date()
                )
            }.sorted { item1, item2 in
                // Directories first
                if item1.isDirectory != item2.isDirectory {
                    return item1.isDirectory
                }

                // Then sort by selected method
                switch sortMethod {
                case .none:
                    return false  // Keep filesystem order
                case .name:
                    return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
                case .dateModified:
                    return item1.modificationDate > item2.modificationDate
                case .dateCreated:
                    return item1.creationDate > item2.creationDate
                case .size:
                    return item1.size > item2.size
                }
            }

        } catch {
            // If we can't access the directory, fall back to home directory
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            if currentPath != homeDir {
                currentPath = homeDir
                loadFiles()  // Retry with home directory
            } else {
                errorMessage = "Error loading directory '\(currentPath)': \(error.localizedDescription)"
            }
        }
    }

    /// Directories first, then the pane's chosen order — the same order `loadFiles` uses.
    private func sortedItems(_ items: [FileItem]) -> [FileItem] {
        items.sorted { item1, item2 in
            if item1.isDirectory != item2.isDirectory {
                return item1.isDirectory
            }
            switch sortMethod {
            case .none:
                return false  // Keep filesystem order
            case .name:
                return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
            case .dateModified:
                return item1.modificationDate > item2.modificationDate
            case .dateCreated:
                return item1.creationDate > item2.creationDate
            case .size:
                return item1.size > item2.size
            }
        }
    }

    // MARK: - Refresh in place — the pane follows a copy or move as it happens

    /// One entry as read off the disk, before it becomes a FileItem on the main thread.
    nonisolated struct Listed: Sendable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int
        let modificationDate: Date
        let creationDate: Date
    }

    @ObservationIgnored private var isRefreshing = false

    /// Re-read the folder WITHOUT disturbing the pane. His report, 2026-09-18: a pane kept
    /// listing 731 files a running Move had already taken, and the preview showed a blank
    /// page for a photo that was no longer there.
    /// - Read off the main thread, so a network drive cannot stall the window.
    /// - An unchanged file keeps its FileItem — and so its ID, so the selection survives.
    /// - Nothing changed → nothing is touched, so the list does not flicker.
    /// - The folder itself is gone (a Move took it) → step up to the nearest folder that
    ///   still exists, instead of jumping all the way home the way `loadFiles` does.
    func refreshInPlace() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let path = currentPath
        Task { @MainActor in
            let listed = await Task.detached(priority: .utility) { Self.readListing(path) }.value
            isRefreshing = false
            guard path == currentPath else { return }   // he moved on while it was reading
            guard let listed else {
                var up = URL(fileURLWithPath: path)
                while up.path != "/" && !FileManager.default.fileExists(atPath: up.path) {
                    up = up.deletingLastPathComponent()
                }
                navigateToFolder(up.path)
                return
            }
            let old = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let fresh = sortedItems(listed.map { l in
                if let o = old[l.path], o.isDirectory == l.isDirectory, o.size == l.size,
                   o.modificationDate == l.modificationDate {
                    return o
                }
                return FileItem(name: l.name, path: l.path, isDirectory: l.isDirectory, size: l.size,
                                modificationDate: l.modificationDate, creationDate: l.creationDate)
            })
            if fresh.map(\.id) != files.map(\.id) {
                files = fresh
            }
        }
    }

    /// The same listing `loadFiles` makes (hidden files skipped, links to folders count as
    /// folders), or nil when the folder cannot be read.
    nonisolated static func readListing(_ path: String) -> [Listed]? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey]
        guard let contents = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                         includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles]) else { return nil }
        return contents.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            var isDir: ObjCBool = false
            let dir = fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            return Listed(name: url.lastPathComponent, path: url.path, isDirectory: dir,
                          size: v.fileSize ?? 0,
                          modificationDate: v.contentModificationDate ?? Date(),
                          creationDate: v.creationDate ?? Date())
        }
    }

    func navigateToFolder(_ path: String) {
        // Remember current folder name before navigating
        lastVisitedFolder = URL(fileURLWithPath: currentPath).lastPathComponent
        virtualListing = nil   // build 101: going to a folder leaves the listing behind
        currentPath = path
        loadFiles()
    }

    func navigateUp() {
        // Build 101: Up out of a listing goes back to the folder the pane was in, not to the
        // listing's parent — a listing has no parent.
        if virtualListing != nil {
            virtualListing = nil
            loadFiles()
            return
        }
        let url = URL(fileURLWithPath: currentPath)
        // Remember which folder we're leaving
        lastVisitedFolder = url.lastPathComponent
        let parentURL = url.deletingLastPathComponent()
        currentPath = parentURL.path
        loadFiles()
    }

    func createFolder(name: String) throws {
        let url = URL(fileURLWithPath: currentPath).appendingPathComponent(name)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        loadFiles()
    }

    func createFile(name: String) throws {
        let fileURL = URL(fileURLWithPath: currentPath).appendingPathComponent(name)
        fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        loadFiles()
    }

    func deleteItem(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        try fileManager.removeItem(at: url)
        loadFiles()
    }

    func canNavigateUp() -> Bool {
        return currentPath != "/"
    }
}

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int
    let modificationDate: Date
    let creationDate: Date

    var displaySize: String {
        if isDirectory {
            return "--"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    var displayDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: modificationDate)
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }
}

struct VolumeItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
}

struct BreadcrumbItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
}
