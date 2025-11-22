//
//  ShazamScannedDatabase.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 19 1930
//

import Foundation

/// Persistent database tracking which files have been successfully Shazam'd
/// Prevents re-scanning files that have already been processed
class ShazamScannedDatabase {
    static let shared = ShazamScannedDatabase()

    private let key = "shazamScannedFiles"
    private var scannedFilePaths: Set<String> = []

    private init() {
        loadDatabase()
    }

    /// Check if a file has been scanned before
    func hasBeenScanned(_ filePath: String) -> Bool {
        return scannedFilePaths.contains(filePath)
    }

    /// Mark a file as successfully scanned
    func markAsScanned(_ filePath: String) {
        scannedFilePaths.insert(filePath)
        saveDatabase()
    }

    /// Remove a file from the database (if user wants to re-scan)
    func removeFromDatabase(_ filePath: String) {
        scannedFilePaths.remove(filePath)
        saveDatabase()
    }

    /// Clear entire database
    func clearAll() {
        scannedFilePaths.removeAll()
        saveDatabase()
    }

    /// Get count of scanned files
    func count() -> Int {
        return scannedFilePaths.count
    }

    private func saveDatabase() {
        let array = Array(scannedFilePaths)
        UserDefaults.standard.set(array, forKey: key)
    }

    private func loadDatabase() {
        if let array = UserDefaults.standard.array(forKey: key) as? [String] {
            scannedFilePaths = Set(array)
            print("📚 [SHAZAM DB] Loaded \(scannedFilePaths.count) previously scanned files")
        }
    }
}
