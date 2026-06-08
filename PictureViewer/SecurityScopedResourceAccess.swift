import Foundation
import os

enum SecurityScopedResourceAccess {
	private static let logger = Logger(subsystem: "com.example.PictureViewer", category: "security-scope")
	private static let lock = NSLock()
	private static var activeURLs: [URL] = []

	static func ensureAccess(for url: URL) -> Bool {
		let standardizedURL = url.standardizedFileURL
		lock.lock()
		if activeURLs.contains(where: { standardizedURL.path.hasPrefix($0.standardizedFileURL.path) }) {
			lock.unlock()
			return true
		}
		lock.unlock()

		if startAccessing(standardizedURL) {
			return true
		}

		if startAccessing(standardizedURL.deletingLastPathComponent()) {
			return true
		}

		if resolvePersistedBookmark(for: standardizedURL) {
			return true
		}

		return false
	}

	private static func startAccessing(_ url: URL) -> Bool {
		guard url.startAccessingSecurityScopedResource() else { return false }
		lock.lock()
		if !activeURLs.contains(url) {
			activeURLs.append(url)
		}
		lock.unlock()
		return true
	}

	private static func resolvePersistedBookmark(for url: URL) -> Bool {
		let bookmarkLists = [
			UserDefaults.standard.array(forKey: "lastFolderBookmarks") as? [Data],
			UserDefaults.standard.data(forKey: "lastFolderBookmark").map { [$0] }
		]

		for bookmarks in bookmarkLists.compactMap({ $0 }) {
			for bookmark in bookmarks {
				var stale = false
				do {
					let resolved = try URL(
						resolvingBookmarkData: bookmark,
						options: .withSecurityScope,
						relativeTo: nil,
						bookmarkDataIsStale: &stale
					)
					if startAccessing(resolved), url.path.hasPrefix(resolved.standardizedFileURL.path) {
						return true
					}
				} catch {
					logger.error("security scope: failed to resolve bookmark error=\(error.localizedDescription, privacy: .public)")
				}
			}
		}
		return false
	}
}
