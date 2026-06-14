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
		_ = AppWorkingDirectory.ensureAccess()
		// Touch the lazy CPU detection so the worker count is computed at launch.
		_ = PhotoLibrary.workerCount
		let logger = Logger(subsystem: "com.example.PictureViewer", category: "app")
		let embeddedVLCIsAvailable = EmbeddedVLCPlayerView.isAvailable
		EmbeddedVLCPlayerView.logAvailabilityResult(context: "app launch")
		if embeddedVLCIsAvailable {
			UserDefaults.standard.set(true, forKey: AppSettingsKey.useVLCForVideoPlayback)
			logger.log("vlc embedded: auto-enabled setting useVLCForVideoPlayback=true at launch")
		} else {
			let currentSetting = UserDefaults.standard.bool(forKey: AppSettingsKey.useVLCForVideoPlayback)
			logger.log("vlc embedded: not auto-enabling setting at launch; embedded runtime unavailable currentSetting=\(currentSetting, privacy: .public)")
		}
		// Respect a runtime toggle to defer potentially expensive background
		// work at launch while debugging responsiveness. Set the UserDefault
		// key "deferAtLaunchBackgroundWork" to false to re-enable the
		// default background work (thumbnail cache sweep).
		let deferAtLaunch = UserDefaults.standard.object(forKey: AppSettingsKey.deferAtLaunchBackgroundWork) as? Bool ?? true
		if deferAtLaunch {
			logger.log("Deferring at-launch background work: thumbnail sweep disabled")
		} else {
			// Refresh the persistent thumbnail cache in the background — drop
			// entries we haven't used recently so the cache stays bounded.
			Task.detached(priority: .background) {
				ThumbnailCache.shared.sweepStale()
			}
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
		NotificationCenter.default.addObserver(
			forName: NSApplication.willTerminateNotification,
			object: nil,
			queue: .main
		) { _ in
			MainActor.assumeIsolated {
				Self.snapshotSessionOnTermination()
			}
		}
	}

	@MainActor
	private static func snapshotSessionOnTermination() {
		let save = UserDefaults.standard.bool(forKey: AppSettingsKey.saveOpenWindows)
		let logger = Logger(subsystem: "com.example.PictureViewer", category: "app")
		WindowStateStore.shared.markAppTerminating()
		PhotoVault.clearWorkingCopiesOnDisk()
		SQLiteObjectStore.clearWorkingCopiesOnDisk()
		var photoWindowEntries: [String] = []
		for w in NSApplication.shared.windows {
			guard let representedURL = w.representedURL else { continue }
			let title = w.title.isEmpty ? "<untitled>" : w.title
			photoWindowEntries.append("\(title):\(representedURL.path)")
		}
		let galleryTabCount = WindowStateStore.shared.openGallerySessionItems().count
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
			ViewDisplayCommands()
			WindowMergeCommands()
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

		WindowGroup(id: "sqlite-store", for: String.self) { $openToken in
			if requirePasswordAtLaunch {
				if authManager.isAuthenticated {
					if let openToken {
						ContentView(initialSQLiteOpenToken: openToken)
							.environmentObject(authManager)
					}
				} else {
					EmptyView()
				}
			} else {
				if let openToken {
					ContentView(initialSQLiteOpenToken: openToken)
						.environmentObject(authManager)
				}
			}
		}
		.windowStyle(.automatic)
		.windowResizability(.contentSize)

		// Single People window — repeated open requests focus the existing one.
		Window("People", id: "people") {
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

@MainActor
enum PeopleWindowPresenter {
	static let windowIdentifier = NSUserInterfaceItemIdentifier("people-window")

	static func show(using openWindow: OpenWindowAction) {
		if focusExistingWindow() { return }
		openWindow(id: "people")
	}

	@discardableResult
	static func focusExistingWindow() -> Bool {
		let peopleWindows = NSApp.windows.filter {
			$0.identifier == windowIdentifier || $0.title == "People"
		}
		guard let window = peopleWindows.first else { return false }
		if window.isMiniaturized {
			window.deminiaturize(nil)
		}
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		return true
	}
}

@MainActor
enum PictureViewerWindowTabber {
	static func mergeAllWindows() {
		let windows = NSApp.windows.filter(isMergeEligible)
		guard let target = NSApp.keyWindow.flatMap({ isMergeEligible($0) ? $0 : nil })
			?? NSApp.mainWindow.flatMap({ isMergeEligible($0) ? $0 : nil })
			?? windows.first
		else {
			return
		}

		target.tabbingMode = .preferred
		target.tabbingIdentifier = "PictureViewerMergedWindows"
		for window in windows where window !== target {
			window.tabbingMode = .preferred
			window.tabbingIdentifier = target.tabbingIdentifier
			if !windowsAreAlreadyTabbed(target, window) {
				target.addTabbedWindow(window, ordered: .above)
			}
		}
		target.makeKeyAndOrderFront(nil)
	}

	private static func isMergeEligible(_ window: NSWindow) -> Bool {
		guard window.isVisible,
			  !window.isMiniaturized,
			  window.canBecomeMain,
			  !(window is NSPanel),
			  !window.styleMask.contains(.fullScreen),
			  window.sheetParent == nil
		else {
			return false
		}
		return true
	}

	private static func windowsAreAlreadyTabbed(_ a: NSWindow, _ b: NSWindow) -> Bool {
		if let group = a.tabGroup {
			return group.windows.contains { $0 === b }
		}
		return false
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

struct WindowMergeCommands: Commands {
	var body: some Commands {
		CommandGroup(after: .windowArrangement) {
			Button("Merge All Windows") {
				PictureViewerWindowTabber.mergeAllWindows()
			}
		}
	}
}

/// View menu toggles that control which metadata strings appear under each
/// thumbnail in the grid. The two toggles are independent.
struct ViewDisplayCommands: Commands {
	@AppStorage(AppSettingsKey.displayDescriptionInGrid) private var displayDescriptionInGrid: Bool = false
	@AppStorage(AppSettingsKey.displayKeywordsInGrid) private var displayKeywordsInGrid: Bool = false

	var body: some Commands {
		CommandGroup(after: .toolbar) {
			Toggle("Display Description", isOn: $displayDescriptionInGrid)
			Toggle("Display Keywords", isOn: $displayKeywordsInGrid)
		}
	}
}

struct VaultFileCommands: Commands {
	@ObservedObject private var fileNavigation = FileNavigationMenuState.shared
	@FocusedValue(\.vaultCommandActions) private var vaultActions
	@FocusedValue(\.fileNavigationActions) private var fileNavigationActions
	@Environment(\.openWindow) private var openWindow

	var body: some Commands {
		CommandGroup(after: .newItem) {
				Button("New…") {
					vaultActions?.newItem()
				}
				.disabled(vaultActions == nil)

				Button("Open…") {
					vaultActions?.openItem()
				}
				.disabled(vaultActions == nil)

				Menu("Open Recent") {
					ForEach(fileNavigation.recentFolders) { entry in
						Button(entry.title) {
							openFolderEntry(entry)
						}
					}
					if fileNavigation.recentFolders.isEmpty {
						Button("No Recent Folders") {}
							.disabled(true)
					}
				}

				Menu("Bookmarks") {
					ForEach(fileNavigation.bookmarks) { entry in
						Button(entry.title) {
							openFolderEntry(entry)
						}
					}
					if fileNavigation.bookmarks.isEmpty {
						Button("No Bookmarks") {}
							.disabled(true)
					}
					Divider()
					Button("Manage Bookmarks…") {
						fileNavigationActions?.showBookmarkManager()
					}
					.disabled(fileNavigationActions == nil)
				}

				Menu("Open Session") {
					ForEach(fileNavigation.sessionEntries) { entry in
						Button(entry.title) {
							openSessionEntry(entry)
						}
					}
					if fileNavigation.sessionEntries.isEmpty {
						Button("No Saved Session") {}
							.disabled(true)
					}
					Divider()
					Button("Restore Gallery Session") {
						fileNavigationActions?.restoreSavedGallerySession()
					}
					.disabled(fileNavigation.sessionEntries.isEmpty || fileNavigationActions == nil)
				}

				Divider()

				Button("Rename…") {
					vaultActions?.renameVault()
				}
				.disabled(vaultActions?.canRenameVault != true)

				Button("Manage…") {
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

			Button("Export Photos…") {
				vaultActions?.exportPhotos()
			}
			.disabled(vaultActions?.canExport != true)

			Divider()

			Button("Sync to Tab…") {
				vaultActions?.syncToTab()
			}
			.disabled(vaultActions?.canSyncToTab != true)

			Button("Sync Tab to SQLite Store…") {
				vaultActions?.syncToSQLiteStore()
			}
			.disabled(vaultActions?.canSyncToSQLiteStore != true)

			Button("Store Selected in SQLite Store…") {
				vaultActions?.syncSelectedToSQLiteStore()
			}
			.disabled(vaultActions?.canSyncSelectedToSQLiteStore != true)

			Button("Backfill Missing SQLite Thumbnails…") {
				vaultActions?.backfillSQLiteThumbnails()
			}
			.disabled(vaultActions?.canBackfillSQLiteThumbnails != true)

			Divider()

			Button("Recognize Displayed Images with Ollama") {
				vaultActions?.recognizeDisplayed()
			}
			.disabled(vaultActions?.canRecognize != true)

			Button("Recognize Selected Images with Ollama") {
				vaultActions?.recognizeSelected()
			}
			.disabled(vaultActions?.canRecognizeSelected != true)

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

	private func openFolderEntry(_ entry: FileNavigationMenuState.FolderEntry) {
		if let actions = fileNavigationActions {
			actions.openFolder(entry.url)
		} else {
			_ = entry.url.startAccessingSecurityScopedResource()
			openWindow(id: "folder", value: entry.url)
		}
	}

	private func openSessionEntry(_ entry: FileNavigationMenuState.SessionEntry) {
		switch entry {
		case .galleryFolder(let url):
			if let actions = fileNavigationActions {
				actions.openFolder(url)
			} else {
				_ = url.startAccessingSecurityScopedResource()
				openWindow(id: "folder", value: url)
			}
		case .gallerySQLite(let storeName):
			if let actions = fileNavigationActions {
				actions.openSQLiteStore(storeName)
			} else {
				let requestID = SQLiteStoreOpenRequestCoordinator.shared.requestOpen(storeName: storeName)
				openWindow(
					id: "sqlite-store",
					value: SQLiteObjectStore.openToken(storeName: storeName, requestID: requestID)
				)
			}
		case .photo(let url):
			if let actions = fileNavigationActions {
				actions.openPhoto(url)
			} else {
				openWindow(id: "photo-viewer", value: url)
			}
		}
	}
}
