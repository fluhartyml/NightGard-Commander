//
//  FileOperationController.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 18
//
//  The main-thread side of a copy or move: starts the engine in the background, puts
//  each question in front of Michael and hands his answer back, shows progress, and
//  keeps the summary. One operation at a time.
//

import SwiftUI
import Observation

@MainActor
@Observable
final class FileOperationController: FileOpDelegate {

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
    }

    var presented: Presented?
    var progress: FileOpProgress?
    private(set) var isRunning = false
    private(set) var runningKind: FileOpKind = .copy
    private(set) var isUndo = false

    /// Show a folder in a pane — the summary's "Show" buttons. Set by ContentView.
    var onReveal: ((URL) -> Void)?
    /// Reload the panes after anything changed on disk. Set by ContentView.
    var onDiskChanged: (() -> Void)?

    private var control: FileOpControl?
    private var onFinish: ((FileOpSummary) -> Void)?
    private var folderReply: CheckedContinuation<Answer<FolderChoice>, Never>?
    private var confirmReply: CheckedContinuation<Bool, Never>?
    private var fileReply: CheckedContinuation<Answer<FileChoice>, Never>?
    private var errorReply: CheckedContinuation<ErrorChoice, Never>?
    private var emptyFoldersReply: CheckedContinuation<Bool, Never>?
    private(set) var runningMode: FileOpMode = .standard

    // MARK: - Start

    func start(_ kind: FileOpKind, sources: [URL], target: URL, mode: FileOpMode = .standard,
               onFinish: ((FileOpSummary) -> Void)? = nil) {
        guard !isRunning, !sources.isEmpty else { return }
        let control = FileOpControl()
        let engine = FileOperationEngine(kind: kind, sources: sources, targetDir: target,
                                         control: control, delegate: self, mode: mode)
        runningMode = mode
        begin(kind: kind, undo: false, control: control, onFinish: onFinish) { await engine.run() }
    }

    /// Extract from a Photos library (7.6): asks Copy or Move and the file type first.
    func offerExtract(library: URL, target: URL, onFinish: ((FileOpSummary) -> Void)? = nil) {
        guard !isRunning else { return }
        guard PhotosLibraryReader.isPhotosLibrary(library) else {
            presented = Presented(prompt: .summary(FileOpSummary(kind: .copy, failed: [
                .init(path: library.path, reason: "“\(library.lastPathComponent)” is not a Photos library. Select a .photoslibrary (or a backup of one) in the source pane.")])))
            return
        }
        presented = Presented(prompt: .extractOptions(ExtractRequest(library: library, target: target, onFinish: onFinish)))
    }

    func answerExtract(_ request: ExtractRequest, kind: FileOpKind?, format: ExtractFormat) {
        presented = nil
        guard let kind else { return }
        start(kind, sources: [request.library], target: request.target, mode: .extract(format), onFinish: request.onFinish)
    }

    /// Undo a whole Move from its log.
    func undo(logAt url: URL) {
        guard let log = Self.readLog(url) else { return }
        undo(log)
    }

    private func undo(_ log: OperationLog) {
        guard !isRunning else { return }
        let control = FileOpControl()
        let engine = FileOperationEngine(undoing: log, control: control, delegate: self)
        begin(kind: .move, undo: true, control: control, onFinish: nil) { await engine.run() }
    }

    /// Menu: Undo Last Move… — finds the newest Move that has not been undone and asks first.
    func offerUndoLastMove() {
        guard !isRunning else { return }
        let folder = OperationLog.folder
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let logs = files.filter { $0.pathExtension == "json" }.compactMap(Self.readLog)
            .filter { $0.kind == .move && !$0.undone && $0.entries.contains { if case .moved = $0 { return true }; return false } }
            .sorted { $0.date > $1.date }
        if let newest = logs.first {
            presented = Presented(prompt: .undoLast(newest))
        } else {
            presented = Presented(prompt: .summary(FileOpSummary(kind: .move, notes: [
                .init(path: folder.path, reason: "There is no move left to undo.")])))
        }
    }

    func confirmUndo(_ log: OperationLog, _ go: Bool) {
        presented = nil
        if go { undo(log) }
    }

    private func begin(kind: FileOpKind, undo: Bool, control: FileOpControl,
                       onFinish: ((FileOpSummary) -> Void)?,
                       work: @escaping @Sendable () async -> FileOpSummary) {
        isRunning = true
        isUndo = undo
        runningKind = kind
        self.control = control
        self.onFinish = onFinish
        progress = FileOpProgress()
        Task { [weak self] in
            let summary = await work()
            guard let self else { return }
            self.isRunning = false
            self.runningMode = .standard
            self.progress = nil
            self.control = nil
            self.onDiskChanged?()
            self.onFinish?(summary)
            self.onFinish = nil
            self.presented = Presented(prompt: .summary(summary))
        }
    }

    // MARK: - Pause / cancel

    func togglePause() {
        guard let control else { return }
        control.setPaused(!control.isPaused)
        progress?.isPaused = control.isPaused
    }

    func cancel() {
        control?.cancel()
    }

    // MARK: - FileOpDelegate — the engine asks, Michael answers

    func askFolder(_ question: FolderQuestion) async -> Answer<FolderChoice> {
        await withCheckedContinuation { reply in
            folderReply = reply
            presented = Presented(prompt: .folder(question))
        }
    }

    func confirmReplace(_ question: ReplaceConfirm) async -> Bool {
        await withCheckedContinuation { reply in
            confirmReply = reply
            presented = Presented(prompt: .confirm(question))
        }
    }

    func askFile(_ question: FileQuestion) async -> Answer<FileChoice> {
        await withCheckedContinuation { reply in
            fileReply = reply
            presented = Presented(prompt: .file(question))
        }
    }

    func askError(_ question: ErrorQuestion) async -> ErrorChoice {
        await withCheckedContinuation { reply in
            errorReply = reply
            presented = Presented(prompt: .error(question))
        }
    }

    func askEmptyFolders(_ question: EmptyFoldersQuestion) async -> Bool {
        await withCheckedContinuation { reply in
            emptyFoldersReply = reply
            presented = Presented(prompt: .emptyFolders(question))
        }
    }

    func report(_ progress: FileOpProgress) {
        guard isRunning else { return }
        self.progress = progress
    }

    // MARK: - Answers from the sheets

    func answerFolder(_ choice: FolderChoice, applyToAll: Bool) {
        presented = nil
        folderReply?.resume(returning: Answer(choice: choice, applyToAll: applyToAll))
        folderReply = nil
    }

    func answerConfirm(_ confirmed: Bool) {
        presented = nil
        confirmReply?.resume(returning: confirmed)
        confirmReply = nil
    }

    func answerFile(_ choice: FileChoice, applyToAll: Bool) {
        presented = nil
        fileReply?.resume(returning: Answer(choice: choice, applyToAll: applyToAll))
        fileReply = nil
    }

    func answerError(_ choice: ErrorChoice) {
        presented = nil
        errorReply?.resume(returning: choice)
        errorReply = nil
    }

    func answerEmptyFolders(remove: Bool) {
        presented = nil
        emptyFoldersReply?.resume(returning: remove)
        emptyFoldersReply = nil
    }

    func dismissSummary() {
        presented = nil
    }

    /// A sheet went away without a button — answer Cancel so the engine never hangs.
    func sheetDismissed() {
        // The next question may already be up by the time the old sheet's dismissal
        // lands — never cancel THAT one.
        guard presented == nil else { return }
        if folderReply != nil { answerFolder(.cancel, applyToAll: false) }
        if confirmReply != nil { answerConfirm(false) }
        if fileReply != nil { answerFile(.cancel, applyToAll: false) }
        if errorReply != nil { answerError(.cancel) }
        if emptyFoldersReply != nil { answerEmptyFolders(remove: false) }   // Leave is the default (7.5)
    }

    // MARK: -

    nonisolated static func readLog(_ url: URL) -> OperationLog? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(OperationLog.self, from: data)
    }
}
