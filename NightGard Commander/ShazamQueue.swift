//
//  ShazamQueue.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 18 1040
//

import SwiftUI

// Item in the Shazam queue (failed detection)
struct QueuedItem: Identifiable, Codable {
    let id = UUID()
    let filePath: String
    let fileName: String
    var attemptCount: Int = 1
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case filePath, fileName, attemptCount, lastError
    }
}

// Queue manager for unmatched files
@Observable
class ShazamQueue {
    static let shared = ShazamQueue()

    var items: [QueuedItem] = [] {
        didSet {
            saveQueue()
        }
    }

    private init() {
        loadQueue()
    }

    func add(filePath: String, fileName: String, error: String? = nil) {
        // Check if already in queue
        if let index = items.firstIndex(where: { $0.filePath == filePath }) {
            // Increment attempt count
            items[index].attemptCount += 1
            items[index].lastError = error
        } else {
            // Add new item
            let item = QueuedItem(filePath: filePath, fileName: fileName, lastError: error)
            items.append(item)
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

    private func saveQueue() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: "shazamQueue")
        }
    }

    private func loadQueue() {
        if let data = UserDefaults.standard.data(forKey: "shazamQueue"),
           let decoded = try? JSONDecoder().decode([QueuedItem].self, from: data) {
            items = decoded
        }
    }
}
