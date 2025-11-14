//
//  InPaneMediaPlayer.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI
import AVFoundation
import AVKit
import Combine

struct InPaneMediaPlayer: View {
    @Binding var currentMedia: FileItem?
    @Binding var isVisible: Bool
    @Binding var autoPlayNext: Bool
    @Binding var autoPlayOpposite: Bool
    let fileSystem: FileSystemService
    let onSwitchToOpposite: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var currentTrackIndex: Int = 0

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var mediaFiles: [FileItem] {
        fileSystem.files.filter { file in
            let ext = (file.name as NSString).pathExtension.lowercased()
            return ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg", "mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
        }
    }

    var isVideo: Bool {
        guard let media = currentMedia else { return false }
        let ext = (media.name as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }

    var nextMedia: FileItem? {
        guard currentTrackIndex + 1 < mediaFiles.count else { return nil }
        return mediaFiles[currentTrackIndex + 1]
    }

    var body: some View {
        if isVisible, let media = currentMedia {
            VStack(spacing: 0) {
                Divider()

                if isVideo {
                    // Video player
                    if let player = player {
                        VideoPlayer(player: player)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(16/9, contentMode: .fit)
                            .onAppear {
                                player.play()
                                isPlaying = true
                            }
                    }
                } else {
                    // Audio player visualization
                    VStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 40))
                            .foregroundColor(.blue)
                            .padding(.top, 8)

                        Text(media.name)
                            .font(.caption)
                            .lineLimit(1)

                        Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    .frame(height: 120)
                }

                // Progress slider
                HStack(spacing: 8) {
                    Text(formatTime(currentTime))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)

                    Slider(value: Binding(
                        get: { currentTime },
                        set: { newValue in
                            seekToTime(newValue)
                            currentTime = newValue
                        }
                    ), in: 0...max(duration, 0.1))
                        .controlSize(.small)

                    Text(formatTime(duration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                // Playback controls
                HStack(spacing: 12) {
                    Button(action: playPrevious) {
                        Image(systemName: "backward.end.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(currentTrackIndex == 0)

                    Button(action: seekBackward) {
                        Image(systemName: "gobackward.15")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    Button(action: togglePlayPause) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)

                    Button(action: seekForward) {
                        Image(systemName: "goforward.15")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    Button(action: playNext) {
                        Image(systemName: "forward.end.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(currentTrackIndex == mediaFiles.count - 1)
                }
                .padding(.vertical, 4)

                // Auto-play toggles
                HStack(spacing: 12) {
                    Toggle(isOn: $autoPlayNext) {
                        Text("▶ Next")
                            .font(.caption2)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Toggle(isOn: $autoPlayOpposite) {
                        Text("⇄ Switch")
                            .font(.caption2)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

                // Next up (always reserve space for consistent height)
                Group {
                    if let next = nextMedia {
                        Text("Next: \(next.name)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(" ")
                            .font(.caption2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
            .background(Color.secondary.opacity(0.05))
            .onAppear {
                setupPlayer()
            }
            .onChange(of: currentMedia) {
                setupPlayer()
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
        guard let media = currentMedia else { return }

        stopPlayback()

        // Update current track index
        if let index = mediaFiles.firstIndex(where: { $0.id == media.id }) {
            currentTrackIndex = index
        }

        let url = URL(fileURLWithPath: media.path)
        player = AVPlayer(url: url)

        // Get duration using modern async API
        Task {
            if let asset = player?.currentItem?.asset {
                do {
                    let loadedDuration = try await asset.load(.duration)
                    await MainActor.run {
                        self.duration = CMTimeGetSeconds(loadedDuration)
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
        guard currentTrackIndex > 0, currentTrackIndex < mediaFiles.count else { return }
        currentMedia = mediaFiles[currentTrackIndex - 1]
    }

    private func playNext() {
        guard currentTrackIndex < mediaFiles.count - 1 else { return }
        currentMedia = mediaFiles[currentTrackIndex + 1]
    }

    private func updatePlaybackTime() {
        guard let player = player else { return }

        if let currentItem = player.currentItem {
            currentTime = CMTimeGetSeconds(currentItem.currentTime())

            // Handle end of media
            if currentTime >= duration - 0.1 && isPlaying {
                player.pause()
                isPlaying = false

                // Check auto-play logic
                if autoPlayNext && currentTrackIndex < mediaFiles.count - 1 {
                    // Play next in same pane
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        playNext()
                    }
                } else if autoPlayOpposite {
                    // Switch to opposite pane
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        stopPlayback()
                        isVisible = false
                        onSwitchToOpposite()
                    }
                } else {
                    // Stop and reset
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
