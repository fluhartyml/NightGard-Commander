//
//  FullscreenVisualizerWindow.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/25/25.
//

import SwiftUI
import AppKit
import Combine

/// Manager for the fullscreen visualizer window (can be sent to Apple TV via AirPlay display)
@MainActor
class FullscreenVisualizerWindowManager: ObservableObject {
    static let shared = FullscreenVisualizerWindowManager()

    @Published var isWindowOpen = false
    @Published var selectedScreen: NSScreen?

    private var window: NSWindow?
    private var hostingView: NSHostingView<FullscreenVisualizerContent>?

    // Visualizer data
    @Published var frequencyData: [Float] = Array(repeating: 0, count: 64)
    @Published var amplitude: Float = 0
    @Published var visualizerType: VisualizerType = .spectrum
    @Published var trackName: String = ""
    @Published var artistName: String = ""

    private init() {}

    /// Get available screens including AirPlay displays
    var availableScreens: [NSScreen] {
        NSScreen.screens
    }

    /// Open visualizer on specified screen (or default if nil)
    func openWindow(on screen: NSScreen? = nil) {
        guard window == nil else {
            // Window exists, bring to front
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let targetScreen = screen ?? selectedScreen ?? NSScreen.main ?? NSScreen.screens.first!

        // Create the window
        let contentView = FullscreenVisualizerContent(manager: self)
        let hostingView = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: targetScreen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )

        window.contentView = hostingView
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver // Above other windows
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]
        window.isReleasedWhenClosed = false

        // Make it fullscreen on the target screen
        window.setFrame(targetScreen.frame, display: true)

        // Handle window close
        window.delegate = WindowDelegate { [weak self] in
            self?.isWindowOpen = false
            self?.window = nil
        }

        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.hostingView = hostingView
        self.isWindowOpen = true
    }

    /// Close the visualizer window
    func closeWindow() {
        window?.close()
        window = nil
        isWindowOpen = false
    }

    /// Toggle window open/close
    func toggleWindow() {
        if isWindowOpen {
            closeWindow()
        } else {
            openWindow()
        }
    }

    /// Move window to a different screen (e.g., AirPlay display)
    func moveToScreen(_ screen: NSScreen) {
        selectedScreen = screen
        if let window = window {
            window.setFrame(screen.frame, display: true, animate: true)
        }
    }

    /// Update visualizer data
    func updateVisualization(frequency: [Float], amp: Float) {
        frequencyData = frequency
        amplitude = amp
    }

    /// Update track info
    func updateTrackInfo(name: String, artist: String) {
        trackName = name
        artistName = artist
    }
}

/// Window delegate to handle close events
private class WindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// The fullscreen visualizer content
struct FullscreenVisualizerContent: View {
    @ObservedObject var manager: FullscreenVisualizerWindowManager

    var body: some View {
        ZStack {
            // Black background
            Color.black.ignoresSafeArea()

            // Visualizer
            VisualizerContainer(
                type: manager.visualizerType,
                frequencyData: manager.frequencyData,
                amplitude: manager.amplitude
            )
            .ignoresSafeArea()

            // Track info overlay (bottom)
            VStack {
                Spacer()

                if !manager.trackName.isEmpty {
                    VStack(spacing: 4) {
                        Text(manager.trackName)
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundColor(.white)
                            .shadow(radius: 10)

                        if !manager.artistName.isEmpty {
                            Text(manager.artistName)
                                .font(.system(size: 24, weight: .regular))
                                .foregroundColor(.white.opacity(0.8))
                                .shadow(radius: 8)
                        }
                    }
                    .padding(.bottom, 60)
                }
            }

            // Controls hint (fades out)
            VStack {
                HStack {
                    Spacer()
                    Text("Press ESC to close • Click to change visualizer")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .padding()
                }
                Spacer()
            }
        }
        .onTapGesture {
            // Cycle visualizer on tap
            let types = VisualizerType.allCases
            if let index = types.firstIndex(of: manager.visualizerType) {
                manager.visualizerType = types[(index + 1) % types.count]
            }
        }
        .onExitCommand {
            // ESC key closes
            manager.closeWindow()
        }
    }
}

/// Button to open visualizer on external display / AirPlay
struct FullscreenVisualizerButton: View {
    @ObservedObject var manager = FullscreenVisualizerWindowManager.shared

    var body: some View {
        Menu {
            // Toggle on current/main screen
            Button(action: {
                manager.selectedScreen = nil
                manager.toggleWindow()
            }) {
                Label(
                    manager.isWindowOpen ? "Close Visualizer" : "Open Visualizer",
                    systemImage: manager.isWindowOpen ? "tv.slash" : "tv"
                )
            }

            if manager.availableScreens.count > 1 {
                Divider()

                Text("Open on Screen:")
                    .font(.caption)

                ForEach(Array(manager.availableScreens.enumerated()), id: \.offset) { index, screen in
                    Button(action: {
                        manager.selectedScreen = screen
                        if manager.isWindowOpen {
                            manager.moveToScreen(screen)
                        } else {
                            manager.openWindow(on: screen)
                        }
                    }) {
                        HStack {
                            Text(screenName(for: screen, index: index))
                            if manager.selectedScreen == screen && manager.isWindowOpen {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: manager.isWindowOpen ? "tv.fill" : "tv")
                .foregroundColor(manager.isWindowOpen ? .green : .secondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20, height: 20)
        .help("Fullscreen Visualizer (for AirPlay display)")
    }

    private func screenName(for screen: NSScreen, index: Int) -> String {
        return screen.localizedName
    }
}
