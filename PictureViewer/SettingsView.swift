//
//  SettingsView.swift
//  PictureViewer
//

import SwiftUI
import AppKit

enum PhotoDisplayMode: String, CaseIterable, Identifiable, Sendable {
	case fullScreen
	case windowMaximized
	case windowed

	var id: String { rawValue }

	var label: String {
		switch self {
		case .fullScreen: "Full Screen"
		case .windowMaximized: "Maximized Window"
		case .windowed: "Window"
		}
	}

	var description: String {
		switch self {
		case .fullScreen:
			"Take over the entire display, hiding the menu bar and Dock."
		case .windowMaximized:
			"Fill the visible screen area, but keep the menu bar and Dock visible."
		case .windowed:
			"Open photos in a regular resizable window."
		}
	}
}

struct SettingsView: View {
	@AppStorage("photoDisplayMode") private var displayMode: PhotoDisplayMode = .fullScreen
	@AppStorage("saveOpenWindows") private var saveOpenWindows: Bool = false
	@AppStorage("requirePasswordAtLaunch") private var requirePasswordAtLaunch: Bool = true
	@AppStorage("deferAtLaunchBackgroundWork") private var deferAtLaunchBackgroundWork: Bool = true
	@AppStorage(AppLogLevel.userDefaultsKey) private var logLevelRaw: String = AppLogLevel.defaultLevel.rawValue
	@State private var vaultStatus = PhotoVaultStatus(isConfigured: false, hasLocation: false, hasPassword: false, isUnlocked: false, locationPath: nil)
	@State private var vaultPassword: String = ""
	@State private var vaultPasswordConfirmation: String = ""
	@State private var vaultMessage: String?
	@State private var vaultPasswordPromptMessage: String?
	@State private var isShowingVaultPasswordPrompt: Bool = false

	var body: some View {
		TabView {
			generalTab
				.tabItem { Label("General", systemImage: "gearshape") }
			performanceTab
				.tabItem { Label("Performance", systemImage: "cpu") }
		}
		.frame(width: 520, height: 400)
		.sheet(isPresented: $isShowingVaultPasswordPrompt) {
			vaultPasswordPrompt
		}
	}

