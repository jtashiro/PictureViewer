//
//  WindowStateStore.swift
//  PictureViewer
//
//  Persists the user's chosen folder (as a security-scoped bookmark) and
//  the list of currently open photo windows, so the next launch can
//  restore the previous session when the matching Settings toggle is on.
//

import Foundation
import AppKit
import os

private let windowStateLogger = Logger(subsystem: "com.example.PictureViewer", category: "window-state")

final class WindowStateStore: @unchecked Sendable {
	static let shared = WindowStateStore()

	private let bookmarkKey = "savedFolderBookmark"
	private let openWindowsKey = "openPhotoPaths"
	private let tabNamePrefix = "tabName:" // prefix for per-folder tab name storage

	private let queueLock = NSLock()
	private var activeFolderURL: URL?
	private var didRestoreThisLaunch = false

	private init() {}

	/// True after the first ContentView at launch has consumed the
	/// persisted session. Used to prevent subsequent windows (e.g. File →
	/// New) from re-applying the saved folder.
	func consumeLaunchRestoration() -> Bool {
		queueLock.lock(); defer { queueLock.unlock() }
		if didRestoreThisLaunch { return false }
		didRestoreThisLaunch = true
		return true
	}

	// MARK: - Folder bookmark (sandbox-safe)

	/// Records the folder the user picked and stores a security-scoped
	/// bookmark so we can re-open it on the next launch.
	func saveActiveFolder(_ url: URL) {
		queueLock.lock()
		defer { queueLock.unlock() }
		if activeFolderURL != url {
			activeFolderURL?.stopAccessingSecurityScopedResource()
			activeFolderURL = url
		}
		do {
			let bookmark = try url.bookmarkData(
				options: [.withSecurityScope],
				includingResourceValuesForKeys: nil,
				relativeTo: nil
			)
			UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
		} catch {
			// Not worth surfacing — restoration just won't be possible.
		}
	}

	/// If the persisted "last active folder" bookmark resolves to `url`,
	/// clear it so launch-time restoration won't reopen that folder. Also
	/// drops the in-process `activeFolderURL` reference if it matches.
	func clearSavedFolderIfMatches(_ url: URL) {
		queueLock.lock()
		defer { queueLock.unlock() }
		if activeFolderURL == url {
			activeFolderURL?.stopAccessingSecurityScopedResource()
			activeFolderURL = nil
		}
		guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
		var stale = false
		if let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
		   resolved == url {
			UserDefaults.standard.removeObject(forKey: bookmarkKey)
		}
	}

	/// Resolves the saved bookmark, activates the security scope, and
	/// returns the URL. Returns nil if there's no saved bookmark or if it
	/// can no longer be resolved (e.g. folder was moved/deleted).
	func resolveSavedFolder() -> URL? {
		queueLock.lock()
		defer { queueLock.unlock() }
		if let active = activeFolderURL {
			return active
		}
		guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
		var isStale = false
		do {
			let url = try URL(
				resolvingBookmarkData: data,
				options: [.withSecurityScope],
				relativeTo: nil,
				bookmarkDataIsStale: &isStale
			)
			guard url.startAccessingSecurityScopedResource() else { return nil }
			activeFolderURL = url
			if isStale {
				if let refreshed = try? url.bookmarkData(
					options: [.withSecurityScope],
					includingResourceValuesForKeys: nil,
					relativeTo: nil
				) {
					UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
				}
			}
			return url
		} catch {
			return nil
		}
	}

	// MARK: - Open photo windows

	func recordOpenPhoto(_ url: URL) {
		queueLock.lock(); defer { queueLock.unlock() }
		var paths = currentPaths()
		let path = url.path
		if !paths.contains(path) {
			paths.append(path)
			UserDefaults.standard.set(paths, forKey: openWindowsKey)
		}
	}

	func recordClosedPhoto(_ url: URL) {
		queueLock.lock(); defer { queueLock.unlock() }
		var paths = currentPaths()
		paths.removeAll { $0 == url.path }
		UserDefaults.standard.set(paths, forKey: openWindowsKey)
	}

	func openPhotoURLs() -> [URL] {
		queueLock.lock(); defer { queueLock.unlock() }
		return currentPaths().map { URL(fileURLWithPath: $0) }
	}

	/// Scans the running app's windows and records any windows that have a
	/// representedURL (set by photo windows). This is used at quit time to
	/// capture the complete set of open photo windows (including those in
	/// background tabs) so they can be restored on the next launch.
	func snapshotOpenPhotosFromSystem() {
		queueLock.lock(); defer { queueLock.unlock() }
		var paths: [String] = []
		var entries: [String] = []
		for window in NSApplication.shared.windows {
			if let url = window.representedURL {
				let path = url.path
				if !paths.contains(path) {
					paths.append(path)
				}
				let title = window.title.isEmpty ? "<untitled>" : window.title
				entries.append("\(title):\(path)")
			}
		}
		if !entries.isEmpty {
			windowStateLogger.log("snapshotOpenPhotosFromSystem captured windowCount=\(entries.count, privacy: .public)")
			if AppLogLevel.current.allows(.debug) {
				windowStateLogger.debug("snapshotOpenPhotosFromSystem captured windows=\(entries.joined(separator: ","), privacy: .public)")
			}
		} else {
			windowStateLogger.log("snapshotOpenPhotosFromSystem found no represented photo windows")
		}
		UserDefaults.standard.set(paths, forKey: openWindowsKey)
	}

	/// Snapshot the tabs belonging to a single window (the window being
	/// closed). This records any represented URLs from the window and its
	/// tabbed windows so closing a tabbed group persists all open photos.
	func snapshotTabs(of window: NSWindow) {
		queueLock.lock(); defer { queueLock.unlock() }
		var paths = currentPaths()
		var entries: [String] = []
		// Include the main window plus any tabbed windows in the same group.
		var group: [NSWindow] = [window]
		if let tabs = window.tabbedWindows {
			group.append(contentsOf: tabs)
		}
		for w in group {
			if let url = w.representedURL {
				let path = url.path
				if !paths.contains(path) {
					paths.append(path)
				}
				let title = w.title.isEmpty ? "<untitled>" : w.title
				entries.append("\(title):\(path)")
			}
		}
		if !entries.isEmpty {
			windowStateLogger.log("snapshotTabs captured windowCount=\(entries.count, privacy: .public)")
			if AppLogLevel.current.allows(.debug) {
				windowStateLogger.debug("snapshotTabs captured windows=\(entries.joined(separator: ","), privacy: .public)")
			}
		}
		UserDefaults.standard.set(paths, forKey: openWindowsKey)
	}

	// MARK: - Per-folder tab name persistence

	func saveTabName(forFolderPath folderPath: String, name: String) {
		queueLock.lock(); defer { queueLock.unlock() }
		let key = tabNamePrefix + PhotoLibrary.safeFilename(for: folderPath)
		UserDefaults.standard.set(name, forKey: key)
	}

	func loadTabName(forFolderPath folderPath: String) -> String? {
		queueLock.lock(); defer { queueLock.unlock() }
		let key = tabNamePrefix + PhotoLibrary.safeFilename(for: folderPath)
		return UserDefaults.standard.string(forKey: key)
	}

	func clearOpenPhotos() {
		queueLock.lock(); defer { queueLock.unlock() }
		UserDefaults.standard.removeObject(forKey: openWindowsKey)
	}

	private func currentPaths() -> [String] {
		UserDefaults.standard.stringArray(forKey: openWindowsKey) ?? []
	}
}
