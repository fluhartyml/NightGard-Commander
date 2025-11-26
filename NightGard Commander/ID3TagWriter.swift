//
//  ID3TagWriter.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 26
//
//  Writes ID3v2.3 tags to MP3 files (artwork, title, artist, album, etc.)
//

import Foundation

class ID3TagWriter {

    enum ID3Error: Error {
        case fileNotFound
        case invalidMP3
        case writeFailed(String)
    }

    struct Metadata {
        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
        var year: String?
        var trackNumber: Int?
        var artworkData: Data?
        var artworkMimeType: String = "image/jpeg"
    }

    // Write ID3v2.3 tags to an MP3 file
    static func write(metadata: Metadata, to fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ID3Error.fileNotFound
        }

        // Read existing file
        var fileData = try Data(contentsOf: fileURL)

        // Check for existing ID3v2 tag and remove it
        fileData = removeExistingID3v2Tag(from: fileData)

        // Build new ID3v2.3 tag
        let id3Tag = buildID3v2Tag(metadata: metadata)

        // Prepend new tag to file data
        var newFileData = Data()
        newFileData.append(id3Tag)
        newFileData.append(fileData)

        // Write back to file
        try newFileData.write(to: fileURL)

        print("✅ [ID3] Wrote tags to: \(fileURL.lastPathComponent)")
    }

    // Remove existing ID3v2 tag from data
    private static func removeExistingID3v2Tag(from data: Data) -> Data {
        guard data.count > 10 else { return data }

        // Check for ID3v2 header: "ID3"
        let header = data.prefix(3)
        guard header == Data([0x49, 0x44, 0x33]) else {
            return data // No ID3v2 tag
        }

        // Read tag size (syncsafe integer at bytes 6-9)
        let size = syncsafeToInt(
            data[6], data[7], data[8], data[9]
        )

        // Total tag size = 10 (header) + size
        let tagSize = 10 + size

        guard data.count > tagSize else { return data }

        print("🔄 [ID3] Removing existing tag (\(tagSize) bytes)")
        return data.dropFirst(tagSize)
    }

    // Build complete ID3v2.3 tag
    private static func buildID3v2Tag(metadata: Metadata) -> Data {
        var frames = Data()

        // Text frames
        if let title = metadata.title, !title.isEmpty {
            frames.append(buildTextFrame(id: "TIT2", text: title))
        }
        if let artist = metadata.artist, !artist.isEmpty {
            frames.append(buildTextFrame(id: "TPE1", text: artist))
        }
        if let album = metadata.album, !album.isEmpty {
            frames.append(buildTextFrame(id: "TALB", text: album))
        }
        if let genre = metadata.genre, !genre.isEmpty {
            frames.append(buildTextFrame(id: "TCON", text: genre))
        }
        if let year = metadata.year, !year.isEmpty {
            frames.append(buildTextFrame(id: "TYER", text: year))
        }
        if let track = metadata.trackNumber {
            frames.append(buildTextFrame(id: "TRCK", text: "\(track)"))
        }

        // Artwork frame (APIC)
        if let artworkData = metadata.artworkData {
            frames.append(buildArtworkFrame(
                imageData: artworkData,
                mimeType: metadata.artworkMimeType
            ))
        }

        // Build header
        var tag = Data()

        // "ID3"
        tag.append(contentsOf: [0x49, 0x44, 0x33])

        // Version: ID3v2.3.0
        tag.append(contentsOf: [0x03, 0x00])

        // Flags: none
        tag.append(0x00)

        // Size (syncsafe integer)
        let sizeBytes = intToSyncsafe(frames.count)
        tag.append(contentsOf: sizeBytes)

        // Append frames
        tag.append(frames)

        return tag
    }

    // Build a text frame (TIT2, TPE1, TALB, etc.)
    private static func buildTextFrame(id: String, text: String) -> Data {
        var frame = Data()

        // Frame ID (4 bytes)
        frame.append(contentsOf: id.utf8.prefix(4))

        // Frame content: encoding byte + text + null terminator
        var content = Data()
        content.append(0x03) // UTF-8 encoding
        content.append(contentsOf: text.utf8)

        // Size (4 bytes, big-endian, NOT syncsafe for ID3v2.3)
        let size = UInt32(content.count)
        frame.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })

        // Flags (2 bytes)
        frame.append(contentsOf: [0x00, 0x00])

        // Content
        frame.append(content)

        return frame
    }

    // Build artwork frame (APIC)
    private static func buildArtworkFrame(imageData: Data, mimeType: String) -> Data {
        var frame = Data()

        // Frame ID
        frame.append(contentsOf: "APIC".utf8)

        // Build content
        var content = Data()
        content.append(0x00) // ISO-8859-1 encoding for mime type
        content.append(contentsOf: mimeType.utf8)
        content.append(0x00) // Null terminator for mime type
        content.append(0x03) // Picture type: Cover (front)
        content.append(0x00) // Empty description (null terminated)
        content.append(imageData)

        // Size (4 bytes, big-endian)
        let size = UInt32(content.count)
        frame.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })

        // Flags
        frame.append(contentsOf: [0x00, 0x00])

        // Content
        frame.append(content)

        return frame
    }

    // Convert syncsafe bytes to integer
    private static func syncsafeToInt(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Int {
        return (Int(b0) << 21) | (Int(b1) << 14) | (Int(b2) << 7) | Int(b3)
    }

    // Convert integer to syncsafe bytes (4 bytes)
    private static func intToSyncsafe(_ value: Int) -> [UInt8] {
        return [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ]
    }
}
