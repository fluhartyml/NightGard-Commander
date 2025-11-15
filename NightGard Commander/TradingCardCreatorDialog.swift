//
//  TradingCardCreatorDialog.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 14
//

import SwiftUI
import Combine

struct TradingCardCreatorDialog: View {
    @Binding var isPresented: Bool
    let currentPath: String
    let onRefresh: () -> Void

    @State private var appleMusicURL: String = ""
    @State private var cardName: String = ""
    @State private var isVideo: Bool = false
    @State private var errorMessage: String?
    @State private var showError: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Text("Create Apple Music Link")
                .font(.title2)
                .fontWeight(.bold)

            Divider()

            // URL Input
            VStack(alignment: .leading, spacing: 8) {
                Text("Apple Music URL:")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                TextField("https://music.apple.com/...", text: $appleMusicURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Text("Paste link from Apple Music (song, video, album, or playlist)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Name Input
            VStack(alignment: .leading, spacing: 8) {
                Text("Link Name:")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                TextField("Bohemian Rhapsody", text: $cardName)
                    .textFieldStyle(.roundedBorder)

                Text("Name for the link file (without extension)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Type Toggle
            HStack {
                Text("Type:")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Picker("", selection: $isVideo) {
                    Text("Audio/Album").tag(false)
                    Text("Music Video").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Spacer()
            }

            Spacer()

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    createTradingCard()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appleMusicURL.isEmpty || cardName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 350)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func createTradingCard() {
        // Validate URL
        guard appleMusicURL.hasPrefix("https://music.apple.com") else {
            errorMessage = "URL must be an Apple Music link (https://music.apple.com/...)"
            showError = true
            return
        }

        // Build filename
        let filename = isVideo ? "\(cardName).video.webloc" : "\(cardName).media.webloc"
        let filePath = (currentPath as NSString).appendingPathComponent(filename)

        // Create webloc plist content
        let weblocContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>URL</key>
        \t<string>\(appleMusicURL)</string>
        </dict>
        </plist>
        """

        // Write file
        do {
            try weblocContent.write(toFile: filePath, atomically: true, encoding: .utf8)

            // Success - close dialog and refresh
            isPresented = false
            onRefresh()
        } catch {
            errorMessage = "Failed to create link file: \(error.localizedDescription)"
            showError = true
        }
    }
}
