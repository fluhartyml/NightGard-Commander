//
//  ServerMountService.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 11 1057
//

import Foundation
import AppKit

enum MountError: Error, LocalizedError {
    case missingPassword
    case mountFailed(String)
    case alreadyMounted
    case unmountFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPassword:
            return "Password not found in Keychain"
        case .mountFailed(let message):
            return "Failed to mount server: \(message)"
        case .alreadyMounted:
            return "Server is already mounted"
        case .unmountFailed(let message):
            return "Failed to unmount server: \(message)"
        }
    }
}

class ServerMountService {
    static let shared = ServerMountService()

    // MARK: - Simulation Mode (for testing without real servers)
    var simulationMode = true // Set to false when testing with real servers

    private init() {}

    // MARK: - Mount Server

    func mountServer(_ server: ServerConfig) async throws -> String {
        print("🔌 [ServerMount] Attempting to mount: \(server.name)")

        // SIMULATION MODE: Use local directory instead of real mounting
        if simulationMode {
            print("🧪 [ServerMount] SIMULATION MODE - Using fake mount point")

            // Check if already "mounted"
            if isServerMounted(server) {
                print("✅ [ServerMount] Already mounted at: \(getSimulatedMountPoint(server))")
                return getSimulatedMountPoint(server)
            }

            // Simulate mount delay
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            // Use home directory as simulated mount point
            let simulatedPath = getSimulatedMountPoint(server)
            print("✅ [ServerMount] Simulated mount successful: \(simulatedPath)")
            return simulatedPath
        }

        // REAL MODE: Actual server mounting
        print("🌐 [ServerMount] REAL MODE - Attempting actual mount")

        // Check if already mounted
        if isServerMounted(server) {
            print("✅ [ServerMount] Already mounted at: \(server.mountPoint)")
            return server.mountPoint
        }

        // Get password from Keychain
        guard let password = KeychainService.shared.getPassword(for: server.id) else {
            print("❌ [ServerMount] Password not found in Keychain")
            throw MountError.missingPassword
        }

        // Build mount URL with credentials
        let urlWithCredentials = "\(server.serverType.urlScheme)://\(server.username):\(password)@\(server.address)/\(server.shareName)"
        print("🔗 [ServerMount] Mount URL: \(server.serverType.urlScheme)://\(server.username):***@\(server.address)/\(server.shareName)")

        // Use NetFS framework via NSWorkspace
        guard let url = URL(string: urlWithCredentials) else {
            print("❌ [ServerMount] Invalid URL")
            throw MountError.mountFailed("Invalid URL")
        }

        let success = NSWorkspace.shared.open(url)
        if !success {
            print("❌ [ServerMount] NSWorkspace.open failed")
            throw MountError.mountFailed("NSWorkspace.open failed")
        }

        // Give system time to mount
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        if isServerMounted(server) {
            print("✅ [ServerMount] Mount successful: \(server.mountPoint)")
            return server.mountPoint
        } else {
            print("❌ [ServerMount] Mount point not found")
            throw MountError.mountFailed("Mount point not found")
        }
    }

    // MARK: - Unmount Server

    func unmountServer(_ server: ServerConfig) throws {
        let mountURL = URL(fileURLWithPath: server.mountPoint)

        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: mountURL)
        } catch {
            throw MountError.unmountFailed(error.localizedDescription)
        }
    }

    // MARK: - Check Mount Status

    func isServerMounted(_ server: ServerConfig) -> Bool {
        if simulationMode {
            // In simulation mode, always consider server "mounted" if it's in our list
            // This is simplistic but works for UI testing
            return false // Will always return false, so mounting always happens
        }
        return FileManager.default.fileExists(atPath: server.mountPoint)
    }

    func getMountedPath(_ server: ServerConfig) -> String? {
        if simulationMode {
            return getSimulatedMountPoint(server)
        }
        return isServerMounted(server) ? server.mountPoint : nil
    }

    // MARK: - Simulation Helpers

    private func getSimulatedMountPoint(_ server: ServerConfig) -> String {
        // Use home directory or Documents as fake mount point
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Documents" // Or could create a temp folder per server
    }
}
