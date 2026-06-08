//
//  LockView.swift
//  PictureViewer
//
//  Created by GitHub Copilot on 6/3/26.
//

import SwiftUI
import AppKit

struct LockView: View {
    @EnvironmentObject private var authManager: AuthenticationManager
    @State private var didRequestAutomaticAuthentication = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(.secondary)

            if authManager.isAuthenticating {
                ProgressView("Authenticating…")
                    .controlSize(.regular)
            } else if authManager.isAuthenticated {
                Text("Unlocked")
                    .font(.headline)
            } else {
                Text("Enter your macOS password to unlock")
                    .font(.headline)
                if let err = authManager.lastError {
                    Text(err)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .padding(.horizontal)
                }

                HStack(spacing: 12) {
                    Button("Unlock") {
                        authManager.authenticate()
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("Quit") {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 180)
        .background {
            WindowAccessor { window in
                configureLockWindow(window)
            }
        }
    }

    private func configureLockWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.title = "Picture Viewer Locked"
        window.tabbingMode = .disallowed

        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            let current = window.frame
            let width = max(current.width, 360)
            let height = max(current.height, 180)
            let frame = NSRect(
                x: visible.midX - width / 2,
                y: visible.midY - height / 2,
                width: width,
                height: height
            )
            window.setFrame(frame, display: true, animate: false)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard !didRequestAutomaticAuthentication, !authManager.isAuthenticated else { return }
        didRequestAutomaticAuthentication = true
        DispatchQueue.main.async {
            authManager.authenticate()
        }
    }
}
