//
//  AudioTags.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 19
//
//  Build 88 — the tag half of "mergge all meta data". Reads an MP3's tags synchronously
//  from its ID3v2 frames, and builds the union of two files' tags for ID3TagWriter.
//
//  ⚠️ Read directly rather than through AVFoundation on purpose: this runs inside the file
//  engine, once per duplicate pair, on thousands of files. Opening an AVAsset for each would
//  cost far more than reading the tag block that has already been located.
//

import Foundation

enum AudioTags {

    /// Every tag an MP3 carries that Commander can write back. Empty fields are nil, never "".
    static func read(_ url: URL) -> ID3TagWriter.Metadata {
        var meta = ID3TagWriter.Metadata()
        guard let frames = try? id3Frames(of: url) else { return meta }
        for (id, payload) in frames {
            switch id {
            case "TIT2", "TT2": meta.title = meta.title ?? text(payload)
            case "TPE1", "TP1": meta.artist = meta.artist ?? text(payload)
            case "TALB", "TAL": meta.album = meta.album ?? text(payload)
            case "TCON", "TCO": meta.genre = meta.genre ?? text(payload)
            case "TYER", "TDRC", "TYE": meta.year = meta.year ?? text(payload)
            case "TRCK", "TRK":
                if meta.trackNumber == nil, let t = text(payload) {
                    meta.trackNumber = Int(t.split(separator: "/").first.map(String.init) ?? t)
                }
            case "APIC", "PIC":
                if meta.artworkData == nil, let art = artwork(payload) {
                    meta.artworkData = art.data
                    meta.artworkMimeType = art.mime
                }
            default:
                break
            }
        }
        return meta
    }

    /// The union: the kept file's own values stand, and every gap is filled from the other.
    /// Returns nil when the other side adds nothing — then the kept file is left untouched,
    /// which matters because writing tags rewrites the whole file.
    static func fillingGaps(in mine: ID3TagWriter.Metadata, from theirs: ID3TagWriter.Metadata) -> ID3TagWriter.Metadata? {
        var merged = mine
        var changed = false
        func fill<T>(_ keep: inout T?, _ other: T?) {
            if keep == nil, let other { keep = other; changed = true }
        }
        fill(&merged.title, theirs.title)
        fill(&merged.artist, theirs.artist)
        fill(&merged.album, theirs.album)
        fill(&merged.genre, theirs.genre)
        fill(&merged.year, theirs.year)
        fill(&merged.trackNumber, theirs.trackNumber)
        if merged.artworkData == nil, let art = theirs.artworkData {
            merged.artworkData = art
            merged.artworkMimeType = theirs.artworkMimeType
            changed = true
        }
        return changed ? merged : nil
    }

    // MARK: - Reading the ID3v2 frames

    /// Frame id → payload, for the ID3v2 tag at the front of the file. Handles v2.2's
    /// three-character ids and v2.3/v2.4's four-character ones.
    private static func id3Frames(of url: URL) throws -> [(String, Data)] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 10), head.count == 10,
              head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 else { return [] }
        let major = head[3]
        let size = Int(syncsafe(head[6], head[7], head[8], head[9]))
        guard size > 0, size < 32 << 20, let body = try handle.read(upToCount: size) else { return [] }

        var frames: [(String, Data)] = []
        var i = 0
        let idLength = major == 2 ? 3 : 4
        let headerLength = major == 2 ? 6 : 10
        while i + headerLength <= body.count {
            let idBytes = body.subdata(in: i ..< i + idLength)
            guard let id = String(data: idBytes, encoding: .isoLatin1), id.first != "\0",
                  id.allSatisfy({ $0.isUppercase || $0.isNumber }) else { break }
            var length = 0
            if major == 2 {
                length = Int(body[i + 3]) << 16 | Int(body[i + 4]) << 8 | Int(body[i + 5])
            } else if major == 4 {
                length = Int(syncsafe(body[i + 4], body[i + 5], body[i + 6], body[i + 7]))
            } else {
                length = Int(body[i + 4]) << 24 | Int(body[i + 5]) << 16 | Int(body[i + 6]) << 8 | Int(body[i + 7])
            }
            let start = i + headerLength
            guard length > 0, start + length <= body.count else { break }
            frames.append((id, body.subdata(in: start ..< start + length)))
            i = start + length
        }
        return frames
    }

    /// A text frame: one encoding byte, then the string. Latin-1, UTF-16 and UTF-8 all appear
    /// in the wild; a frame in an encoding we cannot read is skipped, never guessed at.
    private static func text(_ payload: Data) -> String? {
        guard let encoding = payload.first else { return nil }
        let body = payload.dropFirst()
        guard !body.isEmpty else { return nil }
        let value: String?
        switch encoding {
        case 0: value = String(data: body, encoding: .isoLatin1)
        case 1: value = String(data: body, encoding: .utf16)
        case 2: value = String(data: body, encoding: .utf16BigEndian)
        case 3: value = String(data: body, encoding: .utf8)
        default: value = nil
        }
        let trimmed = value?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// An APIC frame: encoding, MIME type, picture type, description, then the image itself.
    private static func artwork(_ payload: Data) -> (data: Data, mime: String)? {
        guard let encoding = payload.first, payload.count > 4 else { return nil }
        var i = payload.startIndex + 1
        // MIME type, a Latin-1 string ending in NUL ("PNG"/"JPG" in v2.2, where it is 3 bytes).
        var mime = "image/jpeg"
        if payload.count > i + 3, payload[i] != 0, !payload[i...].contains(0) { return nil }
        if let nul = payload[i...].firstIndex(of: 0) {
            if let s = String(data: payload[i ..< nul], encoding: .isoLatin1), !s.isEmpty {
                mime = s.contains("/") ? s : "image/\(s.lowercased())"
            }
            i = nul + 1
        }
        guard i < payload.endIndex else { return nil }
        i += 1                                                   // picture type
        // Description, terminated by NUL (two NULs when the encoding is UTF-16).
        let wide = (encoding == 1 || encoding == 2)
        while i < payload.endIndex {
            if payload[i] == 0 {
                if !wide { i += 1; break }
                if i + 1 < payload.endIndex, payload[i + 1] == 0 { i += 2; break }
            }
            i += 1
        }
        guard i < payload.endIndex else { return nil }
        let image = payload[i...]
        guard image.count > 100 else { return nil }
        return (Data(image), mime)
    }

    private static func syncsafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        (UInt32(a & 0x7F) << 21) | (UInt32(b & 0x7F) << 14) | (UInt32(c & 0x7F) << 7) | UInt32(d & 0x7F)
    }
}
