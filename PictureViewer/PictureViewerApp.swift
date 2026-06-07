//
//  PictureViewerApp.swift
//  PictureViewer
//
//  Created by John Tashiro on 6/3/26.
//

import SwiftUI
import AppKit
import LocalAuthentication
import os

@main
struct PictureViewerApp: App {
	@StateObject private var authManager = AuthenticationManager.shared
	@AppStorage("requirePasswordAtLaunch") private var requirePasswordAtLaunch: Bool = true
	@State private var isShowingAboutSheet = false

	init() {
		// Touch the lazy CPU detection so the worker count is computed at launch.
		_ = PhotoLibrary.workerCount
		// Respect a runtime toggle to defer potentially expensive background
		// work at launch while debugging responsiveness. Set the UserDefault
		// key "deferAtLaunchBackgroundWork" to false to re-enable the
		// default background work (thumbnail cache sweep).
		let deferAtLaunch = UserDefaults.standard.object(forKey: "deferAtLaunchBackgroundWork") as? Bool ?? true
		let logger = Logger(subsystem: "com.example.PictureViewer", category: "app")
		if deferAtLaunch {
			logger.log("Deferring at-launch background work: thumbnail sweep disabled")
		} else {
			// Refresh the persistent thumbnail cache in the background — drop
			// entries we haven't used recently so the cache stays bounded.
			Task.detached(priority: .background) {
				await ThumbnailCache.shared.sweepStale()
			}
		}

		// Trigger authentication as early as possible so the system prompt
		// appears at app launch, but only if the user enabled the option in
		// Settings. The UI will remain gated behind the `authManager.isAuthenticated` flag.
		if requirePasswordAtLaunch {
			AuthenticationManager.shared.authenticate()
		}

		// Ensure automatic window tabbing is enabled so windows can be grouped
		// into tabs by default. This is a global AppKit setting and should be
		// set early in the app lifecycle.
		NSWindow.allowsAutomaticWindowTabbing = true

		// When the app is terminating, snapshot any open photo windows so the
		// user's session (open photos) can be restored on next launch. This
		// is more reliable than depending solely on view lifecycle hooks
		// (onAppear/onDisappear) which may not be invoked for background
		// tabs.
		NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
			let save = UserDefaults.standard.bool(forKey: "saveOpenWindows")
			let logger = Logger(subsystem: "com.example.PictureViewer", category: "app")
			WindowStateStore.shared.markAppTerminating()
			PhotoVault.clearWorkingCopiesOnDisk()
			// Log only restorable windows/tabs. NSApplication.shared.windows
			// includes utility and system windows, so counting all windows
			// overstates the user-visible gallery/photo session.
			var photoWindowEntries: [String] = []
			for w in NSApplication.shared.windows {
				guard let representedURL = w.representedURL else { continue }
				let title = w.title.isEmpty ? "<untitled>" : w.title
				photoWindowEntries.append("\(title):\(representedURL.path)")
			}
			let galleryTabCount = WindowStateStore.shared.openGalleryFolderURLs().count
			if save {
				logger.log("App will terminate; snapshotting restorable session; galleryTabCount=\(galleryTabCount, privacy: .public) photoWindowCount=\(photoWindowEntries.count, privacy: .public)")
				if AppLogLevel.current.allows(.debug) {
					logger.debug("App will terminate; open photo window details=\(photoWindowEntries.joined(separator: ","), privacy: .public)")
				}
				WindowStateStore.shared.snapshotOpenPhotosFromSystem()
			} else {
				logger.log("App will terminate; saveOpenWindows disabled; clearing saved session; galleryTabCount=\(galleryTabCount, privacy: .public) photoWindowCount=\(photoWindowEntries.count, privacy: .public)")
				if AppLogLevel.current.allows(.debug) {
					logger.debug("App will terminate; skipped open photo window details=\(photoWindowEntries.joined(separator: ","), privacy: .public)")
				}
				WindowStateStore.shared.clearOpenPhotos()
			}
		}
	}

	var body: some Scene {
		WindowGroup {
			Group {
				if requirePasswordAtLaunch {
								if authManager.isAuthenticated {
										ContentView()
											.environmentObject(authManager)
					} else {
						LockView()
							.environmentObject(authManager)
					}
				} else {
					ContentView()
						.environmentObject(authManager)
				}
			}
			.sheet(isPresented: $isShowingAboutSheet) {
				AboutBuildView(isShowingAboutSheet: $isShowingAboutSheet)
			}
		}
		.commands {
			VaultFileCommands()
			AboutCommands(isShowingAboutSheet: $isShowingAboutSheet)
		}

		WindowGroup(id: "photo-viewer", for: URL.self) { $url in
			if requirePasswordAtLaunch {
				if authManager.isAuthenticated {
					if let url {
						FullScreenPhotoView(url: url)
					}
				} else {
					EmptyView()
				}
			} else {
				if let url {
					FullScreenPhotoView(url: url)
				}
			}
		}
		.windowStyle(.hiddenTitleBar)
		.windowResizability(.contentSize)

		// Per-folder ContentView window/tab. Open a single WindowGroup for
		// folder-based ContentView instances. For now create a plain
		// ContentView() — the restore code will load persisted snapshots as
		// needed. This avoids requiring a custom initializer on ContentView.
		WindowGroup(id: "folder", for: URL.self) { $url in
			if requirePasswordAtLaunch {
				if authManager.isAuthenticated {
					if let url {
						ContentView(initialFolder: url)
							.environmentObject(authManager)
					}
				} else {
					EmptyView()
				}
			} else {
				if let url {
					ContentView(initialFolder: url)
						.environmentObject(authManager)
				}
			}
		}
		.windowStyle(.automatic)
		.windowResizability(.contentSize)

		// Dedicated People window so users can open the People browser in a
		// separate window rather than a sheet. Use Bool as the value type so
		// it conforms to the required protocols; callers can pass `true` when
		// opening the window.
		WindowGroup(id: "people", for: Bool.self) { _ in
			PeopleView()
		}
		.windowResizability(.contentSize)

		Settings {
			if requirePasswordAtLaunch {
				if authManager.isAuthenticated {
					SettingsView()
				} else {
					LockView()
						.environmentObject(authManager)
				}
			} else {
				// If password protection is disabled, allow access to Settings
				// so the user can change other preferences.
				SettingsView()
			}
		}
	}
}

