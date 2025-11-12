//
//  ServerConfig.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 11 1054
//

import Foundation

enum ServerType: String, CaseIterable, Codable {
    case smb = "SMB"
    case afp = "AFP"
    case nfs = "NFS"

    var displayName: String {
        return self.rawValue
    }

    var urlScheme: String {
        switch self {
        case .smb: return "smb"
        case .afp: return "afp"
        case .nfs: return "nfs"
        }
    }
}

struct ServerConfig: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String              // Display name (e.g., "Home NAS")
    var address: String            // Server address (e.g., "192.168.1.100" or "server.local")
    var shareName: String          // Share/volume name (e.g., "Documents")
    var username: String           // Login username
    var serverType: ServerType     // SMB, AFP, or NFS
    var port: Int?                 // Optional custom port

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        shareName: String,
        username: String,
        serverType: ServerType,
        port: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.shareName = shareName
        self.username = username
        self.serverType = serverType
        self.port = port
    }

    /// Full server URL for mounting (e.g., "smb://192.168.1.100/Documents")
    var serverURL: String {
        var url = "\(serverType.urlScheme)://\(address)"
        if let port = port {
            url += ":\(port)"
        }
        if !shareName.isEmpty {
            url += "/\(shareName)"
        }
        return url
    }

    /// Display string for UI (e.g., "Home NAS (smb://192.168.1.100/Documents)")
    var displayString: String {
        return "\(name) (\(serverURL))"
    }

    /// Expected mount point path (e.g., "/Volumes/Documents")
    var mountPoint: String {
        return "/Volumes/\(shareName)"
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ServerConfig, rhs: ServerConfig) -> Bool {
        lhs.id == rhs.id
    }
}
