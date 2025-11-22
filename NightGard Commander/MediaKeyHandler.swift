//
//  MediaKeyHandler.swift
//  NightGard Commander
//
//  Created by Claude on 2025-11-22.
//  Hardware media key support (keyboard play/pause, next/previous buttons)
//

import Foundation
import AppKit
import MediaPlayer

@MainActor
class MediaKeyHandler {
    private let commandCenter = MPRemoteCommandCenter.shared()

    // Callbacks for media actions
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    init() {
        setupRemoteCommands()
    }

    private func setupRemoteCommands() {
        // Play/Pause button on keyboard
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.onPlayPause?()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.onPlayPause?()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onPlayPause?()
            return .success
        }

        // Next/Previous track buttons
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNext?()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPrevious?()
            return .success
        }

        // Enable the commands
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
    }

    func updateNowPlaying(title: String?, artist: String?, artwork: NSImage?) {
        var nowPlayingInfo = [String: Any]()

        if let title = title {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }

        if let artist = artist {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        }

        if let artwork = artwork {
            let artworkImage = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artworkImage
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    deinit {
        // Disable commands when handler is deallocated
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }
}
