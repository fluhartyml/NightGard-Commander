//
//  FinderReveal.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 18
//
//  "Show in Finder" on every right-click — his words, 2026-09-18: "i also want a show in
//  finder right click for everything". One helper, so every menu does the same thing.
//

import AppKit

enum FinderReveal {
    /// Opens a Finder window with these items selected. Anything that no longer exists (a
    /// Move just took it) is shown by its nearest folder that still does.
    static func show(_ paths: [String]) {
        let fm = FileManager.default
        var urls: [URL] = []
        for p in paths {
            var u = URL(fileURLWithPath: p)
            while u.path != "/" && !fm.fileExists(atPath: u.path) { u = u.deletingLastPathComponent() }
            if !urls.contains(u) { urls.append(u) }
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Opens the folder itself in Finder — for a right-click on a pane's empty space.
    static func open(folder path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}
