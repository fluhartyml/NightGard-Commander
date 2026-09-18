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

    // NightGard Library Commander, merged in 2026-09-16 — his goal: "use nightgard commander
    // as our media playground." It lives in its own window so the two-pane browser is untouched.
    @State private var libraryService = LibraryService()
    @State private var lockerService = PlaylistLockerService()

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

            // A whole Move can be undone later from its log — the old undo covered one file.
            CommandGroup(after: .undoRedo) {
                Button("Undo Last Move…") {
                    NotificationCenter.default.post(name: .undoLastMove, object: nil)
                }
            }

            CommandGroup(after: .windowArrangement) {
                OpenLibraryWindowButton()
            }

            // Plan section 7 — source pane → target pane, like Copy and Move.
            CommandMenu("Operations") {
                Button("Flatten Copy…") {
                    NotificationCenter.default.post(name: .flattenCopy, object: nil)
                }
                .keyboardShortcut("5", modifiers: [.command, .option])
                Button("Flatten Move…") {
                    NotificationCenter.default.post(name: .flattenMove, object: nil)
                }
                .keyboardShortcut("6", modifiers: [.command, .option])
                Divider()
                Button("Extract from Photos Library…") {
                    NotificationCenter.default.post(name: .extractFromLibrary, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NotificationCenter.default.post(name: .openShazamSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("Library", id: LibraryWindow.id) {
            LibraryCommanderView()
                .environment(libraryService)
                .environment(lockerService)
                .task {
                    await libraryService.authorize()
                    lockerService.scanLocker()
                    await libraryService.refreshStats()
                }
        }
        .defaultSize(width: 900, height: 720)
    }
}

enum LibraryWindow {
    static let id = "library"
}

/// Window > Library (⌘L). A View, because `openWindow` is only reachable from the environment.
private struct OpenLibraryWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Library") {
            openWindow(id: LibraryWindow.id)
        }
        .keyboardShortcut("l", modifiers: .command)
    }
}

/// Standard About panel, with the build line added underneath.
/// The credits field is the one place AppKit lets arbitrary text sit in that panel,
/// so the commit, branch and build time land somewhere they can be read out loud.
@MainActor
private func showAboutPanel() {
    let credits = NSMutableAttributedString(
        string: BuildStamp.summary,
        attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
    )
    // ACKNOWLEDGMENTS — his standing rule for every app, in About AND the README
    // (2026-09-18): name the outside work, and say plainly that his copyright does not
    // claim it.
    credits.append(NSAttributedString(
        string: "\n\nAcknowledgments\n"
            + "Copy and Move follow the approach of GNU Midnight Commander "
            + "(GPL v3 or later, midnight-commander.org) — its ideas, rewritten in Swift; "
            + "no Midnight Commander code is included.\n\n"
            + "Copyright covers Michael Fluharty's original work only. It does not claim or "
            + "intend ownership of the work of the original developers named here.",
        attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
    ))
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    NSApp.activate(ignoringOtherApps: true)
}

extension Notification.Name {
    static let openShazamSettings = Notification.Name("openShazamSettings")
    static let undoLastMove = Notification.Name("undoLastMove")
    static let flattenCopy = Notification.Name("flattenCopy")
    static let flattenMove = Notification.Name("flattenMove")
    static let extractFromLibrary = Notification.Name("extractFromLibrary")
}
