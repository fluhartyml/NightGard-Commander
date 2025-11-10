//
//  AudioPlayer.swift
//  NightGard Commander
//
//  Created by Michael Fluharty on 11/10/25.
//

import SwiftUI
import AVFoundation
import Combine

struct AudioPlayer: View {
    let filePath: String
    let fileName: String
    let onClose: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var volume: Float = 0.5

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "music.note")
                    .font(.title2)
                Text(fileName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button("Close") {
                    stopPlayback()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Spacer()

            // Waveform icon
            Image(systemName: "waveform")
                .font(.system(size: 80))
                .foregroundColor(.blue)

            // Time display
            HStack {
                Text(formatTime(currentTime))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .leading)

                Slider(value: $currentTime, in: 0...max(duration, 0.1)) { editing in
                    if !editing {
                        seekToTime(currentTime)
                    }
                }
                .disabled(duration == 0)

                Text(formatTime(duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .padding(.horizontal)

            // Play controls
            HStack(spacing: 30) {
                Button(action: seekBackward) {
                    Image(systemName: "gobackward.15")
                        .font(.title)
                }
                .buttonStyle(.borderless)

                Button(action: togglePlayPause) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                }
                .buttonStyle(.borderless)

                Button(action: seekForward) {
                    Image(systemName: "goforward.15")
                        .font(.title)
                }
                .buttonStyle(.borderless)
            }

            // Volume control
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.secondary)

                Slider(value: $volume, in: 0...1) { _ in
                    player?.volume = volume
                }
                .frame(width: 150)

                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            stopPlayback()
        }
        .onReceive(timer) { _ in
            updatePlaybackTime()
        }
    }

    private func setupPlayer() {
        let url = URL(fileURLWithPath: filePath)
        player = AVPlayer(url: url)
        player?.volume = volume

        // Get duration using modern async API
        Task {
            if let asset = player?.currentItem?.asset {
                do {
                    let loadedDuration = try await asset.load(.duration)
                    await MainActor.run {
                        self.duration = CMTimeGetSeconds(loadedDuration)
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

    private func updatePlaybackTime() {
        guard let player = player else { return }

        if let currentItem = player.currentItem {
            currentTime = CMTimeGetSeconds(currentItem.currentTime())

            // Auto-stop at end
            if currentTime >= duration && isPlaying {
                player.pause()
                player.seek(to: .zero)
                isPlaying = false
                currentTime = 0
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
