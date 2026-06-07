//
//  AuthenticationManager.swift
//  PictureViewer
//
//  Created by GitHub Copilot on 6/3/26.
//

import Foundation
import LocalAuthentication
import SwiftUI
import Combine
import os

@MainActor
final class AuthenticationManager: ObservableObject {
    static let shared = AuthenticationManager()
    private let logger = Logger(subsystem: "com.example.PictureViewer", category: "auth")
    @Published var isAuthenticated: Bool = false
    @Published var isAuthenticating: Bool = false
    @Published var lastError: String?

    /// Start device-owner authentication. This uses LocalAuthentication to
    /// prompt the user for their macOS credentials (biometrics or password).
    /// On success `isAuthenticated` becomes true.
    func authenticate() {
        // Avoid re-entrancy
        guard !isAuthenticating, !isAuthenticated else { return }
        isAuthenticating = true
        lastError = nil
        logger.log("auth:begin")

        let context = LAContext()
        context.interactionNotAllowed = false

        let reason = "Unlock Picture Viewer"

        // deviceOwnerAuthentication allows biometrics and password fallback.
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            let errorDescription = (error as NSError?)?.localizedDescription
            Task { @MainActor in
                AuthenticationManager.shared.finishAuthentication(success: success, errorDescription: errorDescription)
            }
        }
    }

    private func finishAuthentication(success: Bool, errorDescription: String?) {
        isAuthenticating = false
        if success {
            isAuthenticated = true
            logger.log("auth:success")
        } else {
            isAuthenticated = false
            if let errorDescription {
                lastError = errorDescription
                logger.log("auth:failed error=\(errorDescription, privacy: .public)")
            } else {
                lastError = "Authentication failed"
                logger.log("auth:failed unknown")
            }
        }
    }

    /// Reset authentication state (useful for sign-out or retry flows).
    func reset() {
        isAuthenticated = false
        lastError = nil
    }
}
