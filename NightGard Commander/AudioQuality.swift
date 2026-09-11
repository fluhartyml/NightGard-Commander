//
//  AudioQuality.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 10
//
//  When normalisation produces a name collision, the higher-quality file wins.
//  His requirement, restated 2026-09-10: "nightgard is supposed to keep the
//  higher definition of the two."
//
//  ⚠️ EVERY READ HERE IS ASYNC ON PURPOSE. The synchronous AVAsset properties
//  (tracks, estimatedDataRate, formatDescriptions) were deprecated in macOS 13
//  because they block the calling thread while the asset is parsed. On a file
//  sitting on the array over USB that is a real stall, and this runs once per
//  collision across tens of thousands of files.
//

import Foundation
import AVFoundation

enum AudioQuality {

    /// Comparable quality score for an audio file. Higher is better.
    /// Uses the encoded bit rate first, then sample rate, then file size.
    static func score(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        var bitRate = 0.0
        var sampleRate = 0.0

        // A file that cannot be parsed scores on size alone rather than throwing.
        // An unreadable file is still a real file and still has to lose or win a
        // collision; refusing to score it would leave the caller with no answer.
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            if let rate = try? await track.load(.estimatedDataRate) {
                bitRate = Double(rate)
            }
            if let descs = try? await track.load(.formatDescriptions),
               let cm = descs.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cm)?.pointee {
                sampleRate = asbd.mSampleRate
            }
        }

        // One cast, not two. The previous version cast Int64 to Int64 a second
        // time, which the compiler correctly said does nothing.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = Double(attrs?[.size] as? Int64 ?? 0)

        // Bit rate dominates; sample rate breaks ties; size is the last resort
        // for files whose bit rate cannot be read.
        return bitRate * 1000 + sampleRate + size / 1_000_000
    }

    /// True when `candidate` should replace `existing` at the same filename.
    static func candidateIsBetter(_ candidate: URL, than existing: URL) async -> Bool {
        await score(candidate) > score(existing)
    }

    /// Resolves a name collision by keeping the better file.
    /// Returns true if the caller should proceed with the rename.
    @discardableResult
    static func resolveCollision(incoming: URL, existing: URL) async -> Bool {
        let a = await score(incoming), b = await score(existing)
        if a > b {
            print("🏆 [QUALITY] Incoming wins (\(Int(a)) vs \(Int(b))) — replacing \(existing.lastPathComponent)")
            try? FileManager.default.removeItem(at: existing)
            return true
        } else {
            print("🏆 [QUALITY] Existing wins (\(Int(b)) vs \(Int(a))) — discarding \(incoming.lastPathComponent)")
            try? FileManager.default.removeItem(at: incoming)
            return false
        }
    }
}
