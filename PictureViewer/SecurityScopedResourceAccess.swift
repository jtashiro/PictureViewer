import Foundation
import os

enum SecurityScopedResourceAccess {
	nonisolated private static let logger = Logger(subsystem: "com.example.PictureViewer", category: "security-scope")
	nonisolated private static let lock = NSLock()
	nonisolated(unsafe) private static var activeURLs: [URL] = []

	nonisolated static func ensureAccess(for url: URL) -> Bool {
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

		return isWritableWithoutSecurityScope(standardizedURL)
	}

	nonisolated private static func isWritableWithoutSecurityScope(_ url: URL) -> Bool {
		let fm = FileManager.default
		let directory = writableDirectory(containing: url)
		do {
			try fm.createDirectory(at: directory, withIntermediateDirectories: true)
			return fm.isWritableFile(atPath: directory.path)
		} catch {
			logger.error("security scope: path is not writable path=\(directory.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
			return false
		}
	}

	nonisolated private static func writableDirectory(containing url: URL) -> URL {
		let fm = FileManager.default
		var isDirectory: ObjCBool = false
		let path = url.standardizedFileURL.path
		if fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
			return url.standardizedFileURL
		}
		return url.deletingLastPathComponent().standardizedFileURL
	}

	nonisolated private static func startAccessing(_ url: URL) -> Bool {
		guard url.startAccessingSecurityScopedResource() else { return false }
		lock.lock()
		if !activeURLs.contains(url) {
			activeURLs.append(url)
		}
		lock.unlock()
		return true
	}

	nonisolated private static func resolvePersistedBookmark(for url: URL) -> Bool {
		let bookmarkLists = [
			UserDefaults.standard.data(forKey: AppWorkingDirectory.directoryBookmarkKey).map { [$0] },
			UserDefaults.standard.data(forKey: SQLiteObjectStore.databaseBookmarkKey).map { [$0] },
			UserDefaults.standard.data(forKey: SQLiteObjectStore.directoryBookmarkKey).map { [$0] },
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
