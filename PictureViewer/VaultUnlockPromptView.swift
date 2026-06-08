//
//  VaultUnlockPromptView.swift
//  PictureViewer
//

import SwiftUI

struct VaultUnlockPromptView: View {
	let vaultHasPassword: Bool
	let displayName: String
	let pendingAutoOpen: Bool
	let unlockMessage: String?
	@Binding var password: String
	@Binding var confirmation: String
	let onCancel: () -> Void
	let onSubmit: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(vaultHasPassword ? "Unlock \(displayName)" : "Set Password for \(displayName)")
				.font(.headline)

			SecureField("Password", text: $password)
				.textFieldStyle(.roundedBorder)

			if !vaultHasPassword {
				SecureField("Re-enter password", text: $confirmation)
					.textFieldStyle(.roundedBorder)
			}

			Text(pendingAutoOpen
				 ? "This folder contains encrypted photos. Enter the password to open \(displayName)."
				 : "After unlocking, choose Vault → Open Vault to view your photos.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			if let unlockMessage {
				Text(unlockMessage)
					.font(.caption)
					.foregroundStyle(.red)
			}

			HStack {
				Button("Cancel", action: onCancel)
				Spacer()
				Button(vaultHasPassword ? "Unlock" : "Set Password", action: onSubmit)
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding()
		.frame(width: 360)
	}
}
