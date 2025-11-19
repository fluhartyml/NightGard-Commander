//
//  GenreReviewQueue.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 19 1105
//

import SwiftUI

// Item in the genre review queue (matched but needs genre selection)
struct GenreReviewItem: Identifiable, Codable {
    let id = UUID()
    let filePath: String
    let fileName: String
    let title: String?
    let artist: String?
    let album: String?
    let allGenres: [String]  // All available genres to choose from
    var selectedGenre: String?  // User's choice (nil if not yet reviewed)

    enum CodingKeys: String, CodingKey {
        case filePath, fileName, title, artist, album, allGenres, selectedGenre
    }
}

// Queue manager for files needing genre selection
@Observable
class GenreReviewQueue {
    static let shared = GenreReviewQueue()

    var items: [GenreReviewItem] = [] {
        didSet {
            saveQueue()
        }
    }

    private init() {
        loadQueue()
    }

    func add(result: ShazamResult) {
        // Check if already in queue
        if let index = items.firstIndex(where: { $0.filePath == result.filePath }) {
            // Update existing item with fresh data
            items[index] = GenreReviewItem(
                filePath: result.filePath,
                fileName: result.fileName,
                title: result.title,
                artist: result.artist,
                album: result.album,
                allGenres: result.allGenres,
                selectedGenre: items[index].selectedGenre  // Keep previous selection if any
            )
        } else {
            // Add new item
            let item = GenreReviewItem(
                filePath: result.filePath,
                fileName: result.fileName,
                title: result.title,
                artist: result.artist,
                album: result.album,
                allGenres: result.allGenres,
                selectedGenre: nil
            )
            items.append(item)
        }
    }

    func updateGenre(id: UUID, genre: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            var updatedItem = items[index]
            updatedItem.selectedGenre = genre
            items[index] = updatedItem
        }
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    func removeAll() {
        items.removeAll()
    }

    func count() -> Int {
        return items.count
    }

    func pendingCount() -> Int {
        return items.filter { $0.selectedGenre == nil }.count
    }

    private func saveQueue() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: "genreReviewQueue")
        }
    }

    private func loadQueue() {
        if let data = UserDefaults.standard.data(forKey: "genreReviewQueue"),
           let decoded = try? JSONDecoder().decode([GenreReviewItem].self, from: data) {
            items = decoded
        }
    }
}
