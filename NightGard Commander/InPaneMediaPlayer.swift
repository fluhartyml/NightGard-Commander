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
import MusicKit

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
    @State private var isWebloc = false
    @State private var showAuthAlert = false
    @StateObject private var musicService = AppleMusicService.shared

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var mediaFiles: [FileItem] {
        fileSystem.files.filter { file in
            let ext = (file.name as NSString).pathExtension.lowercased()
            let filename = file.name.lowercased()
            // Include regular media files AND Apple Music audio webloc files (not video)
            return ["mp3", "m4a", "wav", "aiff", "aac", "flac", "ogg", "mp4", "mov", "m4v", "avi", "mkv"].contains(ext) ||
                   filename.hasSuffix(".media.webloc")
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

                if isWebloc {
                    // Apple Music native player
                    AppleMusicPlayerView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                } else if isVideo {
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

                if isWebloc {
                    // Webloc files - show streaming label instead of playback controls
                    HStack {
                        Image(systemName: "globe")
                            .foregroundColor(.secondary)
                        Text("Streaming from Apple Music")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    // Progress slider (for local media files only)
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

                    // Playback controls (for local media files only)
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
                }

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
            .alert("Apple Music Authorization Required", isPresented: $showAuthAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please allow access to Apple Music in System Settings to play Apple Music content.")
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

        // Check if this is a webloc file
        let filename = media.name.lowercased()
        if filename.hasSuffix(".media.webloc") {
            // This is an Apple Music audio link - use MusicKit
            isWebloc = true
            Task {
                await playAppleMusicWebloc(path: media.path)
            }
        } else {
            // Regular audio/video file
            isWebloc = false

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
    }

    private func playAppleMusicWebloc(path: String) async {
        // Check authorization first
        if !musicService.isAuthorized {
            await musicService.requestAuthorization()
            if !musicService.isAuthorized {
                showAuthAlert = true
                return
            }
        }

        // Read URL from webloc plist
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let urlString = plist["URL"] as? String else {
            print("Error reading webloc file")
            return
        }

        // Parse Apple Music URL
        guard let (type, id) = musicService.parseAppleMusicURL(urlString) else {
            print("Error parsing Apple Music URL: \(urlString)")
            return
        }

        // Play using MusicKit
        do {
            switch type {
            case "song":
                try await musicService.playSong(id: id)
            case "album":
                try await musicService.playAlbum(id: id)
            default:
                print("Unknown Apple Music type: \(type)")
            }
            isPlaying = true
        } catch {
            print("Error playing Apple Music content: \(error)")
        }
    }

    private func togglePlayPause() {
        if isWebloc {
            // Control MusicKit player
            let musicPlayer = ApplicationMusicPlayer.shared
            if isPlaying {
                musicPlayer.pause()
            } else {
                Task {
                    try? await musicPlayer.play()
                }
            }
            isPlaying.toggle()
        } else {
            // Control AVPlayer
            guard let player = player else { return }
            if isPlaying {
                player.pause()
            } else {
                player.play()
            }
            isPlaying.toggle()
        }
    }

    private func stopPlayback() {
        if isWebloc {
            // Stop MusicKit player
            ApplicationMusicPlayer.shared.stop()
        } else {
            // Stop AVPlayer
            player?.pause()
            player = nil
        }
        isPlaying = false
        currentTime = 0
        duration = 0
        isWebloc = false
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

// Apple Music Player UI - shows current track artwork and info
struct AppleMusicPlayerView: View {
    @State private var currentSong: Song?
    @State private var artwork: Artwork?

    private let player = ApplicationMusicPlayer.shared

    var body: some View {
        VStack(spacing: 16) {
            // Album artwork
            if let artwork = artwork, let url = artwork.url(width: 300, height: 300) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 250, height: 250)
                        .cornerRadius(8)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 250, height: 250)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 80))
                                .foregroundColor(.secondary)
                        )
                }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 250, height: 250)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 80))
                            .foregroundColor(.secondary)
                    )
            }

            // Track info
            if let song = currentSong {
                VStack(spacing: 4) {
                    Text(song.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("Apple Music")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .onReceive(player.queue.objectWillChange) { _ in
            // Update current track when queue changes
            Task { @MainActor in
                if let entry = player.queue.currentEntry,
                   let song = entry.item as? Song {
                    self.currentSong = song
                    self.artwork = song.artwork
                }
            }
        }
        .onAppear {
            // Load initial track
            Task { @MainActor in
                if let entry = player.queue.currentEntry,
                   let song = entry.item as? Song {
                    self.currentSong = song
                    self.artwork = song.artwork
                }
            }
        }
    }
}