struct AboutBuildView: View {
	@Binding var isShowingAboutSheet: Bool

	var body: some View {
		VStack(spacing: 18) {
			Image(nsImage: NSApp.applicationIconImage)
				.resizable()
				.frame(width: 72, height: 72)
				.clipShape(RoundedRectangle(cornerRadius: 14))

			VStack(spacing: 4) {
				Text("Picture Viewer")
					.font(.title2)
					.fontWeight(.semibold)
				Text("Version \(BuildInfo.appVersion) (\(BuildInfo.bundleVersion))")
					.foregroundStyle(.secondary)
			}

			Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
				GridRow {
					Text("Build Date")
						.foregroundStyle(.secondary)
					Text(BuildInfo.buildTimestamp)
						.textSelection(.enabled)
				}
				GridRow {
					Text("Build ID")
						.foregroundStyle(.secondary)
					Text(BuildInfo.buildIdentifier)
						.textSelection(.enabled)
				}
			}
			.font(.system(.body, design: .monospaced))

			Button("Done") {
				isShowingAboutSheet = false
			}
			.keyboardShortcut(.defaultAction)
		}
		.padding(28)
		.frame(width: 420)
	}
}

struct AboutCommands: Commands {
	@Binding var isShowingAboutSheet: Bool

	var body: some Commands {
		CommandGroup(after: .help) {
			Button("About Picture Viewer…") {
				isShowingAboutSheet = true
			}
		}
	}
}

struct VaultFileCommands: Commands {
	@FocusedValue(\.vaultCommandActions) private var vaultActions

	var body: some Commands {
		CommandGroup(after: .newItem) {
			Button("New Vault…") {
				vaultActions?.newVault()
			}
			.disabled(vaultActions == nil)

			Button("Open Vault…") {
				vaultActions?.chooseAndOpenVault()
			}
			.disabled(vaultActions == nil)

			Button("Close Vault") {
				vaultActions?.closeVault()
			}
			.disabled(vaultActions?.canCloseVault != true)

			Button("Rename Vault…") {
				vaultActions?.renameVault()
			}
			.disabled(vaultActions?.canRenameVault != true)

			Button("Manage Vaults…") {
				vaultActions?.manageVaults()
			}
			.disabled(vaultActions == nil)
		}

		CommandGroup(after: .importExport) {
			Divider()
			Button("Import Folder to Vault…") {
				vaultActions?.importFolders()
			}
			.disabled(vaultActions == nil)

			Button("Store Selected Images in Vault") {
				vaultActions?.importSelected()
			}
			.disabled(vaultActions?.canImportSelected != true)

			Button("Open Vault") {
				vaultActions?.chooseAndOpenVault()
			}
			.disabled(vaultActions == nil)

			Button(vaultActions?.canImportSelected == true ? "Export Selected Photos…" : "Export Displayed Photos…") {
				vaultActions?.exportPhotos()
			}
			.disabled(vaultActions?.canExport != true)

			Divider()

			Button("Sync to Tab…") {
				vaultActions?.syncToTab()
			}
			.disabled(vaultActions?.canSyncToTab != true)
		}

		CommandGroup(replacing: .pasteboard) {
			Button("Copy") {
				vaultActions?.copy()
			}
			.keyboardShortcut("c", modifiers: .command)
			.disabled(vaultActions?.canCopy != true)

			Button("Paste") {
				vaultActions?.paste()
			}
			.keyboardShortcut("v", modifiers: .command)
			.disabled(vaultActions?.canPaste != true)

			Button("Select All") {
				vaultActions?.selectAll()
			}
			.keyboardShortcut("a", modifiers: .command)
			.disabled(vaultActions?.canSelectAll != true)
		}
	}
}
