//
//  FileNavigationMenuState.swift
//  PictureViewer
//

import Combine
@preconcurrency import Foundation
import os

private let fileNavigationLogger = Logger(subsystem: "com.example.PictureViewer", category: "file-navigation")

@MainActor
final class FileNavigationMenuState: ObservableObject {
	static let shared = FileNavigationMenuState()

	struct FolderEntry: Identifiable, Hashable {
		let id: String
		let url: URL
		let title: String
	}

	enum SessionEntry: Identifiable, Hashable {
		case galleryFolder(URL)
		case gallerySQLite(String)
		case photo(URL)

		var id: String {
			switch self {
			case .galleryFolder(let url): "gallery:\(url.standardizedFileURL.path)"
			case .gallerySQLite(let name): "sqlite:\(name)"
			case .photo(let url): "photo:\(url.path)"
			}
		}

		var title: String {
			switch self {
			case .galleryFolder(let url): url.lastPathComponent
			case .gallerySQLite(let name): name
			case .photo(let url): url.lastPathComponent
			}
		}
	}

	@Published private(set) var recentFolders: [FolderEntry] = []
	@Published private(set) var bookmarks: [FolderEntry] = []
	@Published private(set) var sessionEntries: [SessionEntry] = []

	nonisolated(unsafe) private var reloadObserver: NSObjectProtocol?

	private init() {
		reloadObserver = NotificationCenter.default.addObserver(
			forName: .fileNavigationMenuShouldReload,
			object: nil,
			queue: .main
		) { _ in
			Task { @MainActor in
				FileNavigationMenuState.shared.reload()
			}
		}
	}

	nonisolated deinit {
		if let reloadObserver {
			NotificationCenter.default.removeObserver(reloadObserver)
		}
	}

	func reload() {
		recentFolders = Self.resolveFolderBookmarks(
			from: Self.recentBookmarkData(),
			logger: fileNavigationLogger
		)
		bookmarks = Self.resolveFolderBookmarks(
			from: UserDefaults.standard.array(forKey: ContentView.kKnownFolderBookmarks) as? [Data] ?? [],
			logger: fileNavigationLogger
		)
		sessionEntries = Self.resolveSessionEntries()
	}

	private static func recentBookmarkData() -> [Data] {
		var data = UserDefaults.standard.array(forKey: ContentView.kLastFolderBookmarks) as? [Data] ?? []
		if data.isEmpty, let legacy = UserDefaults.standard.data(forKey: ContentView.kLastFolderBookmark) {
			data = [legacy]
		}
		return data
	}

	private static func resolveFolderBookmarks(from bookmarkDataList: [Data], logger: Logger) -> [FolderEntry] {
		var entries: [FolderEntry] = []
		var seenPaths: Set<String> = []
		for bookmarkData in bookmarkDataList.reversed() {
			var stale = false
			do {
				let url = try URL(
					resolvingBookmarkData: bookmarkData,
					options: [.withSecurityScope],
					relativeTo: nil,
					bookmarkDataIsStale: &stale
				)
				_ = url.startAccessingSecurityScopedResource()
				let path = url.standardizedFileURL.path
				guard seenPaths.insert(path).inserted else { continue }
				entries.append(FolderEntry(id: path, url: url, title: url.lastPathComponent))
			} catch {
				logger.error("file navigation: failed to resolve bookmark error=\(error.localizedDescription, privacy: .public)")
			}
		}
		return entries
	}

	private static func resolveSessionEntries() -> [SessionEntry] {
		var entries: [SessionEntry] = []
		for item in WindowStateStore.shared.openGallerySessionItems() {
			switch item {
			case .folder(let url):
				entries.append(.galleryFolder(url))
			case .sqliteStore(let storeName):
				entries.append(.gallerySQLite(storeName))
			}
		}
		for url in WindowStateStore.shared.openPhotoURLs() {
			entries.append(.photo(url))
		}
		return entries
	}
}