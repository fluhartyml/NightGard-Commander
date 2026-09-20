//
//  DuplicateSweepDialog.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 19
//
//  Build 92 — Operations › Find Duplicate Media… (⌥⌘7)
//
//  His ask: *"they are different names but are the exact same image"*. A clash popup only ever
//  sees two files headed for the SAME NAME; this finds the copies whose names differ.
//
//  ⛔ It never deletes anything on its own. The scan is read-only, it shows what it found and
//  WHICH copy it would keep, and the removal goes through the ordinary Delete job — Trash on an
//  attached drive, a bar with Pause and Cancel, and an entry in the operation log so Undo works.
//

import SwiftUI

struct DuplicateSweepDialog: View {
    let folder: FileItem
    let fileOps: FileOperationController?
    let onComplete: () -> Void
    @Binding var isPresented: Bool

    @State private var finder = DuplicateFinder()
    @State private var phase: Phase = .scanning
    @State private var mediaOnly = true
    @State private var started = false

    private enum Phase { case scanning, review }

    private var mediaLibraryPath: String { ShazamSettings.shared.musicLibraryPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find Duplicate Media").font(.title2).bold()
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Looks for files with the **same contents** in “\(folder.name)”, whatever they are named. Files of different sizes are never read — only same-size files are compared, byte for byte.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if phase == .scanning {
                scanning
            } else {
                review
            }

            Divider()
            HStack {
                Button(phase == .scanning ? "Cancel" : "Close") {
                    finder.cancel()
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if phase == .review && finder.duplicateCount > 0 {
                    Button("Move \(finder.duplicateCount) Duplicate\(finder.duplicateCount == 1 ? "" : "s") to the Trash") {
                        sweep()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 620)
        .task {
            guard !started else { return }
            started = true
            await finder.scan(roots: [URL(fileURLWithPath: folder.path)],
                              preferInside: mediaLibraryPath.isEmpty ? nil : URL(fileURLWithPath: mediaLibraryPath),
                              extensions: mediaOnly ? Self.mediaExtensions : Set<String>())
            phase = .review
        }
    }

    // MARK: - While it reads

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView().controlSize(.small)
            Text("\(finder.checkedCount) files looked at · \(finder.comparedCount) compared")
                .font(.subheadline)
            if !finder.currentPath.isEmpty {
                Text(finder.currentPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
    }

    // MARK: - What it found

    private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            if finder.groups.isEmpty {
                Text("No duplicates found.").font(.headline)
                Text("\(finder.checkedCount) files were looked at. Every file in here is one of a kind, by contents.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(finder.groups.count) set\(finder.groups.count == 1 ? "" : "s") of duplicates · \(finder.duplicateCount) extra cop\(finder.duplicateCount == 1 ? "y" : "ies") · \(Self.bytes(finder.wastedBytes)) to reclaim")
                    .font(.headline)
                Text("The copy kept is the one already inside your media folder; failing that, the one nearest the top of the tree, then the oldest. The rest go to the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !finder.unreadable.isEmpty {
                Text("⚠️ \(finder.unreadable.count) file\(finder.unreadable.count == 1 ? " was" : "s were") unreadable and left alone — they are not counted as duplicates.")
                    .font(.caption).foregroundStyle(.orange)
            }

            List(finder.groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.keep.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text("kept").font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.15)).clipShape(Capsule())
                        Spacer()
                        Text(Self.bytes(group.size)).font(.caption).foregroundStyle(.secondary)
                        Button("Show in Finder") { FinderReveal.show([group.keep.path]) }
                            .controlSize(.small)
                    }
                    Text(group.keep.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    ForEach(group.duplicates, id: \.self) { dup in
                        HStack(spacing: 6) {
                            Text("→ \(dup.lastPathComponent)").font(.caption)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Show in Finder") { FinderReveal.show([dup.path]) }
                                .controlSize(.small)
                        }
                        Text("   in \(dup.deletingLastPathComponent().path)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func sweep() {
        let doomed = finder.groups.flatMap(\.duplicates)
        guard !doomed.isEmpty, let fileOps else { return }
        isPresented = false
        fileOps.delete(doomed) { _ in onComplete() }
    }

    /// Every audio, video and photo extension build 86 knows about.
    private static let mediaExtensions: Set<String> =
        MediaScanner.audioExtensions
            .union(MediaScanner.videoExtensions)
            .union(MediaScanner.photoExtensions)

    private static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: n)
    }
}
