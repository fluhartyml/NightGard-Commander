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

    // The target music library parent directory.
    //
    // Designated by right-clicking a folder in either pane. Consolidation and
    // normalization write here, so it is remembered between launches rather than
    // being re-picked every session. Stored as a plain path: this app is not
    // sandboxed, so no security-scoped bookmark is needed to reopen it.
    // Empty string means nothing has been designated yet.
    /// ⚠️ STORED, not computed over UserDefaults. @Observable only tracks stored
    /// properties, and the badge in the file list has to redraw the moment either
    /// pane, Settings, or the CLI changes this. A computed accessor reads correctly
    /// and notifies nobody, which is the same as not updating at all.
    var musicLibraryPath: String = UserDefaults.standard.string(forKey: "musicLibraryTargetPath") ?? "" {
        didSet {
            UserDefaults.standard.set(musicLibraryPath, forKey: "musicLibraryTargetPath")
        }
    }

    /// True when a target music library has been designated and still exists on disk.
    /// The folder can be on a drive that is currently unmounted, so this is checked
    /// at the point of use rather than cached.
    var musicLibraryIsAvailable: Bool {
        let p = musicLibraryPath
        guard !p.isEmpty else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    // Check if user has configured settings (completed first-run setup)
    var isConfigured: Bool {
        get { UserDefaults.standard.bool(forKey: "shazamIsConfigured") }
        set { UserDefaults.standard.set(newValue, forKey: "shazamIsConfigured") }
    }

    // Check if the filename format includes genre
    var formatUsesGenre: Bool {
        formatBlocks.contains { $0.field == .genres }
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
