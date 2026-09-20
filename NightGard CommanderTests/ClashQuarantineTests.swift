//
//  ClashQuarantineTests.swift
//  NightGard CommanderTests
//
//  Build 101. His design, 2026-09-20, after a night of "already in the target" boxes:
//  "not knowing it can save both files or merge because it never asked" and
//  "the list of files skipped could also be diverted to a quarantined finder folder".
//
//  ⚠️ THESE TESTS EXIST BECAUSE THIS CODE DELETES HIS SOURCE FILES. The load-bearing
//  case is not "does it quarantine" — it is "the source is removed ONLY after a verified
//  copy is somewhere else." A test that only counted files would pass while losing a photo.
//

import Testing
import Foundation

private final class SilentDelegate: FileOpDelegate {
    /// ⛔ Every ask fails the test. Build 101's whole point is that a name clash is decided
    /// by his rule, not by asking him again — so if the engine asks ANYTHING here, the
    /// behaviour being tested did not happen.
    nonisolated(unsafe) var asked: [String] = []
    func askFolder(_ q: FolderQuestion) async -> Answer<FolderChoice> { asked.append("folder"); return .init(choice: .skip, applyToAll: true) }
    func confirmReplace(_ q: ReplaceConfirm) async -> Bool { asked.append("replace"); return false }
    func askFile(_ q: FileQuestion) async -> Answer<FileChoice> { asked.append("file"); return .init(choice: .skip, applyToAll: true) }
    func askError(_ q: ErrorQuestion) async -> ErrorChoice { asked.append("error: \(q.message)"); return .skipAll }
    func askEmptyFolders(_ q: EmptyFoldersQuestion) async -> Bool { asked.append("empty"); return false }
    func report(_ p: FileOpProgress) {}
}

private struct Sandbox {
    let root: URL
    var source: URL { root.appendingPathComponent("source") }
    var target: URL { root.appendingPathComponent("target") }

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ngc-clash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }
    func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    var quarantine: URL { target.appendingPathComponent("_Name clashes — needs your attention") }
}

private func runMove(_ box: Sandbox, _ delegate: SilentDelegate) async -> FileOpSummary {
    let engine = await FileOperationEngine(
        kind: .move,
        sources: [box.source.appendingPathComponent("photo.jpg")],
        targetDir: box.target,
        control: FileOpControl(),
        delegate: delegate)
    return await engine.run()
}

@Suite(.serialized)
struct ClashQuarantineTests {

    /// Different contents, same name → parked in the clash folder, and the SOURCE IS GONE
    /// because it travelled. This is the case that used to throw and ask him.
    @Test func differentFileWithTakenNameIsQuarantinedAndLeavesTheSource() async throws {
        let box = try Sandbox(); defer { box.clean() }
        try box.write("the photo he is moving", to: box.source.appendingPathComponent("photo.jpg"))
        try box.write("a DIFFERENT photo already there", to: box.target.appendingPathComponent("photo.jpg"))

        let delegate = SilentDelegate()
        let summary = await runMove(box, delegate)

        #expect(delegate.asked.isEmpty, "a name clash must not ask him anything: \(delegate.asked)")
        #expect(summary.quarantined.count == 1)
        #expect(summary.failed.isEmpty)

        // The file that was already in the target is untouched.
        let sitting = try String(contentsOf: box.target.appendingPathComponent("photo.jpg"), encoding: .utf8)
        #expect(sitting == "a DIFFERENT photo already there")

        // The newcomer is in the clash folder, with its content intact.
        let parked = try FileManager.default.contentsOfDirectory(atPath: box.quarantine.path)
        #expect(parked.count == 1)
        let content = try String(contentsOf: box.quarantine.appendingPathComponent(parked[0]), encoding: .utf8)
        #expect(content == "the photo he is moving", "the quarantined copy must be the real bytes")

        // It was a MOVE, so the source is gone — his "the move is how i keep track".
        #expect(!FileManager.default.fileExists(atPath: box.source.appendingPathComponent("photo.jpg").path))
    }

    /// Identical contents, same name → his merge rule. One copy survives, nothing is parked.
    @Test func identicalFileIsMergedNotQuarantined() async throws {
        let box = try Sandbox(); defer { box.clean() }
        try box.write("same bytes", to: box.source.appendingPathComponent("photo.jpg"))
        try box.write("same bytes", to: box.target.appendingPathComponent("photo.jpg"))

        let delegate = SilentDelegate()
        let summary = await runMove(box, delegate)

        #expect(delegate.asked.isEmpty, "an identical twin must not ask him anything: \(delegate.asked)")
        #expect(summary.quarantined.isEmpty, "identical files are merged, never parked")
        #expect(summary.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: box.quarantine.path),
                "the clash folder must not be created when nothing clashed")

        let sitting = try String(contentsOf: box.target.appendingPathComponent("photo.jpg"), encoding: .utf8)
        #expect(sitting == "same bytes")
        #expect(!FileManager.default.fileExists(atPath: box.source.appendingPathComponent("photo.jpg").path),
                "on a move the source goes, because a verified identical copy is in the target")
    }

    /// ⭐ THE NEGATIVE CONTROL. With no clash at all, nothing is parked and no clash folder
    /// is made. Without this, a bug that quarantined EVERYTHING would pass the tests above.
    @Test func anOrdinaryMoveIsUntouchedByAnyOfThis() async throws {
        let box = try Sandbox(); defer { box.clean() }
        try box.write("just a photo", to: box.source.appendingPathComponent("photo.jpg"))

        let delegate = SilentDelegate()
        let summary = await runMove(box, delegate)

        #expect(delegate.asked.isEmpty)
        #expect(summary.quarantined.isEmpty)
        #expect(summary.quarantineFolder == nil)
        #expect(!FileManager.default.fileExists(atPath: box.quarantine.path))
        let landed = try String(contentsOf: box.target.appendingPathComponent("photo.jpg"), encoding: .utf8)
        #expect(landed == "just a photo")
    }

    /// Two different files both wanting one taken name get DIFFERENT parked names — the
    /// second must not overwrite the first. Commandment VI in a unit test.
    @Test func twoClashesDoNotOverwriteEachOtherInTheClashFolder() async throws {
        let box = try Sandbox(); defer { box.clean() }
        try box.write("already here", to: box.target.appendingPathComponent("photo.jpg"))
        let a = box.source.appendingPathComponent("a/photo.jpg")
        let b = box.source.appendingPathComponent("b/photo.jpg")
        try FileManager.default.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try box.write("first newcomer", to: a)
        try box.write("second newcomer", to: b)

        let delegate = SilentDelegate()
        let engine = await FileOperationEngine(kind: .move, sources: [a, b], targetDir: box.target,
                                               control: FileOpControl(), delegate: delegate,
                                               mode: .flatten)
        let summary = await engine.run()

        #expect(summary.quarantined.count == 2, "both must be kept, under different names")
        let parked = try FileManager.default.contentsOfDirectory(atPath: box.quarantine.path).sorted()
        #expect(parked.count == 2, "the second must not have overwritten the first: \(parked)")
        let bodies = Set(try parked.map {
            try String(contentsOf: box.quarantine.appendingPathComponent($0), encoding: .utf8)
        })
        #expect(bodies == ["first newcomer", "second newcomer"], "both sets of bytes must survive")
    }
}
