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
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.isAuthenticating = false
                if success {
                    self?.isAuthenticated = true
                    self?.logger.log("auth:success")
                } else {
                    self?.isAuthenticated = false
                    if let error = error as NSError? {
                        self?.lastError = error.localizedDescription
                        self?.logger.log("auth:failed error=\(error.localizedDescription, privacy: .public)")
                    } else {
                        self?.lastError = "Authentication failed"
                        self?.logger.log("auth:failed unknown")
                    }
                }
            }
        }
    }

    /// Reset authentication state (useful for sign-out or retry flows).
    func reset() {
        isAuthenticated = false
        lastError = nil
    }
}
