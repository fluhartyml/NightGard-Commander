//
//  FileOperationViews.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 18
//
//  Every question a copy or move can ask, the progress bar, and the summary.
//
//  ⭐ "BE EXPLICIT TO THE USER" — his words for the file popup, 2026-09-18. So every
//  choice carries one plain sentence saying what it will do, the two files are shown side
//  by side with their sizes and dates, and anything that deletes says whether it goes to
//  the Trash or is gone for good.
//
//  ⭐ SOURCE AND TARGET, NEVER LEFT AND RIGHT: the incoming item and the one already here.
//

import SwiftUI

// MARK: - Router

struct FileOperationSheet: View {
    let presented: FileOperationController.Presented
    let controller: FileOperationController

    var body: some View {
        Group {
            switch presented.prompt {
            case .folder(let q): FolderQuestionView(question: q, controller: controller)
            case .confirm(let q): ReplaceConfirmView(question: q, controller: controller)
            case .file(let q): FileQuestionView(question: q, controller: controller)
            case .error(let q): ErrorQuestionView(question: q, controller: controller)
            case .summary(let s): SummaryView(summary: s, controller: controller)
            case .undoLast(let log): UndoLastView(log: log, controller: controller)
            case .emptyFolders(let q): EmptyFoldersView(question: q, controller: controller)
            case .extractOptions(let r): ExtractOptionsView(request: r, controller: controller)
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 700, maxWidth: 820)
        .interactiveDismissDisabled()
    }
}

// MARK: - Shared pieces

private enum Fmt {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    static func exact(_ bytes: Int64) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: bytes), number: .decimal) + " bytes"
    }
    static func date(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
    static func folderName(_ url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent
    }
    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? one : (many ?? one + "s"))"
    }
}

/// One choice: a button with the sentence that says what it does.
private struct ChoiceRow: View {
    let title: String
    let explanation: String
    var role: ButtonRole? = nil
    var isDefault = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Button(role: role, action: action) {
                Text(title).frame(minWidth: 150)
            }
            .controlSize(.large)
            .keyboardShortcut(isDefault ? .defaultAction : nil)
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// The two sides, incoming and already here.
private struct SideBySide: View {
    let source: FileFacts
    let target: FileFacts
    var showDates = true
    /// Plan 6.2 — what each folder holds.
    var sourceTally: FolderTally? = nil
    var targetTally: FolderTally? = nil
    var targetLabel = "Already here"

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            card("Incoming", source, other: target, tally: sourceTally, otherTally: targetTally)
            card(targetLabel, target, other: source, tally: targetTally, otherTally: sourceTally)
        }
    }

    private func card(_ label: String, _ f: FileFacts, other: FileFacts,
                      tally: FolderTally?, otherTally: FolderTally?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path))
                    .resizable().frame(width: 32, height: 32)
                Text(f.name).font(.headline).lineLimit(2)
            }
            Text("in “\(Fmt.folderName(f.url))”").font(.callout).foregroundStyle(.secondary)
            if !f.isDirectory || f.isPackage {
                HStack(spacing: 6) {
                    Text(Fmt.size(f.size))
                    if f.size != other.size && !f.isDirectory {
                        Text(f.size > other.size ? "larger" : "smaller").font(.caption)
                            .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                    }
                }
                if !f.isDirectory && f.size >= 1000 { Text(Fmt.exact(f.size)).font(.caption).foregroundStyle(.secondary) }
            }
            if let tally {
                // Plan 6.2: the complete copy shows at a glance — a date alone cannot say it.
                HStack(spacing: 6) {
                    Text("\(Fmt.plural(tally.items, "item")) · \(Fmt.size(tally.bytes))").bold()
                    if let o = otherTally, o.items != tally.items {
                        Text(tally.items > o.items ? "more" : "fewer").font(.caption)
                            .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                    }
                }
            }
            if showDates {
                HStack(spacing: 6) {
                    Text("Modified \(Fmt.date(f.modified))")
                    if let a = f.modified, let b = other.modified, abs(a.timeIntervalSince(b)) >= 1 {
                        Text(a > b ? "newer" : "older").font(.caption)
                            .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                    }
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CancelRow: View {
    let action: () -> Void
    var body: some View {
        ChoiceRow(title: "Cancel",
                  explanation: "Stop here. Nothing has been changed yet — every question is asked before anything moves.",
                  action: action)
            .keyboardShortcut(.cancelAction)
    }
}

// MARK: - Folder: Merge · Replace · Skip · Cancel

private struct FolderQuestionView: View {
    let question: FolderQuestion
    let controller: FileOperationController
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A folder named “\(question.source.name)” is already in “\(Fmt.folderName(question.target.url))”")
                .font(.title2).bold()
            Text("You are \(question.kind == .move ? "moving" : "copying") a folder into a place that already has a folder with the same name.")
                .foregroundStyle(.secondary)
            SideBySide(source: question.source, target: question.target,
                       sourceTally: question.sourceTally, targetTally: question.targetTally)
            Divider()
            ChoiceRow(title: "Merge",
                      explanation: "Combine the two folders. Anything inside that has the same name gets its own question.",
                      isDefault: true) { controller.answerFolder(.merge, applyToAll: applyToAll) }
            ChoiceRow(title: "Replace…",
                      explanation: "Remove the folder already here, and everything in it, and put the incoming one in its place. You will confirm first, with a count of what goes.",
                      role: .destructive) { controller.answerFolder(.replace, applyToAll: applyToAll) }
            ChoiceRow(title: "Skip",
                      explanation: "Leave both folders as they are. This folder is not \(question.kind.pastTense).") {
                controller.answerFolder(.skip, applyToAll: applyToAll)
            }
            if question.remainingLikeThis > 0 {
                Toggle("Do the same for the \(Fmt.plural(question.remainingLikeThis, "other folder")) that \(question.remainingLikeThis == 1 ? "clashes" : "clash")", isOn: $applyToAll)
            }
            Divider()
            CancelRow { controller.answerFolder(.cancel, applyToAll: false) }
        }
    }
}

