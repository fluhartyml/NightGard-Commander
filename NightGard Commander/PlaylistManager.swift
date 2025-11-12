//
//  PlaylistManager.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 12 0840
//

import Foundation
import SwiftUI

@Observable
class PlaylistManager {
    var items: [PlaylistItem] = []

    func addItem(_ fileItem: FileItem) {
        let playlistItem = PlaylistItem(
            name: fileItem.name,
            path: fileItem.path,
            duration: nil // Could extract from AVAsset later
        )
        items.append(playlistItem)
    }

    func removeItem(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func moveItem(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func clear() {
        items.removeAll()
    }

    // MARK: - M3U Export/Import

    func saveToM3U(at url: URL) throws {
        var m3uContent = "#EXTM3U\n"

        for item in items {
            // Add metadata line if duration available
            if let duration = item.duration {
                m3uContent += "#EXTINF:\(Int(duration)),\(item.name)\n"
            } else {
                m3uContent += "#EXTINF:-1,\(item.name)\n"
            }
            // Add file path
            m3uContent += "\(item.path)\n"
        }

        try m3uContent.write(to: url, atomically: true, encoding: .utf8)
    }

    func loadFromM3U(at url: URL) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        items.removeAll()

        var currentName: String?
        var currentDuration: Double?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#EXTINF:") {
                // Parse metadata: #EXTINF:duration,name
                let parts = trimmed.dropFirst(8).components(separatedBy: ",")
                if parts.count >= 2 {
                    currentDuration = Double(parts[0])
                    currentName = parts[1]
                }
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                // This is a file path
                let name = currentName ?? URL(fileURLWithPath: trimmed).lastPathComponent
                let item = PlaylistItem(
                    name: name,
                    path: trimmed,
                    duration: currentDuration
                )
                items.append(item)

                // Reset for next item
                currentName = nil
                currentDuration = nil
            }
        }
    }
}

struct PlaylistItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let duration: Double? // In seconds

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        lhs.id == rhs.id
    }
}
