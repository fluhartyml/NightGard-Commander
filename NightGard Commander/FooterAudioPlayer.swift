//
//  FooterAudioPlayer.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI
import AVFoundation
import Combine

struct FooterAudioPlayer: View {
    let leftFileSystem: FileSystemService
    let rightFileSystem: FileSystemService
    @Binding var activePane: FocusedPane
    @Binding var currentTrackIndex: Int?
    @Binding var isVisible: Bool
    @Binding var autoPlayNextLeft: Bool
    @Binding var autoPlayOppositeLeft: Bool
    @Binding var autoPlayNextRight: Bool
    @Binding var autoPlayOppositeRight: Bool

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var activeFileSystem: FileSystemService {
        activePane == .left ? leftFileSystem : rightFileSystem
    }

    var audioFilesInActivePane: [FileItem] {
        activeFileSystem.files.filter { file in
            let ext = (file.name as NSString).pathExtension.lowercased()
            return ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg"].contains(ext)
        }
    }

    var currentTrack: FileItem? {
        guard let index = currentTrackIndex, index < audioFilesInActivePane.count else { return nil }
        return audioFilesInActivePane[index]
    }

    var nextTrackInPane: FileItem? {
        guard let index = currentTrackIndex, index + 1 < audioFilesInActivePane.count else { return nil }
        return audioFilesInActivePane[index + 1]
    }

    var autoPlayNextEnabled: Bool {
        activePane == .left ? autoPlayNextLeft : autoPlayNextRight
    }

    var autoPlayOppositeEnabled: Bool {
        activePane == .left ? autoPlayOppositeLeft : autoPlayOppositeRight
    }

    var body: some View {
        if isVisible, let current = currentTrack {
            VStack(spacing: 4) {
                // Playback controls - minimal design
                HStack(spacing: 20) {
                    // Previous track
                    Button(action: playPrevious) {
                        Image(systemName: "backward.end.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(currentTrackIndex == 0)

                    // Rewind 15s
                    Button(action: seekBackward) {
                        Image(systemName: "gobackward.15")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)

                    // Play/Pause
                    Button(action: togglePlayPause) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                    }
                    .buttonStyle(.borderless)

                    // Forward 15s
                    Button(action: seekForward) {
                        Image(systemName: "goforward.15")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)

                    // Next track
                    Button(action: playNext) {
                        Image(systemName: "forward.end.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(currentTrackIndex == audioFilesInActivePane.count - 1)

                    Divider()
                        .frame(height: 20)

                    // Per-pane auto-play toggles
                    VStack(alignment: .leading, spacing: 2) {
                        if activePane == .left {
                            Toggle(isOn: $autoPlayNextLeft) {
                                Text("▶ Next (Left)")
                                    .font(.caption2)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)

                            Toggle(isOn: $autoPlayOppositeLeft) {
                                Text("▶ Switch →")
                                    .font(.caption2)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        } else {
                            Toggle(isOn: $autoPlayNextRight) {
                                Text("▶ Next (Right)")
                                    .font(.caption2)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)

                            Toggle(isOn: $autoPlayOppositeRight) {
                                Text("← Switch ▶")
                                    .font(.caption2)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                    }
                    .frame(width: 120)
                }
                .padding(.vertical, 4)

                // Now playing
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .foregroundColor(.blue)
                    Text("Now Playing:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(current.name)
                        .font(.caption)
                        .lineLimit(1)

                    Spacer()

                    Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)

                // Next up
                if let next = nextTrackInPane {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text("Next:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(next.name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                }

                Divider()
            }
            .background(Color.secondary.opacity(0.05))
            .onChange(of: currentTrackIndex) {
                if currentTrackIndex != nil {
                    setupPlayer()
                }
            }
            .onReceive(timer) { _ in
                updatePlaybackTime()
            }
            .onDisappear {
                stopPlayback()
            }
        }
    }

    private func setupPlayer() {
        guard let track = currentTrack else { return }

        stopPlayback()

        let url = URL(fileURLWithPath: track.path)
        player = AVPlayer(url: url)

        // Get duration using modern async API
        Task {
            if let asset = player?.currentItem?.asset {
                do {
                    let loadedDuration = try await asset.load(.duration)
                    await MainActor.run {
                        self.duration = CMTimeGetSeconds(loadedDuration)
                        // Auto-start playback
                        player?.play()
                        isPlaying = true
                    }
                } catch {
                    print("Error loading duration: \(error)")
                }
            }
        }
    }

    private func togglePlayPause() {
        guard let player = player else { return }

        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func stopPlayback() {
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func seekToTime(_ time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime)
    }

    private func seekBackward() {
        let newTime = max(currentTime - 15, 0)
        seekToTime(newTime)
    }

    private func seekForward() {
        let newTime = min(currentTime + 15, duration)
        seekToTime(newTime)
    }

    private func playPrevious() {
        guard let index = currentTrackIndex, index > 0 else { return }
        currentTrackIndex = index - 1
    }

    private func playNext() {
        guard let index = currentTrackIndex, index < audioFilesInActivePane.count - 1 else { return }
        currentTrackIndex = index + 1
    }

    private func switchToOppositePane() {
        // Switch active pane
        activePane = activePane == .left ? .right : .left
        // Start playing first track in new pane
        currentTrackIndex = 0
    }

    private func updatePlaybackTime() {
        guard let player = player else { return }

        if let currentItem = player.currentItem {
            currentTime = CMTimeGetSeconds(currentItem.currentTime())

            // Handle end of track with per-pane toggle logic
            if currentTime >= duration && isPlaying {
                player.pause()
                isPlaying = false

                // Check auto-play toggles for current pane
                if autoPlayNextEnabled {
                    // Play next track in same pane
                    if let index = currentTrackIndex, index < audioFilesInActivePane.count - 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            playNext()
                        }
                    } else {
                        // End of playlist in this pane, check opposite toggle
                        if autoPlayOppositeEnabled {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                switchToOppositePane()
                            }
                        } else {
                            // Stop and reset
                            player.seek(to: .zero)
                            currentTime = 0
                        }
                    }
                } else if autoPlayOppositeEnabled {
                    // Switch to opposite pane
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        switchToOppositePane()
                    }
                } else {
                    // Both toggles off - stop and reset
                    player.seek(to: .zero)
                    currentTime = 0
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        if seconds.isNaN || seconds.isInfinite {
            return "0:00"
        }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
