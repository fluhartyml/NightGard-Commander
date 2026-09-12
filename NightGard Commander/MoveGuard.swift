//
//  MoveGuard.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 11
//
//  ⛔ FILES OWNED BY ANOTHER APP ARE ALWAYS COPIED, NEVER MOVED.
//
//  His instruction, 2026-09-11: "it should have a guardrail to only copy from mail
//  attachments no matter if move is selected or not" — then, immediately after,
//  "same with messages."
//
//  Moving a Mail or Messages attachment out of its store breaks the message that
//  references it, and pulling an original out of a Photos library leaves the
//  database pointing at nothing. None of that shows up at the time; it shows up
//  the next time he opens the message, long past any undo.
//
//  ⚠️ THIS IS A PLAIN ENUM ON PURPOSE. It first lived as a static on the
//  ScanForMediaDialog view, which is @MainActor isolated, and the headless CLI
//  call deadlocked waiting for a main actor that never ran. A safety check has to
//  be callable from anywhere, so it has no actor and no UI dependency.
//

import Foundation

enum MoveGuard {

    /// Packages that own their contents. A media file inside one is tracked by
    /// the owning app's database, not by its path.
    private static let ownedPackageMarkers = [
        ".photoslibrary/",
        ".musiclibrary/",
        ".tvlibrary/",
        ".mbox/",
        ".imovielibrary/",
        ".theater/",
    ]

    /// Directories, relative to home, whose contents belong to another app.
    private static let protectedHomeSubpaths = [
        "Library/Mail",
        "Library/Messages",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Mobile Documents",
    ]

    /// True when this file must be copied even if the user chose Move.
    static func mustCopyNotMove(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path

        for marker in ownedPackageMarkers where path.contains(marker) {
            return true
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for sub in protectedHomeSubpaths {
            let root = home + "/" + sub
            if path == root || path.hasPrefix(root + "/") { return true }
        }

        return false
    }

    /// Short reason for the log and for anything shown to the user.
    static func reason(_ url: URL) -> String? {
        guard mustCopyNotMove(url) else { return nil }
        let path = url.standardizedFileURL.path
        if path.contains(".photoslibrary/") { return "inside a Photos library" }
        if path.contains(".musiclibrary/") || path.contains(".tvlibrary/") { return "inside a Music or TV library" }
        if path.contains(".mbox/") || path.contains("/Library/Mail") { return "a Mail attachment" }
        if path.contains("/Library/Messages") { return "a Messages attachment" }
        return "owned by another app"
    }
}
