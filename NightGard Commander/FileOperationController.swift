//
//  FileOperationController.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 18
//
//  The main-thread side of copies and moves: starts each one as a FileOperationJob, puts
//  their questions in front of Michael ONE AT A TIME in the order they were asked, routes
//  each answer back to the job that asked, and keeps the summaries.
//
//  ⭐ SEVERAL AT ONCE, FROM THE SAME TWO PANES — his spec, 2026-09-18 18:1x:
//  "if it would open a new moving or copying bar in parallel would be best". A second window
//  (⌘N) was ruled out: "command n is not realistic ( not intuitive)". So Copy and Move stay
//  enabled while something runs, and each job gets its own bar.
//  ⛔ Two jobs never touch the same item: one whose sources or destinations overlap a
//  running job's is refused with a plain sentence, never raced.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class FileOperationController {

    /// What is on screen as a sheet. Every question WAITS for an answer — dismissing it
    /// any other way is treated as Cancel, never as a silent default.
    enum Prompt {
        case folder(FolderQuestion)
        case confirm(ReplaceConfirm)
        case file(FileQuestion)
        case error(ErrorQuestion)
        case summary(FileOpSummary)
        case undoLast(OperationLog)
        /// 7.5 — after a Flatten Move: leave or remove the emptied source folders.
        case emptyFolders(EmptyFoldersQuestion)
        /// 7.6 / 7.9 — before an Extract: Copy or Move, and which file type.
        case extractOptions(ExtractRequest)
    }

    /// What Extract was pointed at, waiting for his choices.
    struct ExtractRequest {
        let library: URL
        let target: URL
        let onFinish: ((FileOpSummary) -> Void)?
    }

    struct Presented: Identifiable {
        let id = UUID()
        let prompt: Prompt
        /// The job that asked, when it is a question. Nil for summaries and the other
        /// prompts that belong to no running job.
        let job: FileOperationJob?
    }

    /// The prompt on screen. Set to nil by the sheet when it goes away.
    var presented: Presented?
    /// Every copy or move still running, oldest first — one progress bar each.
    private(set) var jobs: [FileOperationJob] = []
    var isRunning: Bool { !jobs.isEmpty }
    /// Pauses bars while the Mac is unstable and resumes them one at a time (build 76).
    let governor = JobGovernor()

    init() {
        governor.controller = self
    }

    /// Show a folder in a pane — the summary's "Show" buttons. Set by ContentView.
    var onReveal: ((URL) -> Void)?
    /// Reload the panes after anything changed on disk. Set by ContentView.
    var onDiskChanged: (() -> Void)?

    /// The prompt that is on screen and not yet answered. Kept apart from `presented`
    /// because the sheet clears `presented` itself when it is dismissed.
    @ObservationIgnored private var current: Presented?
    /// Prompts waiting their turn behind the one on screen, oldest first.
    @ObservationIgnored private var waiting: [Presented] = []

    // MARK: - Start

    /// `title`, `group` and `sharedTargets` are for bars started together from one scan
    /// (build 76): each is named after its folder, and they share one name registry.
    func start(_ kind: FileOpKind, sources: [URL], target: URL, mode: FileOpMode = .standard,
               title: String? = nil, group: UUID? = nil, sharedTargets: TargetClaims? = nil,
               onFinish: ((FileOpSummary) -> Void)? = nil) {
        guard !sources.isEmpty else { return }
        let footprint = Self.footprint(sources: sources, target: target, mode: mode)
        if let refusal = refusal(for: footprint, kind: kind, group: group) {
            show(.summary(refusal), for: nil)
            return
        }
        let job = FileOperationJob(kind: kind, mode: mode, isUndo: false, footprint: footprint)
        job.title = title
        job.group = group
        let engine = FileOperationEngine(kind: kind, sources: sources, targetDir: target,
                                         control: job.control, delegate: job, mode: mode,
                                         sharedTargets: sharedTargets)
        begin(job, sources: sources, target: target, onFinish: onFinish) { await engine.run() }
    }

    /// Delete as a job (build 70): Trash on a drive attached to this Mac, permanent on a
    /// network drive. Off the main thread, one bar, Pause and Cancel like the others.
    func delete(_ items: [URL], onFinish: ((FileOpSummary) -> Void)? = nil) {
        guard !items.isEmpty else { return }
        if let refusal = refusal(for: items, kind: .delete) {
            show(.summary(refusal), for: nil)
            return
        }
        let job = FileOperationJob(kind: .delete, mode: .standard, isUndo: false, footprint: items)
        let parent = items[0].deletingLastPathComponent()
        let engine = FileOperationEngine(kind: .delete, sources: items, targetDir: parent,
                                         control: job.control, delegate: job)
        begin(job, sources: items, target: nil, onFinish: onFinish) { await engine.run() }
    }

    /// Extract from a Photos library (7.6): asks Copy or Move and the file type first.
    func offerExtract(library: URL, target: URL, onFinish: ((FileOpSummary) -> Void)? = nil) {
        guard PhotosLibraryReader.isPhotosLibrary(library) else {
            show(.summary(FileOpSummary(kind: .copy, failed: [
                .init(path: library.path, reason: "“\(library.lastPathComponent)” is not a Photos library. Select a .photoslibrary (or a backup of one) in the source pane.")])), for: nil)
            return
        }
        show(.extractOptions(ExtractRequest(library: library, target: target, onFinish: onFinish)), for: nil)
    }

    func answerExtract(_ request: ExtractRequest, kind: FileOpKind?, format: ExtractFormat) {
        finishPrompt()
        guard let kind else { return }
        start(kind, sources: [request.library], target: request.target, mode: .extract(format), onFinish: request.onFinish)
    }

    /// Undo a whole Move from its log. Waits for every running job to finish first: an
    /// undo puts files back all over the place, and nothing else may be touching them.
    func undo(logAt url: URL) {
        guard let log = Self.readLog(url) else { return }
        undo(log)
    }

    private func undo(_ log: OperationLog) {
        guard !isRunning else {
            show(.summary(FileOpSummary(kind: .move, notes: [
                .init(path: OperationLog.folder.path, reason: "An undo waits until every copy and move has finished. Try it again when the progress bars are gone.")])), for: nil)
            return
        }
        let job = FileOperationJob(kind: .move, mode: .standard, isUndo: true, footprint: [URL(fileURLWithPath: "/")])
        let engine = FileOperationEngine(undoing: log, control: job.control, delegate: job)
        begin(job, sources: [], target: nil, onFinish: nil) { await engine.run() }
    }

    /// Menu: Undo Last Move… — finds the newest Move that has not been undone and asks first.
    func offerUndoLastMove() {
        let folder = OperationLog.folder
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let logs = files.filter { $0.pathExtension == "json" }.compactMap(Self.readLog)
            .filter { $0.kind == .move && !$0.undone && $0.entries.contains { if case .moved = $0 { return true }; return false } }
            .sorted { $0.date > $1.date }
        if let newest = logs.first {
            show(.undoLast(newest), for: nil)
        } else {
            show(.summary(FileOpSummary(kind: .move, notes: [
                .init(path: folder.path, reason: "There is no move left to undo.")])), for: nil)
        }
    }

    func confirmUndo(_ log: OperationLog, _ go: Bool) {
        finishPrompt()
        if go { undo(log) }
    }

    private func begin(_ job: FileOperationJob, sources: [URL], target: URL?,
                       onFinish: ((FileOpSummary) -> Void)?,
                       work: @escaping @Sendable () async -> FileOpSummary) {
        job.owner = self
        job.onFinish = onFinish
        job.sources = sources
        job.target = target
        jobs.append(job)
        governor.startIfNeeded()
        Task { [weak self] in
            var summary = await work()
            guard let self else { return }
            if summary.sources.isEmpty, let target {
                summary.sources = sources.map(\.path)
                summary.target = target.path
            }
            self.withdrawQuestions(of: job)
            self.jobs.removeAll { $0 === job }
            self.onDiskChanged?()
            job.onFinish?(summary)
            job.onFinish = nil
            self.show(.summary(summary), for: nil)
        }
    }

    // MARK: - Two jobs must never touch the same item

    /// Where a job reads and writes: each source, and where each source lands. Flatten and
    /// Extract pour into the target folder itself, so the whole target is theirs.
    nonisolated static func footprint(sources: [URL], target: URL, mode: FileOpMode) -> [URL] {
        var out = sources
        switch mode {
        case .standard:
            out += sources.map { target.appendingPathComponent($0.lastPathComponent) }
        case .flatten, .extract, .media:
            out.append(target)
        }
        return out
    }

    /// True when one path is the other, or lies inside it. Compared without regard to case,
    /// because Mac drives usually ignore it — refusing a harmless pair beats racing a real one.
    nonisolated static func overlaps(_ a: URL, _ b: URL) -> Bool {
        func key(_ u: URL) -> String {
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            return p.hasSuffix("/") ? p : p + "/"
        }
        let ka = key(a), kb = key(b)
        return ka.hasPrefix(kb) || kb.hasPrefix(ka)
    }

    private func refusal(for footprint: [URL], kind: FileOpKind, group: UUID? = nil) -> FileOpSummary? {
        for job in jobs where group == nil || job.group != group {
            for mine in footprint {
                if let theirs = job.footprint.first(where: { Self.overlaps(mine, $0) }) {
                    let busy = theirs.path == "/" ? "an undo" : "“\(theirs.lastPathComponent)”"
                    return FileOpSummary(kind: kind, failed: [
                        .init(path: mine.path, reason: "Not started: another \(job.isUndo ? "undo" : job.kind.verb.lowercased()) is already working on \(busy). Start this one after that bar is gone.")])
                }
            }
        }
        return nil
    }

    // MARK: - One prompt on screen at a time

    /// Put a prompt on screen, or in line behind the one already there.
    func show(_ prompt: Prompt, for job: FileOperationJob?) {
        let p = Presented(prompt: prompt, job: job)
        if current == nil {
            current = p
            presented = p
        } else {
            waiting.append(p)
        }
    }

    /// A cancelled or finished job's questions leave the line; the others keep their places.
    func withdrawQuestions(of job: FileOperationJob) {
        waiting.removeAll { $0.job === job }
        if let c = current, c.job === job {
            finishPrompt()
        }
    }

    /// The prompt on screen is done with. The next one comes up on the next turn, so the
    /// sheet has a moment to close before it reopens.
    private func finishPrompt() {
        current = nil
        presented = nil
        guard !waiting.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self, self.current == nil, !self.waiting.isEmpty else { return }
            let next = self.waiting.removeFirst()
            self.current = next
            self.presented = next
        }
    }

    // MARK: - Answers from the sheets, routed to the job that asked

    func answerFolder(_ choice: FolderChoice, applyToAll: Bool) {
        let job = current?.job
        finishPrompt()
        job?.answerFolder(choice, applyToAll: applyToAll)
    }

    func answerConfirm(_ confirmed: Bool) {
        let job = current?.job
        finishPrompt()
        job?.answerConfirm(confirmed)
    }

    func answerFile(_ choice: FileChoice, applyToAll: Bool) {
        let job = current?.job
        finishPrompt()
        job?.answerFile(choice, applyToAll: applyToAll)
    }

    func answerError(_ choice: ErrorChoice) {
        let job = current?.job
        finishPrompt()
        job?.answerError(choice)
    }

    func answerEmptyFolders(remove: Bool) {
        let job = current?.job
        finishPrompt()
        job?.answerEmptyFolders(remove: remove)
    }

    func dismissSummary() {
        finishPrompt()
    }

    /// A sheet went away without a button — answer that job's question the safe way so its
    /// engine never hangs, then bring up whatever is waiting.
    func sheetDismissed() {
        // The next prompt may already be up by the time the old sheet's dismissal lands —
        // never cancel THAT one.
        guard presented == nil, let c = current else { return }
        finishPrompt()
        c.job?.answerPendingSafely()
    }

    // MARK: -

    nonisolated static func readLog(_ url: URL) -> OperationLog? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(OperationLog.self, from: data)
    }
}
