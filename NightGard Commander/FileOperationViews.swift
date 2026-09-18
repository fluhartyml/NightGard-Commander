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

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            card("Incoming", source, other: target)
            card("Already here", target, other: source)
        }
    }

    private func card(_ label: String, _ f: FileFacts, other: FileFacts) -> some View {
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
            SideBySide(source: question.source, target: question.target)
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
            SideBySide(source: question.source, target: question.target)
            Divider()
            if question.unitOnly {
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

// MARK: - Summary

private struct SummaryView: View {
    let summary: FileOpSummary
    let controller: FileOperationController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2).bold()
            Text(headline).font(.title3)
                .fixedSize(horizontal: false, vertical: true)  // it was cut off at "was lef…" (2026-09-18)
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
    let controller: FileOperationController

    var body: some View {
        if let p = controller.progress {
            HStack(spacing: 14) {
                Image(systemName: controller.runningKind == .move ? "arrow.right.doc.on.clipboard" : "doc.on.doc")
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
                Button(p.isPaused ? "Resume" : "Pause") { controller.togglePause() }
                    .disabled(p.phase != .transferring && p.phase != .buildingFolders)
                Button("Cancel") { controller.cancel() }
                    .help("Stops after the current file. Nothing half-copied is left behind.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
        }
    }

    private func line(_ p: FileOpProgress) -> String {
        let verb = controller.isUndo ? "Undoing" : controller.runningKind.gerund
        if controller.presented != nil, p.phase == .checking { return "Waiting for your answer…" }
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
        if controller.runningKind == .move && !controller.isUndo { parts[0] += " (includes reading each copy back to verify it)" }
        if p.bytesPerSecond > 0 { parts.append("\(Fmt.size(Int64(p.bytesPerSecond)))/s") }
        if let s = p.secondsLeft {
            let f = DateComponentsFormatter()
            f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute, .second]
            f.unitsStyle = .abbreviated
            parts.append("\(f.string(from: s) ?? "") left")
        }
        return parts.joined(separator: " · ")
    }
}
