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

	enum GallerySessionItem {
		case folder(URL)
		case sqliteStore(String)
	}

	private let bookmarkKey = "savedFolderBookmark"
	private let openWindowsKey = "openPhotoPaths"
	private let openGalleryBookmarksKey = "openGalleryFolderBookmarks"
	private let tabNamePrefix = "tabName:" // prefix for per-folder tab name storage

	private let queueLock = NSLock()
	private var activeFolderURL: URL?
	private var didRestoreThisLaunch = false
	private var appIsTerminating = false

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

	func markAppTerminating() {
		queueLock.lock(); defer { queueLock.unlock() }
		appIsTerminating = true
	}

	func isAppTerminating() -> Bool {
		queueLock.lock(); defer { queueLock.unlock() }
		return appIsTerminating
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
			NotificationCenter.default.post(name: .fileNavigationMenuShouldReload, object: nil)
		}
	}

	func recordClosedPhoto(_ url: URL) {
		queueLock.lock(); defer { queueLock.unlock() }
		var paths = currentPaths()
		paths.removeAll { $0 == url.path }
		UserDefaults.standard.set(paths, forKey: openWindowsKey)
		NotificationCenter.default.post(name: .fileNavigationMenuShouldReload, object: nil)
	}

	func openPhotoURLs() -> [URL] {
		queueLock.lock(); defer { queueLock.unlock() }
		return currentPaths().map { URL(fileURLWithPath: $0) }
	}

	func recordOpenGalleryFolder(_ url: URL) {
		queueLock.lock(); defer { queueLock.unlock() }
		let path = url.standardizedFileURL.path
		var entries = openGalleryBookmarkEntries()
		if entries.contains(where: { $0.kindValue == GalleryBookmarkEntry.folderKind && $0.path == path }) { return }
		do {
			let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
			entries.append(GalleryBookmarkEntry(path: path, bookmark: bookmark))
			UserDefaults.standard.set(try JSONEncoder().encode(entries), forKey: openGalleryBookmarksKey)
		} catch {
			windowStateLogger.error("recordOpenGalleryFolder failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
		}
	}

	func recordOpenSQLiteStore(named storeName: String) {
		queueLock.lock(); defer { queueLock.unlock() }
		let trimmed = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		var entries = openGalleryBookmarkEntries()
		if entries.contains(where: { $0.kindValue == GalleryBookmarkEntry.sqliteKind && $0.storeName == trimmed }) { return }
		entries.append(GalleryBookmarkEntry(sqliteStoreName: trimmed))
		persistOpenGalleryBookmarkEntries(entries)
	}

	func recordClosedGalleryFolder(_ url: URL) {
		queueLock.lock(); defer { queueLock.unlock() }
		let path = url.standardizedFileURL.path
		var entries = openGalleryBookmarkEntries()
		entries.removeAll { $0.kindValue == GalleryBookmarkEntry.folderKind && $0.path == path }
		persistOpenGalleryBookmarkEntries(entries)
	}

	func recordClosedSQLiteStore(named storeName: String) {
		queueLock.lock(); defer { queueLock.unlock() }
		let trimmed = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
		var entries = openGalleryBookmarkEntries()
		entries.removeAll { $0.kindValue == GalleryBookmarkEntry.sqliteKind && $0.storeName == trimmed }
		persistOpenGalleryBookmarkEntries(entries)
	}

	func openGalleryFolderURLs() -> [URL] {
		queueLock.lock(); defer { queueLock.unlock() }
		var resolved: [URL] = []
		var refreshed: [GalleryBookmarkEntry] = []
		for entry in openGalleryBookmarkEntries() {
			guard entry.kindValue == GalleryBookmarkEntry.folderKind,
				  let bookmark = entry.bookmark
			else {
				refreshed.append(entry)
				continue
			}
			var stale = false
			do {
				let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
				_ = url.startAccessingSecurityScopedResource()
				let refreshedBookmark = stale
					? (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? bookmark
					: bookmark
				resolved.append(url)
				refreshed.append(GalleryBookmarkEntry(path: url.standardizedFileURL.path, bookmark: refreshedBookmark))
			} catch {
				windowStateLogger.error("openGalleryFolderURLs failed path=\(entry.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
			}
		}
		if refreshed.count != openGalleryBookmarkEntries().count {
			persistOpenGalleryBookmarkEntries(refreshed)
		}
		return resolved
	}

	func openGallerySessionItems() -> [GallerySessionItem] {
		queueLock.lock(); defer { queueLock.unlock() }
		var restored: [GallerySessionItem] = []
		var refreshed: [GalleryBookmarkEntry] = []
		for entry in openGalleryBookmarkEntries() {
			if entry.kindValue == GalleryBookmarkEntry.sqliteKind {
				if let storeName = entry.storeName, !storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					restored.append(.sqliteStore(storeName))
					refreshed.append(entry)
				}
				continue
			}

			guard let bookmark = entry.bookmark else { continue }
			var stale = false
			do {
				let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
				_ = url.startAccessingSecurityScopedResource()
				let refreshedBookmark = stale
					? (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? bookmark
					: bookmark
				restored.append(.folder(url))
				refreshed.append(GalleryBookmarkEntry(path: url.standardizedFileURL.path, bookmark: refreshedBookmark))
			} catch {
				windowStateLogger.error("openGallerySessionItems failed path=\(entry.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
			}
		}
		if refreshed.count != openGalleryBookmarkEntries().count {
			persistOpenGalleryBookmarkEntries(refreshed)
		}
		return restored
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
		NotificationCenter.default.post(name: .fileNavigationMenuShouldReload, object: nil)
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
		NotificationCenter.default.post(name: .fileNavigationMenuShouldReload, object: nil)
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
		UserDefaults.standard.removeObject(forKey: openGalleryBookmarksKey)
	}

	private func currentPaths() -> [String] {
		UserDefaults.standard.stringArray(forKey: openWindowsKey) ?? []
	}

	private struct GalleryBookmarkEntry: Codable {
		static let folderKind = "folder"
		static let sqliteKind = "sqlite"

		let path: String
		let bookmark: Data?
		let kind: String?
		let storeName: String?

		var kindValue: String {
			kind ?? Self.folderKind
		}

		init(path: String, bookmark: Data) {
			self.path = path
			self.bookmark = bookmark
			self.kind = Self.folderKind
			self.storeName = nil
		}

		init(sqliteStoreName: String) {
			self.path = "sqlite:\(sqliteStoreName)"
			self.bookmark = nil
			self.kind = Self.sqliteKind
			self.storeName = sqliteStoreName
		}
	}

	private func openGalleryBookmarkEntries() -> [GalleryBookmarkEntry] {
		guard let data = UserDefaults.standard.data(forKey: openGalleryBookmarksKey),
			  let entries = try? JSONDecoder().decode([GalleryBookmarkEntry].self, from: data)
		else { return [] }
		return entries
	}

	private func persistOpenGalleryBookmarkEntries(_ entries: [GalleryBookmarkEntry]) {
		if entries.isEmpty {
			UserDefaults.standard.removeObject(forKey: openGalleryBookmarksKey)
			return
		}
		if let data = try? JSONEncoder().encode(entries) {
			UserDefaults.standard.set(data, forKey: openGalleryBookmarksKey)
		}
	}
}
