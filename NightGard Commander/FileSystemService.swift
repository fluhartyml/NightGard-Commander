//
//  FileSystemService.swift
//  NightGard Commander
//
//  Created by Claude on 11/10/25.
//

import Foundation

@Observable
class FileSystemService {
    var currentPath: String
    var files: [FileItem] = []
    var errorMessage: String?
    var mountedVolumes: [VolumeItem] = []

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

    func loadFiles() {
        files = []
        errorMessage = nil

        do {
            let url = URL(fileURLWithPath: currentPath)
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )

            files = contents.compactMap { url -> FileItem? in
                guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]) else {
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
                    modificationDate: resourceValues.contentModificationDate ?? Date()
                )
            }.sorted { item1, item2 in
                // Directories first, then alphabetical
                if item1.isDirectory != item2.isDirectory {
                    return item1.isDirectory
                }
                return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
            }

        } catch {
            errorMessage = "Error loading directory '\(currentPath)': \(error.localizedDescription)"
        }
    }

    func navigateToFolder(_ path: String) {
        currentPath = path
        loadFiles()
    }

    func navigateUp() {
        let url = URL(fileURLWithPath: currentPath)
        let parentURL = url.deletingLastPathComponent()
        navigateToFolder(parentURL.path)
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
