//
//  ShazamSessionDelegate.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2025 Nov 18 1215
//

import Foundation
import ShazamKit

class ShazamSessionDelegate: NSObject, SHSessionDelegate {
    var onMatch: ((SHMatch) -> Void)?
    var onNoMatch: (() -> Void)?
    var onError: ((Error) -> Void)?

    func session(_ session: SHSession, didFind match: SHMatch) {
        onMatch?(match)
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        if let error = error {
            onError?(error)
        } else {
            onNoMatch?()
        }
    }
}
