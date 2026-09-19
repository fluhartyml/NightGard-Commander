//
//  AudioContentCompare.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 19
//
//  Build 88 — his words, on a pair of MP3s 1,124 bytes apart: "the larger one probably has
//  meta data" · "it becomes, mergge all meta data".
//
//  Two songs ripped from the same CD, tagged twice, are the SAME MUSIC in two files that are
//  not byte-identical: one carries artwork or a longer comment, the other does not. Build 81
//  greyed Merge out for them, because Merge means "identical, so nothing can be lost" — and
//  by bytes they are not identical.
//
//  This compares the AUDIO ONLY, skipping the tag blocks at each end of the file. When the
//  audio matches, Merge is offered: the LARGER file is kept (it is the one carrying the extra
//  metadata) and the other file's tags are folded into it, so no metadata is lost either way.
//
//  ⚠️ MP3 ONLY, and deliberately so. In an MP4 container (.m4a, .m4p) the tags are atoms
//  interleaved with the audio, so "skip the tag block" has no meaning; those pairs keep the
//  byte-for-byte rule.
//

import Foundation

enum AudioContentCompare {

    /// The byte range holding the audio frames: the file with its ID3v2 header, ID3v1 footer
    /// and APE tag removed. Nil for anything that is not an MP3 we can read.
    struct AudioRange {
        var offset: UInt64
        var length: UInt64
    }

    static func isMP3(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mp3"
    }

    /// Both files are MP3s whose audio frames are identical, while the files themselves are
    /// not. Returns false for anything it cannot read — never a guess.
    static func sameAudio(_ a: URL, _ b: URL) async throws -> Bool {
        guard isMP3(a), isMP3(b),
              let ra = try audioRange(of: a), let rb = try audioRange(of: b),
              ra.length > 0, ra.length == rb.length else { return false }
        return try await equalRanges(a, ra, b, rb)
    }

    /// Where the audio starts and ends inside an MP3.
    ///
    /// • **ID3v2** sits at the front: `ID3` + version + flags + a four-byte SYNCHSAFE size
    ///   (seven bits per byte), and a 10-byte footer when the footer flag is set.
    /// • **ID3v1** is the last 128 bytes when they begin `TAG`.
    /// • **APE** ends the file with a 32-byte footer beginning `APETAGEX`, preceded by the
    ///   tag body, and may carry its own header on top of that.
    static func audioRange(of url: URL) throws -> AudioRange? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = try handle.seekToEnd()
        guard total > 128 else { return nil }

        var start: UInt64 = 0
        try handle.seek(toOffset: 0)
        if let head = try handle.read(upToCount: 10), head.count == 10,
           head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 {           // "ID3"
            let flags = head[5]
            let size = syncsafe(head[6], head[7], head[8], head[9])
            start = 10 + UInt64(size)
            if flags & 0x10 != 0 { start += 10 }                          // footer present
        }
        guard start < total else { return nil }

        var end = total
        // ID3v1: the last 128 bytes, beginning "TAG".
        if end >= start + 128 {
            try handle.seek(toOffset: end - 128)
            if let tail = try handle.read(upToCount: 3), tail == Data("TAG".utf8) { end -= 128 }
        }
        // APE: a 32-byte footer beginning "APETAGEX"; bytes 12..15 are the tag size, which
        // includes the footer itself. A header of another 32 bytes may sit above it.
        if end >= start + 32 {
            try handle.seek(toOffset: end - 32)
            if let foot = try handle.read(upToCount: 32), foot.count == 32,
               foot.prefix(8) == Data("APETAGEX".utf8) {
                let size = UInt64(littleEndian32(foot, at: 12))
                let flags = littleEndian32(foot, at: 20)
                var drop = size
                if flags & 0x8000_0000 != 0 { drop += 32 }                // header present too
                if end >= start + drop { end -= drop }
            }
        }
        guard end > start else { return nil }
        return AudioRange(offset: start, length: end - start)
    }

    // MARK: - The comparison itself

    private static func equalRanges(_ a: URL, _ ra: AudioRange, _ b: URL, _ rb: AudioRange) async throws -> Bool {
        let fa = open(a.path, O_RDONLY), fb = open(b.path, O_RDONLY)
        defer { if fa >= 0 { close(fa) }; if fb >= 0 { close(fb) } }
        guard fa >= 0, fb >= 0 else { return false }
        guard lseek(fa, off_t(ra.offset), SEEK_SET) >= 0,
              lseek(fb, off_t(rb.offset), SEEK_SET) >= 0 else { return false }

        let chunk = 1 << 20
        let ba = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        let bb = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { ba.deallocate(); bb.deallocate() }

        var left = ra.length
        while left > 0 {
            let want = Int(min(UInt64(chunk), left))
            let na = readFully(fa, ba, want), nb = readFully(fb, bb, want)
            if na != want || nb != want { return false }
            if memcmp(ba, bb, want) != 0 { return false }
            left -= UInt64(want)
            await Task.yield()
        }
        return true
    }

    private static func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var total = 0
        while total < count {
            let n = read(fd, buffer + total, count - total)
            if n < 0 { if errno == EINTR { continue }; return -1 }
            if n == 0 { break }
            total += n
        }
        return total
    }

    private static func syncsafe(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        (UInt32(a & 0x7F) << 21) | (UInt32(b & 0x7F) << 14) | (UInt32(c & 0x7F) << 7) | UInt32(d & 0x7F)
    }

    private static func littleEndian32(_ data: Data, at index: Int) -> UInt32 {
        let i = data.startIndex + index
        return UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
    }
}
