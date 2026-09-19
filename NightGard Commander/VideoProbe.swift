//
//  VideoProbe.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 19
//
//  Build 87 — "Video/ then Resolution then Codec". His words, 2026-09-19: "if possible i think
//  sub folders of resolution 780 1080 4K etc and within those resolutions pidgeon hole codexes".
//
//  Reads a video's first picture track — its size and its codec — and names the shelf:
//  "1080p/H.264", "4K/HEVC", … Anything it cannot read (some .mkv and .webm, a damaged file)
//  goes to "Unknown". ⛔ Never a guess: a file whose details cannot be read is not filed as if
//  they had been.
//
//  RESOLUTION IS THE LONG SIDE. A widescreen 1080p film is 1920×800 — its short side would
//  file it as 720p. An upright phone clip (1080×1920) still comes out 1080p.
//

import AVFoundation
import CoreMedia

nonisolated enum VideoProbe {

    /// "<resolution>/<codec>", or "Unknown".
    static func shelf(for url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let formats = try? await track.load(.formatDescriptions),
              let format = formats.first else { return "Unknown" }
        let longSide = Int(max(abs(size.width), abs(size.height)).rounded())
        guard longSide > 0 else { return "Unknown" }
        return "\(resolution(longSide))/\(codec(CMFormatDescriptionGetMediaSubType(format)))"
    }

    /// The usual names, by the long side.
    static func resolution(_ longSide: Int) -> String {
        switch longSide {
        case ...1024: return "SD"
        case ...1280: return "720p"
        case ...1920: return "1080p"
        case ...2560: return "1440p"
        case ...4096: return "4K"
        default: return "8K"
        }
    }

    /// A codec's everyday name from its four-character code. An unfamiliar one keeps its code,
    /// so it still gets a folder of its own rather than being lumped in with another.
    static func codec(_ subtype: FourCharCode) -> String {
        let code = fourCC(subtype)
        switch code.lowercased().trimmingCharacters(in: .whitespaces) {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1", "dvh1", "dvhe": return "HEVC"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco", "aprn", "aprh": return "ProRes"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "vp08": return "VP8"
        case "mp4v": return "MPEG-4"
        case "mp2v", "mx5p", "mx5n", "mx4p", "mx4n", "mx3p", "mx3n", "hdv1", "hdv2", "hdv3", "hdv5", "hdv6", "hdv7", "hdv8", "hdv9", "xdvc": return "MPEG-2"
        case "mp1v": return "MPEG-1"
        case "jpeg", "mjpa", "mjpb", "mjpg": return "Motion JPEG"
        case "dvc", "dvcp", "dvpp", "dv5n", "dv5p", "dvh5", "dvh6", "dvhp", "dvhq": return "DV"
        case "wmv3", "wvc1", "wmv2", "wmv1": return "WMV"
        case "h263", "s263": return "H.263"
        case "svq3", "svq1": return "Sorenson"
        case "cvid": return "Cinepak"
        default:
            // A folder name may not hold "/" or ":" — keep only safe characters.
            let safe = code.filter { $0.isLetter || $0.isNumber }
            return safe.isEmpty ? "Other" : safe.uppercased()
        }
    }

    static func fourCC(_ value: FourCharCode) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "????"
    }
}
