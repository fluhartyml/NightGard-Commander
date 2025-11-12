//
//  KeychainService.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 11 1057
//

import Foundation
import Security

class KeychainService {
    static let shared = KeychainService()

    private init() {}

    // MARK: - Save Password

    func savePassword(_ password: String, for serverID: UUID) -> Bool {
        guard let passwordData = password.data(using: .utf8) else {
            return false
        }

        // Delete existing entry first
        _ = deletePassword(for: serverID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: serverID.uuidString,
            kSecAttrService as String: "NightGardCommander",
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Retrieve Password

    func getPassword(for serverID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: serverID.uuidString,
            kSecAttrService as String: "NightGardCommander",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let passwordData = result as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            return nil
        }

        return password
    }

    // MARK: - Delete Password

    func deletePassword(for serverID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: serverID.uuidString,
            kSecAttrService as String: "NightGardCommander"
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Update Password

    func updatePassword(_ newPassword: String, for serverID: UUID) -> Bool {
        // Just save again - savePassword already handles delete+add
        return savePassword(newPassword, for: serverID)
    }
}
