//
//  PhotosLibraryReader.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 18
//
//  Reads a Photos library's own database so Extract (plan 7.6–7.11) can give each photo
//  its REAL name and date. His ask, 2026-09-18: "if the commander can get the metadata and
//  file names from the library while copying or moving would be a bonus."
//
//  WHY THIS IS NEEDED. Inside a .photoslibrary the originals are stored under code names —
//  originals/3/3F2A…-UUID.heic. The name he knows (IMG_4512.HEIC), the date it was taken and
//  everything else live in database/Photos.sqlite. Copying the files alone hands back a
//  folder of UUIDs.
//
//  READ-ONLY, ALWAYS. The database is COPIED to a temporary folder (with its -wal/-shm
//  journal, so recent changes are included) and read there. The library itself is never
//  opened for writing and never touched by SQLite.
//
//  Works on the "originals" layout (Photos 5+, macOS 10.15 and later): table ZASSET, or
//  ZGENERICASSET on 10.15. Older "Masters" libraries are reported as unsupported rather
//  than guessed at.
//

import Foundation
import SQLite3

nonisolated struct PhotosLibraryAsset: Sendable {
    /// The original as stored, e.g. …/originals/3/3F2A…-UUID.heic
    let storedURL: URL
    /// The name he knows, e.g. IMG_4512.HEIC. Falls back to the stored name if missing.
    let realName: String
    /// When it was taken (Photos' own date), used for the extracted file's dates.
    let dateTaken: Date?
    /// A Live Photo's short video, if its original is on disk.
    let livePhotoVideo: URL?
}

nonisolated struct PhotosLibraryContents: Sendable {
    var assets: [PhotosLibraryAsset] = []
    /// In "Recently Deleted" — not extracted.
    var trashed = 0
    /// In the database but the original is not on this drive (iCloud "Optimize Storage").
    var missingOriginals = 0
}

nonisolated enum PhotosLibraryReader {

    struct ReadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A Photos library is a folder holding database/Photos.sqlite and originals/. It may be a
    /// .photoslibrary package or — as with a backup copied out by hand — a plain folder.
    static func isPhotosLibrary(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("database/Photos.sqlite").path)
    }

    static func read(_ library: URL) throws -> PhotosLibraryContents {
        let fm = FileManager.default
        let db = library.appendingPathComponent("database/Photos.sqlite")
        guard fm.fileExists(atPath: db.path) else {
            throw ReadError(message: "“\(library.lastPathComponent)” is not a Photos library — it has no database/Photos.sqlite.")
        }
        guard fm.fileExists(atPath: library.appendingPathComponent("originals").path) else {
            throw ReadError(message: "“\(library.lastPathComponent)” is an older Photos library (before macOS 10.15). Commander can only extract from libraries that keep an “originals” folder.")
        }

        // Copy the database out and read the copy. Never open the library's own file.
        let scratch = fm.temporaryDirectory.appendingPathComponent("ngc-photos-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("Photos.sqlite")
        try fm.copyItem(at: db, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: db.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let h = handle else {
            throw ReadError(message: "The Photos database could not be opened.")
        }
        defer { sqlite3_close(h) }

        var assetTable: String?
        if try tableExists(h, "ZASSET") { assetTable = "ZASSET" }
        else if try tableExists(h, "ZGENERICASSET") { assetTable = "ZGENERICASSET" }
        guard let assetTable else {
            throw ReadError(message: "This Photos database has a layout Commander does not recognise.")
        }
        let assetCols = try columns(h, assetTable)
        for needed in ["Z_PK", "ZDIRECTORY", "ZFILENAME"] where !assetCols.contains(needed) {
            throw ReadError(message: "This Photos database has a layout Commander does not recognise (no \(needed)).")
        }
        var hasAttributes = false
        if try tableExists(h, "ZADDITIONALASSETATTRIBUTES") {
            hasAttributes = try columns(h, "ZADDITIONALASSETATTRIBUTES").isSuperset(of: ["ZASSET", "ZORIGINALFILENAME"])
        }

        let date = assetCols.contains("ZDATECREATED") ? "a.ZDATECREATED" : "NULL"
        let uuid = assetCols.contains("ZUUID") ? "a.ZUUID" : "NULL"
        let trashed = assetCols.contains("ZTRASHEDSTATE") ? "a.ZTRASHEDSTATE" : "0"
        let realName = hasAttributes ? "aa.ZORIGINALFILENAME" : "NULL"
        let join = hasAttributes ? "LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK" : ""
        let sql = "SELECT a.ZDIRECTORY, a.ZFILENAME, \(date), \(uuid), \(trashed), \(realName) FROM \(assetTable) a \(join) ORDER BY \(date)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let st = stmt else {
            throw ReadError(message: "The Photos database could not be read: \(String(cString: sqlite3_errmsg(h))).")
        }
        defer { sqlite3_finalize(st) }

        let originals = library.appendingPathComponent("originals", isDirectory: true)
        var listings: [String: [String]] = [:]
        var result = PhotosLibraryContents()

        while sqlite3_step(st) == SQLITE_ROW {
            guard let dir = text(st, 0), let file = text(st, 1) else { continue }
            if sqlite3_column_int(st, 4) != 0 { result.trashed += 1; continue }

            let folder = originals.appendingPathComponent(dir, isDirectory: true)
            let stored = folder.appendingPathComponent(file)
            guard fm.fileExists(atPath: stored.path) else { result.missingOriginals += 1; continue }

            let taken: Date? = sqlite3_column_type(st, 2) == SQLITE_NULL ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 2))   // Core Data: seconds since 2001
            let name = text(st, 5).flatMap { $0.isEmpty ? nil : $0 } ?? file

            // A Live Photo's video sits beside the still as <UUID>_<n>.mov.
            var video: URL?
            if let id = text(st, 3) ?? Optional((file as NSString).deletingPathExtension) {
                let names = listings[dir] ?? ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                listings[dir] = names
                if let match = names.first(where: { $0 != file && $0.hasPrefix(id) && ($0 as NSString).pathExtension.lowercased() == "mov" }) {
                    video = folder.appendingPathComponent(match)
                }
            }
            result.assets.append(PhotosLibraryAsset(storedURL: stored, realName: name, dateTaken: taken, livePhotoVideo: video))
        }
        return result
    }

    // MARK: - SQLite helpers

    private static func text(_ st: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }

    private static func tableExists(_ h: OpaquePointer, _ name: String) throws -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &st, nil) == SQLITE_OK else {
            throw ReadError(message: "The Photos database could not be read.")
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(st) == SQLITE_ROW
    }

    private static func columns(_ h: OpaquePointer, _ table: String) throws -> Set<String> {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, "PRAGMA table_info(\(table))", -1, &st, nil) == SQLITE_OK else {
            throw ReadError(message: "The Photos database could not be read.")
        }
        defer { sqlite3_finalize(st) }
        var names = Set<String>()
        while sqlite3_step(st) == SQLITE_ROW {
            if let n = text(st!, 1) { names.insert(n) }
        }
        return names
    }
}
