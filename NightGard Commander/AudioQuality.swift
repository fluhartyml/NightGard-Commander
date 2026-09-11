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

import Foundation
import AVFoundation

enum AudioQuality {

    /// Comparable quality score for an audio file. Higher is better.
    /// Uses the encoded bit rate first, then sample rate, then file size.
    static func score(_ url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        var bitRate = 0.0
        var sampleRate = 0.0
        if let track = asset.tracks(withMediaType: .audio).first {
            bitRate = Double(track.estimatedDataRate)
            if let desc = track.formatDescriptions.first {
                let cm = desc as! CMAudioFormatDescription
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cm)?.pointee {
                    sampleRate = asbd.mSampleRate
                }
            }
        }
        let size = Double((try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) as? Int64 ?? 0)
        // Bit rate dominates; sample rate breaks ties; size is the last resort
        // for files whose bit rate cannot be read.
        return bitRate * 1000 + sampleRate + size / 1_000_000
    }

    /// True when `candidate` should replace `existing` at the same filename.
    static func candidateIsBetter(_ candidate: URL, than existing: URL) -> Bool {
        score(candidate) > score(existing)
    }

    /// Resolves a name collision by keeping the better file.
    /// Returns true if the caller should proceed with the rename.
    @discardableResult
    static func resolveCollision(incoming: URL, existing: URL) -> Bool {
        let a = score(incoming), b = score(existing)
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
