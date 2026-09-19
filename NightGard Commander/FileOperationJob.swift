//
//  FileOperationJob.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 18
//
//  ONE copy or move: its engine, its progress bar, its Pause and Cancel, and the question
//  it is waiting on. Several can run at once from the same two panes — his words:
//  "i want to be able to manipulate more folders between using the same two panes without
//  leaving them on the same two disk locations" · "if it would open a new moving or copying
//  bar in parallel would be best".
//
//  Every question still goes through FileOperationController, which shows them ONE AT A
//  TIME in the order they were asked, so two jobs never talk over each other.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class FileOperationJob: Identifiable, FileOpDelegate {

    let id = UUID()
    let kind: FileOpKind
    let mode: FileOpMode
    let isUndo: Bool
    /// Every place this job reads from or writes to. A second job whose footprint overlaps
    /// this one is refused rather than raced — two jobs must never touch the same item.
    let footprint: [URL]
    /// What it is working on and where to — for "Show in Finder" on its bar.
    var sources: [URL] = []
    var target: URL?
    /// The folder a Scan for Media bar is working on ("Music", "Backup") — build 76, one
    /// bar per top-level folder. Nil for an ordinary copy or move.
    var title: String?
    /// Bars started together from one scan share a group. They write into the same
    /// shelves on purpose, so they are not refused as overlapping EACH OTHER — the name
    /// registry they share keeps them apart instead. Anything else still is.
    var group: UUID?
    /// Build 82: stopped by Cancel All on a sibling's question. If it moved nothing and hit
    /// nothing, its own summary is not shown — he already said stop.
    var stoppedBySibling = false

    // MARK: Governor state — build 76, his spec 2026-09-18
    /// He pressed Pause. ⛔ The governor never resumes a pause HE made.
    private(set) var pausedByUser = false
    /// The conditions the governor paused this bar for. Nil when it did not.
    private(set) var governorPausedFor: [JobGovernor.Condition]?
    /// Conditions he chose to run through anyway — "the user can override and resumw at
    /// their own rish". The governor does not pause this bar again for the same ones.
    @ObservationIgnored private(set) var overridden = Set<String>()

    private(set) var progress = FileOpProgress()
    /// True while one of this job's questions is on screen or waiting its turn.
    private(set) var isWaitingForAnswer = false

    @ObservationIgnored let control = FileOpControl()
    @ObservationIgnored weak var owner: FileOperationController?
    @ObservationIgnored var onFinish: ((FileOpSummary) -> Void)?

    @ObservationIgnored private var folderReply: CheckedContinuation<Answer<FolderChoice>, Never>?
    @ObservationIgnored private var confirmReply: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var fileReply: CheckedContinuation<Answer<FileChoice>, Never>?
    @ObservationIgnored private var errorReply: CheckedContinuation<ErrorChoice, Never>?
    @ObservationIgnored private var emptyFoldersReply: CheckedContinuation<Bool, Never>?

    init(kind: FileOpKind, mode: FileOpMode, isUndo: Bool, footprint: [URL]) {
        self.kind = kind
        self.mode = mode
        self.isUndo = isUndo
        self.footprint = footprint
    }

    // MARK: - Pause / cancel (this job only)

    /// His button. On a bar the governor paused it is "Resume at Your Own Risk": it runs,
    /// and the governor leaves it alone for the conditions it was paused for.
    func togglePause() {
        if let reasons = governorPausedFor {
            overridden.formUnion(reasons.map(\.key))
            governorPausedFor = nil
            pausedByUser = false
            setPaused(false)
        } else if control.isPaused {
            pausedByUser = false
            setPaused(false)
        } else {
            pausedByUser = true
            setPaused(true)
        }
    }

    /// The governor's pause — only ever on a bar that is running and not already paused.
    func governorPause(for conditions: [JobGovernor.Condition]) {
        guard !pausedByUser, !control.isCancelled else { return }
        governorPausedFor = conditions
        setPaused(true)
    }

    /// The governor's resume — only of a pause the governor made.
    func governorResume() {
        guard governorPausedFor != nil, !pausedByUser else { return }
        governorPausedFor = nil
        setPaused(false)
    }

    private func setPaused(_ value: Bool) {
        control.setPaused(value)
        progress.isPaused = value
    }

    /// Stops after the current file. A question it was waiting on is answered Cancel, and
    /// one still waiting its turn is taken out of the line — the other jobs carry on.
    func cancel() {
        control.cancel()
        owner?.withdrawQuestions(of: self)
        answerPendingSafely()
    }

    // MARK: - FileOpDelegate — the engine asks; the controller puts it on screen in turn

    func askFolder(_ question: FolderQuestion) async -> Answer<FolderChoice> {
        await withCheckedContinuation { reply in
            folderReply = reply
            ask(.folder(question))
        }
    }

    func confirmReplace(_ question: ReplaceConfirm) async -> Bool {
        await withCheckedContinuation { reply in
            confirmReply = reply
            ask(.confirm(question))
        }
    }

    func askFile(_ question: FileQuestion) async -> Answer<FileChoice> {
        await withCheckedContinuation { reply in
            fileReply = reply
            ask(.file(question))
        }
    }

    func askError(_ question: ErrorQuestion) async -> ErrorChoice {
        await withCheckedContinuation { reply in
            errorReply = reply
            ask(.error(question))
        }
    }

    func askEmptyFolders(_ question: EmptyFoldersQuestion) async -> Bool {
        await withCheckedContinuation { reply in
            emptyFoldersReply = reply
            ask(.emptyFolders(question))
        }
    }

    func report(_ progress: FileOpProgress) {
        var p = progress
        p.isPaused = control.isPaused
        self.progress = p
    }

    private func ask(_ prompt: FileOperationController.Prompt) {
        isWaitingForAnswer = true
        guard let owner, !control.isCancelled else {
            answerPendingSafely()
            return
        }
        owner.show(prompt, for: self)
    }

    // MARK: - Answers, routed here by the controller

    func answerFolder(_ choice: FolderChoice, applyToAll: Bool) {
        isWaitingForAnswer = false
        folderReply?.resume(returning: Answer(choice: choice, applyToAll: applyToAll))
        folderReply = nil
    }

    func answerConfirm(_ confirmed: Bool) {
        isWaitingForAnswer = false
        confirmReply?.resume(returning: confirmed)
        confirmReply = nil
    }

    func answerFile(_ choice: FileChoice, applyToAll: Bool) {
        isWaitingForAnswer = false
        fileReply?.resume(returning: Answer(choice: choice, applyToAll: applyToAll))
        fileReply = nil
    }

    func answerError(_ choice: ErrorChoice) {
        isWaitingForAnswer = false
        errorReply?.resume(returning: choice)
        errorReply = nil
    }

    func answerEmptyFolders(remove: Bool) {
        isWaitingForAnswer = false
        emptyFoldersReply?.resume(returning: remove)
        emptyFoldersReply = nil
    }

    /// The question went away without a button (or the job was cancelled): answer it the
    /// safe way so the engine never hangs — Cancel, and Leave for the emptied folders (7.5).
    func answerPendingSafely() {
        if folderReply != nil { answerFolder(.cancel, applyToAll: false) }
        if confirmReply != nil { answerConfirm(false) }
        if fileReply != nil { answerFile(.cancel, applyToAll: false) }
        if errorReply != nil { answerError(.cancel) }
        if emptyFoldersReply != nil { answerEmptyFolders(remove: false) }
        isWaitingForAnswer = false
    }
}
