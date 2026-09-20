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

    // MARK: - Open a run's leftovers in a pane (build 101)

    /// Set when he asks for a finished run's skipped or failed files in a Commander pane.
    /// ContentView watches this, loads the listing into a pane and clears it.
    ///
    /// His design, 2026-09-20: *"open a list of them in commander … maybe it id a commander
    /// pane where the user can move them wherer they want to."* The list is what he acts on —
    /// select, Show in Finder, and Move straight into the other pane with the ordinary keys.
    struct PaneListingRequest: Equatable {
        let title: String
        let paths: [String]
        let reasons: [String: String]
    }

    /// Non-nil for exactly as long as it takes ContentView to pick it up.
    var paneListingRequest: PaneListingRequest?

    /// Hand a summary's skipped items to a pane. Failed items travel the same way.
    func showInPane(_ items: [FileOpSummary.Item], titled title: String) {
        guard !items.isEmpty else { return }
        var reasons: [String: String] = [:]
        for item in items { reasons[item.path] = item.reason }
        paneListingRequest = PaneListingRequest(title: title,
                                                paths: items.map(\.path),
                                                reasons: reasons)
    }

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
    /// Build 99 — his choice, 2026-09-19: *"user can choose three parallel or one series"*,
    /// after watching the bars share one network link: *"at the moment im doing one at a time
    /// because the status bar on one moves faster."*
    ///
    /// **He is right about the bar and right to ask.** The link to Cold Storage is the limit,
    /// so bars running together split it — measured at ~3.5 MB/s between three. The total time
    /// is much the same, but one at a time means less contention, fewer part-written files if
    /// he stops, and a bar that visibly moves. → `feedback_progress_must_prove_it_is_alive`
    var runOneAtATime = false
    /// Bars from a scan that have not been started yet, oldest first.
    private var queuedStarts: [(group: UUID, run: () -> Void)] = []
    /// Shown on the bars' footer so a waiting folder is never mistaken for a lost one.
    var queuedCount: Int { queuedStarts.count }

    /// Build 100: how many bars each scan handed out, and how many have finished — so a
    /// summary can say "1 of 3" instead of speaking for the whole scan. Counted in `start`,
    /// where every bar of a scan passes exactly once whether it runs now or waits its turn.
    private var barsPerGroup: [UUID: Int] = [:]
    private var barsFinishedPerGroup: [UUID: Int] = [:]

    func start(_ kind: FileOpKind, sources: [URL], target: URL, mode: FileOpMode = .standard,
               title: String? = nil, group: UUID? = nil, sharedTargets: TargetClaims? = nil,
               onFinish: ((FileOpSummary) -> Void)? = nil) {
        guard !sources.isEmpty else { return }
        // Build 100: count this bar into its scan before it runs or queues, so "1 of 3" is
        // the scan's own figure and not a count of whatever happens to be running.
        if let group { barsPerGroup[group, default: 0] += 1 }
        // One at a time: the first bar of a scan runs, the rest wait their turn.
        if runOneAtATime, let group, jobs.contains(where: { $0.group == group }) || queuedStarts.contains(where: { $0.group == group }) {
            queuedStarts.append((group, { [weak self] in
                self?.startNow(kind, sources: sources, target: target, mode: mode,
                               title: title, group: group, sharedTargets: sharedTargets, onFinish: onFinish)
            }))
            return
        }
        startNow(kind, sources: sources, target: target, mode: mode,
                 title: title, group: group, sharedTargets: sharedTargets, onFinish: onFinish)
    }

    /// Start the next waiting bar, if its scan has none running.
    private func startNextQueued() {
        guard !queuedStarts.isEmpty else { return }
        let running = Set(jobs.compactMap(\.group))
        guard let i = queuedStarts.firstIndex(where: { !running.contains($0.group) }) else { return }
        let next = queuedStarts.remove(at: i)
        next.run()
    }

    /// Nothing from this scan will run: he cancelled it. ⛔ Queued bars must go too, or a
    /// Cancel All would be followed by the next folder starting itself.
    func dropQueued(of group: UUID) {
        let dropped = queuedStarts.filter { $0.group == group }.count
        if dropped > 0 { barsPerGroup[group] = max(0, (barsPerGroup[group] ?? dropped) - dropped) }
        queuedStarts.removeAll { $0.group == group }
    }

    private func startNow(_ kind: FileOpKind, sources: [URL], target: URL, mode: FileOpMode = .standard,
                          title: String? = nil, group: UUID? = nil, sharedTargets: TargetClaims? = nil,
                          onFinish: ((FileOpSummary) -> Void)? = nil) {
        guard !sources.isEmpty else { return }
        let footprint = Self.footprint(sources: sources, target: target, mode: mode)
        if let refusal = refusal(for: footprint, kind: kind, group: group) {
            // A refused bar never runs, so it is not one of the scan's "3" either.
            if let group { barsPerGroup[group] = max(0, (barsPerGroup[group] ?? 1) - 1) }
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

    /// Build 102 — his ask, 2026-09-20: *"the user may have paused all but one status bar and
    /// left, when one bar finishes unattended the next bar closest to the top automatically
    /// unpauses and it auto unpauses until all status bars complete."*
    ///
    /// It turns a pile of bars into a QUEUE he can walk away from: pause all but one, leave,
    /// and they run one after another instead of the run stopping at the first finish line.
    /// "Closest to the top" is `jobs` order, which is the order they are drawn in.
    ///
    /// ⛔ IT ONLY EVER UNDOES A PAUSE HE MADE. A bar the governor paused is left exactly where
    /// it is — the governor stopped it because the machine was in trouble, and resuming it
    /// unattended would overrule the one thing watching the hardware while he is not there.
    /// That is also why this does not use `governorResume()`: the two pauses mean different
    /// things and only one of them is this feature's business.
    ///
    /// ⚠️ It resumes ONE bar per finish, not all of them. The number running therefore stays
    /// what he left it at — if he left two going, two keep going. Releasing the whole queue at
    /// once would hand the network more work than he chose to give it, on his behalf, while
    /// he is asleep.
    private func resumeNextPausedBar() {
        guard let next = jobs.first(where: { $0.pausedByUser && $0.governorPausedFor == nil })
        else { return }
        next.togglePause()
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
            // ⛔ A CANCEL IS NOT A FINISH. Promoting the next bar after he presses Cancel
            // would answer "stop" with "here is the next one" — he is at the keyboard in
            // that moment and the queue is his to restart. The relay is for the bars that
            // ran out of work while nobody was watching. → Commandment VIII
            if !summary.cancelled { self.resumeNextPausedBar() }
            // Build 100: say WHICH bar this is and where it came in. Counted after the job
            // leaves `jobs`, so "still going" is the honest remainder, queued bars included.
            summary.barName = job.title
            if let group = job.group {
                let done = (self.barsFinishedPerGroup[group] ?? 0) + 1
                self.barsFinishedPerGroup[group] = done
                let total = max(self.barsPerGroup[group] ?? done, done)
                summary.barsDone = done
                summary.barsTotal = total
                summary.barsLeft = self.jobs.filter { $0.group == group }.count
                             + self.queuedStarts.filter { $0.group == group }.count
                if summary.barsLeft == 0 {
                    self.barsPerGroup[group] = nil
                    self.barsFinishedPerGroup[group] = nil
                }
            }
            self.onDiskChanged?()
            // Build 99: the next folder of this scan begins as this one ends.
            self.startNextQueued()
            job.onFinish?(summary)
            job.onFinish = nil
            let nothingToSay = job.stoppedBySibling && summary.filesTransferred == 0 && summary.failed.isEmpty
            if !nothingToSay { self.show(.summary(summary), for: nil) }
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
    /// Build 96 — ⛔ **one sheet per window, always.** His report: *"theres a ghost after i
    /// pressed cancel on the first progress bar"* — a large empty panel over the window. A
    /// question or summary was being presented while the Scan for Media sheet already owned
    /// the window, and macOS shows the second one as an empty box: no content, no buttons,
    /// nothing to dismiss it with.
    ///
    /// The scan sheet sets this while it is up, and anything the jobs want to say waits in
    /// the same queue that already holds one bar's question behind another's.
    var anotherSheetIsUp = false {
        didSet { if !anotherSheetIsUp { presentNextIfFree() } }
    }

    func show(_ prompt: Prompt, for job: FileOperationJob?) {
        let p = Presented(prompt: prompt, job: job)
        if current == nil && !anotherSheetIsUp {
            current = p
            presented = p
        } else {
            waiting.append(p)
        }
    }

    /// Put the next queued prompt on screen, if nothing else holds the window.
    private func presentNextIfFree() {
        guard current == nil, !anotherSheetIsUp, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        current = next
        presented = next
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
            self?.presentNextIfFree()
        }
    }

    // MARK: - Answers from the sheets, routed to the job that asked

    /// Build 82: the question on screen came from a bar started by a scan.
    var presentedIsGrouped: Bool { presented?.job?.group != nil }

    /// Build 82 — Cancel on a scan's question is a FULL STOP. His words: "i press cancel once
    /// … and the same popup maybe different content pops up cancel should be full dtop".
    /// Every other bar from the same scan is cancelled first, so its waiting questions leave
    /// the line and never come up; then the asking bar gets its Cancel.
    private func stopSiblings(of job: FileOperationJob?) {
        guard let job, let group = job.group else { return }
        // Build 99: ⛔ a Cancel All must also drop the folders still WAITING their turn, or
        // the next one would start itself the moment this bar ends — "full stop" would not be.
        dropQueued(of: group)
        for other in jobs where other !== job && other.group == group {
            other.stoppedBySibling = true
            other.cancel()
        }
    }

    func answerFolder(_ choice: FolderChoice, applyToAll: Bool) {
        let job = current?.job
        if choice == .cancel { stopSiblings(of: job) }
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
        if case .cancel = choice { stopSiblings(of: job) }
        finishPrompt()
        job?.answerFile(choice, applyToAll: applyToAll)
    }

    func answerError(_ choice: ErrorChoice) {
        let job = current?.job
        if case .cancel = choice { stopSiblings(of: job) }
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
