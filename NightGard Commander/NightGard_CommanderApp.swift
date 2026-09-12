//
//  NightGard_CommanderApp.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI
import CoreData
import AppKit

@main
struct NightGard_CommanderApp: App {
    let persistenceController = PersistenceController.shared

    /// Headless command-line mode. Returns immediately unless a recognised
    /// verb was passed, in which case the job runs and the process exits
    /// before any window is created. See CLIRunner.swift.
    init() {
        CLIRunner.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                // The build number rides in the window title so it can be read off
                // the screen without opening About. His ask, 2026-09-11, and he was
                // explicit that this is for us only, before the app is distributed.
                // ⚠️ REMOVE THIS BEFORE ANY PUBLIC RELEASE — the title bar is not
                // where a shipped app states its version.
                .navigationTitle("NightGard Commander — build \(BuildStamp.number)")
        }
        .commands {
            // About must name the exact build. A build that cannot say which commit it
            // is cannot be told apart from another, which is what the build-number
            // standard exists to prevent. See BuildStamp.swift.
            CommandGroup(replacing: .appInfo) {
                Button("About NightGard Commander") {
                    showAboutPanel()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NotificationCenter.default.post(name: .openShazamSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Standard About panel, with the build line added underneath.
/// The credits field is the one place AppKit lets arbitrary text sit in that panel,
/// so the commit, branch and build time land somewhere they can be read out loud.
@MainActor
private func showAboutPanel() {
    let credits = NSAttributedString(
        string: BuildStamp.summary,
        attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
    )
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    NSApp.activate(ignoringOtherApps: true)
}

extension Notification.Name {
    static let openShazamSettings = Notification.Name("openShazamSettings")
}