// MARK: - The second confirm on Replace (his 5.2)

private struct ReplaceConfirmView: View {
    let question: ReplaceConfirm
    let controller: FileOperationController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2).bold()
            Text("This removes \(Fmt.plural(question.fileCount, "file")) (\(Fmt.size(question.byteCount))) that \(question.fileCount == 1 ? "is" : "are") already there.")
                .font(.title3)
            if question.goesToTrash {
                Label("They go to the Trash, so you can get them back.", systemImage: "trash")
            } else {
                Label("This drive is on the network and has no Trash. They will be deleted immediately. You can't undo this action.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if question.targets.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(question.targets, id: \.self) { Text($0.path).font(.callout.monospaced()) }
                    }
                }
                .frame(maxHeight: 160)
            }
            HStack {
                Spacer()
                Button("Don't Replace") { controller.answerConfirm(false) }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button(question.goesToTrash ? "Replace" : "Replace and Delete", role: .destructive) {
                    controller.answerConfirm(true)
                }
                .controlSize(.large)
            }
        }
    }

    private var title: String {
        if question.targets.count == 1, let t = question.targets.first {
            return "Replace “\(t.lastPathComponent)” in “\(Fmt.folderName(t))”?"
        }
        return "Replace \(question.targets.count) folders?"
    }
}

// MARK: - File: Replace · Skip · Keep Both (+ the two MC choices)

private struct FileQuestionView: View {
    let question: FileQuestion
    let controller: FileOperationController
    @State private var applyToAll = false

    private var goesText: String {
        question.targetGoesToTrash
            ? "The one already here goes to the Trash."
            : "The one already here is deleted immediately — this drive has no Trash."
    }

    private var isNewer: Bool {
        guard let a = question.source.modified, let b = question.target.modified else { return false }
        return a.timeIntervalSince(b) >= 1
    }

