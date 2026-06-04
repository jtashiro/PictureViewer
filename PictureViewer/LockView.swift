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
        .onAppear {
            // Attempt authentication immediately when the view appears.
            if !authManager.isAuthenticated {
                authManager.authenticate()
            }
        }
    }
}

#Preview {
    LockView()
}
