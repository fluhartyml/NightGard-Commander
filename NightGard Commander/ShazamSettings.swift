//
//  ShazamSettings.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 18 1035
//

import SwiftUI

// Persistent settings for Shazam operations
@Observable
class ShazamSettings {
    static let shared = ShazamSettings()

    // Format blocks for filename generation
    var formatBlocks: [FormatBlock] {
        get {
            // Load from UserDefaults
            if let data = UserDefaults.standard.data(forKey: "shazamFormatBlocks"),
               let decoded = try? JSONDecoder().decode([FormatBlockCodable].self, from: data) {
                return decoded.map { FormatBlock(field: $0.field) }
            }
            // Default format: Artist - Title - Album
            return [
                FormatBlock(field: .artist),
                FormatBlock(field: .separator),
                FormatBlock(field: .title),
                FormatBlock(field: .separator),
                FormatBlock(field: .albumName)
            ]
        }
        set {
            let codable = newValue.map { FormatBlockCodable(field: $0.field) }
            if let encoded = try? JSONEncoder().encode(codable) {
                UserDefaults.standard.set(encoded, forKey: "shazamFormatBlocks")
            }
        }
    }

    // Auto-rename after successful detection
    var autoRename: Bool {
        get { UserDefaults.standard.bool(forKey: "shazamAutoRename") }
        set { UserDefaults.standard.set(newValue, forKey: "shazamAutoRename") }
    }

    // Add unmatched files to queue
    var queueUnmatched: Bool {
        get {
            // Default true if never set
            if UserDefaults.standard.object(forKey: "shazamQueueUnmatched") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "shazamQueueUnmatched")
        }
        set { UserDefaults.standard.set(newValue, forKey: "shazamQueueUnmatched") }
    }

    // Check if user has configured settings (completed first-run setup)
    var isConfigured: Bool {
        get { UserDefaults.standard.bool(forKey: "shazamIsConfigured") }
        set { UserDefaults.standard.set(newValue, forKey: "shazamIsConfigured") }
    }

    private init() {
        // Set defaults on first launch
        if !isConfigured {
            autoRename = true
            queueUnmatched = true
        }
    }
}

// Codable wrapper for FormatBlock (for UserDefaults persistence)
struct FormatBlockCodable: Codable {
    let field: MetadataField
}

// Extend MetadataField to be Codable
extension MetadataField: Codable {}
