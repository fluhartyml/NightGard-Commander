//
//  MoveGuard.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 11
//
//  ⛔ FILES OWNED BY A LIVE APP ARE ALWAYS COPIED, NEVER MOVED.
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
//  ⭐ LIVE LIBRARIES ONLY — his ruling, 2026-09-18: "only live libraries, backups are
//  just folders." Until then this guarded ANY path containing ".photoslibrary/", so a
//  backup copy of a library on the Raid could not be moved either. Now a library is
//  guarded only when an app is actually using it:
//    • the Photos library(ies) photolibraryd has on record, plus
//    • the standard library locations in ~/Pictures, ~/Music/Music, ~/Movies/TV, ~/Movies.
//  The Mail / Messages / container stores in ~/Library are always live.
//  Moving a live library PACKAGE itself is also guarded — moving the whole thing away
//  breaks the app just as surely as reaching inside it.
//
//  ⚠️ DO NOT READ com.apple.Music / com.apple.TV / com.apple.Photos PREFERENCES TO FIND
//  LIBRARIES. On 2026-09-18 a `defaults read com.apple.Music` from the terminal put a
//  privacy prompt on his screen. photolibraryd's domain answered without one; the rest
//  come from known locations.
//
//  ⚠️ THIS IS A PLAIN ENUM ON PURPOSE. It first lived as a static on the
//  ScanForMediaDialog view, which is @MainActor isolated, and the headless CLI
//  call deadlocked waiting for a main actor that never ran. A safety check has to
//  be callable from anywhere, so it has no actor and no UI dependency.
//

import Foundation

nonisolated enum MoveGuard {

    private static let libraryExtensions: Set<String> = [
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "theater",
    ]

    /// Directories, relative to home, whose contents belong to a running app.
    private static let protectedHomeSubpaths = [
        "Library/Mail",
        "Library/Messages",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Mobile Documents",
    ]

    /// Library packages an app is using right now. Computed once per launch — a library
    /// switch mid-session is rare, and a stale answer errs toward copying, never toward
    /// moving something live.
    static let liveLibraries: [String] = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var found = Set<String>()

        // Photos: whatever photolibraryd has on record (this domain raised no prompt).
        if let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.photolibraryd") {
            func collect(_ value: Any) {
                if let s = value as? String, s.hasSuffix(".photoslibrary") { found.insert(s) }
                else if let a = value as? [Any] { a.forEach(collect) }
                else if let d = value as? [String: Any] { d.values.forEach(collect) }
            }
            domain.values.forEach(collect)
        }

        // Standard locations for each app's library.
        for folder in ["Pictures", "Music/Music", "Movies/TV", "Movies"] {
            let dir = home + "/" + folder
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where libraryExtensions.contains((name as NSString).pathExtension.lowercased()) {
                found.insert(dir + "/" + name)
            }
        }
        return found.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.sorted()
    }()

    /// True when this item must be copied even if the user chose Move.
    static func mustCopyNotMove(_ url: URL) -> Bool {
        reason(url) != nil
    }

    /// Short reason for the log and for anything shown to the user; nil = free to move.
    static func reason(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path

        for lib in liveLibraries where path == lib || path.hasPrefix(lib + "/") {
            switch (lib as NSString).pathExtension.lowercased() {
            case "photoslibrary": return "inside the Photos library in use"
            case "musiclibrary", "tvlibrary": return "inside the Music or TV library in use"
            default: return "inside a library an app is using"
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for sub in protectedHomeSubpaths {
            let root = home + "/" + sub
            guard path == root || path.hasPrefix(root + "/") else { continue }
            if sub == "Library/Mail" { return "a Mail attachment" }
            if sub == "Library/Messages" { return "a Messages attachment" }
            return "owned by another app"
        }
        return nil
    }

    /// True when a folder HOLDS something guarded (e.g. moving ~/Pictures would carry the
    /// live Photos library with it). Such a folder is never moved in one piece; the engine
    /// walks into it so the guarded part is copied and the rest moves.
    static func containsGuarded(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let roots = liveLibraries + protectedHomeSubpaths.map { home + "/" + $0 }
        return roots.contains { $0.hasPrefix(path + "/") }
    }

    /// True when the path is (or is inside) any library package, live or not.
    /// Used to keep a library whole — never merged file by file (plan 3.7).
    static func isLibraryPackage(_ url: URL) -> Bool {
        libraryExtensions.contains(url.pathExtension.lowercased())
    }
}