    private var keepBothName: String {
        let u = question.source.url
        let ext = u.pathExtension
        let base = ext.isEmpty ? u.lastPathComponent : u.deletingPathExtension().lastPathComponent
        return ext.isEmpty ? "\(base) 2" : "\(base) 2.\(ext)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            SideBySide(source: question.source, target: question.target,
                       targetLabel: question.targetIsIncoming ? "Also incoming" : "Already here")
            Divider()
            if question.flattenOnly {
                flattenChoices
            } else if question.unitOnly {
                unitChoices
            } else if question.isIdentical {
                identicalChoices
            } else {
                differingChoices
            }
            if question.remainingLikeThis > 0 {
                Toggle(applyToAllLabel, isOn: $applyToAll)
            }
            Divider()
            CancelRow { controller.answerFile(.cancel, applyToAll: false) }
        }
    }

    @ViewBuilder private var header: some View {
        if question.flattenOnly {
            Text(question.targetIsIncoming
                 ? "Two files named “\(question.source.name)” are coming into the same folder"
                 : "“\(question.source.name)” is already in “\(Fmt.folderName(question.target.url))”")
                .font(.title2).bold()
            Text("Flattening puts every file in one folder, so files from different folders can share a name. Nothing already there is ever replaced.")
                .foregroundStyle(.secondary)
        } else {
            standardHeader
        }
    }

    /// 7.2 — Flatten offers only these two. His words: "skip or keep both and apply to all".
    @ViewBuilder private var flattenChoices: some View {
        ChoiceRow(title: "Keep Both",
                  explanation: "Bring this one in too, renamed with a number, like “\(keepBothName)”.",
                  isDefault: true) { controller.answerFile(.keepBoth, applyToAll: applyToAll) }
        ChoiceRow(title: "Skip",
                  explanation: question.kind == .move
                    ? "Leave this one where it is, in the source."
                    : "Do not copy this one.") { controller.answerFile(.skip, applyToAll: applyToAll) }
    }

    @ViewBuilder private var standardHeader: some View {
        switch question.sameness {
        case .sameSizeAndDate:
            Text("These two files look identical").font(.title2).bold()
            Text("Same name, same size and the same date. Their contents were not compared.")
                .foregroundStyle(.secondary)
        case .sameContents:
            Text("These two files are identical").font(.title2).bold()
            Text(question.source.modified == question.target.modified
                 ? "Same name, same size and the same contents, compared byte for byte."
                 : "Same name, same size and the same contents, compared byte for byte. Only their dates differ.")
                .foregroundStyle(.secondary)
        case .verifiedEarlier:
            Text("These two files are identical").font(.title2).bold()
            Text("Commander copied or compared this exact pair on an earlier run, and neither file's size or date has changed since, so it was not read again.")
                .foregroundStyle(.secondary)
        case .differs:
            Text("“\(question.source.name)” is already in “\(Fmt.folderName(question.target.url))”")
                .font(.title2).bold()
            if question.unitOnly {
                Text(question.source.isPackage || question.target.isPackage
                     ? "Libraries and packages are handled as one item and are never merged inside — mixing two libraries' files leaves one the app cannot open."
                     : "One is a file and the other is a folder, so they can only replace each other or both be kept.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var differingChoices: some View {
        ChoiceRow(title: "Replace",
                  explanation: "Put the incoming file here. \(goesText)",
                  role: .destructive) { controller.answerFile(.replace, applyToAll: applyToAll) }
        ChoiceRow(title: "Replace if newer",
                  explanation: "Only replaces when the incoming file is dated later than the one already here. For this file: \(isNewer ? "the incoming one is newer, so it would be replaced." : "the one already here is the same age or newer, so it would be kept.")") {
            controller.answerFile(.replaceIfNewer, applyToAll: applyToAll)
        }
        ChoiceRow(title: "Replace if size differs",
                  explanation: "Only replaces when the two files are not the same size. For this file: \(question.source.size != question.target.size ? "the sizes differ, so it would be replaced." : "the sizes match, so it would be kept.")") {
            controller.answerFile(.replaceIfSizeDiffers, applyToAll: applyToAll)
        }
        ChoiceRow(title: "Skip",
                  explanation: "Leave the file already here. The incoming file stays where it is.",
                  isDefault: true) { controller.answerFile(.skip, applyToAll: applyToAll) }
        ChoiceRow(title: "Keep Both",
                  explanation: "Keep both. The incoming file is renamed with a number, like “\(keepBothName)”.") {
            controller.answerFile(.keepBoth, applyToAll: applyToAll)
        }
    }

    @ViewBuilder private var identicalChoices: some View {
        ChoiceRow(title: "Skip",
                  explanation: question.kind == .move
                    ? "Leave both. The incoming copy stays in the source."
                    : "Leave the file already here; nothing is copied.",
                  isDefault: true) { controller.answerFile(.skip, applyToAll: applyToAll) }
        if question.kind == .move {
            ChoiceRow(title: "Remove from source",
                      explanation: "The same file is already here, so remove the duplicate from the source. Every byte is compared first — if they differ at all, nothing is removed.",
                      role: .destructive) { controller.answerFile(.removeFromSource, applyToAll: applyToAll) }
        }
        ChoiceRow(title: "Replace",
                  explanation: "Put the incoming file here anyway. \(goesText)") {
            controller.answerFile(.replace, applyToAll: applyToAll)
        }
        ChoiceRow(title: "Keep Both",
                  explanation: "Keep both. The incoming file is renamed with a number, like “\(keepBothName)”.") {
            controller.answerFile(.keepBoth, applyToAll: applyToAll)
        }
    }

    @ViewBuilder private var unitChoices: some View {
        ChoiceRow(title: "Replace…",
                  explanation: "Remove what is already here and put the incoming one in its place. \(question.target.isDirectory ? "You will confirm first, with a count of what goes." : goesText)",
                  role: .destructive) { controller.answerFile(.replace, applyToAll: applyToAll) }
        ChoiceRow(title: "Skip",
                  explanation: "Leave both as they are.",
                  isDefault: true) { controller.answerFile(.skip, applyToAll: applyToAll) }
        ChoiceRow(title: "Keep Both",
                  explanation: "Keep both. The incoming one is renamed with a number, like “\(keepBothName)”.") {
            controller.answerFile(.keepBoth, applyToAll: applyToAll)
        }
    }

    private var applyToAllLabel: String {
        let n = question.remainingLikeThis
        if question.flattenOnly {
            return "Do the same for the \(Fmt.plural(n, "other file", "other files")) with a name that clashes"
        }
        let what = question.unitOnly ? "other item like this"
            : (question.isIdentical ? "other identical file" : "other file that clashes")
        let base = "Do the same for the \(Fmt.plural(n, what, question.unitOnly ? "other items like this" : (question.isIdentical ? "other identical files" : "other files that clash")))"
        return question.isIdentical || question.unitOnly ? base
            : base + " — Replace if newer / if size differs are still checked file by file"
    }
}

// MARK: - Error: Retry · Skip · Skip All · Cancel

private struct ErrorQuestionView: View {
    let question: ErrorQuestion
    let controller: FileOperationController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .font(.title2).bold()
                .foregroundStyle(.orange)
            Text(question.message).font(.title3).fixedSize(horizontal: false, vertical: true)
            Text(question.path).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            ChoiceRow(title: "Retry", explanation: "Try this item again.", isDefault: true) { controller.answerError(.retry) }
            ChoiceRow(title: "Skip", explanation: "Leave this item where it is and carry on with the rest.") { controller.answerError(.skip) }
            ChoiceRow(title: "Skip All", explanation: "Carry on, and skip anything else that fails without asking. Every skipped item is listed at the end.") { controller.answerError(.skipAll) }
            ChoiceRow(title: "Cancel", explanation: "Stop now. What is already done stays done; nothing half-copied is left behind.") { controller.answerError(.cancel) }
                .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: - 7.5: after a Flatten Move — the emptied folders

private struct EmptyFoldersView: View {
    let question: EmptyFoldersQuestion
    let controller: FileOperationController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The source now has \(Fmt.plural(question.folders.count, "empty folder"))").font(.title2).bold()
            Text("Every file in them was moved into one folder. What should happen to the folders they came from?")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(question.folders.reversed(), id: \.self) { Text($0.path).font(.callout.monospaced()) }
                }
            }
            .frame(maxHeight: 160)
            Divider()
            ChoiceRow(title: "Leave Them",
                      explanation: "Keep the empty folders where they are. Nothing else changes.",
                      isDefault: true) { controller.answerEmptyFolders(remove: false) }
            ChoiceRow(title: "Remove Them",
                      explanation: "Delete these empty folders. Only folders with nothing left in them are listed here; any folder still holding a file stays.") {
                controller.answerEmptyFolders(remove: true)
            }
        }
    }
}

