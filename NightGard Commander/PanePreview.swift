//
//  PanePreview.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 18
//
//  The preview area in the lower part of each pane — his idea, 2026-09-18: "maybe the
//  lower half of each pane has a preview of the folder contents or image or even the
//  files icon."
//
//  ⭐ A VIDEO SHOWS A STILL, NEVER PLAYS. His words: "i wasnt thinking auto playing video,
//  more like showing the first frame or the title frame used in meta data as a movie
//  poster." Order, engineer's call (plan 4.5):
//    1. the poster artwork embedded in the file's metadata;
//    2. otherwise a frame a few seconds in — the literal first frame is often black.
//  Music shows its embedded album art. Everything else goes through Quick Look, which
//  draws images, PDFs and text and falls back to the file's real icon.
//  A folder shows how many items it holds, their total size, and thumbnails of the first
//  few.
//
//  ⭐ CHEAP ON THE NETWORK (plan 4.8): only metadata and one frame are read, never the
//  whole file, and the work starts when a file is selected and is cancelled the moment the
//  selection moves on.
//

import SwiftUI
import AVFoundation
import QuickLookThumbnailing

struct PanePreview: View {
    let item: FileItem?

    @State private var image: NSImage?
    @State private var caption: String = ""
    @State private var folder: FolderSummary?
    @State private var loading = false

    struct FolderSummary {
        var items: Int
        var files: Int
        var bytes: Int64
        var complete: Bool
        var counting = true
        var thumbs: [(name: String, image: NSImage)]
    }

    var body: some View {
        VStack(spacing: 6) {
            if let item {
                content(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(item.name).font(.caption).bold().lineLimit(1).truncationMode(.middle)
                if !caption.isEmpty {
                    Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Spacer()
                Text("Select a file or folder to preview it").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.05))
        .task(id: item?.path) { await load() }
    }

    @ViewBuilder
    private func content(for item: FileItem) -> some View {
        if let folder {
            folderView(folder)
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 2)
        } else if loading {
            ProgressView().controlSize(.small)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 96, maxHeight: 96)
        }
    }

    private func folderView(_ f: FolderSummary) -> some View {
        VStack(spacing: 8) {
            Text("\(f.items.formatted()) \(f.items == 1 ? "item" : "items")"
                 + " · \(ByteCountFormatter.string(fromByteCount: f.bytes, countStyle: .file))\(f.complete ? "" : "+")"
                 + " in \(f.files.formatted()) \(f.files == 1 ? "file" : "files")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if f.counting {
                Text("Counting…").font(.caption2).foregroundStyle(.secondary)
            } else if !f.complete {
                Text("A large folder — counted for a few seconds, so the total is at least this.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !f.thumbs.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 96), spacing: 8)], spacing: 8) {
                    ForEach(Array(f.thumbs.enumerated()), id: \.offset) { _, t in
                        VStack(spacing: 2) {
                            Image(nsImage: t.image).resizable().aspectRatio(contentMode: .fit).frame(height: 56)
                            Text(t.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Loading

    private static let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]
    private static let audioExts: Set<String> = ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg"]

    private func load() async {
        image = nil
        folder = nil
        caption = ""
        guard let item else { return }
        loading = true
        defer { loading = false }
        let url = URL(fileURLWithPath: item.path)
        let ext = url.pathExtension.lowercased()

        if item.isDirectory && !isPackage(url) {
            await loadFolder(url)
            return
        }
        caption = "\(item.displaySize) · \(item.displayDate)"

        if Self.videoExts.contains(ext) || Self.audioExts.contains(ext) {
            let asset = AVURLAsset(url: url)
            if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
                caption = "\(Self.clock(seconds)) · " + caption
            }
            if let art = await Self.embeddedArtwork(asset) {
                image = art
                return
            }
            if Self.videoExts.contains(ext), let frame = await Self.frameFewSecondsIn(asset) {
                image = frame
                return
            }
        }
        if Task.isCancelled { return }
        image = await Self.quickLook(url, size: CGSize(width: 480, height: 480))
    }

    private func loadFolder(_ url: URL) async {
        let fm = FileManager.default
        let children = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var summary = FolderSummary(items: children.count, files: 0, bytes: 0, complete: false, thumbs: [])
        folder = summary

        for child in children.prefix(12) {
            if Task.isCancelled { return }
            if let thumb = await Self.quickLook(child, size: CGSize(width: 128, height: 128)) {
                summary.thumbs.append((child.lastPathComponent, thumb))
                folder = summary
            }
        }

        // Total size, counted in the background and cut off after a few seconds on a huge
        // or slow folder — the "+" says it is a floor, not the total.
        let counted = await Task.detached(priority: .utility) { Self.countTree(url, seconds: 4) }.value
        if Task.isCancelled { return }
        summary.files = counted.files
        summary.bytes = counted.bytes
        summary.complete = counted.complete
        summary.counting = false
        folder = summary
    }

    /// Files and bytes under a folder, giving up after `seconds` so a huge or slow network
    /// folder never ties the preview up.
    nonisolated static func countTree(_ url: URL, seconds: TimeInterval) -> (files: Int, bytes: Int64, complete: Bool) {
        var files = 0
        var bytes: Int64 = 0
        let started = Date()
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return (0, 0, true)
        }
        while let file = walker.nextObject() as? URL {
            if Date().timeIntervalSince(started) > seconds { return (files, bytes, false) }
            let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true { files += 1; bytes += Int64(v?.fileSize ?? 0) }
        }
        return (files, bytes, true)
    }

    private func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    // MARK: - Sources of a picture

    /// Poster or album art stored in the file's own metadata (MP4 cover, ID3 picture, …).
    nonisolated static func embeddedArtwork(_ asset: AVURLAsset) async -> NSImage? {
        guard let common = try? await asset.load(.commonMetadata) else { return nil }
        let art = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierArtwork)
        for entry in art {
            if let data = try? await entry.load(.dataValue), let image = NSImage(data: data) { return image }
        }
        return nil
    }

    /// One frame a little way in: 10% of the length, at most 3 seconds.
    nonisolated static func frameFewSecondsIn(_ asset: AVURLAsset) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let length = (try? await asset.load(.duration).seconds) ?? 0
        let at = length.isFinite && length > 0 ? min(3, length * 0.1) : 0
        guard let frame = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)) else { return nil }
        // Copy into an ordinary sRGB bitmap. The decoder's own frame can be backed by video
        // memory, and drawing it directly blacked out the whole preview in testing
        // (2026-09-18) while the frame itself was fine.
        let cg = frame.image
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let plain = context.makeImage() else { return nil }
        return NSImage(cgImage: plain, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Quick Look: a real preview where the system has one, the file's icon otherwise.
    nonisolated static func quickLook(_ url: URL, size: CGSize) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2,
                                                   representationTypes: .all)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return rep.nsImage
    }

    nonisolated static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
