//
//  ShazamScannedDatabase.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 19 1930
//

import Foundation

/// Metadata stored for each scanned file
struct ShazamStoredMetadata: Codable {
    let artist: String?
    let title: String?
    let album: String?
    let genre: String?
    let year: String?
    let shazamID: String?       // Shazam fingerprint database ID
    let appleMusicID: String?   // iTunes/Apple Music catalog ID
    let scanDate: Date
    let wasRenamed: Bool
    let originalFilename: String
    let currentFilename: String
}

/// Persistent database tracking Shazam results for files
/// Stores full metadata so filenames can be reformatted without re-scanning
class ShazamScannedDatabase {
    static let shared = ShazamScannedDatabase()

    private let legacyKey = "shazamScannedFiles"  // Old format (just paths)
    private let metadataKey = "shazamScannedMetadata"  // New format (full metadata)

    // New: Full metadata storage keyed by original file path
    private var scannedMetadata: [String: ShazamStoredMetadata] = [:]

    // Legacy: Just paths (for backwards compatibility)
    private var scannedFilePaths: Set<String> = []

    private init() {
        loadDatabase()
    }

    /// Check if a file has been scanned before
    func hasBeenScanned(_ filePath: String) -> Bool {
        return scannedMetadata[filePath] != nil || scannedFilePaths.contains(filePath)
    }

    /// Get stored metadata for a file (if available)
    func getMetadata(for filePath: String) -> ShazamStoredMetadata? {
        return scannedMetadata[filePath]
    }

    /// Find metadata by filename (fallback when path doesn't match)
    func findByFilename(_ filename: String) -> ShazamStoredMetadata? {
        // Check currentFilename first (most likely match after rename)
        if let match = scannedMetadata.first(where: { $0.value.currentFilename == filename }) {
            return match.value
        }
        // Check originalFilename
        if let match = scannedMetadata.first(where: { $0.value.originalFilename == filename }) {
            return match.value
        }
        // Check if path ends with filename
        if let match = scannedMetadata.first(where: { $0.key.hasSuffix("/\(filename)") }) {
            return match.value
        }
        return nil
    }

    /// Store full metadata for a scanned file
    func storeMetadata(
        filePath: String,
        artist: String?,
        title: String?,
        album: String?,
        genre: String?,
        year: String?,
        shazamID: String?,
        appleMusicID: String? = nil,
        wasRenamed: Bool,
        originalFilename: String,
        currentFilename: String
    ) {
        let metadata = ShazamStoredMetadata(
            artist: artist,
            title: title,
            album: album,
            genre: genre,
            year: year,
            shazamID: shazamID,
            appleMusicID: appleMusicID,
            scanDate: Date(),
            wasRenamed: wasRenamed,
            originalFilename: originalFilename,
            currentFilename: currentFilename
        )
        scannedMetadata[filePath] = metadata
        scannedFilePaths.insert(filePath)  // Also keep in legacy set
        saveDatabase()
    }

    /// Update just the filename (after reformatting)
    func updateFilename(originalPath: String, newFilename: String, newPath: String) {
        if let metadata = scannedMetadata[originalPath] {
            let updated = ShazamStoredMetadata(
                artist: metadata.artist,
                title: metadata.title,
                album: metadata.album,
                genre: metadata.genre,
                year: metadata.year,
                shazamID: metadata.shazamID,
                appleMusicID: metadata.appleMusicID,
                scanDate: metadata.scanDate,
                wasRenamed: true,
                originalFilename: metadata.originalFilename,
                currentFilename: newFilename
            )
            // Remove old path, add new path
            scannedMetadata.removeValue(forKey: originalPath)
            scannedMetadata[newPath] = updated
            scannedFilePaths.remove(originalPath)
            scannedFilePaths.insert(newPath)
            saveDatabase()
        }
    }

    /// Mark a file as successfully scanned (legacy - for backwards compatibility)
    func markAsScanned(_ filePath: String) {
        scannedFilePaths.insert(filePath)
        saveDatabase()
    }

    /// Remove a file from the database (if user wants to re-scan)
    func removeFromDatabase(_ filePath: String) {
        scannedMetadata.removeValue(forKey: filePath)
        scannedFilePaths.remove(filePath)
        saveDatabase()
    }

    /// Clear entire database
    func clearAll() {
        scannedMetadata.removeAll()
        scannedFilePaths.removeAll()
        saveDatabase()
    }

    /// Get count of scanned files
    func count() -> Int {
        return max(scannedMetadata.count, scannedFilePaths.count)
    }

    /// Get all files with stored metadata (for batch reformatting)
    func getAllMetadata() -> [String: ShazamStoredMetadata] {
        return scannedMetadata
    }

    /// Get files that can be reformatted (have metadata stored)
    func getReformattableFiles() -> [(path: String, metadata: ShazamStoredMetadata)] {
        return scannedMetadata.map { ($0.key, $0.value) }
    }

    /// Get all files that have Apple Music IDs (for iTunes API lookup)
    func getAllWithAppleMusicID() -> [(path: String, metadata: ShazamStoredMetadata)] {
        return scannedMetadata
            .filter { $0.value.appleMusicID != nil && !$0.value.appleMusicID!.isEmpty }
            .map { ($0.key, $0.value) }
    }

    /// Count files with Apple Music IDs
    func countWithAppleMusicID() -> Int {
        return scannedMetadata.filter { $0.value.appleMusicID != nil && !$0.value.appleMusicID!.isEmpty }.count
    }

    private func saveDatabase() {
        // Save legacy paths
        let array = Array(scannedFilePaths)
        UserDefaults.standard.set(array, forKey: legacyKey)

        // Save full metadata
        if let encoded = try? JSONEncoder().encode(scannedMetadata) {
            UserDefaults.standard.set(encoded, forKey: metadataKey)
        }
    }

    private func loadDatabase() {
        // Load legacy paths
        if let array = UserDefaults.standard.array(forKey: legacyKey) as? [String] {
            scannedFilePaths = Set(array)
        }

        // Load full metadata
        if let data = UserDefaults.standard.data(forKey: metadataKey),
           let decoded = try? JSONDecoder().decode([String: ShazamStoredMetadata].self, from: data) {
            scannedMetadata = decoded
        }

        print("📚 [SHAZAM DB] Loaded \(scannedFilePaths.count) scanned files, \(scannedMetadata.count) with full metadata")
    }
}