// MARK: - 7.6 / 7.9: Extract from a Photos library — Copy or Move, and the file type

private struct ExtractOptionsView: View {
    let request: FileOperationController.ExtractRequest
    let controller: FileOperationController
    @State private var move = false
    @State private var type = 1         // 0 Original · 1 JPEG · 2 PNG · 3 TIFF — his pick is JPEG
    @State private var quality = 0.9

    private var format: ExtractFormat {
        switch type {
        case 0: return .original
        case 2: return .png
        case 3: return .tiff
        default: return .jpeg(quality: quality)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Extract photos from “\(request.library.lastPathComponent)”").font(.title2).bold()
            Text("Every photo in the library goes into “\(request.target.lastPathComponent)” under the name and date it has in Photos — not the code names the library stores them under. Live Photos bring their short video along beside them.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $move) {
                Text("Copy").tag(false)
                Text("Move").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(move
                 ? "Move takes the originals OUT of the library and leaves it empty of photos. The library will no longer open with its pictures. A library Photos is using right now is always copied instead."
                 : "Copy leaves the library exactly as it was.")
                .foregroundStyle(move ? .red : .secondary).fixedSize(horizontal: false, vertical: true)

            Picker("File type", selection: $type) {
                Text("Original").tag(0)
                Text("JPEG").tag(1)
                Text("PNG").tag(2)
                Text("TIFF").tag(3)
            }
            .pickerStyle(.segmented)
            Text(typeExplanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if type == 1 {
                HStack {
                    Text("Quality")
                    Slider(value: $quality, in: 0.5...1.0, step: 0.05)
                    Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            if move && type != 0 {
                Label("Each original goes to the Trash after its converted copy is checked — or is deleted on a network drive, which has no Trash.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { controller.answerExtract(request, kind: nil, format: format) }
                    .keyboardShortcut(.cancelAction).controlSize(.large)
                Button(move ? "Extract and Move" : "Extract") {
                    controller.answerExtract(request, kind: move ? .move : .copy, format: format)
                }
                .keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
    }

    private var typeExplanation: String {
        switch type {
        case 0: return "Exactly as stored, usually HEIC. Fastest, and nothing is lost."
        case 2: return "Loses no quality, but the files are much larger. Some print shops ask for it."
        case 3: return "Loses no quality; the files are large. The usual choice for print shops."
        default: return "Opens anywhere. HEIC photos are compressed again — invisible at high quality, but not the original. Videos are always kept as they are."
        }
    }
}

// MARK: - Summary

private struct SummaryView: View {
    let summary: FileOpSummary
    let controller: FileOperationController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2).bold()
            Text(headline).font(.title3)
                .fixedSize(horizontal: false, vertical: true)  // it was cut off at "was lef…" (2026-09-18)
            if !summary.wasUndo, !summary.sources.isEmpty, let target = summary.target {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("From").foregroundStyle(.secondary)
                        Text(fromText).textSelection(.enabled)
                            .contextMenu { Button("Show in Finder") { FinderReveal.show(summary.sources) } }
                    }
                    GridRow {
                        Text("To").foregroundStyle(.secondary)
                        Text(Self.readable(target)).textSelection(.enabled)
                            .contextMenu { Button("Show in Finder") { FinderReveal.open(folder: target) } }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if summary.skipped.isEmpty && summary.failed.isEmpty && summary.notes.isEmpty {
                Label("Nothing was skipped and nothing failed.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("Failed", summary.failed, "xmark.octagon.fill", .red)
                    section("Skipped", summary.skipped, "arrow.uturn.right.circle", .orange)
                    section("Good to know", summary.notes, "info.circle", .blue)
                }
            }
            .frame(maxHeight: 320)
            HStack {
                if summary.canUndo, let log = summary.logURL, !summary.wasUndo {
                    Button("Undo This Move") { controller.dismissSummary(); controller.undo(logAt: log) }
                        .help("Puts everything back where it came from, and brings back anything that was replaced from the Trash.")
                        .controlSize(.large)
                }
                Spacer()
                Button("Done") { controller.dismissSummary() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
    }

    /// One item: its own path. Several: the folder they came from and their names.
    private var fromText: String {
        let paths = summary.sources
        if paths.count == 1 { return Self.readable(paths[0]) }
        let parents = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
        if parents.count == 1, let parent = parents.first {
            return "\(Self.readable(parent)) — \(names.count) items: \(shown)"
        }
        return "\(names.count) items: \(shown)"
    }

    /// "Raid_4x4 › Users › michaelfluharty › Wallpapers" — the drive first, the way Finder's
    /// path bar reads, so two folders with the same name on different drives are not confused.
    static func readable(_ path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        if parts.first == "Volumes" { parts.removeFirst() } else { parts.insert("Macintosh HD", at: 0) }
        return parts.joined(separator: " › ")
    }

    private var title: String {
        if summary.wasUndo { return summary.cancelled ? "Undo stopped" : "Undo finished" }
        return summary.cancelled ? "\(summary.kind.verb) cancelled" : "\(summary.kind.verb) finished"
    }

    private var headline: String {
        let what = Fmt.plural(summary.filesTransferred, "item")
        let verb = summary.wasUndo ? "put back" : summary.kind.pastTense
        var line = "\(what) \(verb)"
        if summary.bytesTransferred > 0 { line += " (\(Fmt.size(summary.bytesTransferred)))" }
        if summary.cancelled { line += " before you stopped it. Nothing half-copied was left behind." }
        return line + (summary.cancelled ? "" : ".")
    }

    @ViewBuilder
    private func section(_ name: String, _ items: [FileOpSummary.Item], _ icon: String, _ color: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(name) (\(items.count))", systemImage: icon).font(.headline).foregroundStyle(color)
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((item.path as NSString).lastPathComponent).bold()
                            Text(item.reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Show") {
                            controller.onReveal?(URL(fileURLWithPath: item.path).deletingLastPathComponent())
                        }
                    }
                    .contextMenu { Button("Show in Finder") { FinderReveal.show([item.path]) } }
                }
            }
        }
    }
}

// MARK: - Undo Last Move…

private struct UndoLastView: View {
    let log: OperationLog
    let controller: FileOperationController

    private var movedCount: Int {
        log.entries.filter { if case .moved = $0 { return true }; return false }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Undo the last move?").font(.title2).bold()
            Text("On \(log.date.formatted(date: .abbreviated, time: .shortened)), \(Fmt.plural(movedCount, "item")) moved into “\(URL(fileURLWithPath: log.target).lastPathComponent)”.")
                .font(.title3)
            Text("Everything goes back where it came from, and anything that was replaced comes back out of the Trash. Items replaced on a network drive were deleted and cannot come back.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Don't Undo") { controller.confirmUndo(log, false) }
                    .keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Undo Move") { controller.confirmUndo(log, true) }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
    }
}

// MARK: - Progress bar (sits above the command bar; browsing carries on)

struct FileOperationProgressBar: View {
    /// One bar per running job — several can be running at once (his spec, 2026-09-18).
    let job: FileOperationJob

    var body: some View {
        let p = job.progress
        HStack(spacing: 14) {
            Image(systemName: job.kind == .move ? "arrow.right.doc.on.clipboard" : "doc.on.doc")
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(line(p)).lineLimit(1).truncationMode(.middle)
                if p.phase == .transferring {
                    ProgressView(value: p.fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if p.phase == .transferring, p.folderCount > 0 {
                    Text(folderLine(p)).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                if p.phase == .transferring, p.bytesTotal > 0 || p.secondsLeft != nil {
                    Text(detail(p)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(p.isPaused ? "Resume" : "Pause") { job.togglePause() }
                .disabled(p.phase != .transferring && p.phase != .buildingFolders)
            Button("Cancel") { job.cancel() }
                .help("Stops this one after the current file. Nothing half-copied is left behind. Any other copy or move carries on.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .contextMenu {
            if !job.sources.isEmpty {
                Button(job.sources.count == 1 ? "Show What Is Being \(job.kind == .move ? "Moved" : "Copied") in Finder"
                                              : "Show the \(job.sources.count) Items Being \(job.kind == .move ? "Moved" : "Copied") in Finder") {
                    FinderReveal.show(job.sources.map(\.path))
                }
            }
            if let target = job.target {
                Button("Show Where It Is Going in Finder") { FinderReveal.open(folder: target.path) }
            }
        }
    }

    private func line(_ p: FileOpProgress) -> String {
        let verb: String
        switch job.mode {
        case .flatten: verb = job.kind == .move ? "Flattening (moving)" : "Flattening (copying)"
        case .media: verb = job.kind == .move ? "Sorting media (moving)" : "Sorting media (copying)"
        case .extract: verb = job.kind == .move ? "Extracting (moving)" : "Extracting"
        case .standard: verb = job.isUndo ? "Undoing" : job.kind.gerund
        }
        if job.isWaitingForAnswer { return "Waiting for your answer…" }
        switch p.phase {
        case .checking:
            return "Checking before anything moves… \(p.itemsChecked.formatted()) items looked at"
        case .buildingFolders:
            return "Making the folders first — \(p.foldersMade.formatted()) of \(p.foldersToMake.formatted()) — \(p.currentName)"
        case .transferring:
            if p.isPaused { return "Paused — \(p.filesDone.formatted()) of \(p.filesTotal.formatted()) done" }
            return "\(verb) \(min(p.filesDone + 1, p.filesTotal).formatted()) of \(p.filesTotal.formatted()) — \(p.currentName)"
        case .finishing:
            return "Finishing…"
        }
    }

    /// Plan 8.4: where it is, by folder — "Folder 12 of 340 — 2025 SEP 02 Photos/2019 — file 88 of 412".
    private func folderLine(_ p: FileOpProgress) -> String {
        "Folder \(p.folderIndex.formatted()) of \(p.folderCount.formatted()) — \(p.folderName) — file \(p.fileInFolder.formatted()) of \(p.filesInFolder.formatted())"
    }

    private func detail(_ p: FileOpProgress) -> String {
        var parts = ["\(Fmt.size(p.bytesDone)) of \(Fmt.size(p.bytesTotal))"]
        if job.kind == .move && !job.isUndo { parts[0] += " (includes reading each copy back to verify it)" }
        if p.bytesPerSecond > 0 { parts.append("\(Fmt.size(Int64(p.bytesPerSecond)))/s") }
        if let raw = p.secondsLeft {
            // Rounded, so it reads as the estimate it is: 5-minute steps past an hour,
            // whole minutes under an hour, "under a minute" at the end.
            let f = DateComponentsFormatter()
            f.unitsStyle = .abbreviated
            if raw >= 3600 {
                f.allowedUnits = [.day, .hour, .minute]
                parts.append("about \(f.string(from: (raw / 300).rounded() * 300) ?? "") left")
            } else if raw >= 60 {
                f.allowedUnits = [.minute]
                parts.append("about \(f.string(from: (raw / 60).rounded() * 60) ?? "") left")
            } else {
                parts.append("under a minute left")
            }
        } else if p.filesDone > 0 && p.filesDone < p.filesTotal {
            // No large file timed yet — a guess here was 357 hours for a two-hour job.
            parts.append("estimating time left…")
        }
        return parts.joined(separator: " · ")
    }
}