	private var generalTab: some View {
		Form {
			Section {
				Picker(selection: $displayMode) {
					ForEach(PhotoDisplayMode.allCases) { mode in
						Text(mode.label).tag(mode)
					}
				} label: {
					Text("Open photos in")
				}
				.pickerStyle(.radioGroup)

				Text(displayMode.description)
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Photo Display")
			}

			Section {
				Toggle("Save Open Windows and Reload at Start", isOn: $saveOpenWindows)
				Text("When enabled, the folder you're browsing and any open photo windows are remembered, and reopened the next time you launch Picture Viewer.")
					.font(.caption)
					.foregroundStyle(.secondary)
				Toggle("Password protection (require macOS credentials at launch)", isOn: $requirePasswordAtLaunch)
				Text("When enabled, Picture Viewer will require your macOS password or Touch ID at launch before showing any content.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Session")
			}

			Section {
				HStack {
					VStack(alignment: .leading, spacing: 2) {
						Text(vaultStatus.locationPath ?? "No encrypted storage location selected")
							.lineLimit(1)
							.truncationMode(.middle)
						Text(vaultStatus.isUnlocked ? "Unlocked" : "Locked")
							.font(.caption)
							.foregroundStyle(vaultStatus.isUnlocked ? .green : .secondary)
					}
					Spacer()
					Button("Choose…") {
						chooseVaultLocation()
					}
				}

				HStack {
					Button(vaultStatus.hasPassword ? "Unlock Password" : "Set Password") {
						showVaultPasswordPrompt()
					}
					Spacer()
				}
				if let vaultMessage {
					Text(vaultMessage)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Text("Photos imported into encrypted storage are written as password-encrypted vault files. Picture Viewer uses private working copies so photos remain viewable and editable in the app, then exports restored image files when requested.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Encrypted Photo Storage")
			}
		}
		.formStyle(.grouped)
		.task {
			await refreshVaultStatus()
		}
	}

	private var performanceTab: some View {
		Form {
			Section {
				LabeledContent("Logical CPU cores",
							   value: "\(ProcessInfo.processInfo.processorCount)")
				LabeledContent("Active cores",
							   value: "\(ProcessInfo.processInfo.activeProcessorCount)")
				LabeledContent("Scanner threads",
							   value: "\(PhotoLibrary.workerCount)")
				Toggle("Defer at-launch background work (use cached snapshot, skip re-scan)", isOn: $deferAtLaunchBackgroundWork)
				Text("When enabled, the app will populate the UI from the saved snapshot at launch but skip the potentially expensive background re-scan.")
					.font(.caption)
					.foregroundStyle(.secondary)

				Picker("Log level", selection: $logLevelRaw) {
					ForEach(AppLogLevel.allCases) { level in
						Text(level.title).tag(level.rawValue)
					}
				}
				Text("Default is Info. Set to Debug to show verbose thumbnail/cache diagnostics.")
					.font(.caption)
					.foregroundStyle(.secondary)
			} header: {
				Text("Detected at launch")
			} footer: {
				Text("Folder scans run in parallel across the listed worker threads to load large libraries quickly.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
	}

	private var vaultPasswordPrompt: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(vaultStatus.hasPassword ? "Unlock Encrypted Storage" : "Set Encrypted Storage Password")
				.font(.headline)

			SecureField("Password", text: $vaultPassword)
				.textFieldStyle(.roundedBorder)

			if !vaultStatus.hasPassword {
				SecureField("Re-enter password", text: $vaultPasswordConfirmation)
					.textFieldStyle(.roundedBorder)
			}

			if let vaultPasswordPromptMessage {
				Text(vaultPasswordPromptMessage)
					.font(.caption)
					.foregroundStyle(.red)
			}

			HStack {
				Button("Cancel") {
					clearVaultPasswordPrompt()
					isShowingVaultPasswordPrompt = false
				}
				Spacer()
				Button(vaultStatus.hasPassword ? "Unlock" : "Set Password") {
					submitVaultPasswordPrompt()
				}
				.keyboardShortcut(.defaultAction)
			}
		}
		.padding()
		.frame(width: 360)
	}
}

private extension SettingsView {
	func refreshVaultStatus() async {
		let status = await PhotoVault.shared.status()
		await MainActor.run {
			vaultStatus = status
		}
	}

	func chooseVaultLocation() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = true
		panel.message = "Choose where Picture Viewer should store encrypted photo files"
		panel.prompt = "Choose"
		if panel.runModal() == .OK, let url = panel.url {
			Task {
				do {
					try await PhotoVault.shared.setLocation(url)
					vaultMessage = "Encrypted storage location saved."
				} catch {
					vaultMessage = error.localizedDescription
				}
				await refreshVaultStatus()
			}
		}
	}

	func showVaultPasswordPrompt() {
		clearVaultPasswordPrompt()
		isShowingVaultPasswordPrompt = true
	}

	func clearVaultPasswordPrompt() {
		vaultPassword = ""
		vaultPasswordConfirmation = ""
		vaultPasswordPromptMessage = nil
	}

	func submitVaultPasswordPrompt() {
		let password = vaultPassword
		let confirmation = vaultPasswordConfirmation
		let isSettingNewPassword = !vaultStatus.hasPassword
		guard !password.isEmpty else {
			vaultPasswordPromptMessage = "Enter a password."
			return
		}
		if isSettingNewPassword {
			guard password == confirmation else {
				vaultPasswordPromptMessage = "Passwords do not match."
				return
			}
		}
		Task {
			do {
				let status = await PhotoVault.shared.status()
				if status.hasPassword {
					try await PhotoVault.shared.unlock(password: password)
					vaultMessage = "Encrypted storage unlocked."
				} else {
					try await PhotoVault.shared.configureNewVaultPassword(password)
					vaultMessage = "Encrypted storage password saved."
				}
				clearVaultPasswordPrompt()
				isShowingVaultPasswordPrompt = false
			} catch {
				vaultPasswordPromptMessage = error.localizedDescription
			}
			await refreshVaultStatus()
		}
	}
}

#Preview {
	SettingsView()
}
