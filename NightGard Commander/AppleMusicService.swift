//
//  AppleMusicService.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 15 1051
//

import Foundation
import MusicKit
import Combine
import SwiftUI

@MainActor
class AppleMusicService: ObservableObject {
    static let shared = AppleMusicService()

    @Published var isAuthorized = false
    @Published var authorizationStatus: MusicAuthorization.Status = .notDetermined

    private init() {
        checkAuthorizationStatus()
    }

    func checkAuthorizationStatus() {
        authorizationStatus = MusicAuthorization.currentStatus
        isAuthorized = (authorizationStatus == .authorized)
    }

    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        authorizationStatus = status
        isAuthorized = (status == .authorized)
    }

    // Parse Apple Music URL to extract ID
    func parseAppleMusicURL(_ urlString: String) -> (type: String, id: String)? {
        guard let url = URL(string: urlString) else { return nil }

        let pathComponents = url.pathComponents

        // Songs: /us/album/album-name/ALBUM_ID?i=SONG_ID
        if pathComponents.contains("album"), let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            if let songID = queryItems.first(where: { $0.name == "i" })?.value {
                return ("song", songID)
            }
            // Album only
            if let albumID = pathComponents.last {
                return ("album", albumID)
            }
        }

        return nil
    }

    // Play a song by ID
    func playSong(id: String) async throws {
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        let response = try await request.response()

        guard let song = response.items.first else {
            throw AppleMusicError.songNotFound
        }

        let player = ApplicationMusicPlayer.shared
        player.queue = [song]
        try await player.play()
    }

    // Play an album by ID
    func playAlbum(id: String) async throws {
        let request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(id))
        let response = try await request.response()

        guard let album = response.items.first else {
            throw AppleMusicError.albumNotFound
        }

        let player = ApplicationMusicPlayer.shared
        player.queue = [album]
        try await player.play()
    }
}

enum AppleMusicError: Error {
    case songNotFound
    case albumNotFound
    case invalidURL
    case notAuthorized
}
