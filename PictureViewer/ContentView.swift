//  ContentView.swift
//  PictureViewer
//
//  Created by John Tashiro on 6/3/26.
//

import SwiftUI
import AppKit
import CoreImage
import ImageIO
import CryptoKit
import os
import UniformTypeIdentifiers

private struct PhotoGridSection: Identifiable {
	let id: String
	let title: String
	let photos: [PhotoItem]
}

struct ContentView: View {
	@StateObject private var library = PhotoLibrary()
	@StateObject private var faceScanProgress = FaceScanProgress.shared
	@ObservedObject private var ollamaProgress = OllamaProgress.shared
	@StateObject private var personFilterState = PersonFilterState.shared
	@State private var thumbnailSize: CGFloat = 160
	@AppStorage("sortMode") private var sortModeRaw: Int = 0
	@AppStorage("groupGridByDescription") private var groupGridByDescription = false
	private enum SortMode: Int, CaseIterable, Identifiable {
		case alphaAsc = 0
		case alphaDesc = 1
		case fileDate = 2
		case imageDate = 3
		case descriptionAsc = 4
		case descriptionDesc = 5

		var id: Int { rawValue }
		var title: String {
			switch self {
			case .alphaAsc: return "Name ↑"
			case .alphaDesc: return "Name ↓"
			case .fileDate: return "File Date"
			case .imageDate: return "Image Date"
			case .descriptionAsc: return "Description ↑"
			case .descriptionDesc: return "Description ↓"
			}
		}
	}

	private enum KeywordEditOperation: Sendable {
		case append
		case replace
		case clear
	}

	@State private var initialFolderURL: URL?
	@State private var initialSQLiteOpenToken: String?
	@State private var tabID = UUID()
	@State private var registeredGalleryFolderURL: URL?
	@State private var registeredSQLiteStoreName: String?
	@State private var activeSQLiteStoreName: String?

	init(initialFolder: URL? = nil, initialSQLiteOpenToken: String? = nil) {
		_initialFolderURL = State(initialValue: initialFolder)
		_initialSQLiteOpenToken = State(initialValue: initialSQLiteOpenToken)
	}

	private var resolvedInitialSQLiteStoreName: String? {
		guard let token = initialSQLiteOpenToken else { return nil }
		return SQLiteObjectStore.storeName(fromOpenToken: token)
	}

	/// Restore a persisted security-scoped bookmark (if present) and start
	/// accessing the resource so the app can write into the folder while
	/// sandboxed. This is safe to call at startup.
	private func restoreFolderBookmarkIfNeeded(library: PhotoLibrary, logger: Logger) async -> Bool {
		guard saveOpenWindows else {
			logger.log("launch folder restore: result=skipped reason=saveOpenWindows-disabled")
			return false
		}

		let sessionItems = Self.uniqueGallerySessionItems(WindowStateStore.shared.openGallerySessionItems())
		if !sessionItems.isEmpty {
				logger.log("launch gallery restore: source=open-gallery-tabs itemCount=\(sessionItems.count, privacy: .public)")
				await MainActor.run {
					for (index, item) in sessionItems.enumerated() {
						switch item {
						case .folder(let url):
							if index == 0 {
								if !tryOpenFolderAsVault(url) {
									library.folderURL = url
									activeFolderNames = [url.lastPathComponent]
									library.scan(folder: url)
								}
							} else {
								logger.log("launch gallery restore: source=open-gallery-tabs action=open-folder-tab folder=\(url.path, privacy: .public)")
								openWindow(id: "folder", value: url)
							}
						case .sqliteStore(let storeName):
							if index == 0 {
								openSQLiteObjectStore(named: storeName)
							} else {
								logger.log("launch gallery restore: source=open-gallery-tabs action=open-sqlite-tab store=\(storeName, privacy: .public)")
								let requestID = SQLiteStoreOpenRequestCoordinator.shared.requestOpen(storeName: storeName)
								openWindow(
									id: "sqlite-store",
									value: SQLiteObjectStore.openToken(storeName: storeName, requestID: requestID)
								)
							}
						}
					}
				}
				return true
		}

		// Prefer multi-bookmark list if available.
		if let arr = UserDefaults.standard.array(forKey: Self.kLastFolderBookmarks) as? [Data], !arr.isEmpty {
			var resolvedFolders: [URL] = []
			var seenPaths: Set<String> = []
			var seenNames: Set<String> = []
			var duplicateCount = 0
			for bm in arr {
				var stale = false
				do {
					let url = try URL(resolvingBookmarkData: bm, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
					if url.startAccessingSecurityScopedResource() {
						let pathInserted = seenPaths.insert(url.path).inserted
						let nameInserted = seenNames.insert(Self.normalizedBookmarkOpenName(url.lastPathComponent)).inserted
						if pathInserted && nameInserted {
							resolvedFolders.append(url)
							if AppLogLevel.current.allows(.debug) {
								logger.debug("launch folder restore: resolved bookmark path=\(url.path, privacy: .public) stale=\(stale, privacy: .public)")
							}
						} else {
							duplicateCount += 1
						}
						if !Self.activeSecurityScopedURLs.contains(url) { Self.activeSecurityScopedURLs.append(url) }
					}
				} catch {
					logger.error("restoreFolderBookmarkIfNeeded: failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
				}
			}

			guard !resolvedFolders.isEmpty else {
				logger.log("launch folder restore: source=bookmark-list result=none bookmarkCount=\(arr.count, privacy: .public)")
				return false
			}

			// Multi-bookmark restore: seed the first bookmark into THIS
			// ContentView and open additional folder windows for the rest, so
			// each bookmark becomes its own tab instead of being combined.
			let first = resolvedFolders[0]
			let rest = Array(resolvedFolders.dropFirst())
			logger.log("launch folder restore: source=bookmark-list storage=filesystem bookmarkCount=\(arr.count, privacy: .public) uniqueFolders=\(resolvedFolders.count, privacy: .public) duplicatesRemoved=\(duplicateCount, privacy: .public) primaryFolder=\(first.path, privacy: .public)")
			await MainActor.run {
				if !tryOpenFolderAsVault(first) {
					library.folderURL = first
					activeFolderNames = [first.lastPathComponent]
					library.scan(folder: first)
				}
				for url in rest {
					logger.log("launch folder restore: source=bookmark-list storage=filesystem action=open-tab folder=\(url.path, privacy: .public)")
					openWindow(id: "folder", value: url)
				}
			}
			return true
		}

		// Fallback to single-bookmark behavior for backward compatibility.
		guard let bm = UserDefaults.standard.data(forKey: Self.kLastFolderBookmark) else {
			logger.log("launch folder restore: source=legacy-bookmark result=none")
			return false
		}
		var stale = false
		do {
			let url = try URL(resolvingBookmarkData: bm, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
			if url.startAccessingSecurityScopedResource() {
				if await MainActor.run(body: { tryOpenFolderAsVault(url) }) {
					if !Self.activeSecurityScopedURLs.contains(url) { Self.activeSecurityScopedURLs.append(url) }
					logger.log("launch folder restore: source=legacy-bookmark storage=vault action=prompt folder=\(url.path, privacy: .public)")
					return true
				}
				// Don't start an immediate full scan at launch; doing so can
				// block the UI while the scanner enumerates the filesystem. Instead,
				// publish the folder and try to restore a cached snapshot (if any)
				// so the UI can populate quickly from the persisted snapshot.
				await MainActor.run {
					// Remember the resolved URL so higher-level code may use it
					// for writes that require security-scoped access. Keep a
					// persistent array of active security-scoped URLs so the
					// app can perform writes across multiple selected folders.
					if !Self.activeSecurityScopedURLs.contains(url) { Self.activeSecurityScopedURLs.append(url) }
					library.folderURL = url
					activeFolderNames = [url.lastPathComponent]
				}
				// Attempt to load a previously saved snapshot for this folder and
				// publish it in small batches off the main actor. This avoids a
				// costly re-scan at launch while still showing thumbnails quickly.
				Task.detached {
					if let urls = PhotoLibrary.loadCachedSnapshot(for: url) {
						var deduped: [URL] = []
						var seen: Set<String> = []
						for u in urls {
							let name = u.lastPathComponent.lowercased()
							if seen.insert(name).inserted { deduped.append(u) }
						}
						deduped.sort {
							$0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
						}
						let dedupedCount = deduped.count
						await MainActor.run {
							logger.log("launch folder restore: source=legacy-bookmark storage=cache folder=\(url.path, privacy: .public) cachedFiles=\(urls.count, privacy: .public) uniqueFiles=\(dedupedCount, privacy: .public)")
						}
						let batchSize = 512
						await MainActor.run { library.photos = [] }
						var idx = 0
						while idx < deduped.count {
							let end = min(idx + batchSize, deduped.count)
							let slice = deduped[idx..<end].map { PhotoItem(url: $0) }
							await MainActor.run {
								library.photos.append(contentsOf: slice)
								library.lastScanDate = Date()
							}
							warmFilesystemThumbnails(for: slice)

							idx = end
							try? await Task.sleep(nanoseconds: 10_000_000) // 10ms gap between batches
						}
						// Kick off a low-priority background refresh scan so the
						// UI is populated quickly from the snapshot but the on-disk
						// state is reconciled afterwards. This keeps the app
						// responsive while ensuring the snapshot is eventually
						// refreshed. The refresh is cancellable and runs at
						// background priority.
						Task.detached(priority: .background) {
							// Small delay to let the UI stabilize and avoid
							// contention on startup.
							try? await Task.sleep(nanoseconds: 1_000_000_000)
							await MainActor.run {
								// Ensure we still have the same folder before
								// starting a potentially expensive re-scan.
								if library.folderURL == url {
									// Read the AppStorage-backed flag from UserDefaults here
									// because this is a static context and instance
									// properties (like @AppStorage) aren't available.
									if UserDefaults.standard.bool(forKey: "deferAtLaunchBackgroundWork") {
										logger.log("launch folder refresh: source=legacy-bookmark storage=filesystem result=deferred folder=\(url.path, privacy: .public)")
									} else {
										logger.log("launch folder refresh: source=legacy-bookmark storage=filesystem result=started folder=\(url.path, privacy: .public)")
										library.scan(folder: url)
									}
								}
							}
						}
					} else {
						// No cached snapshot available; retain current behavior
						// of not auto-scanning at launch.
						await MainActor.run {
							logger.log("launch folder restore: source=legacy-bookmark storage=cache result=miss folder=\(url.path, privacy: .public)")
							library.folderURL = url
							activeFolderNames = [url.lastPathComponent]
						}
					}
				}
				return true
			}
		} catch {
			logger.error("restoreFolderBookmarkIfNeeded: failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
		}
		return false
	}

	/// Attempt to repair metadata for `url` by reading any existing sidecar
	/// (adjacent or app-support) and re-embedding its contents into the
	/// image file. Returns (success, errorMessage).
	static func repairMetadata(for url: URL) async -> (Bool, String?) {
		let fm = FileManager.default
		// Try adjacent sidecar first
		let scURL = sidecarURL(for: url)
		var sidecar: PVSidecar? = nil
		if fm.fileExists(atPath: scURL.path) {
			if let data = try? Data(contentsOf: scURL), let sc = try? JSONDecoder().decode(PVSidecar.self, from: data) {
				sidecar = sc
			}
		}
		// Fallback to app-support sidecar
		if sidecar == nil {
			if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
				let sidecarDir = appSupport.appendingPathComponent("PictureViewer/sidecars", isDirectory: true)
				let digest = sha256Hex(of: url.path)
				let appSidecar = sidecarDir.appendingPathComponent("\(digest).pvmeta.json")
				if fm.fileExists(atPath: appSidecar.path), let data = try? Data(contentsOf: appSidecar), let sc = try? JSONDecoder().decode(PVSidecar.self, from: data) {
					sidecar = sc
				}
			}
		}

		guard let sc = sidecar else {
			return (false, "No sidecar metadata found")
		}

		var errors: [String] = []

		// If recognition exists but no keywords, treat recognition as keywords
		let kws = sc.keywords ?? sc.recognition
		if let keywords = kws, !keywords.isEmpty {
			let ok = await writeKeywords(to: url, keywords: keywords)
			if !ok { errors.append("Failed to write keywords") }
		}

		if let deg = sc.rotationDegrees {
			if deg % 360 != 0 {
				let ok = await rotateImageFile(at: url, degrees: deg)
				if !ok { errors.append("Failed to apply rotation") }
			}
		}

		// If we succeeded in performing at least one operation, attempt to
		// remove sidecars (both adjacent and app-support) to avoid stale data.
		if errors.isEmpty {
			// remove adjacent
			try? fm.removeItem(at: scURL)
			// remove app-support
			if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
				let sidecarDir = appSupport.appendingPathComponent("PictureViewer/sidecars", isDirectory: true)
				let digest = sha256Hex(of: url.path)
				let appSidecar = sidecarDir.appendingPathComponent("\(digest).pvmeta.json")
				try? fm.removeItem(at: appSidecar)
			}
			return (true, nil)
		}

		return (false, errors.joined(separator: "; "))
	}

	// Sidecar format used as a safe fallback when embedded writes fail
	struct PVSidecar: Codable {
		var keywords: [String]?
		var rotationDegrees: Int?
		var recognition: [String]?
		var source: String?
		var timestamp: Date = Date()
		var originalPath: String?
	}

	static func sidecarURL(for url: URL) -> URL {
		return url.appendingPathExtension("pvmeta.json")
	}

	/// Write a JSON sidecar next to the image file atomically. Returns true on success.
	static func writeSidecar(for url: URL, sidecar: PVSidecar) async -> Bool {
		let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
		let fm = FileManager.default
		let scURL = sidecarURL(for: url)
		let uuid = UUID().uuidString
		let dir = scURL.deletingLastPathComponent()
		let tempFile = dir.appendingPathComponent(".pvtmp-\(uuid).pvmeta.json")
		do {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted]
			let data = try encoder.encode(sidecar)
			// Write atomically to the temp file, then move into place.
			try data.write(to: tempFile, options: .atomic)
			if fm.fileExists(atPath: scURL.path) { try? fm.removeItem(at: scURL) }
			try fm.moveItem(at: tempFile, to: scURL)
			return true
		} catch {
			// Clean up any temp file we may have created
			try? fm.removeItem(at: tempFile)
			// Attempt fallback to application-support sidecar store so we
			// can persist metadata even when the target directory is not writable.
			do {
				if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
					let sidecarDir = appSupport.appendingPathComponent("PictureViewer/sidecars", isDirectory: true)
					try fm.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
					// Use a stable filename derived from the original path so
					// sidecars can be looked up later.
					let digest = Self.sha256Hex(of: url.path)
					let appSidecar = sidecarDir.appendingPathComponent("\(digest).pvmeta.json")
					// Include originalPath for clarity
					var sc = sidecar
					sc.originalPath = url.path
					let appData = try JSONEncoder().encode(sc)
					let tmp = sidecarDir.appendingPathComponent(".pvtmp-\(UUID().uuidString)")
					try appData.write(to: tmp, options: .atomic)
					if fm.fileExists(atPath: appSidecar.path) { try? fm.removeItem(at: appSidecar) }
					try fm.moveItem(at: tmp, to: appSidecar)
					return true
				}
			} catch {
				logger.error("writeSidecar: app-support fallback failed: \(error.localizedDescription, privacy: .public)")
			}
			return false
		}
	}

	static func sha256Hex(of string: String) -> String {
		let data = Data(string.utf8)
		let hashed = SHA256.hash(data: data)
		return hashed.compactMap { String(format: "%02x", $0) }.joined()
	}

	/// Ensure security-scoped access for the folder containing `url` if a
	/// persisted bookmark exists. Returns true if access is active.
	static func ensureSecurityScopedAccess(for url: URL) async -> Bool {
		let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
		// If we already have an active security URL that is an ancestor of
		// the target, reuse it.
		if Self.activeSecurityScopedURLs.contains(where: { url.path.hasPrefix($0.path) }) {
			return true
		}

		// Prefer the multi-bookmark key if present (backwards compatible).
		if let arr = UserDefaults.standard.array(forKey: Self.kLastFolderBookmarks) as? [Data], !arr.isEmpty {
			for bm in arr {
				var stale = false
				do {
					let resolved = try URL(resolvingBookmarkData: bm, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
					if resolved.startAccessingSecurityScopedResource() {
						if !Self.activeSecurityScopedURLs.contains(resolved) { Self.activeSecurityScopedURLs.append(resolved) }
						if url.path.hasPrefix(resolved.path) { return true }
					}
				} catch {
					logger.error("ensureSecurityScopedAccess: failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
				}
			}
			logger.log("ensureSecurityScopedAccess: no matching bookmark found in multi-bookmark list")
			return false
		}

		// Fallback to the original single-bookmark behavior.
		guard let bm = UserDefaults.standard.data(forKey: Self.kLastFolderBookmark) else {
			logger.log("ensureSecurityScopedAccess: no persisted bookmark")
			return false
		}
		var stale = false
		do {
			let resolved = try URL(resolvingBookmarkData: bm, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
				if resolved.startAccessingSecurityScopedResource() {
					if !Self.activeSecurityScopedURLs.contains(resolved) { Self.activeSecurityScopedURLs.append(resolved) }
					return url.path.hasPrefix(resolved.path)
				} else {
				logger.error("ensureSecurityScopedAccess: failed to start accessing security scoped resource")
				return false
			}
		} catch {
			logger.error("ensureSecurityScopedAccess: failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
			return false
		}
	}

	/// Rotate the image file at `url` by `degrees` clockwise (90-degree increments expected).
	/// Returns true on success. This is a best-effort rewrite that preserves metadata when possible.
	private static func rotateImageFile(at url: URL, degrees: Int) async -> Bool {
		let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
		let deg = ((degrees % 360) + 360) % 360
		guard deg != 0 else { return true }

		// Ensure we have security-scoped access to the containing folder if available
		_ = await Self.ensureSecurityScopedAccess(for: url)

		guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else { return false }
		guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }

		let radians = Double(deg) * Double.pi / 180.0
		var destWidth = cg.width
		var destHeight = cg.height
		if deg == 90 || deg == 270 {
			destWidth = cg.height
			destHeight = cg.width
		}

		guard let colorSpace = cg.colorSpace else { return false }
		guard let ctx = CGContext(data: nil, width: destWidth, height: destHeight, bitsPerComponent: cg.bitsPerComponent, bytesPerRow: 0, space: colorSpace, bitmapInfo: cg.bitmapInfo.rawValue) else { return false }

		ctx.translateBy(x: CGFloat(destWidth)/2.0, y: CGFloat(destHeight)/2.0)
		ctx.rotate(by: CGFloat(radians))
		ctx.translateBy(x: -CGFloat(cg.width)/2.0, y: -CGFloat(cg.height)/2.0)
		ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))

		guard let rotated = ctx.makeImage() else { return false }

		let fm = FileManager.default
		let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
		let dir = url.deletingLastPathComponent()
		let tempURL = dir.appendingPathComponent(".pvtmp-\(UUID().uuidString)").appendingPathExtension(url.pathExtension)

		guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else {
			logger.error("rotateImageFile: cannot create destination")
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "rotateImageFile", "message": "CGImageDestinationCreateWithURL failed when attempting to rewrite image for rotation."])
			// Embedded rewrite failed; do not fall back to sidecar per policy.
			return false
		}
		if let metadata = props as CFDictionary? {
			CGImageDestinationAddImage(dest, rotated, metadata)
		} else {
			CGImageDestinationAddImage(dest, rotated, nil)
		}
		if !CGImageDestinationFinalize(dest) {
			try? fm.removeItem(at: tempURL)
			logger.error("rotateImageFile: finalize failed")
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "rotateImageFile", "message": "CGImageDestinationFinalize failed when attempting to rewrite image for rotation."])
			// Do not persist sidecar; report failure to the caller.
			return false
		}

		do {
			let backupURL = url.appendingPathExtension("backup")
			if fm.fileExists(atPath: backupURL.path) { try? fm.removeItem(at: backupURL) }
			try fm.moveItem(at: url, to: backupURL)
			try fm.moveItem(at: tempURL, to: url)
			try? fm.removeItem(at: backupURL)
			MetadataCache.shared.invalidate(for: url)
			await PhotoVault.shared.reencryptWorkingCopyIfNeeded(url)
			return true
		} catch {
			try? fm.removeItem(at: tempURL)
			logger.error("rotateImageFile: failed to replace original file: \(error.localizedDescription, privacy: .public)")
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "rotateImageFile", "message": "Failed to replace original file after writing temp file: \(error.localizedDescription)"])
			// Do not fall back to sidecar; surface failure.
			return false
		}
	}

		/// Adjust brightness of the image at `url` by `delta` (−1…+1, CIColorControls scale).
		/// Returns true on success. Preserves original format and metadata when possible.
		private static func adjustBrightnessFile(at url: URL, delta: Double) async -> Bool {
			let logger = Logger(subsystem: "com.example.PictureViewer", category: "brightness")
			guard delta != 0 else { return true }

			_ = await Self.ensureSecurityScopedAccess(for: url)

			guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
				  let type = CGImageSourceGetType(src),
				  let cgIn = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
				logger.error("adjustBrightnessFile: cannot load image")
				return false
			}

			let ci = CIImage(cgImage: cgIn)
			guard let filter = CIFilter(name: "CIColorControls") else {
				logger.error("adjustBrightnessFile: CIColorControls unavailable")
				return false
			}
			filter.setValue(ci, forKey: kCIInputImageKey)
			filter.setValue(Float(delta), forKey: kCIInputBrightnessKey)
			guard let ciOut = filter.outputImage else {
				logger.error("adjustBrightnessFile: filter produced no output")
				return false
			}

			let ctx = CIContext()
			guard let cgOut = ctx.createCGImage(ciOut, from: ciOut.extent) else {
				logger.error("adjustBrightnessFile: createCGImage failed")
				return false
			}

			let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
			let fm = FileManager.default
			let tempURL = url.deletingLastPathComponent()
				.appendingPathComponent(".pvtmp-\(UUID().uuidString)")
				.appendingPathExtension(url.pathExtension)
			guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else {
				logger.error("adjustBrightnessFile: cannot create destination")
				NotificationCenter.default.post(name: .embedWriteFailed, object: nil,
					userInfo: ["url": url.path, "op": "adjustBrightness",
							   "message": "CGImageDestinationCreateWithURL failed"])
				return false
			}
			CGImageDestinationAddImage(dest, cgOut, props as CFDictionary?)
			guard CGImageDestinationFinalize(dest) else {
				try? fm.removeItem(at: tempURL)
				logger.error("adjustBrightnessFile: finalize failed")
				NotificationCenter.default.post(name: .embedWriteFailed, object: nil,
					userInfo: ["url": url.path, "op": "adjustBrightness",
							   "message": "CGImageDestinationFinalize failed"])
				return false
			}

			do {
				let backupURL = url.appendingPathExtension("backup")
				if fm.fileExists(atPath: backupURL.path) { try? fm.removeItem(at: backupURL) }
				try fm.moveItem(at: url, to: backupURL)
				try fm.moveItem(at: tempURL, to: url)
				try? fm.removeItem(at: backupURL)
				await PhotoVault.shared.reencryptWorkingCopyIfNeeded(url)
				return true
			} catch {
				try? fm.removeItem(at: tempURL)
				logger.error("adjustBrightnessFile: replace failed: \(error.localizedDescription, privacy: .public)")
				return false
			}
		}

		// Displayed (sorted) snapshot of photos. Computed in background when
		// the underlying library or the sort mode changes.
	@State private var displayedPhotos: [PhotoItem] = []
	@State private var displayedPhotoSections: [PhotoGridSection] = []
	@State private var collapsedPhotoSectionIDs: Set<String> = []
	@State private var sortTask: Task<Void, Never>? = nil
	@State private var photoChangeTask: Task<Void, Never>? = nil
	@State private var refreshToken = UUID()
	@State private var metadataRefreshTokens: [URL: UUID] = [:]
	@State private var pendingMetadataRefreshURLs: Set<URL> = []
	@State private var metadataRefreshTask: Task<Void, Never>? = nil
	@State private var forceThumbnailLoading = false
	@State private var isSQLiteObjectStoreView = false
	@State private var searchText: String = ""
	@State private var isRefreshing = false
	@State private var selectionMode: Bool = false
	@State private var selectedItems: Set<URL> = []
	@State private var isAllDisplayedSelectionActive: Bool = false
	@State private var deselectedItemsFromAll: Set<URL> = []
	@State private var thumbnailFrames: [URL: CGRect] = [:]
	@State private var pendingThumbnailFrames: [URL: CGRect] = [:]
	@State private var thumbnailFrameTask: Task<Void, Never>? = nil
	@State private var selectionDragStart: CGPoint? = nil
	@State private var selectionDragCurrent: CGPoint? = nil
	@State private var selectionDragBase: Set<URL> = []
	@State private var selectionDragMode: MarqueeSelectionMode = .replace
	@State private var suppressMarqueeDuringItemDrag: Bool = false
	@State private var gridScrollView: NSScrollView? = nil
	@State private var selectionAutoScrollTask: Task<Void, Never>? = nil
	@State private var pendingSQLiteFocusFilename: String? = nil
	@State private var pendingSQLiteFocusTask: Task<Void, Never>? = nil
	@State private var photoGridScrollRequest: PhotoGridScrollRequest? = nil
	private let thumbnailDraggingSource = ThumbnailDraggingSource()
	@State private var isEditingKeywords: Bool = false
	@State private var keywordEditTargets: [URL] = []
	@State private var editKeywordsText: String = ""
	@State private var isApplyingKeywords: Bool = false
	@State private var editProgressCount: Int = 0
	@State private var editingResults: [URL: Bool?] = [:]
	@State private var isAssigningPerson: Bool = false
	@State private var assignPersonTargetURLs: [URL] = []
	@State private var assignPersonName: String = ""
	@State private var existingPersonNames: [String] = []
	@State private var showPersonAssignmentResult: Bool = false
	@State private var personAssignmentResultMessage: String = ""
	@State private var isRescanningFaces: Bool = false
	@State private var showFaceRescanResult: Bool = false
	@State private var faceRescanResultMessage: String = ""

	@State private var isPersonRecognitionWorking: Bool = false
	@State private var personRecognitionTask: Task<Void, Never>? = nil
	@State private var personRecognitionProgressMessage: String = ""
	@State private var personRecognitionProgressCompleted: Int = 0
	@State private var personRecognitionProgressTotal: Int = 0
	@State private var showPersonRecognitionResult: Bool = false
	@State private var personRecognitionResultMessage: String = ""
	@State private var personFilterPaths: Set<String>? = nil
	@State private var personFilterID: UUID? = nil
	@State private var showDeleteConfirmation: Bool = false
	@State private var isDeleting: Bool = false
	@State private var deleteProgressCount: Int = 0
	@State private var deleteResults: [URL: Bool?] = [:]
	@State private var deleteErrorMessages: [URL: String?] = [:]
	@State private var showDeleteErrorSummary: Bool = false
	@State private var deleteErrorSummary: String = ""
	@State private var deleteHadFailures: Bool = false
	@State private var deletingURLs: [URL] = []
	@State private var pendingDeleteURLs: [URL] = []
	@State private var selectedRotations: [URL: Int] = [:]
	@State private var isShowingRotationSheet: Bool = false
	@State private var isApplyingRotations: Bool = false
	@State private var rotProgressCount: Int = 0
	@State private var rotationResults: [URL: Bool?] = [:]
	@State private var isShowingBrightnessSheet: Bool = false
	@State private var isApplyingBrightness: Bool = false
	@State private var brightnessAdjustment: Double = 0.2
	@State private var brightnessProgressCount: Int = 0
	@State private var brightnessResults: [URL: Bool?] = [:]
	// Use a dedicated window for People; open via `openWindow(id:value:)`
	@State private var lastRefreshDuration: TimeInterval?
	@State private var lastRefreshDate: Date?
	@AppStorage("saveOpenWindows") private var saveOpenWindows: Bool = false
	@Environment(\.openWindow) private var openWindow
	@AppStorage("disableAutoRestoreWindows") private var disableAutoRestoreWindows: Bool = true
	@AppStorage("deferAtLaunchBackgroundWork") private var deferAtLaunchBackgroundWork: Bool = true
	@AppStorage("useVLCForVideoPlayback") private var useVLCForVideoPlayback: Bool = false

	private let logger = Logger(subsystem: "com.example.PictureViewer", category: "ui")
	// Persisted security-scoped bookmark keys
	static let kLastFolderBookmark = "lastFolderBookmark"
	// New key that holds an array of bookmarks when the user selects
	// multiple folders. Kept for backward compatibility with the single
	// bookmark key above.
	static let kLastFolderBookmarks = "lastFolderBookmarks"
	static let kKnownFolderBookmarks = "knownFolderBookmarks"
	private static let sqliteStoreContentTypes: [UTType] = [
		UTType(filenameExtension: "sqlite") ?? .data,
		UTType(filenameExtension: "sqlite3") ?? .data,
		UTType(filenameExtension: "db") ?? .data
	]
	private static var openableContentTypes: [UTType] {
		sqliteStoreContentTypes + PhotoLibrary.supportedMediaContentTypes
	}
	// Active resolved security-scoped URLs (kept open for the app lifetime)
	private static var activeSecurityScopedURLs: [URL] = []
	// First mounted gallery window. Subsequent windows are force-tabbed onto
	// this one so bookmarks load as tabs of the main window instead of as
	// standalone windows. Weak so it clears if the main window closes.
	private static weak var mainGalleryWindow: NSWindow?
	// Track whether we've already attempted the automatic launch-time
	// restoration. Prevents new tabs created after launch from auto-loading
	// cached snapshots — instead we will prompt the user to choose a folder.
	private static var didPerformLaunchRestore: Bool = false
	// Names of the active folders (used for multi-folder tab title)
	@State private var activeFolderNames: [String] = []
	@State private var hostingWindow: NSWindow?
	// Resolved URLs for each persisted bookmark; populated by reloadBookmarks()
	// and consumed by the toolbar bookmark dropdown.
	@State private var bookmarkURLs: [URL] = []
	@State private var showBookmarkManager: Bool = false

	// Deduper used for multi-folder scans to avoid showing duplicate
	// basenames when combining results from multiple folders. We perform
	// a cross-folder dedupe here because `PhotoLibrary.scanStream` only
	// deduplicates within a single folder scan.
	private actor MultiFolderDeduper {
		private var seen: Set<String> = []
		func isUnique(_ name: String) -> Bool {
			let key = name.lowercased()
			if seen.contains(key) { return false }
			seen.insert(key)
			return true
		}
	}
	@State private var folderSecurityURL: URL? = nil // resolved security-scoped URL (if any)
	@State private var repairResultMessage: String? = nil
	@State private var showRepairResult: Bool = false
	@State private var showEmbedWriteAlert: Bool = false
	@State private var embedFailMessage: String? = nil
	@State private var embedFailURL: URL? = nil
	@State private var isVaultWorking: Bool = false
	@State private var vaultProgressMessage: String = ""
	@State private var vaultProgressCompleted: Int = 0
	@State private var vaultProgressTotal: Int = 0
	@State private var vaultProgressCurrentFile: String = ""
	@State private var sqliteLoadStartDate: Date?
	@State private var sqliteLastLoadDuration: TimeInterval?
	@State private var sqliteLastThumbnailLoadDuration: TimeInterval?
	@State private var showVaultAlert: Bool = false
	@State private var vaultAlertMessage: String = ""
	@State private var vaultStatus = PhotoVaultStatus(isConfigured: false, hasLocation: false, hasPassword: false, isUnlocked: false, locationPath: nil)
	@State private var isShowingVaultUnlockPrompt: Bool = false
	@State private var isShowingOllamaPromptSheet: Bool = false
	/// When true, the active Ollama prompt sheet targets the current selection
	/// rather than all displayed photos.
	@State private var ollamaSheetUsesSelection: Bool = false
	/// When non-nil, the active Ollama prompt sheet targets exactly these URLs
	/// (used by context-menu invocations). Overrides `ollamaSheetUsesSelection`.
	@State private var ollamaSheetExplicitURLs: [URL]? = nil
	@AppStorage("ollamaLastPrompt") private var ollamaPrompt: String = OllamaRecognizer.defaultPrompt
	@AppStorage("ollamaSelectedModel") private var ollamaSelectedModel: String = OllamaRecognizer.defaultModel
	@AppStorage("ollamaUpdateMetadata") private var ollamaUpdateMetadata: Bool = true
	@State private var vaultUnlockPassword: String = ""
	@State private var vaultUnlockConfirmation: String = ""
	@State private var vaultUnlockMessage: String?
	@State private var vaultStoreTask: Task<Void, Never>?
	@State private var folderScanTask: Task<Void, Never>?
	@State private var refreshTask: Task<Void, Never>?
	@State private var deleteTask: Task<Void, Never>?
	@State private var keywordEditTask: Task<Void, Never>?
	@State private var rotationApplyTask: Task<Void, Never>?
	@State private var brightnessApplyTask: Task<Void, Never>?
	@State private var ollamaRecognitionTask: Task<Void, Never>?
	@State private var isOllamaRecognitionRunning = false
	@State private var pendingVaultAutoOpen: Bool = false
	@State private var isShowingVaultManager: Bool = false
	@State private var knownVaults: [KnownVault] = []

	private var isActiveVaultView: Bool {
		activeFolderNames.count == 1 && activeFolderNames[0].hasSuffix("*")
	}

	private var canPasteFilesToVault: Bool {
		isActiveVaultView && !pasteboardFileURLs().isEmpty
	}

	private var currentVaultDisplayName: String {
		Self.vaultDisplayName(for: Self.vaultURL(from: vaultStatus))
	}

	private nonisolated static func vaultURL(from status: PhotoVaultStatus) -> URL? {
		status.locationPath.map { URL(fileURLWithPath: $0) }
	}

	private nonisolated static func vaultDisplayName(for url: URL?) -> String {
		let name = url?.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
		let baseName = (name?.isEmpty == false) ? name! : "Vault"
		return baseName.hasSuffix("*") ? baseName : "\(baseName)*"
	}

	private nonisolated static func normalizedBookmarkOpenName(_ name: String) -> String {
		name
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
	}

	private nonisolated static func uniqueFoldersByBookmarkName(_ urls: [URL]) -> [URL] {
		var seenNames: Set<String> = []
		return urls.filter { url in
			let key = normalizedBookmarkOpenName(url.lastPathComponent)
			guard !key.isEmpty else { return true }
			return seenNames.insert(key).inserted
		}
	}

	private nonisolated static func uniqueGallerySessionItems(_ items: [WindowStateStore.GallerySessionItem]) -> [WindowStateStore.GallerySessionItem] {
		var seenNames: Set<String> = []
		return items.filter { item in
			let name: String
			switch item {
			case .folder(let url):
				name = url.lastPathComponent
			case .sqliteStore(let storeName):
				name = storeName
			}
			let key = normalizedBookmarkOpenName(name)
			guard !key.isEmpty else { return true }
			return seenNames.insert(key).inserted
		}
	}

	private nonisolated static func isSQLiteStoreFile(_ url: URL) -> Bool {
		["sqlite", "sqlite3", "db"].contains(url.pathExtension.lowercased())
	}

	@MainActor
	private static func windowsAreAlreadyTabbed(_ first: NSWindow, _ second: NSWindow) -> Bool {
		first.tabbedWindows?.contains(second) == true || second.tabbedWindows?.contains(first) == true
	}

	@MainActor
	private static func focusGalleryTab(_ window: NSWindow) {
		DispatchQueue.main.async {
			window.tabGroup?.selectedWindow = window
			window.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: false)
		}
	}

	private var galleryNavigationTitle: String {
		if activeFolderNames.isEmpty {
			return library.folderURL?.lastPathComponent ?? "Picture Viewer"
		}
		if activeFolderNames.count == 1 {
			return activeFolderNames[0]
		}
		return activeFolderNames.joined(separator: " · ")
	}

	private var fileNavigationCommandActions: FileNavigationCommandActions {
		FileNavigationCommandActions(
			openFolder: { openBookmarkedFolder($0) },
			openSQLiteStore: { openSQLiteStoreFromMenu(named: $0) },
			openPhoto: { openWindow(id: "photo-viewer", value: $0) },
			restoreSavedGallerySession: { restoreSavedGallerySession() },
			showBookmarkManager: { showBookmarkManager = true }
		)
	}

	private var vaultCommandActions: VaultCommandActions {
		VaultCommandActions(
			newItem: { newItem() },
			openItem: { chooseFolder() },
			newVault: { newVault() },
			importFolders: { importFolderToVault() },
			importSelected: { importSelectedImagesToVault() },
			chooseAndOpenVault: { chooseAndOpenVault() },
			openVault: { openVault() },
			closeVault: { closeVault() },
			renameVault: { renameVault() },
			manageVaults: { showVaultManager() },
			exportPhotos: { exportVaultSelection() },
			syncToTab: { syncToAnotherTab() },
			syncToSQLiteStore: { syncCurrentTabToSQLiteStore() },
			syncSelectedToSQLiteStore: { syncSelectedMediaToSQLiteStore() },
			backfillSQLiteThumbnails: { backfillSQLiteThumbnails() },
			openSQLiteStore: { chooseAndOpenSQLiteObjectStore() },
			copy: { copySelectedFiles() },
			paste: { pasteFilesToVault() },
			selectAll: { selectAllDisplayedPhotos() },
			recognizeDisplayed: { recognizeDisplayedImagesWithOllama() },
			recognizeSelected: { recognizeSelectedImagesWithOllama() },
			canCloseVault: isSQLiteObjectStoreView || isActiveVaultView || vaultStatus.isUnlocked,
			canRenameVault: isActiveVaultView && library.folderURL != nil,
			canImportSelected: hasSelectedPhotos,
			canExport: !library.photos.isEmpty,
			canSyncToTab: !library.photos.isEmpty,
			canSyncToSQLiteStore: !library.photos.isEmpty,
			canSyncSelectedToSQLiteStore: hasSelectedPhotos,
			canBackfillSQLiteThumbnails: isSQLiteObjectStoreView && !isVaultWorking && !library.photos.isEmpty,
			canOpenSQLiteStore: true,
			canCopy: hasSelectedPhotos,
			canPaste: canPasteFilesToVault,
			canSelectAll: !displayedPhotos.isEmpty,
			canRecognize: !displayedPhotos.isEmpty,
			canRecognizeSelected: hasSelectedPhotos
		)
	}

	var body: some View {
		galleryShell
	}

	@ViewBuilder
	private var galleryNavigationRoot: some View {
		NavigationStack {
			VStack(spacing: 0) {
				StatusBarView(
					library: library,
					isRefreshing: isRefreshing,
					isSQLiteObjectStoreView: isSQLiteObjectStoreView,
					isVaultWorking: isVaultWorking,
					vaultProgressMessage: vaultProgressMessage,
					vaultProgressCurrentFile: vaultProgressCurrentFile,
					vaultProgressTotal: vaultProgressTotal,
					vaultProgressCompleted: vaultProgressCompleted,
					sqliteLoadStartDate: sqliteLoadStartDate,
					sqliteLastLoadDuration: sqliteLastLoadDuration,
					sqliteLastThumbnailLoadDuration: sqliteLastThumbnailLoadDuration,
					lastRefreshDate: lastRefreshDate,
					lastRefreshDuration: lastRefreshDuration,
					onRefreshThumbnails: { refreshThumbnails() },
					onBackfillSQLiteThumbnails: isSQLiteObjectStoreView ? { backfillSQLiteThumbnails() } : nil
				)
					.fixedSize(horizontal: false, vertical: true)
				Divider()
				contentBody
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			.navigationTitle(galleryNavigationTitle)
			.toolbar { toolbarItems }
			.focusedSceneValue(\.fileNavigationActions, fileNavigationCommandActions)
			.focusedSceneValue(\.vaultCommandActions, vaultCommandActions)
		}
		.frame(minWidth: 760, minHeight: 540)
		// Attach a WindowAccessor so we can set window-level defaults like
		// preferring tabs for this app's windows.
		.background(GalleryWindowCloseInstaller(onCloseRequest: handleTabCloseRequest))
		.background(WindowAccessor { window in
			// Force every gallery window to live in the same NSWindow tab
			// group. macOS only honors tabbingMode/Identifier when the system
			// "Prefer tabs" preference allows tabbing, so we also explicitly
			// add new windows to the main gallery window's tab set.
			guard let window else { return }
			hostingWindow = window
			window.tabbingMode = .preferred
			window.tabbingIdentifier = "PictureViewerGallery"
			if let main = ContentView.mainGalleryWindow, main !== window, main.isVisible {
				// If AppKit already tabbed the new window (e.g. user pressed
				// "+" on the tab bar), leave it alone. Otherwise attach the
				// new window to the main window's tab group so programmatic
				// openWindow(id:value:) opens land as tabs too.
				if !Self.windowsAreAlreadyTabbed(main, window) {
					main.addTabbedWindow(window, ordered: .above)
				}
				Self.focusGalleryTab(window)
			} else {
				ContentView.mainGalleryWindow = window
			}
		})
		.task(id: initialSQLiteOpenToken) {
			guard let storeName = resolvedInitialSQLiteStoreName else { return }
			await openInitialSQLiteStoreIfNeeded(storeName: storeName)
		}
		.onAppear {
			updateTabRegistry()
			// Initialize displayed photos immediately so the UI shows
			// something, but defer heavier startup work (sorting and
			// session restoration) briefly to avoid blocking the main
			// thread right after authentication. This helps prevent a
			// startup "beach ball" when the system is busy handling the
			// auth transition.
			displayedPhotos = library.photos
			reloadBookmarks()
			// If this ContentView was opened with a seed folder
			// (per-folder window opened via openWindow(id:"folder", value:url)),
			// scan that folder directly and skip launch restoration.
			if let seed = initialFolderURL {
				logger.log("launch folder restore: source=initial-folder-window storage=filesystem folder=\(seed.path, privacy: .public)")
				library.folderURL = seed
				activeFolderNames = [seed.lastPathComponent]
				if tryOpenFolderAsVault(seed) { return }
				forceThumbnailLoading = false
				library.scan(folder: seed)
				return
			}
			if initialSQLiteOpenToken != nil {
				return
			}
			let shouldRestoreAtLaunch = saveOpenWindows
			// Defer work by a short amount; if responsiveness is still an
			// issue we can increase the delay or gate more startup tasks.
			Task.detached(priority: .utility) {
				try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
				await MainActor.run {
					scheduleSort()
				}
				// Attempt to resolve any persisted security-scoped bookmark
				// and start access so background writes are allowed when the
				// app is sandboxed. Run this after a short delay so the UI
				// can finish initial setup first.
				if shouldRestoreAtLaunch {
					Task {
						// Only perform the automatic launch restore once. Subsequent
						// ContentView instances (tabs/windows created after launch)
						// should not re-load the cached snapshot; leave those
						// instances blank instead.
						let didRestore = await MainActor.run { Self.didPerformLaunchRestore }
						if !didRestore {
							let restoredBookmarks = await self.restoreFolderBookmarkIfNeeded(library: library, logger: self.logger)
							await MainActor.run { Self.didPerformLaunchRestore = true }
							await MainActor.run { restoreSavedWindowsIfNeeded(skipSavedFolder: restoredBookmarks) }
						}
					}
				} else {
					await MainActor.run { Self.didPerformLaunchRestore = true }
				}
			}
		}
		.onDisappear {
			cancelAllBackgroundOperations()
			Task { @MainActor in
				GalleryTabRegistry.shared.remove(id: tabID)
				if let folderURL = registeredGalleryFolderURL, !WindowStateStore.shared.isAppTerminating() {
					WindowStateStore.shared.recordClosedGalleryFolder(folderURL)
				}
				if let sqliteStoreName = registeredSQLiteStoreName, !WindowStateStore.shared.isAppTerminating() {
					WindowStateStore.shared.recordClosedSQLiteStore(named: sqliteStoreName)
				}
			}
		}
		.onChange(of: library.photos) {
			if library.isScanning {
				syncDisplayedPhotosDuringScan()
			}
			queuePhotoChangeRefresh()
		}
		.onChange(of: library.isScanning) {
			if !library.isScanning {
				scheduleSort()
			}
		}
		.onChange(of: activeFolderNames) {
			updateTabRegistry()
		}
		.onChange(of: library.folderURL) {
			updateTabRegistry()
		}
		.onChange(of: sortModeRaw) {
			let mode = SortMode(rawValue: sortModeRaw) ?? .alphaAsc
			if mode == .descriptionAsc || mode == .descriptionDesc {
				groupGridByDescription = true
			}
			scheduleSort()
		}
		.onChange(of: groupGridByDescription) {
			scheduleSort()
		}
		.onChange(of: searchText) {
			scheduleSort()
		}
		.onChange(of: personFilterState.active) {
			applyPersonFilter(personFilterState.active)
		}
		.task {
			applyPersonFilter(personFilterState.active)
		}
	}

	@ViewBuilder
	private var galleryShell: some View {
		galleryNavigationRoot
		.sheet(isPresented: $showBookmarkManager) {
			VStack(spacing: 12) {
				Text("Manage Bookmarks")
					.font(.headline)
				if bookmarkURLs.isEmpty {
					Text("No bookmarks saved.")
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					List {
						ForEach(bookmarkURLs, id: \.self) { url in
							HStack {
								VStack(alignment: .leading, spacing: 2) {
									Text(url.lastPathComponent)
									Text(url.path)
										.font(.caption)
										.foregroundStyle(.secondary)
										.lineLimit(1)
										.truncationMode(.middle)
								}
								Spacer()
								Button(role: .destructive) {
									deleteBookmark(url)
								} label: {
									Image(systemName: "trash")
								}
								.buttonStyle(.borderless)
								.help("Remove this bookmark")
							}
						}
					}
					.frame(minHeight: 220)
				}
				HStack {
					Spacer()
					Button("Done") { showBookmarkManager = false }
						.keyboardShortcut(.defaultAction)
				}
			}
			.padding()
			.frame(minWidth: 480, minHeight: 280)
		}
		.sheet(isPresented: $isShowingVaultManager) {
			VStack(spacing: 12) {
				Text("Manage Vaults")
					.font(.headline)
				if knownVaults.isEmpty {
					Text("No vaults known.")
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					List {
						ForEach(knownVaults) { vault in
							HStack(spacing: 12) {
								VStack(alignment: .leading, spacing: 2) {
									Text(vault.displayName)
									Text(vault.path)
										.font(.caption)
										.foregroundStyle(.secondary)
										.lineLimit(1)
										.truncationMode(.middle)
								}
								Spacer()
								Button("Rename") {
									renameKnownVault(vault)
								}
								.buttonStyle(.borderless)
								Button("Move") {
									moveKnownVault(vault)
								}
								.buttonStyle(.borderless)
								Button(role: .destructive) {
									deleteKnownVault(vault)
								} label: {
									Image(systemName: "trash")
								}
								.buttonStyle(.borderless)
								.help("Delete this vault")
							}
						}
					}
					.frame(minHeight: 260)
				}
				HStack {
					Button("Refresh") { reloadKnownVaults() }
					Spacer()
					Button("Done") { isShowingVaultManager = false }
						.keyboardShortcut(.defaultAction)
				}
			}
			.padding()
			.frame(minWidth: 680, minHeight: 340)
		}
		.sheet(isPresented: $isEditingKeywords) {
			VStack(spacing: 12) {
				Text("Edit Keywords for \(keywordEditTargets.count) photo\(keywordEditTargets.count == 1 ? "" : "s")")
					.font(.headline)
				TextField("Keywords (comma-separated)", text: $editKeywordsText)
					.textFieldStyle(.roundedBorder)
					.padding(.horizontal)
				Text("Append adds to existing IPTC keywords. Replace overwrites them. Clear removes all IPTC keywords.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.padding(.horizontal)

				let urls = keywordEditTargets
				if !urls.isEmpty {
					ProgressView(value: Double(editProgressCount), total: Double(urls.count))
						.padding(.horizontal)
					ScrollView {
						VStack(alignment: .leading, spacing: 8) {
							ForEach(urls, id: \.self) { u in
								HStack {
									Text(u.lastPathComponent)
										.font(.caption)
										.lineLimit(1)
									Spacer()
									if isApplyingKeywords {
										if editingResults[u] == nil {
											ProgressView()
												.controlSize(.small)
										} else if editingResults[u] == true {
											Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
										} else {
											Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
										}
									} else if let res = editingResults[u] {
										if res == true {
											Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
										} else {
											Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
										}
									}
								}
							}
						}
						.padding(.horizontal)
						.frame(maxHeight: 220)
					}
				}

				HStack {
					Button("Cancel") {
						if !isApplyingKeywords {
							isEditingKeywords = false
						}
					}
					.disabled(isApplyingKeywords)
					Spacer()
					if isApplyingKeywords {
						Button("Close") {
							isEditingKeywords = false
						}
					} else {
						Button("Clear Keywords") {
							applyKeywordEdit(.clear)
						}
						Button("Append") {
							applyKeywordEdit(.append)
						}
						.disabled(editKeywordsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keywordEditTargets.isEmpty)
						Button("Replace") {
							applyKeywordEdit(.replace)
						}
						.disabled(keywordEditTargets.isEmpty)
					}
				}
				.padding(.horizontal)
			}
			.padding()
			.frame(minWidth: 420, minHeight: 200)
		}
		.sheet(isPresented: $isAssigningPerson) {
			VStack(spacing: 12) {
				Text("Assign Person")
					.font(.headline)
				Text("Assign faces, write the person name to metadata, and teach Ollama recognition for \(assignPersonTargetURLs.count) photo\(assignPersonTargetURLs.count == 1 ? "" : "s").")
					.font(.caption)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.leading)
				TextField("Person name", text: $assignPersonName)
					.textFieldStyle(.roundedBorder)
					.padding(.horizontal)
				if !filteredPersonNameSuggestions.isEmpty {
					VStack(alignment: .leading, spacing: 6) {
						Text("Suggestions")
							.font(.caption2)
							.foregroundStyle(.secondary)
						ForEach(filteredPersonNameSuggestions.prefix(6), id: \.self) { name in
							Button(name) {
								assignPersonName = name
							}
							.buttonStyle(.plain)
						}
					}
					.padding(.horizontal)
				}
				if !existingPersonNames.isEmpty {
					VStack(alignment: .leading, spacing: 6) {
						Text("Existing names")
							.font(.caption2)
							.foregroundStyle(.secondary)
						ScrollView(.horizontal, showsIndicators: false) {
							HStack(spacing: 6) {
								ForEach(existingPersonNames, id: \.self) { name in
									Button(name) {
										assignPersonName = name
									}
									.buttonStyle(.bordered)
									.controlSize(.small)
								}
							}
						}
					}
					.padding(.horizontal)
				}
				HStack {
					Button("Cancel") {
						isAssigningPerson = false
					}
					.keyboardShortcut(.cancelAction)
					Spacer()
					Button("Apply") {
						applyPersonNameToSelection()
					}
					.keyboardShortcut(.defaultAction)
					.disabled(assignPersonTargetURLs.isEmpty || assignPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPersonRecognitionWorking)
				}
				.padding(.horizontal)
			}
			.padding()
			.frame(minWidth: 420, minHeight: 180)
			.onAppear {
				loadExistingPersonNamesForAssignment()
			}
		}
		.confirmationDialog(
			"Are you sure you want to delete \(pendingDeleteURLs.count) file\(pendingDeleteURLs.count == 1 ? "" : "s")?",
			isPresented: $showDeleteConfirmation,
			titleVisibility: .visible
		) {
			Button("Delete", role: .destructive) {
				let urls = pendingDeleteURLs
				pendingDeleteURLs = []
				performDelete(urls: urls)
			}
			Button("Cancel", role: .cancel) {
				pendingDeleteURLs = []
			}
		} message: {
			Text("This will permanently delete the selected files.")
		}
		.alert(isPresented: $showDeleteErrorSummary) {
			if deleteHadFailures {
				Alert(
					title: Text("Delete completed with issues"),
					message: Text(deleteErrorSummary),
					primaryButton: .default(Text("Retry Failed")) {
						let failed = deleteResults.compactMap { (k, v) -> URL? in
							if let ok = v, ok == false { return k }
							return nil
						}
						if !failed.isEmpty {
							requestDeleteConfirmation(urls: failed, source: "retry-alert")
						}
					},
					secondaryButton: .default(Text("OK"))
				)
			} else {
				Alert(
					title: Text("Delete completed"),
					message: Text(deleteErrorSummary),
					dismissButton: .default(Text("OK"))
				)
			}
		}
		.alert(isPresented: $showRepairResult) {
			Alert(title: Text("Repair Metadata"), message: Text(repairResultMessage ?? ""), dismissButton: .default(Text("OK")))
		}
		.alert("Assign Person", isPresented: $showPersonAssignmentResult) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(personAssignmentResultMessage)
		}
		.alert("Rescan Facial Recognition", isPresented: $showFaceRescanResult) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(faceRescanResultMessage)
		}
		.alert("Person Recognition", isPresented: $showPersonRecognitionResult) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(personRecognitionResultMessage)
		}
		.sheet(isPresented: $isPersonRecognitionWorking) {
			VStack(spacing: 12) {
				Text(personRecognitionProgressMessage)
					.font(.headline)
				if personRecognitionProgressTotal > 0 {
					ProgressView(value: Double(personRecognitionProgressCompleted), total: Double(personRecognitionProgressTotal))
						.padding(.horizontal)
					Text("\(personRecognitionProgressCompleted) of \(personRecognitionProgressTotal)")
						.font(.caption)
						.foregroundStyle(.secondary)
						.monospacedDigit()
				} else {
					ProgressView()
						.controlSize(.large)
				}
				Button("Cancel", role: .cancel) {
					personRecognitionProgressMessage = "Cancelling..."
					personRecognitionTask?.cancel()
				}
				.disabled(personRecognitionTask == nil || personRecognitionTask?.isCancelled == true)
			}
			.padding()
			.frame(minWidth: 360, minHeight: 140)
		}
		.onReceive(NotificationCenter.default.publisher(for: .embedWriteFailed)) { n in
			if let info = n.userInfo as? [String: String] {
				embedFailMessage = info["message"]
				if let path = info["url"] { embedFailURL = URL(fileURLWithPath: path) }
			}
			showEmbedWriteAlert = true
		}
		.alert(isPresented: $showEmbedWriteAlert) {
			Alert(
				title: Text("Unable to write embedded metadata"),
				message: Text(embedFailMessage ?? "The app could not embed metadata into the file. This may be due to missing write permission for the folder."),
				primaryButton: .default(Text("Choose Folder…")) {
					// Prompt the user to re-select the folder to create a fresh
					// security-scoped bookmark which may enable embedded writes.
					chooseFolder()
				},
				secondaryButton: .cancel(Text("OK"))
			)
		}
		.alert("Vault", isPresented: $showVaultAlert) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(vaultAlertMessage)
		}
		.sheet(isPresented: $isShowingOllamaPromptSheet) {
			OllamaPromptSheet(
				imageCount: ollamaRecognitionURLs(
					selectedOnly: ollamaSheetUsesSelection,
					explicit: ollamaSheetExplicitURLs
				).count,
				modelName: ollamaSelectedModel,
				prompt: $ollamaPrompt,
				updateMetadata: $ollamaUpdateMetadata,
				onCancel: {
					isShowingOllamaPromptSheet = false
					ollamaSheetExplicitURLs = nil
				},
				onRun: {
					let selectedOnly = ollamaSheetUsesSelection
					let explicit = ollamaSheetExplicitURLs
					isShowingOllamaPromptSheet = false
					ollamaSheetExplicitURLs = nil
					runOllamaRecognition(selectedOnly: selectedOnly, explicit: explicit)
				}
			)
		}
		.onChange(of: ollamaProgress.lastCompletedURL) { _, newURL in
			if let newURL { queueMetadataRefresh(for: newURL) }
		}
		.sheet(isPresented: $isShowingVaultUnlockPrompt, onDismiss: clearVaultUnlockPrompt) {
			VaultUnlockPromptView(
				vaultHasPassword: vaultStatus.hasPassword,
				displayName: currentVaultDisplayName,
				pendingAutoOpen: pendingVaultAutoOpen,
				unlockMessage: vaultUnlockMessage,
				password: $vaultUnlockPassword,
				confirmation: $vaultUnlockConfirmation,
				onCancel: {
					pendingVaultAutoOpen = false
					clearVaultUnlockPrompt()
					isShowingVaultUnlockPrompt = false
				},
				onSubmit: submitVaultUnlockPrompt
			)
		}
		.task {
			await refreshVaultStatus()
		}
		.onReceive(NotificationCenter.default.publisher(for: .photoVaultStatusChanged)) { _ in
			Task { await refreshVaultStatus() }
		}
		.onReceive(NotificationCenter.default.publisher(for: .galleryTabSyncImported)) { notification in
			receiveSyncedFiles(notification)
		}
		.onReceive(NotificationCenter.default.publisher(for: .sqliteSyncWillBegin)) { notification in
			guard let storeName = notification.userInfo?["storeName"] as? String else { return }
			guard isSQLiteObjectStoreView,
			      SQLiteObjectStore.storeNamesMatch(activeSQLiteStoreName, storeName) else { return }
			vaultStoreTask?.cancel()
			vaultStoreTask = nil
		}
		.onReceive(NotificationCenter.default.publisher(for: .sqliteObjectStoreDidChange)) { notification in
			guard isSQLiteObjectStoreView, !isVaultWorking else { return }
			if let changedStoreName = notification.userInfo?["storeName"] as? String,
			   changedStoreName != activeSQLiteStoreName {
				return
			}
			// Skip the reload on the tab that originated the change — its
			// library.photos was already mutated in place by performSQLiteDelete
			// / performSQLiteSync so a close-and-reopen would just churn the UI.
			if let originator = notification.object as? UUID, originator == tabID {
				return
			}
			let focusFilename = notification.userInfo?["filename"] as? String
			refreshThumbnails(focusFilename: focusFilename)
		}
		.sheet(isPresented: nonSQLiteWorkingSheetBinding) {
			VStack(spacing: 12) {
				Text(vaultProgressMessage)
					.font(.headline)
				if vaultProgressTotal > 0 {
					ProgressView(value: Double(vaultProgressCompleted), total: Double(vaultProgressTotal))
					Text("\(vaultProgressCompleted) of \(vaultProgressTotal) synced")
						.font(.caption)
						.foregroundStyle(.secondary)
						.monospacedDigit()
					if !vaultProgressCurrentFile.isEmpty {
						Text(vaultProgressCurrentFile)
							.font(.caption2)
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.truncationMode(.middle)
					}
				} else {
					ProgressView()
						.controlSize(.large)
					if vaultProgressCompleted > 0 {
						Text("\(vaultProgressCompleted) photo\(vaultProgressCompleted == 1 ? "" : "s") found")
							.font(.caption)
							.foregroundStyle(.secondary)
							.monospacedDigit()
					}
				}
				if let task = vaultStoreTask {
					Button("Cancel", role: .cancel) {
						task.cancel()
					}
					.disabled(task.isCancelled)
				}
			}
			.padding()
			.frame(minWidth: 360, minHeight: 160)
		}
		// Show inline deletion progress while background delete runs
		.sheet(isPresented: $isDeleting) {
			VStack(spacing: 12) {
				Text("Deleting files…")
					.font(.headline)
				if !deletingURLs.isEmpty {
					ProgressView(value: Double(deleteProgressCount), total: Double(deletingURLs.count))
						.padding(.horizontal)
				} else {
					ProgressView()
						.padding(.horizontal)
				}
				ScrollView {
					VStack(alignment: .leading, spacing: 8) {
						ForEach(deletingURLs, id: \ .self) { u in
							HStack(alignment: .top) {
								VStack(alignment: .leading) {
									Text(u.lastPathComponent)
										.font(.caption)
									if let msg = deleteErrorMessages[u], let m = msg {
										Text(m)
											.font(.caption2)
											.foregroundStyle(.red)
									}
								}
								Spacer()
								if let res = deleteResults[u] {
									if res == nil {
										ProgressView().controlSize(.small)
									} else if res == true {
										Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
									} else {
										Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
									}
								} else {
									ProgressView().controlSize(.small)
								}
							}
						}
					}
					.padding()
				}
				HStack {
					Button("Close") { isDeleting = false }
						.disabled(deleteProgressCount < (deletingURLs.isEmpty ? 1 : deletingURLs.count))
					Spacer()
					Button("Retry Failed") {
						let failed = deleteResults.compactMap { (k, v) -> URL? in
							if let ok = v, ok == false { return k }
							return nil
						}
						if !failed.isEmpty { requestDeleteConfirmation(urls: failed, source: "retry-sheet") }
					}
					.disabled(!deleteResults.values.contains { $0 == false })
				}
				.padding(.horizontal)
			}
			.padding()
			.frame(minWidth: 420, minHeight: 240)
		}
		.sheet(isPresented: $isShowingRotationSheet) {
			VStack(spacing: 12) {
				Text("Apply Rotations to \(selectedPhotoCount) photos")
					.font(.headline)

				let urls = selectedPhotoURLs
				if !urls.isEmpty {
					ProgressView(value: Double(rotProgressCount), total: Double(urls.count))
						.padding(.horizontal)
					ScrollView {
						VStack(alignment: .leading, spacing: 8) {
							ForEach(urls, id: \.self) { u in
								HStack {
									Text(u.lastPathComponent)
										.font(.caption)
										.lineLimit(1)
									Spacer()
									Text("\(selectedRotations[u] ?? 0)°")
										.font(.caption2)
										.foregroundStyle(.secondary)
									Spacer(minLength: 8)
									if isApplyingRotations {
										if rotationResults[u] == nil {
											ProgressView().controlSize(.small)
										} else if rotationResults[u] == true {
											Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
										} else {
											Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
										}
									}
								}
							}
						}
						.padding(.horizontal)
						.frame(maxHeight: 220)
					}
				}

				HStack {
					Button("Cancel") { if !isApplyingRotations { isShowingRotationSheet = false } }
						.disabled(isApplyingRotations)
					Spacer()
					if isApplyingRotations {
						Button("Close") { isShowingRotationSheet = false }
					} else {
						Button("Apply") {
							let urls = selectedPhotoURLs
							rotationResults = Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as Bool?) })
							rotProgressCount = 0
							isApplyingRotations = true
							let rotationsCopy = selectedRotations
							rotationApplyTask?.cancel()
							rotationApplyTask = Task.detached(priority: .utility) {
								for u in urls {
									if Task.isCancelled { break }
									let deg = rotationsCopy[u] ?? 0
									if deg % 360 == 0 {
										await MainActor.run { rotationResults[u] = true; rotProgressCount += 1 }
										continue
									}
									let ok = await Self.rotateImageFile(at: u, degrees: deg)
									await MainActor.run {
										rotationResults[u] = ok
										rotProgressCount += 1
										if ok {
											// Update UI: remove from selection and refresh thumbnails
											removeFromSelection(u)
										}
									}
								}
								await MainActor.run {
									isApplyingRotations = false
									// Force thumbnail refresh
									refreshToken = UUID()
									isShowingRotationSheet = false
								}
							}
						}
						.disabled(!hasSelectedPhotos)
					}
				}
				.padding(.horizontal)
			}
			.padding()
			.frame(minWidth: 420, minHeight: 200)
		}
		.sheet(isPresented: $isShowingBrightnessSheet) {
			VStack(spacing: 16) {
				Text("Adjust Brightness for \(selectedPhotoCount) photo\(selectedPhotoCount == 1 ? "" : "s")")
					.font(.headline)

				VStack(alignment: .leading, spacing: 6) {
					HStack {
						Text("Brightness")
						Spacer()
						Text(String(format: "%+.2f", brightnessAdjustment))
							.monospacedDigit()
							.foregroundStyle(.secondary)
					}
					Slider(value: $brightnessAdjustment, in: -1.0...1.0, step: 0.05)
				}
				.padding(.horizontal)

				if isApplyingBrightness {
					ProgressView(value: Double(brightnessProgressCount), total: Double(selectedPhotoCount))
						.padding(.horizontal)
					ScrollView {
						VStack(alignment: .leading, spacing: 8) {
							ForEach(selectedPhotoURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }), id: \.self) { u in
								HStack {
									Text(u.lastPathComponent)
										.font(.caption)
										.lineLimit(1)
									Spacer()
									if brightnessResults[u] == nil {
										ProgressView().controlSize(.small)
									} else if brightnessResults[u] == true {
										Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
									} else {
										Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
									}
								}
							}
						}
						.padding(.horizontal)
					}
					.frame(maxHeight: 200)
				}

				HStack {
					Button("Cancel") { if !isApplyingBrightness { isShowingBrightnessSheet = false } }
						.disabled(isApplyingBrightness)
					Spacer()
					if isApplyingBrightness {
						Button("Close") { isShowingBrightnessSheet = false }
					} else {
						Button("Apply") {
							let urls = selectedPhotoURLs
							brightnessResults = Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as Bool?) })
							brightnessProgressCount = 0
							isApplyingBrightness = true
							let delta = brightnessAdjustment
							brightnessApplyTask?.cancel()
							brightnessApplyTask = Task.detached(priority: .utility) {
								for u in urls {
									if Task.isCancelled { break }
									let ok = await Self.adjustBrightnessFile(at: u, delta: delta)
									await MainActor.run {
										brightnessResults[u] = ok
										brightnessProgressCount += 1
									}
								}
								await MainActor.run {
									isApplyingBrightness = false
									refreshToken = UUID()
									isShowingBrightnessSheet = false
								}
							}
						}
						.disabled(!hasSelectedPhotos || brightnessAdjustment == 0)
					}
				}
				.padding(.horizontal)
			}
			.padding()
			.frame(minWidth: 380, minHeight: 220)
		}
	}

	private var nonSQLiteWorkingSheetBinding: Binding<Bool> {
		Binding(
			get: { isVaultWorking && !isSQLiteObjectStoreView },
			set: { newValue in
				if !newValue {
					isVaultWorking = false
				}
			}
		)
	}

	// MARK: - Main content

	private func triggerRepairMetadata(for url: URL) {
		Task.detached(priority: .utility) {
			let (ok, msg) = await Self.repairMetadata(for: url)
			await MainActor.run {
				if ok {
					refreshToken = UUID()
					repairResultMessage = "Repair succeeded for \(url.lastPathComponent)"
				} else {
					logger.error("Repair metadata failed: \(msg ?? "")")
					repairResultMessage = "Repair failed for \(url.lastPathComponent): \(msg ?? "Unknown error")"
				}
				showRepairResult = true
			}
		}
	}

	@ViewBuilder
	private var contentBody: some View {
		VStack(spacing: 0) {
			PersonFilterBanner(personFilterState: personFilterState)
			Group {
				if library.folderURL == nil && !isSQLiteObjectStoreView {
					EmptyFolderView(chooseFolder: chooseFolder)
				} else if library.isScanning && library.photos.isEmpty {
					VStack(spacing: 12) {
						ProgressView()
						Text("Scanning \(library.folderURL?.lastPathComponent ?? "")…")
							.foregroundStyle(.secondary)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if isSQLiteObjectStoreView && isVaultWorking && library.photos.isEmpty {
					Color.clear
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if library.photos.isEmpty {
					ContentUnavailableView(
						isSQLiteObjectStoreView ? "No Objects Found" : "No Photos Found",
						systemImage: "photo.on.rectangle.angled",
						description: Text(isSQLiteObjectStoreView ? "The SQLite object store does not contain any displayable objects." : "This folder doesn't contain any supported image files.")
					)
				} else {
					photoGrid
				}
			}
		}
		.onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
			guard isSQLiteObjectStoreView else { return false }
			Task {
				let urls = await Self.collectFileURLs(from: providers)
				await MainActor.run {
					guard !urls.isEmpty else { return }
					performSQLiteSync(sourceURLs: urls)
				}
			}
			return true
		}
	}

	private nonisolated static func collectFileURLs(from providers: [NSItemProvider]) async -> [URL] {
		var result: [URL] = []
		var seen: Set<String> = []
		for provider in providers {
			if let url = await loadFileURL(from: provider),
			   seen.insert(url.standardizedFileURL.path).inserted {
				result.append(url)
			}
		}
		return result
	}

	private nonisolated static func loadFileURL(from provider: NSItemProvider) async -> URL? {
		if provider.canLoadObject(ofClass: URL.self) {
			let loadedURL = await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
				_ = provider.loadObject(ofClass: URL.self) { url, _ in
					if let url, url.isFileURL {
						cont.resume(returning: url)
					} else {
						cont.resume(returning: nil)
					}
				}
			}
			if let loadedURL {
				return loadedURL
			}
		}

		return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
			provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
				if let url = item as? URL, url.isFileURL {
					cont.resume(returning: url)
					return
				}
				if let data = item as? Data,
				   let string = String(data: data, encoding: .utf8),
				   let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
				   url.isFileURL {
					cont.resume(returning: url)
					return
				}
				if let string = item as? String,
				   let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
				   url.isFileURL {
					cont.resume(returning: url)
					return
				}
				cont.resume(returning: nil)
			}
		}
	}

	@ViewBuilder
	private var photoGrid: some View {
		ScrollViewReader { scrollProxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 16) {
					if shouldGroupGridByDescription, !displayedPhotoSections.isEmpty {
						ForEach(displayedPhotoSections) { section in
							photoGridSectionHeader(section)
							if !isPhotoSectionCollapsed(section) {
								photoGridCells(for: section.photos)
							}
						}
					} else {
						photoGridCells(for: displayedPhotos)
					}
				}
				.padding(12)
			}
			.coordinateSpace(name: "photoGridArea")
			.onChange(of: photoGridScrollRequest) { _, request in
				guard let request else { return }
				withAnimation(.easeInOut(duration: 0.2)) {
					scrollProxy.scrollTo(request.url, anchor: .center)
				}
				DispatchQueue.main.async {
					_ = scrollGridToPhoto(request.url)
				}
			}
			.onPreferenceChange(ThumbnailFramePreferenceKey.self) { frames in
				queueThumbnailFrameUpdate(frames)
			}
			.simultaneousGesture(
				DragGesture(minimumDistance: 4, coordinateSpace: .named("photoGridArea"))
					.onChanged { value in
						if selectionDragStart == nil {
							if let startURL = thumbnailURL(at: value.startLocation) {
								let dragURLs = contextActionURLs(for: startURL)
								if beginSystemFileDrag(urls: dragURLs) {
									suppressMarqueeDuringItemDrag = true
									stopSelectionAutoScroll()
									return
								}
							}
							selectionDragStart = value.startLocation
							selectionDragBase = selectedSetForMarqueeBase()
							selectionDragMode = marqueeSelectionModeForCurrentModifiers()
						}
						if suppressMarqueeDuringItemDrag { return }
						selectionDragCurrent = value.location
						updateDragSelection()
						startSelectionAutoScrollIfNeeded()
					}
					.onEnded { _ in
						if suppressMarqueeDuringItemDrag {
							suppressMarqueeDuringItemDrag = false
							stopSelectionAutoScroll()
							return
						}
						updateDragSelection()
						selectionDragStart = nil
						selectionDragCurrent = nil
						selectionDragBase = []
						selectionDragMode = .replace
						stopSelectionAutoScroll()
					}
			)
			.overlay(alignment: .topLeading) {
				if let rect = currentSelectionRect {
					RoundedRectangle(cornerRadius: 6)
						.fill(Color.accentColor.opacity(0.15))
						.overlay {
							RoundedRectangle(cornerRadius: 6)
								.stroke(Color.accentColor.opacity(0.8), lineWidth: 1.5)
						}
						.frame(width: rect.width, height: rect.height)
						.position(x: rect.midX, y: rect.midY)
				}
			}
			.overlay(alignment: .bottom) {
				if library.isScanning {
					HStack(spacing: 8) {
						ProgressView().controlSize(.small)
						Text("Scanning… \(library.photos.count.formatted()) photo\(library.photos.count == 1 ? "" : "s") found")
							.font(.callout)
					}
					.padding(.horizontal, 14)
					.padding(.vertical, 8)
					.background(.thinMaterial, in: Capsule())
					.padding(.bottom, 12)
				}
			}
				.overlay(alignment: .top) {
					FaceScanProgressOverlay()
				}
				.background {
					SelectAllKeyboardShortcutView(isEnabled: !displayedPhotos.isEmpty) {
						selectAllDisplayedPhotos()
					}
				}
				.background {
					GridArrowKeyboardShortcutView(isEnabled: !displayedPhotos.isEmpty) { direction in
						moveGridSelection(in: direction)
					}
				}
				.background {
					ScrollViewAccessor { scrollView in
						gridScrollView = scrollView
					}
				}
		}
	}

	@ToolbarContentBuilder
	private var toolbarItems: some ToolbarContent {
		ToolbarItem(placement: .automatic) {
			HStack(spacing: 6) {
				Image(systemName: "photo")
					.imageScale(.small)
				Slider(value: $thumbnailSize, in: 80...320)
					.frame(width: 120)
				Image(systemName: "photo.fill")
					.imageScale(.medium)
				// Sort menu
				Picker(selection: $sortModeRaw) {
					ForEach(SortMode.allCases) { mode in
						Text(mode.title).tag(mode.rawValue)
					}
				} label: {
					Image(systemName: "arrow.up.arrow.down.square")
				}
				.pickerStyle(.menu)
				.help("Sort photos")
				Button {
					groupGridByDescription.toggle()
				} label: {
					Image(systemName: groupGridByDescription ? "rectangle.split.3x1.fill" : "rectangle.split.3x1")
				}
				.help(groupGridByDescription ? "Showing sections by Description — click to show a flat grid" : "Group thumbnails into sections by Description (person name)")
				Button {
					PeopleWindowPresenter.show(using: openWindow)
				} label: {
					Image(systemName: "person.2.fill")
				}
				.help("People")
				Menu {
					if bookmarkURLs.isEmpty {
						Text("No bookmarks")
					} else {
						ForEach(bookmarkURLs, id: \.self) { url in
							Button(url.lastPathComponent) {
								openBookmarkedFolder(url)
							}
						}
						Divider()
					}
					Button("Manage Bookmarks…") {
						showBookmarkManager = true
					}
				} label: {
					Image(systemName: "bookmark")
				}
				.help("Open or manage bookmarked folders")
				// Edit / selection controls
				Button {
					selectionMode.toggle()
				} label: {
					Text(selectionMode ? "Done" : "Edit")
				}
				.help("Select multiple thumbnails for bulk operations")
				Button(action: {
					loadExistingPersonNamesForAssignment()
					assignPersonTargetURLs = faceActionTargetURLs
					isAssigningPerson = true
				}) {
					Text("Assign Person")
				}
				.disabled(faceActionTargetURLs.isEmpty || isPersonRecognitionWorking)
				.help("Assign faces, write metadata, and teach Ollama recognition for selected or displayed photos")
				Button(action: {
					rescanFaceRecognitionForSelection()
				}) {
					Text("Rescan Faces")
				}
				.disabled(faceActionTargetURLs.isEmpty || isRescanningFaces || faceScanProgress.isActive)
				.help("Rescan selected photos, or all currently displayed photos when none are selected")
				Button(action: {
					recognizePeopleWithOllama()
				}) {
					Text("Recognize People")
				}
				.disabled(personRecognitionTargetURLs.isEmpty || isPersonRecognitionWorking)
				.help("Recognize taught people in selected photos, or all displayed photos when none are selected")
					if selectionMode {
					Button(action: {
						beginKeywordEditing(for: selectedPhotoURLs)
					}) {
						Text("Edit Keywords")
					}
					.disabled(!hasSelectedPhotos)
					.help("Edit keyword metadata for selected photos")
					Button(action: {
						// Rotate selected thumbnails left
						for u in selectedPhotoURLs {
							let cur = selectedRotations[u] ?? 0
							let next = (cur - 90) % 360
							selectedRotations[u] = next < 0 ? next + 360 : next
						}
					}) {
						Image(systemName: "rotate.left")
					}
					.disabled(!hasSelectedPhotos)
					.help("Rotate selection left 90° (preview)")
					Button(action: {
						// Rotate selected thumbnails right
						for u in selectedPhotoURLs {
							let cur = selectedRotations[u] ?? 0
							selectedRotations[u] = (cur + 90) % 360
						}
					}) {
						Image(systemName: "rotate.right")
					}
					.disabled(!hasSelectedPhotos)
					.help("Rotate selection right 90° (preview)")
					Button(action: {
						// Trigger delete confirmation
						requestDeleteConfirmation(urls: selectedPhotoURLs, source: "toolbar")
					}) {
						Image(systemName: "trash")
					}
					.disabled(!hasSelectedPhotos)
					.help("Permanently delete selected files")
					Button(action: {
						// Show rotation apply sheet
						isShowingRotationSheet = true
					}) {
						Text("Apply Rotations")
					}
					.disabled(!hasSelectedPhotos || selectedRotations.filter { $0.value % 360 != 0 }.isEmpty)
					.help("Persist rotations for selected files")
					Button(action: {
						isShowingBrightnessSheet = true
					}) {
						Image(systemName: "sun.max")
					}
					.disabled(!hasSelectedPhotos)
					.help("Adjust brightness of selected photos")
					Button(action: {
						selectAllDisplayedPhotos()
					}) {
						Text("Select All")
					}
					.help("Select all displayed thumbnails")
					Button(action: { clearSelection() }) {
						Text("Clear")
					}
					.help("Clear selection")
				}
				// Search field for filtering thumbnails by regex against
				// filename, DESCRIPTION (person name), and other metadata.
				// Runs filtering in the background via `scheduleSort()`.
				if let galleryStatusText {
					Text(galleryStatusText)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.help(galleryStatusHelpText)
				}
				HStack(spacing: 6) {
					Image(systemName: "magnifyingglass")
					TextField("Search (regex)", text: $searchText)
						.textFieldStyle(.roundedBorder)
						.frame(minWidth: 180, maxWidth: 380)
					if !searchText.isEmpty {
						Button {
							searchText = ""
						} label: {
							Image(systemName: "xmark.circle.fill")
						}
						.buttonStyle(.plain)
					}
				}
			}
			.font(.caption)
			.help("Thumbnail size")
		}
	}
	
	
	// MARK: - Actions

	private var filteredPersonNameSuggestions: [String] {
		let query = assignPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return [] }
		return existingPersonNames.filter {
			$0.localizedCaseInsensitiveContains(query) && $0.localizedCaseInsensitiveCompare(query) != .orderedSame
		}
	}

	private var selectedPhotoCount: Int {
		if isAllDisplayedSelectionActive {
			return max(0, displayedPhotos.count - deselectedItemsFromAll.count)
		}
		return selectedItems.count
	}

	private var hasSelectedPhotos: Bool {
		selectedPhotoCount > 0
	}

	private var isGalleryFilterActive: Bool {
		!searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || personFilterPaths != nil
	}

	private var activeSortMode: SortMode {
		SortMode(rawValue: sortModeRaw) ?? .alphaAsc
	}

	private var shouldGroupGridByDescription: Bool {
		groupGridByDescription
	}

	private static let noDescriptionSectionKey = "\u{0000}No Description"

	private func isPhotoSectionCollapsed(_ section: PhotoGridSection) -> Bool {
		collapsedPhotoSectionIDs.contains(section.id)
	}

	private func togglePhotoSectionCollapse(_ sectionID: String) {
		if collapsedPhotoSectionIDs.contains(sectionID) {
			collapsedPhotoSectionIDs.remove(sectionID)
		} else {
			collapsedPhotoSectionIDs.insert(sectionID)
		}
	}

	@ViewBuilder
	private func photoGridSectionHeader(_ section: PhotoGridSection) -> some View {
		Button {
			withAnimation(.easeInOut(duration: 0.2)) {
				togglePhotoSectionCollapse(section.id)
			}
		} label: {
			HStack(spacing: 8) {
				Image(systemName: isPhotoSectionCollapsed(section) ? "chevron.right" : "chevron.down")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
					.frame(width: 12)
				Text(section.title)
					.font(.headline)
					.foregroundStyle(.primary)
				Text("\(section.photos.count)")
					.font(.caption)
					.foregroundStyle(.secondary)
					.monospacedDigit()
				Spacer()
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(isPhotoSectionCollapsed(section) ? "Expand section" : "Collapse section")
	}

	@ViewBuilder
	private func photoGridCells(for photos: [PhotoItem]) -> some View {
		LazyVGrid(
			columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize * 1.4), spacing: 10)],
			spacing: 10
		) {
			ForEach(photos) { photo in
				PhotoGridCell(
					url: photo.url,
					size: thumbnailSize,
					refreshToken: refreshToken,
					metadataRefreshToken: metadataRefreshTokens[photo.url] ?? refreshToken,
					forceLoad: forceThumbnailLoading,
					isSelected: isPhotoSelected(photo.url),
					selectionMode: selectionMode,
					contextActionURLs: { contextActionURLs(for: photo.url) },
					onSingleClick: { handleThumbnailSingleClick(photo.url) },
					onDoubleClick: { openPhotoViewer(photo.url) },
					onCopyFiles: copyFilesToPasteboard,
					onEditKeywords: { beginKeywordEditing(for: contextActionURLs(for: photo.url)) },
					onRepairMetadata: { triggerRepairMetadata(for: photo.url) },
					onRecognizeWithOllama: {
						recognizeContextImagesWithOllama(contextActionURLs(for: photo.url))
					}
				)
			}
		}
	}

	private var galleryStatusText: String? {
		var parts: [String] = []
		if isGalleryFilterActive {
			parts.append("\(displayedPhotos.count) visible")
		}
		if hasSelectedPhotos {
			parts.append("\(selectedPhotoCount) selected")
		}
		guard !parts.isEmpty else { return nil }
		return parts.joined(separator: " · ")
	}

	private var galleryStatusHelpText: String {
		var parts: [String] = []
		if isGalleryFilterActive {
			parts.append("\(displayedPhotos.count) of \(library.photos.count) thumbnails match the active filter")
		}
		if hasSelectedPhotos {
			parts.append("\(selectedPhotoCount) thumbnail\(selectedPhotoCount == 1 ? "" : "s") selected")
		}
		return parts.joined(separator: ". ")
	}

	private var selectedPhotoURLs: [URL] {
		if isAllDisplayedSelectionActive {
			let excluded = deselectedItemsFromAll
			return displayedPhotos.map(\.url).filter { !excluded.contains($0) }
		}
		return Array(selectedItems)
	}

	private func selectedPhotoURLsInDisplayOrder() -> [URL] {
		let orderedURLs = displayedPhotos.map(\.url)
		let orderIndex = Dictionary(uniqueKeysWithValues: orderedURLs.enumerated().map { ($1, $0) })
		return selectedPhotoURLs.sorted {
			(orderIndex[$0] ?? Int.max) < (orderIndex[$1] ?? Int.max)
		}
	}

	private func isPhotoSelected(_ url: URL) -> Bool {
		if isAllDisplayedSelectionActive {
			return !deselectedItemsFromAll.contains(url)
		}
		return selectedItems.contains(url)
	}

	private func clearSelection() {
		selectedItems.removeAll()
		deselectedItemsFromAll.removeAll()
		isAllDisplayedSelectionActive = false
	}

	private func selectSinglePhoto(_ url: URL) {
		selectedItems = [url]
		deselectedItemsFromAll.removeAll()
		isAllDisplayedSelectionActive = false
	}

	private func removeFromSelection(_ url: URL) {
		if isAllDisplayedSelectionActive {
			deselectedItemsFromAll.insert(url)
		} else {
			selectedItems.remove(url)
		}
	}

	private func selectedSetForMarqueeBase() -> Set<URL> {
		Set(selectedPhotoURLs)
	}

	private func loadExistingPersonNamesForAssignment() {
		Task.detached(priority: .utility) {
			let names = await FaceProcessor.shared.personsList()
				.compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			let unique = Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
			await MainActor.run { existingPersonNames = unique }
		}
	}

	private var faceActionTargetURLs: [URL] {
		if hasSelectedPhotos { return selectedPhotoURLs }
		return displayedPhotos.map(\.url)
	}

	private func beginKeywordEditing(for urls: [URL]) {
		var seen: Set<URL> = []
		let targets = urls.filter { seen.insert($0).inserted }
		guard !targets.isEmpty else { return }
		keywordEditTargets = targets
		editKeywordsText = ""
		editProgressCount = 0
		editingResults = [:]
		isEditingKeywords = true

		if targets.count == 1, let target = targets.first {
			Task.detached(priority: .utility) {
				let keywords = await Self.readKeywords(from: target)
				await MainActor.run {
					if keywordEditTargets == targets && !isApplyingKeywords {
						editKeywordsText = keywords.joined(separator: ", ")
					}
				}
			}
		}
	}

	private func applyKeywordEdit(_ operation: KeywordEditOperation) {
		let urls = keywordEditTargets
		guard !urls.isEmpty else { return }

		let keywords: [String]
		switch operation {
		case .append, .replace:
			keywords = Self.parseKeywordInput(editKeywordsText)
		case .clear:
			keywords = []
		}

		if operation == .append && keywords.isEmpty {
			return
		}

		editingResults = Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as Bool?) })
		editProgressCount = 0
		isApplyingKeywords = true

		keywordEditTask?.cancel()
		keywordEditTask = Task.detached(priority: .utility) {
			let workerCount = max(1, min(urls.count, PhotoLibrary.workerCount))
			await withTaskGroup(of: (URL, Bool).self) { group in
				var nextIndex = 0

				func enqueueNext() {
					guard nextIndex < urls.count else { return }
					let url = urls[nextIndex]
					nextIndex += 1
					group.addTask {
						if Task.isCancelled { return (url, false) }
						let ok: Bool
						switch operation {
						case .append:
							ok = await Self.writeKeywords(to: url, keywords: keywords)
						case .replace:
							ok = await Self.replaceKeywords(on: url, keywords: keywords)
						case .clear:
							ok = await Self.replaceKeywords(on: url, keywords: [])
						}
						return (url, ok)
					}
				}

				for _ in 0..<workerCount {
					enqueueNext()
				}

				while let (url, ok) = await group.next() {
					await MainActor.run {
						editingResults[url] = ok
						editProgressCount += 1
						if ok {
							MetadataCache.shared.invalidate(for: url)
							queueMetadataRefresh(for: url)
						}
					}
					enqueueNext()
				}
			}

			await MainActor.run {
				for (url, result) in editingResults where result == true {
					removeFromSelection(url)
				}
				isApplyingKeywords = false
				scheduleSort()
			}
		}
	}

	private func openPhotoViewer(_ url: URL) {
		let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
		let isVideo = PhotoLibrary.isVideoMediaFile(url, contentType: contentType)
		if isVideo,
		   PhotoLibrary.requiresExternalVideoPlayer(url),
		   !useVLCForVideoPlayback {
			vaultAlertMessage = "\(url.lastPathComponent) cannot be played by the built-in player. Enable General > Use VLC for video playback to use embedded VLC playback."
			showVaultAlert = true
			return
		}
		if isVideo,
		   useVLCForVideoPlayback,
		   !EmbeddedVLCPlayerView.isAvailable,
		   PhotoLibrary.requiresExternalVideoPlayer(url) {
			vaultAlertMessage = "Embedded VLC playback is enabled, but libVLC could not be loaded from VLC.app. Install VLC.app or use a QuickTime-supported video format."
			showVaultAlert = true
			return
		}
		PhotoNavigationContext.shared.update(urls: displayedPhotos.map(\.url))
		if SQLiteObjectStore.needsMaterialization(url) {
			Task.detached(priority: .userInitiated) {
				_ = try? await SQLiteObjectStore.shared.materializeWorkingCopyIfNeeded(url)
			}
		}
		openWindow(id: "photo-viewer", value: url)
	}

	private func thumbnailColumnCount() -> Int {
		let sortedFrames = displayedPhotos.compactMap { photo -> (url: URL, frame: CGRect)? in
			guard let frame = thumbnailFrames[photo.url] else { return nil }
			return (photo.url, frame)
		}
		guard let first = sortedFrames.min(by: {
			if abs($0.frame.minY - $1.frame.minY) > 0.5 {
				return $0.frame.minY < $1.frame.minY
			}
			return $0.frame.minX < $1.frame.minX
		}) else {
			return 1
		}
		let rowY = first.frame.minY
		let threshold: CGFloat = 1
		let count = sortedFrames.filter { abs($0.frame.minY - rowY) < threshold }.count
		return max(1, count)
	}

	private func moveGridSelection(in direction: GridNavigationDirection) {
		guard !displayedPhotos.isEmpty else { return }
		guard !isAllDisplayedSelectionActive else { return }

		let orderedPhotos = displayedPhotos.map(\.url)
		let orderedSelection = selectedPhotoURLsInDisplayOrder()
		guard orderedSelection.count <= 1 else { return }

		guard let currentURL = orderedSelection.first else {
			guard let firstURL = orderedPhotos.first else { return }
			selectSinglePhoto(firstURL)
			return
		}

		guard let currentIndex = orderedPhotos.firstIndex(of: currentURL) else { return }

		let nextIndex: Int?
		switch direction {
		case .left:
			nextIndex = currentIndex > 0 ? currentIndex - 1 : nil
		case .right:
			nextIndex = currentIndex + 1 < orderedPhotos.count ? currentIndex + 1 : nil
		case .up:
			let step = thumbnailColumnCount()
			nextIndex = currentIndex >= step ? currentIndex - step : nil
		case .down:
			let step = thumbnailColumnCount()
			nextIndex = currentIndex + step < orderedPhotos.count ? currentIndex + step : nil
		}

		guard let nextIndex, orderedPhotos.indices.contains(nextIndex) else { return }
		let targetURL = orderedPhotos[nextIndex]

		selectSinglePhoto(targetURL)
	}

	private func startSelectionAutoScrollIfNeeded() {
		guard selectionAutoScrollTask == nil else { return }
		selectionAutoScrollTask = Task { @MainActor in
			defer { selectionAutoScrollTask = nil }
			while !Task.isCancelled {
				guard selectionDragStart != nil,
					  selectionDragCurrent != nil,
					  !suppressMarqueeDuringItemDrag
				else {
					break
				}

				guard let scrollView = gridScrollView,
					  let documentView = scrollView.documentView,
					  let dragPoint = selectionDragCurrent
				else {
					try? await Task.sleep(nanoseconds: 30_000_000)
					continue
				}

				let visibleRect = scrollView.contentView.bounds
				let edgeThreshold: CGFloat = 80
				let maxStep: CGFloat = 36
				var deltaY: CGFloat = 0

				if dragPoint.y > visibleRect.maxY - edgeThreshold {
					let distance = min(edgeThreshold, dragPoint.y - (visibleRect.maxY - edgeThreshold))
					deltaY = maxStep * (distance / edgeThreshold)
				} else if dragPoint.y < visibleRect.minY + edgeThreshold {
					let distance = min(edgeThreshold, (visibleRect.minY + edgeThreshold) - dragPoint.y)
					deltaY = -maxStep * (distance / edgeThreshold)
				}

				if deltaY != 0 {
					let maxOriginY = max(0, documentView.bounds.height - visibleRect.height)
					let nextOriginY = min(max(0, visibleRect.origin.y + deltaY), maxOriginY)
					if nextOriginY != visibleRect.origin.y {
						scrollView.contentView.bounds.origin.y = nextOriginY
						scrollView.reflectScrolledClipView(scrollView.contentView)
						updateDragSelection()
					}
				}

				try? await Task.sleep(nanoseconds: 30_000_000)
			}
		}
	}

	private func stopSelectionAutoScroll() {
		selectionAutoScrollTask?.cancel()
		selectionAutoScrollTask = nil
	}

	private func selectAllDisplayedPhotos() {
		selectedItems.removeAll()
		deselectedItemsFromAll.removeAll()
		isAllDisplayedSelectionActive = true
	}

	private func recognizeDisplayedImagesWithOllama() {
		guard !ollamaRecognitionURLs(selectedOnly: false).isEmpty else { return }
		ollamaSheetUsesSelection = false
		ollamaSheetExplicitURLs = nil
		isShowingOllamaPromptSheet = true
	}

	private func recognizeSelectedImagesWithOllama() {
		guard !ollamaRecognitionURLs(selectedOnly: true).isEmpty else { return }
		ollamaSheetUsesSelection = true
		ollamaSheetExplicitURLs = nil
		isShowingOllamaPromptSheet = true
	}

	private func ollamaRecognitionURLs(selectedOnly: Bool, explicit: [URL]? = nil) -> [URL] {
		let candidates: [URL]
		if let explicit {
			candidates = explicit
		} else if selectedOnly {
			candidates = selectedPhotoURLsInDisplayOrder()
		} else {
			candidates = displayedPhotos.map(\.url)
		}
		return candidates.filter { url in
			let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
			return !PhotoLibrary.isVideoMediaFile(url, contentType: contentType)
		}
	}

	/// Invoked from a thumbnail's right-click context menu. `urls` is the set
	/// returned by `contextActionURLs(for:)` — either the single right-clicked
	/// photo or the current selection if the click happened on a selected cell.
	private func recognizeContextImagesWithOllama(_ urls: [URL]) {
		let filtered = ollamaRecognitionURLs(selectedOnly: false, explicit: urls)
		guard !filtered.isEmpty else { return }
		ollamaSheetUsesSelection = false
		ollamaSheetExplicitURLs = filtered
		isShowingOllamaPromptSheet = true
	}

	private var personRecognitionTargetURLs: [URL] {
		let candidates = hasSelectedPhotos ? selectedPhotoURLs : displayedPhotos.map(\.url)
		return teachableImageURLs(from: candidates)
	}

	private func teachableImageURLs(from urls: [URL]) -> [URL] {
		urls.filter { url in
			let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
			return !PhotoLibrary.isVideoMediaFile(url, contentType: contentType)
		}
	}

	private func applyPersonNameToSelection() {
		let name = assignPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
		let urls = assignPersonTargetURLs
		guard !name.isEmpty, !urls.isEmpty else { return }

		let teachableURLs = teachableImageURLs(from: urls)
		let totalPhotos = urls.count

		isAssigningPerson = false
		isPersonRecognitionWorking = true
		personRecognitionProgressMessage = "Assigning \(name)"
		personRecognitionProgressCompleted = 0
		personRecognitionProgressTotal = max(totalPhotos, 1)

		let model = ollamaSelectedModel
		personRecognitionTask?.cancel()
		let task = Task.detached(priority: .utility) {
			let assignment = await FaceProcessor.shared.assignPerson(named: name, toFiles: urls)

			var updatedURLs: [URL] = []
			for u in urls {
				if Task.isCancelled { break }
				if await ContentView.writeDescription(to: u, description: name) {
					updatedURLs.append(u)
				}
			}

			if Task.isCancelled {
				await MainActor.run {
					isPersonRecognitionWorking = false
					personRecognitionTask = nil
					personAssignmentResultMessage = "Assigning \(name) was cancelled."
					showPersonAssignmentResult = true
				}
				return
			}

			let metadataUpdatedURLs = updatedURLs
			await MainActor.run {
				refreshMetadataAfterWrite(for: metadataUpdatedURLs)
			}

			let training: PersonRecognitionTrainingResult
			if teachableURLs.isEmpty {
				training = PersonRecognitionTrainingResult(examplesAdded: 0, failed: 0)
			} else {
				await MainActor.run {
					personRecognitionProgressMessage = "Teaching \(name)"
					personRecognitionProgressCompleted = 0
					personRecognitionProgressTotal = teachableURLs.count
				}
				training = await PersonRecognitionStore.shared.train(name: name, imageURLs: teachableURLs, model: model) { completed, total, status in
					Task { @MainActor in
						personRecognitionProgressCompleted = completed
						personRecognitionProgressTotal = total
						personRecognitionProgressMessage = status
					}
				}
			}

			if Task.isCancelled {
				await MainActor.run {
					isPersonRecognitionWorking = false
					personRecognitionTask = nil
					personAssignmentResultMessage = "Assigning \(name) was cancelled."
					showPersonAssignmentResult = true
				}
				return
			}

			await MainActor.run {
				isPersonRecognitionWorking = false
				personRecognitionTask = nil
				personAssignmentResultMessage = Self.personAssignAndTeachResultMessage(
					name: name,
					totalPhotos: totalPhotos,
					assignment: assignment,
					training: training,
					teachableCount: teachableURLs.count
				)
				showPersonAssignmentResult = true
			}
		}
		personRecognitionTask = task
	}

	private static func personAssignAndTeachResultMessage(
		name: String,
		totalPhotos: Int,
		assignment: PersonAssignmentResult,
		training: PersonRecognitionTrainingResult,
		teachableCount: Int
	) -> String {
		var parts: [String] = []
		if assignment.facesAssigned > 0 {
			let faces = assignment.facesAssigned
			let photosUsed = assignment.photosWithFaces
			let skipped = totalPhotos - photosUsed
			var message = "Assigned \(faces) face\(faces == 1 ? "" : "s") from \(photosUsed) of \(totalPhotos) photo\(totalPhotos == 1 ? "" : "s") to \"\(name)\"."
			if skipped > 0 {
				message += " \(skipped) photo\(skipped == 1 ? "" : "s") had no detectable face."
			}
			parts.append(message)
		} else {
			parts.append("No detectable faces were found in the selected photos, but metadata was updated where possible.")
		}

		if teachableCount == 0 {
			parts.append("No teachable image\(totalPhotos == 1 ? "" : "s") were available for Ollama recognition.")
		} else if training.examplesAdded > 0 {
			parts.append("Added \(training.examplesAdded) Ollama training example\(training.examplesAdded == 1 ? "" : "s") for \(name).")
			if training.failed > 0 {
				parts.append("\(training.failed) training photo\(training.failed == 1 ? "" : "s") failed.")
			}
		} else {
			parts.append("No Ollama training examples were added for \(name). \(training.failed) photo\(training.failed == 1 ? "" : "s") failed.")
		}
		return parts.joined(separator: " ")
	}

	private func recognizePeopleWithOllama() {
		let urls = personRecognitionTargetURLs
		guard !urls.isEmpty else { return }
		let model = ollamaSelectedModel
		isPersonRecognitionWorking = true
		personRecognitionProgressMessage = "Recognizing people"
		personRecognitionProgressCompleted = 0
		personRecognitionProgressTotal = urls.count

		personRecognitionTask?.cancel()
		let task = Task.detached(priority: .utility) {
			let profileCount = await PersonRecognitionStore.shared.profileCount()
			guard profileCount > 0 else {
				await MainActor.run {
					isPersonRecognitionWorking = false
					personRecognitionTask = nil
					personRecognitionResultMessage = "Teach at least one person before running recognition."
					showPersonRecognitionResult = true
				}
				return
			}

			let result = await PersonRecognitionStore.shared.recognize(imageURLs: urls, model: model) { completed, total, status in
				Task { @MainActor in
					personRecognitionProgressCompleted = completed
					personRecognitionProgressTotal = total
					personRecognitionProgressMessage = status
				}
				} onRecognized: { url, names in
					for name in names {
						_ = await FaceProcessor.shared.assignPerson(named: name, toFiles: [url])
					}
					if !names.isEmpty {
						let desc = names.joined(separator: ", ")
						_ = await ContentView.writeDescription(to: url, description: desc)
					}
					await MainActor.run {
						queueMetadataRefresh(for: url)
				}
			}

			if Task.isCancelled {
				await MainActor.run {
					isPersonRecognitionWorking = false
					personRecognitionTask = nil
					personRecognitionResultMessage = "Person recognition was cancelled."
					showPersonRecognitionResult = true
				}
				return
			}

			await MainActor.run {
				isPersonRecognitionWorking = false
				personRecognitionTask = nil
				personRecognitionResultMessage = "Processed \(result.photosProcessed) photo\(result.photosProcessed == 1 ? "" : "s"). Matched taught people in \(result.photosWithMatches) photo\(result.photosWithMatches == 1 ? "" : "s") and assigned \(result.namesAssigned) name\(result.namesAssigned == 1 ? "" : "s"). \(result.failed) failed."
				showPersonRecognitionResult = true
				scheduleSort()
			}
		}
		personRecognitionTask = task
	}

	private func runOllamaRecognition(selectedOnly: Bool, explicit: [URL]? = nil) {
		let urls = ollamaRecognitionURLs(selectedOnly: selectedOnly, explicit: explicit)
		guard !urls.isEmpty else { return }
		let prompt = ollamaPrompt
		let model = ollamaSelectedModel
		let shouldUpdateMetadata = ollamaUpdateMetadata
		isOllamaRecognitionRunning = true
		ollamaRecognitionTask?.cancel()
		let task = Task.detached(priority: .utility) {
			_ = await OllamaRecognizer.shared.recognizeAndLog(
				imageURLs: urls,
				prompt: prompt,
				model: model,
				onRecognized: { url, text in
					guard shouldUpdateMetadata else { return }
					let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
					guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return }
					_ = await ContentView.writeKeywords(to: url, keywords: [trimmed])
					await MainActor.run {
						OllamaProgress.shared.markMetadataUpdated(for: url)
					}
				}
			)
			await MainActor.run {
				OllamaProgress.shared.end()
				isOllamaRecognitionRunning = false
				ollamaRecognitionTask = nil
			}
		}
		ollamaRecognitionTask = task
		OllamaProgress.shared.begin(total: urls.count, model: model, cancel: { task.cancel() })
	}

	private func rescanFaceRecognitionForSelection() {
		let urls = faceActionTargetURLs
		guard !urls.isEmpty else { return }
		isRescanningFaces = true
		let rescanTask = Task.detached(priority: .utility) {
			let rescanned = await FaceProcessor.shared.rescanFaceRecognition(forFiles: urls) { phase, completed, total in
				Task { @MainActor in
					FaceScanProgress.shared.update(completed: completed, total: total, status: phase)
				}
			}
			let wasCancelled = Task.isCancelled
			await MainActor.run {
				FaceScanProgress.shared.end()
				isRescanningFaces = false
				if !wasCancelled {
					faceRescanResultMessage = "Rescanned facial recognition for \(rescanned) file\(rescanned == 1 ? "" : "s")."
					showFaceRescanResult = true
				}
			}
		}
		FaceScanProgress.shared.begin(title: "Rescanning Faces", total: urls.count) {
			rescanTask.cancel()
		}
	}

	private func handleThumbnailSingleClick(_ url: URL) {
		selectionDragStart = nil
		selectionDragCurrent = nil
		selectionDragBase = []
		selectionDragMode = .replace
		suppressMarqueeDuringItemDrag = false
		let modifierMode = marqueeSelectionModeForCurrentModifiers()
		if !selectionMode && modifierMode == .replace {
			selectedItems = [url]
			deselectedItemsFromAll.removeAll()
			isAllDisplayedSelectionActive = false
			return
		}

		switch modifierMode {
		case .replace where selectionMode:
			toggleSinglePhotoSelection(url)
		case .replace:
			selectedItems = [url]
			deselectedItemsFromAll.removeAll()
			isAllDisplayedSelectionActive = false
		case .add:
			addSinglePhotoSelection(url)
		case .subtract:
			removeFromSelection(url)
		case .toggle:
			toggleSinglePhotoSelection(url)
		}
	}

	private func addSinglePhotoSelection(_ url: URL) {
		if isAllDisplayedSelectionActive {
			deselectedItemsFromAll.remove(url)
		} else {
			selectedItems.insert(url)
		}
	}

	private func toggleSinglePhotoSelection(_ url: URL) {
		if isAllDisplayedSelectionActive {
			if deselectedItemsFromAll.contains(url) {
				deselectedItemsFromAll.remove(url)
			} else {
				deselectedItemsFromAll.insert(url)
			}
		} else if selectedItems.contains(url) {
			selectedItems.remove(url)
		} else {
			selectedItems.insert(url)
		}
	}

	private var currentSelectionRect: CGRect? {
		guard let start = selectionDragStart, let current = selectionDragCurrent else { return nil }
		let origin = CGPoint(x: min(start.x, current.x), y: min(start.y, current.y))
		let size = CGSize(width: abs(current.x - start.x), height: abs(current.y - start.y))
		if size.width < 2, size.height < 2 { return nil }
		return CGRect(origin: origin, size: size)
	}

	private func updateDragSelection() {
		guard let selectionRect = currentSelectionRect else { return }
		let hits = thumbnailFrames.compactMap { (url, frame) -> URL? in
			frame.intersects(selectionRect) ? url : nil
		}
		let hitSet = Set(hits)
		isAllDisplayedSelectionActive = false
		deselectedItemsFromAll.removeAll()
		switch selectionDragMode {
		case .replace:
			selectedItems = hitSet
		case .add:
			selectedItems = selectionDragBase.union(hitSet)
		case .subtract:
			selectedItems = selectionDragBase.subtracting(hitSet)
		case .toggle:
			var next = selectionDragBase
			for url in hitSet {
				if next.contains(url) {
					next.remove(url)
				} else {
					next.insert(url)
				}
			}
			selectedItems = next
		}
	}

	private func marqueeSelectionModeForCurrentModifiers() -> MarqueeSelectionMode {
		let flags = NSEvent.modifierFlags
		if flags.contains(.command) { return .toggle }
		if flags.contains(.option) { return .subtract }
		if flags.contains(.shift) { return .add }
		return .replace
	}

	private func thumbnailURL(at point: CGPoint) -> URL? {
		for (url, frame) in thumbnailFrames where frame.contains(point) {
			return url
		}
		return nil
	}

	private func beginSystemFileDrag(urls: [URL]) -> Bool {
		guard !urls.isEmpty,
			  let event = NSApp.currentEvent,
			  let contentView = NSApp.keyWindow?.contentView
		else {
			return false
		}

		let origin = event.locationInWindow
		let items: [NSDraggingItem] = urls.enumerated().map { (idx, url) in
			let item = NSDraggingItem(pasteboardWriter: url as NSURL)
			let icon = NSWorkspace.shared.icon(forFile: url.path)
			icon.size = NSSize(width: 48, height: 48)
			let offset = CGFloat(min(idx, 10)) * 2.0
			let frame = NSRect(x: origin.x + offset, y: origin.y - offset, width: 48, height: 48)
			item.setDraggingFrame(frame, contents: icon)
			return item
		}

		let session = contentView.beginDraggingSession(with: items, event: event, source: thumbnailDraggingSource)
		session.animatesToStartingPositionsOnCancelOrFail = true
		return true
	}

	private func contextActionURLs(for photoURL: URL) -> [URL] {
		if isPhotoSelected(photoURL), hasSelectedPhotos {
			return selectedPhotoURLs.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
		}
		return [photoURL]
	}

	private func copyFilesToPasteboard(_ urls: [URL]) {
		guard !urls.isEmpty else { return }
		let copied = NSPasteboard.general
		copied.clearContents()
		let items: [NSPasteboardItem] = urls.map { url in
			let item = NSPasteboardItem()
			item.setString(url.absoluteString, forType: .fileURL)
			item.setString(url.path, forType: .string)
			return item
		}
		if copied.writeObjects(items) {
			logger.log("copyFilesToPasteboard: copied \(urls.count, privacy: .public) file URL(s)")
		} else {
			logger.error("copyFilesToPasteboard: failed to write \(urls.count, privacy: .public) file URL(s) to pasteboard")
		}
	}

	private func copySelectedFiles() {
		copyFilesToPasteboard(selectedPhotoURLs)
	}

	private func pasteboardFileURLs() -> [URL] {
		let pasteboard = NSPasteboard.general
		let classes: [AnyClass] = [NSURL.self]
		let options: [NSPasteboard.ReadingOptionKey: Any] = [
			.urlReadingFileURLsOnly: true
		]
		let urls = pasteboard.readObjects(forClasses: classes, options: options) as? [URL] ?? []
		if !urls.isEmpty {
			return urls
		}

		guard let items = pasteboard.pasteboardItems else { return [] }
		return items.compactMap { item in
			if let fileURLString = item.string(forType: .fileURL),
			   let url = URL(string: fileURLString),
			   url.isFileURL {
				return url
			}
			if let path = item.string(forType: .string), path.hasPrefix("/") {
				return URL(fileURLWithPath: path)
			}
			return nil
		}
	}

	private func updateTabRegistry() {
		let title = activeFolderNames.isEmpty
			? (library.folderURL?.lastPathComponent ?? "Picture Viewer")
			: (activeFolderNames.count == 1 ? activeFolderNames[0] : activeFolderNames.joined(separator: " · "))
		let currentSQLiteStoreName = isSQLiteObjectStoreView ? (activeSQLiteStoreName ?? SQLiteObjectStore.configuredStoreName) : nil
		let snapshot = GalleryTabSnapshot(
			id: tabID,
			title: title,
			folderURL: library.folderURL,
			sqliteStoreName: currentSQLiteStoreName,
			isVault: isActiveVaultView,
			photoURLs: library.photos.map(\.url)
		)
		if registeredGalleryFolderURL?.standardizedFileURL.path != library.folderURL?.standardizedFileURL.path,
		   let previousURL = registeredGalleryFolderURL {
			WindowStateStore.shared.recordClosedGalleryFolder(previousURL)
		}
		if registeredSQLiteStoreName != currentSQLiteStoreName,
		   let previousSQLiteStoreName = registeredSQLiteStoreName {
			WindowStateStore.shared.recordClosedSQLiteStore(named: previousSQLiteStoreName)
		}
		if let folderURL = library.folderURL {
			WindowStateStore.shared.recordOpenGalleryFolder(folderURL)
		} else if let currentSQLiteStoreName {
			WindowStateStore.shared.recordOpenSQLiteStore(named: currentSQLiteStoreName)
		}
		registeredGalleryFolderURL = library.folderURL
		registeredSQLiteStoreName = currentSQLiteStoreName
		Task { @MainActor in
			GalleryTabRegistry.shared.update(snapshot)
			FileNavigationMenuState.shared.reload()
		}
	}

	private func syncToAnotherTab() {
		let targets = GalleryTabRegistry.shared.targets(excluding: tabID)
		guard !targets.isEmpty else {
			vaultAlertMessage = "Open another folder or vault tab before syncing."
			showVaultAlert = true
			return
		}

		let alert = NSAlert()
		alert.messageText = "Sync to Tab"
		alert.informativeText = "Copy files missing from this tab into the selected target tab."
		alert.addButton(withTitle: "Sync")
		alert.addButton(withTitle: "Cancel")
		let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
		for target in targets {
			popup.addItem(withTitle: target.title)
		}
		let ignoreDuplicates = NSButton(checkboxWithTitle: "Ignore duplicates", target: nil, action: nil)
		ignoreDuplicates.state = .on
		let stack = NSStackView(views: [popup, ignoreDuplicates])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 8
		stack.frame = NSRect(x: 0, y: 0, width: 340, height: 60)
		alert.accessoryView = stack
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		let target = targets[popup.indexOfSelectedItem]
		performSync(to: target, ignoreDuplicates: ignoreDuplicates.state == .on)
	}

	private func performSync(to target: GalleryTabSnapshot, ignoreDuplicates: Bool) {
		let sourceURLs = library.photos.map(\.url)
		let syncURLs: [URL]
		if ignoreDuplicates {
			let targetNames = Set(target.photoURLs.map { $0.lastPathComponent.lowercased() })
			syncURLs = sourceURLs.filter { !targetNames.contains($0.lastPathComponent.lowercased()) }
		} else {
			syncURLs = sourceURLs
		}
		guard !syncURLs.isEmpty else {
			vaultAlertMessage = "The target tab is already synchronized."
			showVaultAlert = true
			return
		}

		if target.isVault {
			syncFilesToVault(syncURLs, target: target, ignoreDuplicates: ignoreDuplicates)
		} else {
			syncFilesToFolder(syncURLs, target: target)
		}
	}

	private func syncCurrentTabToSQLiteStore() {
		performSQLiteSync(sourceURLs: library.photos.map(\.url))
	}

	private func syncSelectedMediaToSQLiteStore() {
		performSQLiteSync(sourceURLs: selectedPhotoURLs)
	}

	private func backfillSQLiteThumbnails() {
		guard isSQLiteObjectStoreView, !isVaultWorking else { return }
		let storeName = activeSQLiteStoreName ?? SQLiteObjectStore.configuredStoreName
		let databaseFilename = SQLiteObjectStore.databaseFilename(forStoreName: storeName)

		Task {
			do {
				let missingCount = try await SQLiteObjectStore.shared.countObjectsMissingThumbnails(storeName: storeName)
				guard missingCount > 0 else {
					await MainActor.run {
						vaultAlertMessage = "All objects in \(databaseFilename) already have stored thumbnails."
						showVaultAlert = true
					}
					return
				}

				let confirmed = await MainActor.run { () -> Bool in
					let alert = NSAlert()
					alert.messageText = "Backfill Missing Thumbnails"
					alert.informativeText = "Generate and store thumbnail images for \(missingCount) object\(missingCount == 1 ? "" : "s") in \(databaseFilename) that do not have thumbnail data yet. This may take a while for large stores."
					alert.alertStyle = .informational
					alert.addButton(withTitle: "Backfill")
					alert.addButton(withTitle: "Cancel")
					return alert.runModal() == .alertFirstButtonReturn
				}
				guard confirmed else { return }

				await MainActor.run {
					isVaultWorking = true
					vaultProgressMessage = "Backfilling thumbnails in \(databaseFilename)..."
					vaultProgressCompleted = 0
					vaultProgressTotal = missingCount
					sqliteLoadStartDate = Date()
				}

				let backfillStart = Date()
				logger.log("sqlite thumbnail backfill ui: begin store=\(storeName, privacy: .public) missing=\(missingCount, privacy: .public)")
				let progressUI = BackfillProgressUIThrottler()
				let result = try await SQLiteObjectStore.shared.backfillMissingThumbnails(storeName: storeName) { completed, total, currentFilename in
					let shouldUpdateUI = await MainActor.run {
						progressUI.shouldUpdate(completed: completed, total: total)
					}
					guard shouldUpdateUI else { return }
					await MainActor.run {
						vaultProgressCompleted = completed
						vaultProgressTotal = total
						vaultProgressMessage = "Backfilling thumbnails in \(databaseFilename)..."
						vaultProgressCurrentFile = currentFilename
					}
					if completed == total || completed.isMultiple(of: 8) {
						logger.log("sqlite thumbnail backfill ui: progress completed=\(completed, privacy: .public) total=\(total, privacy: .public) file=\(currentFilename, privacy: .public)")
					}
				}

				let hydratedCount = try await SQLiteObjectStore.shared.hydrateStoredThumbnailsForLoadedObjects(
					storeName: storeName
				)
				logger.log("sqlite thumbnail backfill ui: complete filled=\(result.filled, privacy: .public) failed=\(result.failed, privacy: .public) hydrated=\(hydratedCount, privacy: .public) duration=\(Date().timeIntervalSince(backfillStart), privacy: .public)")

				await MainActor.run {
					sqliteLastThumbnailLoadDuration = Date().timeIntervalSince(backfillStart)
					refreshToken = UUID()
					isVaultWorking = false
					vaultProgressMessage = ""
					vaultProgressCompleted = 0
					vaultProgressTotal = 0
					vaultProgressCurrentFile = ""
					sqliteLoadStartDate = nil
					if result.failed > 0 {
						vaultAlertMessage = "Backfilled \(result.filled) of \(result.candidates) thumbnails. \(result.failed) object\(result.failed == 1 ? "" : "s") could not be processed."
						showVaultAlert = true
					}
				}
			} catch {
				await MainActor.run {
					isVaultWorking = false
					vaultProgressMessage = ""
					vaultProgressCompleted = 0
					vaultProgressTotal = 0
					vaultProgressCurrentFile = ""
					sqliteLoadStartDate = nil
					vaultAlertMessage = "Thumbnail backfill failed: \(error.localizedDescription)"
					showVaultAlert = true
				}
			}
		}
	}

	private func warmFilesystemThumbnails(for items: [PhotoItem]) {
		Task.detached(priority: .utility) {
			for item in items {
				if Task.isCancelled { break }
				if ThumbnailCache.shared.memoryImage(for: item.url) != nil { continue }
				if ThumbnailCache.shared.hydrateFromDiskIfAvailable(for: item.url) != nil { continue }
				guard PhotoLibrary.shouldGenerateFilesystemThumbnail(for: item.url, forceLoad: false) else {
					_ = ThumbnailCache.shared.hydrateFromDiskIfAvailable(for: item.url, requireFresh: false)
					continue
				}
				do {
					let img = try await ThumbnailGenerator.shared.generateThumbnail(for: item.url)
					ThumbnailCache.shared.store(img, for: item.url)
				} catch { }
			}
		}
	}

	private func performSQLiteSync(sourceURLs: [URL]) {
		guard SQLiteObjectStore.configuredDirectoryPath != nil else {
			vaultAlertMessage = "Create or open a SQLite store before syncing."
			showVaultAlert = true
			return
		}
		guard !sourceURLs.isEmpty else { return }
		let sqliteTargets = visibleSQLiteSyncTargets()
		guard !sqliteTargets.isEmpty else {
			vaultAlertMessage = "Open a SQLite store before syncing."
			showVaultAlert = true
			return
		}
		let workers = max(1, min(sourceURLs.count, PhotoLibrary.workerCount))

		let alert = NSAlert()
		alert.messageText = "Sync to SQLite Store"
		alert.informativeText = "Sync \(sourceURLs.count) object\(sourceURLs.count == 1 ? "" : "s") to the selected store using up to \(workers) worker\(workers == 1 ? "" : "s")."
		alert.addButton(withTitle: "Sync")
		alert.addButton(withTitle: "Cancel")
		let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
		for target in sqliteTargets {
			popup.addItem(withTitle: target.title)
		}
		alert.accessoryView = popup
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		let selectedTarget = sqliteTargets[popup.indexOfSelectedItem]
			let targetStoreName = selectedTarget.storeName
		let databaseFilename = SQLiteObjectStore.databaseFilename(forStoreName: targetStoreName)

		isVaultWorking = true
		vaultProgressMessage = "Checking \(databaseFilename) for existing objects..."
		vaultProgressCompleted = 0
		vaultProgressTotal = sourceURLs.count
		vaultStoreTask?.cancel()
		let requestedFocusFilename = sourceURLs.count == 1 ? sourceURLs[0].lastPathComponent : nil
		let task = Task.detached(priority: .userInitiated) {
			struct PreparedSQLiteObject: Sendable {
				let index: Int
				let filename: String
				let pendingObject: SQLiteObjectStore.PendingObject
			}

			final class SyncAccumulator: @unchecked Sendable {
				var failedCount = 0
				var processedCount = 0
				var storedCount = 0
			}

			await SQLiteObjectStore.shared.cancelThumbnailHydrationForSync()
			await MainActor.run {
				NotificationCenter.default.post(
					name: .sqliteSyncWillBegin,
					object: nil,
					userInfo: ["storeName": targetStoreName]
				)
			}

			let sortedSourceURLs = sourceURLs.sorted {
				$0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
			}
			let duplicateCheckStart = Date()
			let tabFilenames = Set(sortedSourceURLs.map { $0.lastPathComponent.lowercased() })
			logger.log("sqlite sync: duplicate check begin database=\(databaseFilename, privacy: .public) tabObjects=\(sortedSourceURLs.count, privacy: .public) uniqueFilenames=\(tabFilenames.count, privacy: .public)")
			let existingFilenames: Set<String>
			do {
				existingFilenames = try await SQLiteObjectStore.shared.existingFilenamesAmongTabFilenames(
					tabFilenames,
					storeName: targetStoreName,
					requestedAt: duplicateCheckStart
				)
			} catch {
				let message = "Could not read existing objects from \(databaseFilename): \(error.localizedDescription)"
				logger.error("sqlite sync: duplicate check failed database=\(databaseFilename, privacy: .public) duration=\(Date().timeIntervalSince(duplicateCheckStart), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
				await MainActor.run {
					isVaultWorking = false
					vaultStoreTask = nil
					vaultAlertMessage = message
					showVaultAlert = true
				}
				return
			}

			let syncURLs = sortedSourceURLs.filter { url in
				!existingFilenames.contains(url.lastPathComponent.lowercased())
			}
			let duplicateCount = sortedSourceURLs.count - syncURLs.count
			logger.log("sqlite sync: duplicate check complete database=\(databaseFilename, privacy: .public) tabObjects=\(sortedSourceURLs.count, privacy: .public) matchedInStore=\(existingFilenames.count, privacy: .public) duplicatesSkipped=\(duplicateCount, privacy: .public) toSync=\(syncURLs.count, privacy: .public) duration=\(Date().timeIntervalSince(duplicateCheckStart), privacy: .public)")

			await MainActor.run {
				vaultProgressMessage = "Opening \(databaseFilename) for writing..."
				vaultProgressCompleted = 0
				vaultProgressTotal = syncURLs.count
			}

			guard !syncURLs.isEmpty else {
				await MainActor.run {
					isVaultWorking = false
					vaultStoreTask = nil
					vaultAlertMessage = "All \(sortedSourceURLs.count) object\(sortedSourceURLs.count == 1 ? "" : "s") already exist in \(databaseFilename)."
					showVaultAlert = true
				}
				return
			}

			let writeSessionStart = Date()
			do {
				try await SQLiteObjectStore.shared.prepareForSyncWrite(storeName: targetStoreName)
				try await SQLiteObjectStore.shared.beginSyncWriteSession(storeName: targetStoreName)
			} catch {
				let message = "Could not open \(databaseFilename) for writing: \(error.localizedDescription)"
				logger.error("sqlite sync: write session open failed database=\(databaseFilename, privacy: .public) duration=\(Date().timeIntervalSince(writeSessionStart), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
				await MainActor.run {
					isVaultWorking = false
					vaultStoreTask = nil
					vaultAlertMessage = message
					showVaultAlert = true
				}
				return
			}
			logger.log("sqlite sync: write session open complete database=\(databaseFilename, privacy: .public) duration=\(Date().timeIntervalSince(writeSessionStart), privacy: .public)")

			var syncWriteSessionOpened = true
			defer {
				if syncWriteSessionOpened {
					Task {
						try? await SQLiteObjectStore.shared.endSyncWriteSession(commit: false)
					}
				}
			}

			let accumulator = SyncAccumulator()
			let syncStart = Date()
			let syncWorkers = max(1, min(syncURLs.count, PhotoLibrary.workerCount))
			// Write one object at a time so the progress bar advances per stored file.
			let writeBatchSize = 1
			await MainActor.run {
				vaultProgressMessage = "Syncing to \(databaseFilename)..."
				vaultProgressCompleted = 0
				vaultProgressTotal = syncURLs.count
				vaultProgressCurrentFile = ""
			}
			logger.log("sqlite sync: begin database=\(databaseFilename, privacy: .public) tabObjects=\(sortedSourceURLs.count, privacy: .public) toSync=\(syncURLs.count, privacy: .public) duplicatesSkipped=\(duplicateCount, privacy: .public) workers=\(syncWorkers, privacy: .public) writeBatchSize=\(writeBatchSize, privacy: .public)")

			await withTaskGroup(of: PreparedSQLiteObject?.self) { group in
				var nextIndex = 0
				var pendingWrite: [PreparedSQLiteObject] = []

				func enqueueNext() {
					guard nextIndex < syncURLs.count else { return }
					let index = nextIndex
					let url = syncURLs[index]
					nextIndex += 1
					group.addTask {
						if Task.isCancelled { return nil }
						let prepareStart = Date()
						let filename = url.lastPathComponent
						logger.log("sqlite sync: prepare begin index=\(index, privacy: .public) filename=\(filename, privacy: .public)")
						do {
							let resourceValues = try? url.resourceValues(forKeys: [
								.contentTypeKey,
								.creationDateKey,
								.contentModificationDateKey,
								.fileSizeKey
							])
							guard PhotoLibrary.isSupportedMediaFile(url, contentType: resourceValues?.contentType) else {
								logger.log("sqlite sync: prepare skipped unsupported index=\(index, privacy: .public) filename=\(filename, privacy: .public)")
								return nil
							}
							let started = url.startAccessingSecurityScopedResource()
							defer { if started { url.stopAccessingSecurityScopedResource() } }
							let contentType = resourceValues?.contentType?.identifier
								?? UTType(filenameExtension: url.pathExtension)?.identifier
							let thumbnailStart = Date()
							let thumbnailData = await SQLiteObjectStore.shared.resolvedThumbnailDataForSync(for: url)
							logger.log("sqlite sync: prepare thumbnail resolved index=\(index, privacy: .public) filename=\(filename, privacy: .public) bytes=\(thumbnailData?.count ?? 0, privacy: .public) duration=\(Date().timeIntervalSince(thumbnailStart), privacy: .public)")
							let fileSize = resourceValues?.fileSize ?? 0
							let streamLargeObject = fileSize > SQLiteObjectStore.largeObjectStreamThresholdBytes
							let readStart = Date()
							let data: Data
							let contentHash: String
							if streamLargeObject {
								logger.log("sqlite sync: prepare stream-hash begin index=\(index, privacy: .public) filename=\(filename, privacy: .public) expectedBytes=\(fileSize, privacy: .public)")
								contentHash = try SQLiteObjectStore.contentHash(ofFile: url)
								data = Data()
								logger.log("sqlite sync: prepare stream-hash complete index=\(index, privacy: .public) filename=\(filename, privacy: .public) expectedBytes=\(fileSize, privacy: .public) duration=\(Date().timeIntervalSince(readStart), privacy: .public)")
							} else {
								logger.log("sqlite sync: prepare read begin index=\(index, privacy: .public) filename=\(filename, privacy: .public) expectedBytes=\(fileSize, privacy: .public)")
								data = try Data(contentsOf: url)
								try Task.checkCancellation()
								contentHash = SQLiteObjectStore.contentHash(of: data)
								logger.log("sqlite sync: prepare read complete index=\(index, privacy: .public) filename=\(filename, privacy: .public) bytes=\(data.count, privacy: .public) duration=\(Date().timeIntervalSince(readStart), privacy: .public)")
							}
							let extractedMetadata = SQLiteObjectStore.extractObjectMetadata(
								from: data,
								originalURL: url,
								contentTypeIdentifier: contentType
							)
							logger.log("sqlite sync: prepare complete index=\(index, privacy: .public) filename=\(filename, privacy: .public) duration=\(Date().timeIntervalSince(prepareStart), privacy: .public)")
							return PreparedSQLiteObject(
								index: index,
								filename: url.lastPathComponent,
								pendingObject: SQLiteObjectStore.PendingObject(
									objectData: data,
									originalURL: url,
									contentHash: contentHash,
									contentTypeIdentifier: contentType,
									thumbnailData: thumbnailData,
									extractedMetadata: extractedMetadata,
									sourceFileSize: resourceValues?.fileSize,
									sourceCreatedAt: resourceValues?.creationDate,
									sourceModifiedAt: resourceValues?.contentModificationDate
								)
							)
						} catch {
							logger.error("sqlite sync: prepare failed index=\(index, privacy: .public) filename=\(filename, privacy: .public) duration=\(Date().timeIntervalSince(prepareStart), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
							return nil
						}
					}
				}

				func flushPendingWrite() async {
					guard !pendingWrite.isEmpty else { return }
					pendingWrite.sort { $0.index < $1.index }
					let batch = pendingWrite
					pendingWrite.removeAll(keepingCapacity: true)
					let writeStart = Date()
					let writingFilename = batch.last?.filename ?? ""
					await MainActor.run {
						vaultProgressMessage = "Syncing to \(databaseFilename)..."
						vaultProgressCurrentFile = writingFilename
					}
					logger.log("sqlite sync: batch write begin prepared=\(batch.count, privacy: .public) firstIndex=\(batch.first?.index ?? -1, privacy: .public) lastIndex=\(batch.last?.index ?? -1, privacy: .public)")
					do {
						let pendingObjects = batch.map(\.pendingObject)
						let writtenCount = try await SQLiteObjectStore.shared.storeObjectBatchThrowing(
							pendingObjects,
							storeName: targetStoreName
						)
						accumulator.storedCount += writtenCount
						let writeFailedCount = max(0, batch.count - writtenCount)
						accumulator.failedCount += writeFailedCount
						let syncedFilename = batch.last?.filename ?? ""
						await MainActor.run {
							vaultProgressCompleted = accumulator.storedCount
							vaultProgressTotal = syncURLs.count
							vaultProgressMessage = "Syncing to \(databaseFilename)..."
							vaultProgressCurrentFile = syncedFilename
						}
						logger.log("sqlite sync: batch write complete prepared=\(batch.count, privacy: .public) written=\(writtenCount, privacy: .public) writeFailed=\(writeFailedCount, privacy: .public) duration=\(Date().timeIntervalSince(writeStart), privacy: .public)")
					} catch {
						accumulator.failedCount += batch.count
						logger.error("sqlite sync: batch write failed prepared=\(batch.count, privacy: .public) filename=\(writingFilename, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
						await MainActor.run {
							vaultProgressMessage = "Sync failed for \(writingFilename)"
						}
					}
				}

				for _ in 0..<syncWorkers {
					enqueueNext()
				}
				logger.log("sqlite sync: prepare workers started count=\(syncWorkers, privacy: .public)")

				while let result = await group.next() {
					if let result {
						pendingWrite.append(result)
						if pendingWrite.count >= writeBatchSize {
							await flushPendingWrite()
						}
					} else {
						accumulator.failedCount += 1
					}
					accumulator.processedCount += 1
					if !Task.isCancelled {
						enqueueNext()
					}
				}

				await flushPendingWrite()
			}

			syncWriteSessionOpened = false
			let wasCancelled = Task.isCancelled
			let syncWriteCommitted = accumulator.storedCount > 0
			do {
				try await SQLiteObjectStore.shared.endSyncWriteSession(commit: syncWriteCommitted)
				if wasCancelled, syncWriteCommitted {
					logger.log("sqlite sync: partial commit on cancel database=\(databaseFilename, privacy: .public) stored=\(accumulator.storedCount, privacy: .public)")
				}
			} catch {
				logger.error("sqlite sync: write session close failed database=\(databaseFilename, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
			}
			let finalFailedCount = accumulator.failedCount
			let finalStoredCount = accumulator.storedCount
			let finalProcessedCount = accumulator.processedCount
			let finalSkippedCount = max(0, syncURLs.count - finalProcessedCount)
			let finalFocusFilename = (finalStoredCount > 0) ? requestedFocusFilename : nil
			logger.log("sqlite sync: complete database=\(databaseFilename, privacy: .public) tabObjects=\(sortedSourceURLs.count, privacy: .public) toSync=\(syncURLs.count, privacy: .public) processed=\(finalProcessedCount, privacy: .public) stored=\(finalStoredCount, privacy: .public) failed=\(finalFailedCount, privacy: .public) skipped=\(finalSkippedCount, privacy: .public) duplicatesSkipped=\(duplicateCount, privacy: .public) cancelled=\(wasCancelled, privacy: .public) duration=\(Date().timeIntervalSince(syncStart), privacy: .public)")
			await MainActor.run {
				isVaultWorking = false
				vaultStoreTask = nil
				vaultAlertMessage = sqliteSyncSummary(
					stored: finalStoredCount,
					processed: finalProcessedCount,
					requested: syncURLs.count,
					failed: finalFailedCount,
					skipped: finalSkippedCount,
					duplicates: duplicateCount,
					cancelled: wasCancelled,
					databaseFilename: databaseFilename
				)
				showVaultAlert = true
				if finalStoredCount > 0 {
					if isSQLiteObjectStoreView && activeSQLiteStoreName == targetStoreName {
						refreshThumbnails(focusFilename: finalFocusFilename)
					}
					var changeUserInfo: [String: Any] = ["storeName": targetStoreName]
					if let finalFocusFilename {
						changeUserInfo["filename"] = finalFocusFilename
					}
					NotificationCenter.default.post(
						name: .sqliteObjectStoreDidChange,
						object: tabID,
						userInfo: changeUserInfo
					)
				}
			}
		}
		vaultStoreTask = task
	}

	private struct SQLiteSyncTarget {
		let title: String
		let storeName: String
	}

	private func visibleSQLiteSyncTargets() -> [SQLiteSyncTarget] {
		var targets: [SQLiteSyncTarget] = []
		var seenNames: Set<String> = []
		func append(storeName: String) {
			let trimmed = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty, seenNames.insert(trimmed).inserted else { return }
			targets.append(SQLiteSyncTarget(title: SQLiteObjectStore.databaseFilename(forStoreName: trimmed), storeName: trimmed))
		}
		if isSQLiteObjectStoreView {
			append(storeName: activeSQLiteStoreName ?? SQLiteObjectStore.configuredStoreName)
		}
		for snapshot in GalleryTabRegistry.shared.sqliteTargets(excluding: tabID) {
			if let storeName = snapshot.sqliteStoreName {
				append(storeName: storeName)
			}
		}
		return targets
	}

	private func sqliteSyncSummary(
		stored: Int,
		processed: Int,
		requested: Int,
		failed: Int,
		skipped: Int,
		duplicates: Int,
		cancelled: Bool,
		databaseFilename: String
	) -> String {
		var pieces: [String] = []
		let objectSuffix = requested == 1 ? "" : "s"
		if cancelled {
			if stored > 0 {
				pieces.append("Cancelled; kept \(stored) of \(requested) new object\(objectSuffix) in \(databaseFilename).")
			} else {
				pieces.append("Cancelled.")
			}
		} else {
			pieces.append("Synced \(stored) of \(requested) new object\(objectSuffix) to \(databaseFilename).")
		}
		if duplicates > 0 {
			pieces.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s") skipped.")
		}
		if cancelled, stored > 0, processed != stored {
			pieces.append("Processed \(processed) before cancellation.")
		}
		if skipped > 0 {
			pieces.append("\(skipped) object\(skipped == 1 ? " was" : "s were") not completed.")
		}
		if failed > 0 {
			pieces.append("\(failed) object\(failed == 1 ? " failed" : "s failed").")
		}
		return pieces.joined(separator: " ")
	}

	private func chooseAndOpenSQLiteObjectStore() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.allowedContentTypes = Self.sqliteStoreContentTypes
		panel.message = "Choose a SQLite object-store database"
		panel.prompt = "Open"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		openSQLiteObjectStore(fileURL: url)
	}

	private var canReuseCurrentGalleryTabForSQLiteOpen: Bool {
		library.folderURL == nil && library.photos.isEmpty && !isVaultWorking
	}

	private var isGalleryTabActive: Bool {
		guard let window = hostingWindow, window.isVisible else { return false }
		if let tabGroup = window.tabGroup {
			return tabGroup.selectedWindow === window
		}
		return window.isKeyWindow
	}

	private func waitUntilGalleryTabIsActive(maxAttempts: Int = 120) async {
		for attempt in 0..<maxAttempts {
			if isGalleryTabActive {
				if attempt > 0 {
					logger.log("sqlite ui: tab active after \(attempt, privacy: .public) waits store=\(self.resolvedInitialSQLiteStoreName ?? "none", privacy: .public)")
				}
				return
			}
			try? await Task.sleep(nanoseconds: 50_000_000)
		}
		logger.warning("sqlite ui: tab activation timed out visible=\(self.hostingWindow?.isVisible == true, privacy: .public) key=\(self.hostingWindow?.isKeyWindow == true, privacy: .public) store=\(self.resolvedInitialSQLiteStoreName ?? self.activeSQLiteStoreName ?? "none", privacy: .public)")
	}

	private func openInitialSQLiteStoreIfNeeded(storeName: String) async {
		let openToken = initialSQLiteOpenToken
		let requestID = openToken.flatMap { SQLiteObjectStore.requestID(fromOpenToken: $0) }
		let hasPendingOpen = openToken.map { SQLiteStoreOpenRequestCoordinator.shared.matchesOpenToken($0) } == true
		await waitUntilGalleryTabIsActive()
		logger.log("sqlite ui: initial-open ready tabActive=\(self.isGalleryTabActive, privacy: .public) tabID=\(self.tabID.uuidString, privacy: .public) store=\(storeName, privacy: .public) pending=\(hasPendingOpen, privacy: .public) token=\(openToken ?? "none", privacy: .public)")

		if hasPendingOpen, let requestID {
			guard let pending = SQLiteStoreOpenRequestCoordinator.shared.consumePending(for: storeName, requestID: requestID) else {
				logger.log("sqlite ui: initial-open skipped pending-already-consumed store=\(storeName, privacy: .public)")
				return
			}
			if let fileURL = pending.fileURL {
				do {
					try await SQLiteObjectStore.shared.setDatabaseFile(fileURL)
				} catch {
					vaultAlertMessage = "Could not open SQLite store: \(error.localizedDescription)"
					showVaultAlert = true
					logger.error("sqlite ui: initial-open setDatabaseFile failed store=\(storeName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
					return
				}
			}
		}

		guard !isSQLiteObjectStoreView
			|| !SQLiteObjectStore.storeNamesMatch(activeSQLiteStoreName, storeName)
			|| library.photos.isEmpty else {
			logger.log("sqlite ui: initial-open skipped already-loaded store=\(storeName, privacy: .public)")
			return
		}

		logger.log("launch sqlite restore: source=initial-sqlite-window store=\(storeName, privacy: .public)")
		openSQLiteObjectStore(named: storeName)
	}

	private func scheduleSQLiteOpenFallback(requestID: UUID, storeName: String, fileURL: URL?) {
		Task { @MainActor in
			for _ in 0..<60 {
				try? await Task.sleep(nanoseconds: 100_000_000)
				if !SQLiteStoreOpenRequestCoordinator.shared.hasPending(requestID: requestID) {
					return
				}
			}
			guard let pending = SQLiteStoreOpenRequestCoordinator.shared.consumePending(matchingRequestID: requestID) else { return }
			logger.warning("sqlite ui: pending open fallback on caller tab store=\(storeName, privacy: .public)")
			if let fileURL = pending.fileURL ?? fileURL {
				do {
					try await SQLiteObjectStore.shared.setDatabaseFile(fileURL)
				} catch {
					vaultAlertMessage = "Could not open SQLite store: \(error.localizedDescription)"
					showVaultAlert = true
					return
				}
			}
			await waitUntilGalleryTabIsActive()
			openSQLiteObjectStore(named: pending.storeName)
		}
	}

	private func openSQLiteObjectStore(fileURL: URL) {
		Task { @MainActor in
			let storeName = SQLiteObjectStore.normalizedStoreName(fileURL.deletingPathExtension().lastPathComponent)
			if canReuseCurrentGalleryTabForSQLiteOpen {
				do {
					try await SQLiteObjectStore.shared.setDatabaseFile(fileURL)
					logger.log("sqlite ui: open reuse-current-tab store=\(storeName, privacy: .public) path=\(fileURL.path, privacy: .public)")
					await waitUntilGalleryTabIsActive()
					openSQLiteObjectStore(named: storeName)
				} catch {
					vaultAlertMessage = "Could not open SQLite store: \(error.localizedDescription)"
					showVaultAlert = true
					logger.error("sqlite ui: open failed path=\(fileURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
				}
			} else {
				logger.log("sqlite ui: open new-tab store=\(storeName, privacy: .public) path=\(fileURL.path, privacy: .public)")
				let requestID = SQLiteStoreOpenRequestCoordinator.shared.requestOpen(storeName: storeName, fileURL: fileURL)
				let openToken = SQLiteObjectStore.openToken(storeName: storeName, requestID: requestID)
				openWindow(id: "sqlite-store", value: openToken)
				scheduleSQLiteOpenFallback(requestID: requestID, storeName: storeName, fileURL: fileURL)
			}
		}
	}

	private func registerSQLiteThumbnailRefreshHandler(for storeName: String) {
		SQLiteThumbnailRefreshCoordinator.shared.setHandler(for: storeName) {
			guard isSQLiteObjectStoreView,
			      SQLiteObjectStore.storeNamesMatch(activeSQLiteStoreName, storeName) else { return }
			refreshToken = UUID()
		}
	}

	private func openSQLiteObjectStore(named storeName: String? = nil) {
		var storeNameForOpen = SQLiteObjectStore.configuredStoreName
		if let storeName {
			let trimmed = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
			if !trimmed.isEmpty {
				let normalized = SQLiteObjectStore.normalizedStoreName(trimmed)
				UserDefaults.standard.set(normalized, forKey: SQLiteObjectStore.storeNameKey)
				let requestedFilename = SQLiteObjectStore.databaseFilename(forStoreName: normalized)
				if let savedPath = UserDefaults.standard.string(forKey: SQLiteObjectStore.databasePathKey),
				   URL(fileURLWithPath: savedPath).lastPathComponent != requestedFilename {
					UserDefaults.standard.removeObject(forKey: SQLiteObjectStore.databaseBookmarkKey)
					UserDefaults.standard.removeObject(forKey: SQLiteObjectStore.databasePathKey)
				}
				storeNameForOpen = normalized
			}
		}
		guard SQLiteObjectStore.configuredDirectoryPath != nil else {
			vaultAlertMessage = "Choose a SQLite store file before opening it."
			showVaultAlert = true
			return
		}
		if isSQLiteObjectStoreView,
		   SQLiteObjectStore.storeNamesMatch(activeSQLiteStoreName, storeNameForOpen),
		   isVaultWorking || !library.photos.isEmpty {
			logger.log("sqlite ui: open skipped alreadyActive store=\(storeNameForOpen, privacy: .public) working=\(self.isVaultWorking, privacy: .public) photos=\(self.library.photos.count, privacy: .public)")
			return
		}

		isVaultWorking = true
		vaultProgressMessage = "Opening SQLite store \(SQLiteObjectStore.databaseFilename(forStoreName: storeNameForOpen))..."
		vaultProgressCompleted = 0
		vaultProgressTotal = 0
		let sqliteOpenStart = Date()
		sqliteLoadStartDate = sqliteOpenStart
		sqliteLastLoadDuration = nil
		sqliteLastThumbnailLoadDuration = nil
		library.photos = []
		displayedPhotos = []
		library.folderURL = nil
		isSQLiteObjectStoreView = true
		activeSQLiteStoreName = storeNameForOpen
		activeFolderNames = [storeNameForOpen]
		WindowStateStore.shared.recordOpenSQLiteStore(named: storeNameForOpen)
		selectedItems.removeAll()
		deselectedItemsFromAll.removeAll()
		vaultStoreTask?.cancel()

		let openedStoreName = storeNameForOpen
		registerSQLiteThumbnailRefreshHandler(for: openedStoreName)
		let thumbnailProgress = SQLiteThumbnailRefreshSupport.progressHandler(for: openedStoreName)
		logger.log("sqlite ui: open queued tabActive=\(self.isGalleryTabActive, privacy: .public) tabID=\(self.tabID.uuidString, privacy: .public) store=\(openedStoreName, privacy: .public)")
		let task = Task.detached(priority: .userInitiated) {
			do {
				logger.log("sqlite ui: open begin filename=\(SQLiteObjectStore.databaseFilename(forStoreName: openedStoreName), privacy: .public)")
				let urls = try await SQLiteObjectStore.shared.loadObjectWorkingFiles(
					storeName: openedStoreName,
					progress: { completed, total, batch in
						guard !batch.isEmpty else { return }
						await MainActor.run {
							let photos = batch.map { PhotoItem(url: $0) }
							library.photos = photos
							displayedPhotos = photos
							vaultProgressCompleted = completed
							vaultProgressTotal = total
							library.folderURL = nil
							activeSQLiteStoreName = openedStoreName
							activeFolderNames = ["\(openedStoreName) (SQLite)"]
							isVaultWorking = false
							vaultStoreTask = nil
							sqliteLoadStartDate = nil
							lastRefreshDate = Date()
							forceThumbnailLoading = false
							applyOpenedSQLiteStoreSort()
						}
					},
					thumbnailProgress: thumbnailProgress
				)
				await MainActor.run {
					let duration = Date().timeIntervalSince(sqliteOpenStart)
					sqliteLastLoadDuration = duration
					vaultProgressCompleted = urls.count
					vaultProgressTotal = urls.count
					logger.log("sqlite ui: open complete filename=\(SQLiteObjectStore.databaseFilename(forStoreName: openedStoreName), privacy: .public) objects=\(urls.count, privacy: .public) duration=\(duration, privacy: .public)")
				}
				if await SQLiteObjectStore.shared.thumbnailsNeedHydration(storeName: openedStoreName) {
					let thumbnailStart = Date()
					logger.log("sqlite ui: background thumbnail hydration begin filename=\(SQLiteObjectStore.databaseFilename(forStoreName: openedStoreName), privacy: .public) source=database-blob-batch")
					let count = try await SQLiteObjectStore.shared.hydrateStoredThumbnailsForLoadedObjects(
						storeName: openedStoreName,
						progress: thumbnailProgress
					)
					await MainActor.run {
						let thumbnailDuration = Date().timeIntervalSince(thumbnailStart)
						if isSQLiteObjectStoreView && SQLiteObjectStore.storeNamesMatch(activeSQLiteStoreName, openedStoreName) {
							sqliteLastThumbnailLoadDuration = thumbnailDuration
						}
						logger.log("sqlite ui: background thumbnail hydration complete filename=\(SQLiteObjectStore.databaseFilename(forStoreName: openedStoreName), privacy: .public) thumbnails=\(count, privacy: .public) duration=\(thumbnailDuration, privacy: .public)")
					}
				} else {
					logger.log("sqlite ui: background thumbnail hydration skipped filename=\(SQLiteObjectStore.databaseFilename(forStoreName: openedStoreName), privacy: .public)")
				}
			} catch {
				await MainActor.run {
					isVaultWorking = false
					vaultStoreTask = nil
					sqliteLoadStartDate = nil
					vaultAlertMessage = "Could not open SQLite object store: \(error.localizedDescription)"
					showVaultAlert = true
					logger.error("sqlite object store: open failed error=\(error.localizedDescription, privacy: .public)")
				}
			}
		}
		vaultStoreTask = task
	}

	private func syncFilesToFolder(_ sourceURLs: [URL], target: GalleryTabSnapshot) {
		guard let folder = target.folderURL else { return }
		isVaultWorking = true
		vaultProgressMessage = "Syncing files..."
		vaultProgressCompleted = 0
		vaultProgressTotal = sourceURLs.count
		vaultStoreTask?.cancel()
		let task = Task.detached(priority: .userInitiated) {
			let started = folder.startAccessingSecurityScopedResource()
			defer { if started { folder.stopAccessingSecurityScopedResource() } }
			var copiedURLs: [URL] = []
			var failedCount = 0
			for (index, sourceURL) in sourceURLs.enumerated() {
				if Task.isCancelled { break }
				do {
					let destinationURL = Self.uniqueSyncDestinationURL(for: sourceURL.lastPathComponent, in: folder)
					try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
					copiedURLs.append(destinationURL)
				} catch {
					failedCount += 1
					logger.error("sync folder: failed source=\(sourceURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
				}
				if index + 1 == sourceURLs.count || (index + 1) % 128 == 0 {
					let completed = index + 1
					await MainActor.run {
						vaultProgressCompleted = completed
						vaultProgressTotal = sourceURLs.count
					}
				}
			}
			let wasCancelled = Task.isCancelled
			let finalCopiedURLs = copiedURLs
			let finalFailedCount = failedCount
			await MainActor.run {
				isVaultWorking = false
				vaultStoreTask = nil
				postSyncedFiles(finalCopiedURLs, to: target)
				vaultAlertMessage = "Synced \(finalCopiedURLs.count) of \(sourceURLs.count) file\(sourceURLs.count == 1 ? "" : "s").\(finalFailedCount > 0 ? " \(finalFailedCount) failed." : "")\(wasCancelled ? " Cancelled." : "")"
				showVaultAlert = true
			}
		}
		vaultStoreTask = task
	}

	private func syncFilesToVault(_ sourceURLs: [URL], target: GalleryTabSnapshot, ignoreDuplicates: Bool) {
		guard let folder = target.folderURL else { return }
		guard let password = promptForVaultPassword(title: "Unlock \(target.title)", message: "Enter the target vault password to sync encrypted files.") else {
			return
		}
		isVaultWorking = true
		vaultProgressMessage = "Syncing encrypted files..."
		vaultProgressCompleted = 0
		vaultProgressTotal = sourceURLs.count
		vaultStoreTask?.cancel()
		let task = Task.detached(priority: .userInitiated) {
			do {
				try await PhotoVault.shared.setLocation(folder)
				try await PhotoVault.shared.unlock(password: password)
				let result = try await PhotoVault.shared.importFiles(sourceURLs, ignoreDuplicates: false) { completed, total, _ in
					if completed == total || completed % 128 == 0 {
						await MainActor.run {
							vaultProgressCompleted = completed
							vaultProgressTotal = total
						}
					}
				}
				let wasCancelled = Task.isCancelled
				await MainActor.run {
					isVaultWorking = false
					vaultStoreTask = nil
					postSyncedFiles(result.workingURLs, to: target)
					vaultAlertMessage = vaultStoreSummary(
						stored: result.workingURLs.count,
						requested: sourceURLs.count,
						duplicates: result.duplicateCount,
						failures: result.failedCount,
						cancelled: wasCancelled
					)
					showVaultAlert = true
				}
			} catch {
				await MainActor.run {
					isVaultWorking = false
					vaultStoreTask = nil
					vaultAlertMessage = error.localizedDescription
					showVaultAlert = true
				}
			}
		}
		vaultStoreTask = task
	}

	private func promptForVaultPassword(title: String, message: String) -> String? {
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = message
		alert.addButton(withTitle: "Sync")
		alert.addButton(withTitle: "Cancel")
		let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
		alert.accessoryView = field
		guard alert.runModal() == .alertFirstButtonReturn else { return nil }
		return field.stringValue
	}

	private func postSyncedFiles(_ urls: [URL], to target: GalleryTabSnapshot) {
		guard !urls.isEmpty else { return }
		NotificationCenter.default.post(
			name: .galleryTabSyncImported,
			object: nil,
			userInfo: [
				"tabID": target.id.uuidString,
				"urls": urls,
				"isVault": target.isVault
			]
		)
	}

	private func receiveSyncedFiles(_ notification: Notification) {
		guard let targetID = notification.userInfo?["tabID"] as? String,
			  targetID == tabID.uuidString,
			  let urls = notification.userInfo?["urls"] as? [URL]
		else { return }
		let existing = Set(library.photos.map(\.url))
		let newPhotos = urls.filter { !existing.contains($0) }.map { PhotoItem(url: $0) }
		guard !newPhotos.isEmpty else { return }
		library.photos.append(contentsOf: newPhotos)
		forceThumbnailLoading = (notification.userInfo?["isVault"] as? Bool) == true
		refreshToken = UUID()
		scheduleSort()
		updateTabRegistry()
	}

	private nonisolated static func uniqueSyncDestinationURL(for filename: String, in folder: URL) -> URL {
		let cleanName = filename.isEmpty ? "photo" : URL(fileURLWithPath: filename).lastPathComponent
		let sourceURL = URL(fileURLWithPath: cleanName)
		let base = sourceURL.deletingPathExtension().lastPathComponent
		let ext = sourceURL.pathExtension
		var candidate = folder.appendingPathComponent(cleanName)
		var index = 1
		while FileManager.default.fileExists(atPath: candidate.path) {
			let name = "\(base)-\(index)"
			candidate = folder.appendingPathComponent(name)
			if !ext.isEmpty {
				candidate = candidate.appendingPathExtension(ext)
			}
			index += 1
		}
		return candidate
	}

	private func dragItemProvider(for photoURL: URL) -> NSItemProvider {
		let urls = contextActionURLs(for: photoURL)
		let primaryURL = urls.first ?? photoURL
		let provider = NSItemProvider(contentsOf: primaryURL) ?? NSItemProvider(object: primaryURL as NSURL)

		// Provide broad URL/file-list representations; different macOS targets
		// consume different type identifiers for multi-file drops.
		let fileURLList = urls.map(\.absoluteString).joined(separator: "\n")
		let uriList = urls.map(\.absoluteString).joined(separator: "\r\n") + "\r\n"

		provider.registerDataRepresentation(forTypeIdentifier: NSPasteboard.PasteboardType.fileURL.rawValue, visibility: .all) { completion in
			completion(primaryURL.absoluteString.data(using: .utf8), nil)
			return nil
		}
		provider.registerDataRepresentation(forTypeIdentifier: "public.utf8-plain-text", visibility: .all) { completion in
			completion(fileURLList.data(using: .utf8), nil)
			return nil
		}
		provider.registerDataRepresentation(forTypeIdentifier: "public.url", visibility: .all) { completion in
			completion(primaryURL.absoluteString.data(using: .utf8), nil)
			return nil
		}
		provider.registerDataRepresentation(forTypeIdentifier: "public.file-url", visibility: .all) { completion in
			completion(fileURLList.data(using: .utf8), nil)
			return nil
		}
		provider.registerDataRepresentation(forTypeIdentifier: "text/uri-list", visibility: .all) { completion in
			completion(uriList.data(using: .utf8), nil)
			return nil
		}

		return provider
	}

	/// Remove a bookmark by URL from the persisted multi-bookmark list and
	/// stop security-scoped access for it. The legacy single-bookmark key is
	/// kept in sync with the first remaining entry.
	private func deleteBookmark(_ url: URL) {
		let urlPath = url.standardizedFileURL.path
		let filterBookmarks: ([Data]) -> [Data] = { bookmarks in
			bookmarks.compactMap { data in
				var stale = false
				if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
					return resolved.standardizedFileURL.path == urlPath ? nil : data
				}
				return data
			}
		}

		let known = UserDefaults.standard.array(forKey: Self.kKnownFolderBookmarks) as? [Data] ?? []
		UserDefaults.standard.set(filterBookmarks(known), forKey: Self.kKnownFolderBookmarks)

		let last = UserDefaults.standard.array(forKey: Self.kLastFolderBookmarks) as? [Data] ?? []
		let remaining = filterBookmarks(last)
		UserDefaults.standard.set(remaining, forKey: Self.kLastFolderBookmarks)

		if let legacy = UserDefaults.standard.data(forKey: Self.kLastFolderBookmark) {
			var stale = false
			if let resolved = try? URL(resolvingBookmarkData: legacy, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
			   resolved.standardizedFileURL.path == urlPath {
				if let first = remaining.first {
					UserDefaults.standard.set(first, forKey: Self.kLastFolderBookmark)
				} else {
					UserDefaults.standard.removeObject(forKey: Self.kLastFolderBookmark)
				}
			}
		}

		url.stopAccessingSecurityScopedResource()
		Self.activeSecurityScopedURLs.removeAll { $0 == url }
		reloadBookmarks()
	}

	/// Resolve persisted folder bookmarks and start security-scoped access
	/// for each. Populates `bookmarkURLs` for the toolbar dropdown.
	private func reloadBookmarks() {
		var resolved: [URL] = []
		var seenPaths: Set<String> = []
		var resolvedData: [Data] = []

		func addBookmarkData(_ bookmarkData: Data) {
			var stale = false
			do {
				let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
				if url.startAccessingSecurityScopedResource(), !Self.activeSecurityScopedURLs.contains(url) {
					Self.activeSecurityScopedURLs.append(url)
				}
				let path = url.standardizedFileURL.path
				guard seenPaths.insert(path).inserted else { return }
				resolved.append(url)
				if stale,
				   let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
					resolvedData.append(refreshed)
				} else {
					resolvedData.append(bookmarkData)
				}
			} catch {
				logger.error("reloadBookmarks: failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
			}
		}

		func addURL(_ url: URL) {
			let path = url.standardizedFileURL.path
			guard seenPaths.insert(path).inserted else { return }
			if url.startAccessingSecurityScopedResource(), !Self.activeSecurityScopedURLs.contains(url) {
				Self.activeSecurityScopedURLs.append(url)
			}
			do {
				let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
				resolved.append(url)
				resolvedData.append(bookmarkData)
			} catch {
				logger.error("reloadBookmarks: failed to refresh known bookmark: \(error.localizedDescription, privacy: .public)")
			}
		}

		for bookmarkData in UserDefaults.standard.array(forKey: Self.kKnownFolderBookmarks) as? [Data] ?? [] {
			addBookmarkData(bookmarkData)
		}
		for bookmarkData in UserDefaults.standard.array(forKey: Self.kLastFolderBookmarks) as? [Data] ?? [] {
			addBookmarkData(bookmarkData)
		}
		if let legacy = UserDefaults.standard.data(forKey: Self.kLastFolderBookmark) {
			addBookmarkData(legacy)
		}
		for url in WindowStateStore.shared.openGalleryFolderURLs() {
			addURL(url)
		}

		UserDefaults.standard.set(resolvedData, forKey: Self.kKnownFolderBookmarks)
		bookmarkURLs = Self.sortedBookmarkURLs(resolved)
		FileNavigationMenuState.shared.reload()
	}

	private static func sortedBookmarkURLs(_ urls: [URL]) -> [URL] {
		urls.sorted {
			$0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
		}
	}

	private func rememberKnownBookmarks(_ urls: [URL]) {
		var bookmarks = UserDefaults.standard.array(forKey: Self.kKnownFolderBookmarks) as? [Data] ?? []
		var knownPaths = Set(bookmarkURLs.map { $0.standardizedFileURL.path })
		for url in urls {
			let path = url.standardizedFileURL.path
			guard knownPaths.insert(path).inserted else { continue }
			do {
				let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
				bookmarks.append(bookmark)
			} catch {
				logger.error("rememberKnownBookmarks: failed to create bookmark: \(error.localizedDescription, privacy: .public)")
			}
		}
		UserDefaults.standard.set(bookmarks, forKey: Self.kKnownFolderBookmarks)
	}

	private func openBookmarkedFolder(_ url: URL) {
		guard !GalleryTabRegistry.shared.containsBookmarkName(url.lastPathComponent) else {
			vaultAlertMessage = "\(url.lastPathComponent) is already open in this window."
			showVaultAlert = true
			return
		}
		openWindow(id: "folder", value: url)
	}

	private func openSQLiteStoreFromMenu(named storeName: String) {
		let trimmed = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		guard !GalleryTabRegistry.shared.containsBookmarkName(trimmed) else {
			vaultAlertMessage = "\(trimmed) is already open in this window."
			showVaultAlert = true
			return
		}
		let requestID = SQLiteStoreOpenRequestCoordinator.shared.requestOpen(storeName: trimmed)
		openWindow(
			id: "sqlite-store",
			value: SQLiteObjectStore.openToken(storeName: trimmed, requestID: requestID)
		)
	}

	private func restoreSavedGallerySession() {
		let sessionItems = Self.uniqueGallerySessionItems(WindowStateStore.shared.openGallerySessionItems())
		guard !sessionItems.isEmpty else { return }
		for (index, item) in sessionItems.enumerated() {
			switch item {
			case .folder(let url):
				if index == 0 {
					if !tryOpenFolderAsVault(url) {
						library.folderURL = url
						activeFolderNames = [url.lastPathComponent]
						library.scan(folder: url)
					}
				} else {
					openBookmarkedFolder(url)
				}
			case .sqliteStore(let storeName):
				if index == 0 {
					openSQLiteObjectStore(named: storeName)
				} else {
					openSQLiteStoreFromMenu(named: storeName)
				}
			}
		}
		FileNavigationMenuState.shared.reload()
	}

	private func filterAlreadyOpenBookmarkNames(_ urls: [URL]) -> [URL] {
		var namesInSelection: Set<String> = []
		var skippedNames: [String] = []
		let filtered = urls.filter { url in
			let name = url.lastPathComponent
			let key = Self.normalizedBookmarkOpenName(name)
			guard namesInSelection.insert(key).inserted else {
				skippedNames.append(name)
				return false
			}
			if GalleryTabRegistry.shared.containsBookmarkName(name) {
				skippedNames.append(name)
				return false
			}
			return true
		}
		if !skippedNames.isEmpty {
			let uniqueNames = Array(Set(skippedNames)).sorted()
			vaultAlertMessage = "Already open: \(uniqueNames.joined(separator: ", "))"
			showVaultAlert = true
		}
		return filtered
	}

	private func promptForVaultImportOptions(itemCount: Int, title: String, itemName: String = "photo") -> VaultImportOptions? {
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = "Import \(itemCount) \(itemName)\(itemCount == 1 ? "" : "s") into the current vault."
		alert.addButton(withTitle: "Import")
		alert.addButton(withTitle: "Cancel")
		let checkbox = NSButton(checkboxWithTitle: "Ignore duplicates", target: nil, action: nil)
		checkbox.state = .on
		let label = NSTextField(labelWithString: "Keywords to append")
		let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
		field.placeholderString = "Optional, comma-separated"
		let stack = NSStackView(views: [checkbox, label, field])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 8
		stack.frame = NSRect(x: 0, y: 0, width: 380, height: 78)
		alert.accessoryView = stack
		guard alert.runModal() == .alertFirstButtonReturn else { return nil }
		return VaultImportOptions(
			ignoreDuplicates: checkbox.state == .on,
			keywords: Self.parseKeywordInput(field.stringValue)
		)
	}

	private static func parseKeywordInput(_ input: String) -> [String] {
		var keywords: [String] = []
		var seen: Set<String> = []
		for part in input.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" }) {
			let keyword = part.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !keyword.isEmpty else { continue }
			let key = keyword.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			if seen.insert(key).inserted {
				keywords.append(keyword)
			}
		}
		return keywords
	}

	private func importFolderToVault() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = true
		panel.message = "Choose one or more photo folders to import into the vault"
		panel.prompt = "Import"
		guard panel.runModal() == .OK else { return }
		let folders = panel.urls
		guard !folders.isEmpty else { return }
		guard let importOptions = promptForVaultImportOptions(itemCount: folders.count, title: "Import Folder to Vault", itemName: "selected folder") else { return }

		vaultStoreTask?.cancel()
		isVaultWorking = true
		vaultProgressMessage = "Counting photos..."
		vaultProgressCompleted = 0
		vaultProgressTotal = 0
		vaultProgressCurrentFile = ""
		logger.log("vault import: start scan folders=\(folders.count, privacy: .public) ignoreDuplicates=\(importOptions.ignoreDuplicates, privacy: .public) keywordCount=\(importOptions.keywords.count, privacy: .public)")

		let task = Task.detached(priority: .userInitiated) {
			do {
				let scopedFolders = folders.map { folder in
					(url: folder, started: folder.startAccessingSecurityScopedResource())
				}
				defer {
					for scopedFolder in scopedFolders where scopedFolder.started {
						scopedFolder.url.stopAccessingSecurityScopedResource()
					}
				}
				var totalToImport = 0
				var importURLs: [URL] = []
				for folder in scopedFolders.map(\.url) {
					if Task.isCancelled { break }
					for await batch in PhotoLibrary.scanStream(folder: folder, batchSize: 512) {
						if Task.isCancelled { break }
						totalToImport += batch.count
						importURLs.append(contentsOf: batch.map(\.url))
						if totalToImport % 512 == 0 {
							let counted = totalToImport
							await MainActor.run { vaultProgressCompleted = counted }
						}
					}
				}

					if Task.isCancelled || totalToImport == 0 {
						let cancelled = Task.isCancelled
						let foundCount = totalToImport
					await MainActor.run {
						isVaultWorking = false
						vaultStoreTask = nil
						if cancelled {
							vaultAlertMessage = "Cancelled before any photos were imported."
						} else {
							vaultAlertMessage = "No supported images were found in the selected folders."
						}
						showVaultAlert = true
						logger.log("vault import: count ended cancelled=\(cancelled, privacy: .public) found=\(foundCount, privacy: .public)")
					}
						return
					}

					let totalImportCount = totalToImport
					await MainActor.run {
						vaultProgressMessage = "Importing encrypted photos..."
						vaultProgressCompleted = 0
						vaultProgressTotal = totalImportCount
						logger.log("vault import: count complete total=\(totalImportCount, privacy: .public)")
					}

				let requestedCount = importURLs.count
				let result = try await PhotoVault.shared.importFiles(importURLs, ignoreDuplicates: importOptions.ignoreDuplicates, keywordsToAppend: importOptions.keywords) { completed, total, _ in
					if completed == total || completed % 128 == 0 {
						await MainActor.run {
							vaultProgressCompleted = completed
							vaultProgressTotal = totalImportCount
						}
					}
				}
				let workingURLs = result.workingURLs
				let storedCount = result.workingURLs.count
				let duplicateCount = result.duplicateCount
				let failedCount = result.failedCount

				if requestedCount == 0 {
					await MainActor.run {
						isVaultWorking = false
						vaultStoreTask = nil
						vaultAlertMessage = "No supported images were found in the selected folders."
						showVaultAlert = true
						logger.log("vault import: scan ended requested=0")
					}
					return
				}

					let wasCancelled = Task.isCancelled
					let photos = workingURLs.map { PhotoItem(url: $0) }
					let finalRequestedCount = totalImportCount
				let finalStoredCount = storedCount
				let finalDuplicateCount = duplicateCount
				let finalFailedCount = failedCount
				let status = await PhotoVault.shared.status()
				let vaultURL = Self.vaultURL(from: status)
				let vaultName = Self.vaultDisplayName(for: vaultURL)
				await MainActor.run {
					let existing = Set(library.photos.map(\.url))
					let newPhotos = photos.filter { !existing.contains($0.url) }
					library.photos.append(contentsOf: newPhotos)
					library.folderURL = vaultURL
					activeFolderNames = [vaultName]
					vaultStatus = status
					forceThumbnailLoading = true
					library.lastScanDate = Date()
					library.lastScanDuration = nil
					clearSelection()
					isVaultWorking = false
					vaultStoreTask = nil
					vaultAlertMessage = vaultStoreSummary(
						stored: finalStoredCount,
						requested: finalRequestedCount,
						duplicates: finalDuplicateCount,
						failures: finalFailedCount,
						cancelled: wasCancelled
					)
					showVaultAlert = true
					logger.log("vault store: complete requested=\(finalRequestedCount, privacy: .public) stored=\(finalStoredCount, privacy: .public) duplicates=\(finalDuplicateCount, privacy: .public) failed=\(finalFailedCount, privacy: .public) cancelled=\(wasCancelled, privacy: .public)")
					scheduleSort()
				}
			} catch {
				let msg = error.localizedDescription
				await MainActor.run {
					isVaultWorking = false
					vaultStoreTask = nil
					vaultAlertMessage = msg
					showVaultAlert = true
					logger.error("vault store: failed error=\(msg, privacy: .public)")
				}
			}
		}
		vaultStoreTask = task
	}

	private func importSelectedImagesToVault() {
		let urls = selectedPhotoURLs
		logger.log("vault store selected: requested selectedCount=\(urls.count, privacy: .public) allDisplayedActive=\(isAllDisplayedSelectionActive, privacy: .public)")
		guard !urls.isEmpty else { return }
		storeImagesInVault(urls, progressMessage: "Storing selected photos...")
	}

	private func pasteFilesToVault() {
		guard isActiveVaultView else {
			vaultAlertMessage = "Open a vault tab before pasting files."
			showVaultAlert = true
			return
		}
		let urls = pasteboardFileURLs()
		guard !urls.isEmpty else {
			vaultAlertMessage = "The clipboard does not contain file URLs."
			showVaultAlert = true
			return
		}
		storeImagesInVault(urls, progressMessage: "Pasting files into vault...")
	}

	private func storeImagesInVault(_ urls: [URL], progressMessage: String) {
		guard !urls.isEmpty else { return }
		guard let importOptions = promptForVaultImportOptions(itemCount: urls.count, title: "Store Photos in Vault") else { return }
		vaultStoreTask?.cancel()
		isVaultWorking = true
		vaultProgressMessage = progressMessage
		vaultProgressCompleted = 0
		vaultProgressTotal = urls.count
		vaultProgressCurrentFile = ""
		logger.log("vault store: start count=\(urls.count, privacy: .public) ignoreDuplicates=\(importOptions.ignoreDuplicates, privacy: .public) keywordCount=\(importOptions.keywords.count, privacy: .public)")
		let task = Task.detached(priority: .userInitiated) {
			do {
				let result = try await PhotoVault.shared.importFiles(urls, ignoreDuplicates: importOptions.ignoreDuplicates, keywordsToAppend: importOptions.keywords) { completed, total, _ in
					if completed == total || completed % 128 == 0 {
						await MainActor.run {
							vaultProgressCompleted = completed
							vaultProgressTotal = total
						}
					}
				}
				let wasCancelled = Task.isCancelled
				let workingURLs = result.workingURLs
				let dupCount = result.duplicateCount
				let failCount = result.failedCount
				let photos = workingURLs.map { PhotoItem(url: $0) }
				let status = await PhotoVault.shared.status()
				let vaultURL = Self.vaultURL(from: status)
				let vaultName = Self.vaultDisplayName(for: vaultURL)
				await MainActor.run {
					let existing = Set(library.photos.map(\.url))
					let newPhotos = photos.filter { !existing.contains($0.url) }
					library.photos.append(contentsOf: newPhotos)
						library.folderURL = vaultURL
						activeFolderNames = [vaultName]
						vaultStatus = status
						forceThumbnailLoading = true
						library.lastScanDate = Date()
					library.lastScanDuration = nil
					clearSelection()
					isVaultWorking = false
					vaultStoreTask = nil
					vaultAlertMessage = vaultStoreSummary(
						stored: workingURLs.count,
						requested: urls.count,
						duplicates: dupCount,
						failures: failCount,
						cancelled: wasCancelled
					)
					showVaultAlert = true
					logger.log("vault store: complete requested=\(urls.count, privacy: .public) stored=\(workingURLs.count, privacy: .public) duplicates=\(dupCount, privacy: .public) failed=\(failCount, privacy: .public) cancelled=\(wasCancelled, privacy: .public)")
					scheduleSort()
				}
			} catch {
				await MainActor.run {
					isVaultWorking = false
					vaultStoreTask = nil
					vaultAlertMessage = error.localizedDescription
					showVaultAlert = true
					logger.error("vault store: failed error=\(error.localizedDescription, privacy: .public)")
				}
			}
		}
		vaultStoreTask = task
	}

	private func vaultStoreSummary(stored: Int, requested: Int, duplicates: Int, failures: Int, cancelled: Bool) -> String {
		let photoSuffix = requested == 1 ? "" : "s"
		var pieces: [String] = []
		if cancelled {
			pieces.append("Cancelled.")
		}
		pieces.append("Stored \(stored) of \(requested) photo\(photoSuffix) in the vault.")
		if duplicates > 0 {
			pieces.append("Skipped \(duplicates) duplicate\(duplicates == 1 ? "" : "s").")
		}
		if failures > 0 {
			pieces.append("\(failures) photo\(failures == 1 ? " was" : "s were") not imported due to errors.")
		}
		return pieces.joined(separator: " ")
	}

	private func newItem() {
		let alert = NSAlert()
		alert.messageText = "New"
		alert.informativeText = "Choose the type to create."
		alert.addButton(withTitle: "Continue")
		alert.addButton(withTitle: "Cancel")

		let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
		popup.addItems(withTitles: ["Vault", "SQLite Store"])
		alert.accessoryView = popup

		guard alert.runModal() == .alertFirstButtonReturn else { return }
		if popup.indexOfSelectedItem == 1 {
			newSQLiteStore()
		} else {
			newVault()
		}
	}

	private func newVault() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = true
		panel.message = "Choose or create a folder for the new vault"
		panel.prompt = "Create Vault"
		guard panel.runModal() == .OK, let folder = panel.url else { return }

		Task {
			do {
				try await PhotoVault.shared.setLocation(folder)
				await refreshVaultStatus()
				pendingVaultAutoOpen = true
				clearVaultUnlockPrompt()
				isShowingVaultUnlockPrompt = true
			} catch {
				vaultAlertMessage = error.localizedDescription
				showVaultAlert = true
			}
		}
	}

	private func newSQLiteStore() {
		let panel = NSSavePanel()
		panel.allowedContentTypes = Self.sqliteStoreContentTypes
		panel.canCreateDirectories = true
		panel.nameFieldStringValue = SQLiteObjectStore.configuredDatabaseFilename
		panel.message = "Choose where to create the SQLite object store"
		panel.prompt = "Create"
		guard panel.runModal() == .OK, let url = panel.url else { return }

		Task {
			do {
				try await SQLiteObjectStore.shared.createDatabaseFile(url)
				await MainActor.run {
					let storeName = SQLiteObjectStore.configuredStoreName
					let requestID = SQLiteStoreOpenRequestCoordinator.shared.requestOpen(storeName: storeName, fileURL: url)
					openWindow(
						id: "sqlite-store",
						value: SQLiteObjectStore.openToken(storeName: storeName, requestID: requestID)
					)
				}
			} catch {
				await MainActor.run {
					vaultAlertMessage = "Could not create SQLite store: \(error.localizedDescription)"
					showVaultAlert = true
				}
			}
		}
	}

	private func chooseAndOpenVault() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = false
		panel.message = "Choose a vault folder"
		panel.prompt = "Open Vault"
		guard panel.runModal() == .OK, let folder = panel.url else { return }

		if tryOpenFolderAsVault(folder) { return }
		vaultAlertMessage = "The selected folder does not contain vault files."
		showVaultAlert = true
	}

	private func closeVault() {
		handleTabCloseRequest()
	}

	private func handleTabCloseRequest() {
		let operations = activeBackgroundOperationDescriptions()
		if !operations.isEmpty {
			let alert = NSAlert()
			alert.messageText = "Background Operation in Progress"
			alert.informativeText = """
			This tab is still working on:

			\(operations.map { "• \($0)" }.joined(separator: "\n"))

			Close the tab and cancel these operations?
			"""
			alert.alertStyle = .warning
			alert.addButton(withTitle: "Close Tab")
			alert.addButton(withTitle: "Keep Working")
			guard alert.runModal() == .alertFirstButtonReturn else { return }
			cancelAllBackgroundOperations()
		}
		executeTabClose()
	}

	private func activeBackgroundOperationDescriptions() -> [String] {
		var operations: [String] = []
		if isVaultWorking {
			let message = vaultProgressMessage.trimmingCharacters(in: .whitespacesAndNewlines)
			operations.append(message.isEmpty ? "Store operation" : message)
		}
		if library.isScanning {
			operations.append("Scanning folder")
		}
		if isRefreshing {
			operations.append("Refreshing thumbnails")
		}
		if isRescanningFaces {
			operations.append("Rescanning faces")
		}
		if isPersonRecognitionWorking {
			let message = personRecognitionProgressMessage.trimmingCharacters(in: .whitespacesAndNewlines)
			operations.append(message.isEmpty ? "Person recognition" : message)
		}
		if isOllamaRecognitionRunning {
			operations.append("Ollama image recognition")
		}
		if isDeleting {
			operations.append("Deleting files")
		}
		if isApplyingKeywords {
			operations.append("Editing keywords")
		}
		if isApplyingRotations {
			operations.append("Applying rotations")
		}
		if isApplyingBrightness {
			operations.append("Adjusting brightness")
		}
		return operations
	}

	private func cancelAllBackgroundOperations() {
		vaultStoreTask?.cancel()
		vaultStoreTask = nil
		folderScanTask?.cancel()
		folderScanTask = nil
		refreshTask?.cancel()
		refreshTask = nil
		isRefreshing = false
		library.cancelScan()
		personRecognitionTask?.cancel()
		personRecognitionTask = nil
		isPersonRecognitionWorking = false
		isAssigningPerson = false
		if isRescanningFaces {
			FaceScanProgress.shared.cancel()
		}
		isRescanningFaces = false
		ollamaRecognitionTask?.cancel()
		ollamaRecognitionTask = nil
		if isOllamaRecognitionRunning {
			OllamaProgress.shared.cancel()
		}
		isOllamaRecognitionRunning = false
		deleteTask?.cancel()
		deleteTask = nil
		isDeleting = false
		deletingURLs = []
		keywordEditTask?.cancel()
		keywordEditTask = nil
		isApplyingKeywords = false
		rotationApplyTask?.cancel()
		rotationApplyTask = nil
		isApplyingRotations = false
		brightnessApplyTask?.cancel()
		brightnessApplyTask = nil
		isApplyingBrightness = false
		sortTask?.cancel()
		sortTask = nil
		metadataRefreshTask?.cancel()
		metadataRefreshTask = nil
		photoChangeTask?.cancel()
		photoChangeTask = nil
		pendingSQLiteFocusTask?.cancel()
		pendingSQLiteFocusTask = nil
		selectionAutoScrollTask?.cancel()
		selectionAutoScrollTask = nil
		isVaultWorking = false
		vaultProgressMessage = ""
		vaultProgressCompleted = 0
		vaultProgressTotal = 0
		vaultProgressCurrentFile = ""
		sqliteLoadStartDate = nil
	}

	private func executeTabClose() {
		if isSQLiteObjectStoreView {
			let storeName = activeSQLiteStoreName ?? SQLiteObjectStore.configuredStoreName
			isVaultWorking = true
			vaultProgressMessage = "Closing SQLite store \(SQLiteObjectStore.databaseFilename(forStoreName: storeName))..."
			vaultProgressCompleted = 0
			vaultProgressTotal = 0
			sqliteLoadStartDate = Date()
			Task {
				do {
					logger.log("sqlite object store: close maintenance begin filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeName), privacy: .public)")
					try await SQLiteObjectStore.shared.reindexDatabase(storeName: storeName)
					logger.log("sqlite object store: close maintenance complete filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeName), privacy: .public)")
				} catch {
					logger.error("sqlite object store: close maintenance failed filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeName), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
				}

				await MainActor.run {
					SQLiteThumbnailRefreshCoordinator.shared.removeHandler(for: storeName)
					WindowStateStore.shared.recordClosedSQLiteStore(named: storeName)
					GalleryTabRegistry.shared.remove(id: tabID)
					isVaultWorking = false
					sqliteLoadStartDate = nil
					isSQLiteObjectStoreView = false
					vaultProgressMessage = ""
					vaultProgressCompleted = 0
					vaultProgressTotal = 0
					library.photos = []
					displayedPhotos = []
					library.folderURL = nil
					activeFolderNames = []
					activeSQLiteStoreName = nil
					registeredSQLiteStoreName = nil
					clearSelection()
					refreshToken = UUID()
					closeCurrentGalleryTab()
				}
			}
			return
		}

		Task {
			if isActiveVaultView {
				await PhotoVault.shared.lock()
				await refreshVaultStatus()
			}
			await MainActor.run {
				library.photos = []
				displayedPhotos = []
				library.folderURL = nil
				activeFolderNames = []
				clearSelection()
				forceThumbnailLoading = false
				refreshToken = UUID()
				isVaultWorking = false
				closeCurrentGalleryTab()
			}
		}
	}

	private func closeCurrentGalleryTab() {
		let window = hostingWindow ?? NSApp.keyWindow
		if Self.shouldKeepGalleryWindowOpen(afterClosing: window) {
			NSApp.activate(ignoringOtherApps: true)
			window?.makeKeyAndOrderFront(nil)
			if let window {
				ContentView.mainGalleryWindow = window
			}
			return
		}
		GalleryTabCloseCoordinator.shared.isPerformingConfirmedClose = true
		DispatchQueue.main.async {
			window?.performClose(nil)
			NSApp.activate(ignoringOtherApps: true)
		}
	}

	@MainActor
	private static func shouldKeepGalleryWindowOpen(afterClosing window: NSWindow?) -> Bool {
		guard let window else { return false }
		if let group = window.tabGroup {
			let visibleTabs = group.windows.filter(\.isVisible)
			if visibleTabs.count > 1 {
				return false
			}
		}
		let visibleGalleryWindows = NSApp.windows.filter {
			$0.isVisible && $0.tabbingIdentifier == "PictureViewerGallery"
		}
		return visibleGalleryWindows.count <= 1
	}

	private func renameVault() {
		guard isActiveVaultView, let folder = library.folderURL else {
			vaultAlertMessage = "Open a vault before renaming it."
			showVaultAlert = true
			return
		}

		let alert = NSAlert()
		alert.messageText = "Rename Vault"
		alert.informativeText = "Enter a new folder name for \(folder.lastPathComponent)."
		alert.addButton(withTitle: "Rename")
		alert.addButton(withTitle: "Cancel")
		let field = NSTextField(string: folder.lastPathComponent)
		field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
		alert.accessoryView = field
		guard alert.runModal() == .alertFirstButtonReturn else { return }

		let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !newName.isEmpty, newName != folder.lastPathComponent else { return }
		let destination = folder.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
		do {
			try FileManager.default.moveItem(at: folder, to: destination)
		} catch {
			vaultAlertMessage = error.localizedDescription
			showVaultAlert = true
			return
		}
		Task {
			do {
				try await PhotoVault.shared.setLocation(destination)
				await refreshVaultStatus()
				let status = await PhotoVault.shared.status()
				let vaultURL = Self.vaultURL(from: status)
				let vaultName = Self.vaultDisplayName(for: vaultURL)
				await MainActor.run {
					library.folderURL = vaultURL
					activeFolderNames = [vaultName]
					vaultStatus = status
					openVault()
				}
			} catch {
				await MainActor.run {
					vaultAlertMessage = error.localizedDescription
					showVaultAlert = true
				}
			}
		}
	}

	private func showVaultManager() {
		reloadKnownVaults()
		isShowingVaultManager = true
	}

	private func reloadKnownVaults() {
		Task {
			let vaults = await PhotoVault.shared.knownVaults()
			await MainActor.run {
				knownVaults = vaults
			}
		}
	}

	private func renameKnownVault(_ vault: KnownVault) {
		let alert = NSAlert()
		alert.messageText = "Rename Vault"
		alert.informativeText = "Enter a new folder name for \(vault.url.lastPathComponent)."
		alert.addButton(withTitle: "Rename")
		alert.addButton(withTitle: "Cancel")
		let field = NSTextField(string: vault.url.lastPathComponent)
		field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
		alert.accessoryView = field
		guard alert.runModal() == .alertFirstButtonReturn else { return }

		let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !newName.isEmpty, newName != vault.url.lastPathComponent else { return }
		let destination = vault.url.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
		guard !FileManager.default.fileExists(atPath: destination.path) else {
			vaultAlertMessage = "A folder named \(newName) already exists."
			showVaultAlert = true
			return
		}

		let scoped = vault.url.startAccessingSecurityScopedResource()
		defer { if scoped { vault.url.stopAccessingSecurityScopedResource() } }
		do {
			try FileManager.default.moveItem(at: vault.url, to: destination)
		} catch {
			vaultAlertMessage = error.localizedDescription
			showVaultAlert = true
			return
		}

		Task {
			await finishKnownVaultMove(from: vault.url, to: destination)
		}
	}

	private func moveKnownVault(_ vault: KnownVault) {
		let panel = NSOpenPanel()
		panel.title = "Move Vault"
		panel.message = "Choose the destination folder for \(vault.displayName)."
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = true
		guard panel.runModal() == .OK, let destinationFolder = panel.url else { return }

		let destination = destinationFolder.appendingPathComponent(vault.url.lastPathComponent, isDirectory: true)
		guard destination.standardizedFileURL.path != vault.url.standardizedFileURL.path else { return }
		guard !FileManager.default.fileExists(atPath: destination.path) else {
			vaultAlertMessage = "A vault or folder already exists at the destination."
			showVaultAlert = true
			return
		}

		let sourceScoped = vault.url.startAccessingSecurityScopedResource()
		let destinationScoped = destinationFolder.startAccessingSecurityScopedResource()
		defer {
			if sourceScoped { vault.url.stopAccessingSecurityScopedResource() }
			if destinationScoped { destinationFolder.stopAccessingSecurityScopedResource() }
		}
		do {
			try FileManager.default.moveItem(at: vault.url, to: destination)
		} catch {
			vaultAlertMessage = error.localizedDescription
			showVaultAlert = true
			return
		}

		Task {
			await finishKnownVaultMove(from: vault.url, to: destination)
		}
	}

	private func deleteKnownVault(_ vault: KnownVault) {
		let alert = NSAlert()
		alert.alertStyle = .critical
		alert.messageText = "Delete Vault?"
		alert.informativeText = "This permanently deletes the vault folder and its encrypted files:\n\(vault.path)"
		alert.addButton(withTitle: "Delete")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return }

		let scoped = vault.url.startAccessingSecurityScopedResource()
		defer { if scoped { vault.url.stopAccessingSecurityScopedResource() } }
		do {
			try FileManager.default.removeItem(at: vault.url)
		} catch {
			vaultAlertMessage = error.localizedDescription
			showVaultAlert = true
			return
		}

		Task {
			await PhotoVault.shared.removeKnownVault(vault.url)
			await refreshVaultStatus()
			await MainActor.run {
				if library.folderURL?.standardizedFileURL.path == vault.url.standardizedFileURL.path {
					library.photos = []
					displayedPhotos = []
					library.folderURL = nil
					activeFolderNames = []
					clearSelection()
					refreshToken = UUID()
				}
				reloadKnownVaults()
			}
		}
	}

	private func finishKnownVaultMove(from oldURL: URL, to newURL: URL) async {
		do {
			try await PhotoVault.shared.replaceKnownVault(oldURL: oldURL, newURL: newURL)
			await refreshVaultStatus()
			await MainActor.run {
				if library.folderURL?.standardizedFileURL.path == oldURL.standardizedFileURL.path {
					library.folderURL = newURL
					activeFolderNames = [Self.vaultDisplayName(for: newURL)]
					openVault()
				}
				reloadKnownVaults()
			}
		} catch {
			await MainActor.run {
				vaultAlertMessage = error.localizedDescription
				showVaultAlert = true
				reloadKnownVaults()
			}
		}
	}

	private func refreshVaultStatus() async {
		let status = await PhotoVault.shared.status()
		await MainActor.run { vaultStatus = status }
	}

	private static func folderContainsEncryptedFiles(_ folder: URL) -> Bool {
		let fm = FileManager.default
		guard let contents = try? fm.contentsOfDirectory(
			at: folder,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
		) else {
			return false
		}
		return contents.contains { $0.pathExtension == PhotoVault.encryptedExtension }
	}

	/// If `folder` contains `.pvencrypted` files, point the vault at it and
	/// either open it (when already unlocked) or prompt for the password.
	/// Returns true when the folder was claimed as a vault.
	@discardableResult
	private func tryOpenFolderAsVault(_ folder: URL) -> Bool {
		guard Self.folderContainsEncryptedFiles(folder) else { return false }
		logger.log("vault auto-open: folder=\(folder.path, privacy: .public) contains encrypted files; switching to vault flow")
		isSQLiteObjectStoreView = false
		library.photos = []
		displayedPhotos = []
		library.folderURL = folder
		activeFolderNames = [Self.vaultDisplayName(for: folder)]
		forceThumbnailLoading = true
		refreshToken = UUID()
		Task {
			do {
				try await PhotoVault.shared.setLocation(folder)
				let status = await PhotoVault.shared.status()
				await MainActor.run { vaultStatus = status }
				if status.isUnlocked {
					openVault()
				} else {
					pendingVaultAutoOpen = true
					clearVaultUnlockPrompt()
					isShowingVaultUnlockPrompt = true
				}
			} catch {
				await MainActor.run {
					vaultAlertMessage = error.localizedDescription
					showVaultAlert = true
				}
			}
		}
		return true
	}

	private func toggleVaultLock() {
		if vaultStatus.isUnlocked {
			Task {
				await PhotoVault.shared.lock()
				await refreshVaultStatus()
			}
		} else {
			clearVaultUnlockPrompt()
			isShowingVaultUnlockPrompt = true
		}
	}

	private func clearVaultUnlockPrompt() {
		vaultUnlockPassword = ""
		vaultUnlockConfirmation = ""
		vaultUnlockMessage = nil
	}

	private func submitVaultUnlockPrompt() {
		let password = vaultUnlockPassword
		let confirmation = vaultUnlockConfirmation
		let isSettingNewPassword = !vaultStatus.hasPassword
		guard !password.isEmpty else {
			vaultUnlockMessage = "Enter a password."
			return
		}
		if isSettingNewPassword {
			guard password == confirmation else {
				vaultUnlockMessage = "Passwords do not match."
				return
			}
		}
		Task {
			var unlocked = false
			do {
				let status = await PhotoVault.shared.status()
				if status.hasPassword {
					try await PhotoVault.shared.unlock(password: password)
				} else {
					try await PhotoVault.shared.configureNewVaultPassword(password)
				}
				clearVaultUnlockPrompt()
				isShowingVaultUnlockPrompt = false
				unlocked = true
			} catch {
				vaultUnlockMessage = error.localizedDescription
			}
			await refreshVaultStatus()
			if unlocked, pendingVaultAutoOpen {
				pendingVaultAutoOpen = false
				openVault()
			}
		}
	}

	private func openVault() {
		isSQLiteObjectStoreView = false
		isVaultWorking = true
		vaultProgressMessage = "Opening vault..."
		vaultProgressCompleted = 0
		vaultProgressTotal = 0
		vaultProgressCurrentFile = ""
		Task.detached(priority: .userInitiated) {
			do {
				let status = await PhotoVault.shared.status()
				let vaultURL = Self.vaultURL(from: status)
				let vaultName = Self.vaultDisplayName(for: vaultURL)
				await MainActor.run {
					library.photos = []
					library.folderURL = vaultURL
					activeFolderNames = [vaultName]
					vaultStatus = status
					forceThumbnailLoading = true
					selectedItems.removeAll()
				}

				let workingURLs = try await PhotoVault.shared.loadWorkingCopies { completed, total, currentFile, loadedURLs in
					await MainActor.run {
						vaultProgressCompleted = completed
						vaultProgressTotal = total
						vaultProgressCurrentFile = currentFile
						if !loadedURLs.isEmpty {
							library.photos.append(contentsOf: loadedURLs.map { PhotoItem(url: $0) })
						}
					}
				}
				let photos = workingURLs.map { PhotoItem(url: $0) }
				await MainActor.run {
					library.photos = photos
					library.folderURL = vaultURL
					activeFolderNames = [vaultName]
					vaultStatus = status
					forceThumbnailLoading = true
					refreshToken = UUID()
					library.lastScanDate = Date()
					library.lastScanDuration = nil
					isVaultWorking = false
					scheduleSort()
				}
			} catch {
				await MainActor.run {
					isVaultWorking = false
					vaultAlertMessage = error.localizedDescription
					showVaultAlert = true
				}
			}
		}
	}

	private func exportVaultSelection() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = true
		panel.message = "Choose where exported photo files should be restored"
		panel.prompt = "Export"
		guard panel.runModal() == .OK, let folder = panel.url else { return }
		let urls = selectedItems.isEmpty ? displayedPhotos.map(\.url) : Array(selectedItems)
		guard !urls.isEmpty else { return }

		isVaultWorking = true
		vaultProgressMessage = "Exporting photos..."
		Task.detached(priority: .userInitiated) {
			let started = folder.startAccessingSecurityScopedResource()
			defer { if started { folder.stopAccessingSecurityScopedResource() } }
			do {
				let count = try await PhotoVault.shared.exportFiles(urls, to: folder)
				await MainActor.run {
					isVaultWorking = false
					vaultAlertMessage = "Exported \(count) photo\(count == 1 ? "" : "s")."
					showVaultAlert = true
				}
			} catch {
				await MainActor.run {
					isVaultWorking = false
					vaultAlertMessage = error.localizedDescription
					showVaultAlert = true
				}
			}
		}
	}

	private func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = true
		panel.allowedContentTypes = Self.openableContentTypes
		panel.message = "Choose one or more folders containing media, media files, or a SQLite object-store database"
		panel.prompt = "Choose"
		if panel.runModal() == .OK {
			var urls: [URL] = []
			var selectedPaths: Set<String> = []
			for url in panel.urls where selectedPaths.insert(url.path).inserted {
				urls.append(url)
			}
			guard !urls.isEmpty else { return }
			let sqliteURLs = urls.filter { Self.isSQLiteStoreFile($0) }
			if let sqliteURL = sqliteURLs.first {
				if urls.count > 1 {
					vaultAlertMessage = "Open one SQLite store at a time."
					showVaultAlert = true
					return
				}
				openSQLiteObjectStore(fileURL: sqliteURL)
				return
			}
			urls = filterAlreadyOpenBookmarkNames(urls)
			guard !urls.isEmpty else { return }
			let mediaFiles = urls.filter { url in
				(try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
					&& PhotoLibrary.isSupportedMediaFile(url)
			}
			let scanFolders = urls.filter { url in
				(try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
			}
			if !scanFolders.isEmpty {
				rememberKnownBookmarks(scanFolders)
				reloadBookmarks()
				for folder in scanFolders {
					_ = folder.startAccessingSecurityScopedResource()
					if !Self.activeSecurityScopedURLs.contains(folder) {
						Self.activeSecurityScopedURLs.append(folder)
					}
					openWindow(id: "folder", value: folder)
				}
				return
			}
			let scanTargets = scanFolders + mediaFiles
			guard !scanTargets.isEmpty else { return }
			isSQLiteObjectStoreView = false

			// Create bookmarks for each selected folder and persist them as
			// an array so we can restore multiple folders at next launch.
			var bookmarkDatas: [Data] = []
			for url in scanFolders {
				do {
					let bm = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
					bookmarkDatas.append(bm)
				} catch {
					logger.error("chooseFolder: failed to create bookmark: \(error.localizedDescription, privacy: .public)")
				}
			}
			if !bookmarkDatas.isEmpty {
				UserDefaults.standard.set(bookmarkDatas, forKey: Self.kLastFolderBookmarks)
				// Maintain legacy single bookmark for compatibility (first one).
				if let first = bookmarkDatas.first {
					UserDefaults.standard.set(first, forKey: Self.kLastFolderBookmark)
				}
				rememberKnownBookmarks(scanFolders)
				reloadBookmarks()
			}

			// Try to start security access for each folder. Keep the first as
			// the displayed folder (used for UI title) and as the primary
			// security-scoped URL.
			for (i, url) in scanTargets.enumerated() {
					if url.startAccessingSecurityScopedResource() {
						if i == 0 { folderSecurityURL = url }
						if !Self.activeSecurityScopedURLs.contains(url) { Self.activeSecurityScopedURLs.append(url) }
					}
			}

			// Update UI title to reflect selected folders
			activeFolderNames = scanTargets.map { $0.lastPathComponent }

			if scanFolders.isEmpty {
				library.photos = mediaFiles.map { PhotoItem(url: $0) }
				library.folderURL = mediaFiles.first?.deletingLastPathComponent()
				library.lastScanDate = Date()
				library.lastScanDuration = nil
				forceThumbnailLoading = false
				clearSelection()
				scheduleSort()
				return
			}

			// If only one folder selected, reuse the existing scan API which
			// handles state, telemetry and persistence. For multiple folders
			// we perform per-folder scans in the background and append the
			// results into the library so the UI shows a combined view.
			if scanTargets.count == 1, let url = scanFolders.first {
				// Single-folder flow: set the active folder name and start
				// the normal PhotoLibrary scan which handles persistence.
				activeFolderNames = [url.lastPathComponent]
				// If the folder is an encrypted vault, open it directly
				// (prompting for the password if needed) instead of scanning.
				if tryOpenFolderAsVault(url) { return }
				forceThumbnailLoading = false
				library.scan(folder: url)
				return
			}

			// Multi-folder scan: clear existing photos and iteratively append
			// batches discovered from each folder. Run as a background task
			// and publish small batches to keep the UI responsive.
			folderScanTask?.cancel()
			folderScanTask = Task.detached(priority: .userInitiated) {
				await MainActor.run {
					library.photos = mediaFiles.map { PhotoItem(url: $0) }
					library.folderURL = scanTargets.first
					library.isScanning = true
					library.scanStartDate = Date()
				}
				let start = Date()

				let crossDeduper = MultiFolderDeduper()
				await withTaskGroup(of: Void.self) { group in
								for folder in scanFolders {
										group.addTask {
											let startedAccess = folder.startAccessingSecurityScopedResource()
											defer { if startedAccess { folder.stopAccessingSecurityScopedResource() } }
											for await batch in PhotoLibrary.scanStream(folder: folder, batchSize: 512) {
												if Task.isCancelled { break }
												// Filter out items whose basenames were already seen from
												// other folders.
												var filtered: [PhotoItem] = []
												for item in batch {
													if Task.isCancelled { break }
													if await crossDeduper.isUnique(item.url.lastPathComponent) {
														filtered.append(item)
													}
												}
												if filtered.isEmpty { continue }
												// Capture an immutable copy for use in concurrently-executing tasks
												let batchCopy = filtered
												await MainActor.run { library.photos.append(contentsOf: batchCopy) }
												// Background work: telemetry, face processing and
												// thumbnail warming for each batch. Use the immutable copy
												// to avoid capturing a mutable variable in concurrently
												// executing code (Swift concurrency safety).
												await MainActor.run { self.logger.log("scan:batch yielded=\(batchCopy.count, privacy: .public) total=\(library.photos.count, privacy: .public)") }
												Task.detached { await Telemetry.shared.recordFound(batchCopy.count) }

							warmFilesystemThumbnails(for: batchCopy)
											}
										}
									}
				}

				await MainActor.run {
					library.isScanning = false
					library.lastScanDate = Date()
					library.lastScanDuration = Date().timeIntervalSince(start)
				}

				// Persist a combined snapshot for faster restore next launch.
				let finalPhotos = await MainActor.run { library.photos }
				PhotoLibrary.persistCombinedSnapshot(finalPhotos, for: scanFolders)
			}
		}
	}

	private func refreshThumbnails(focusFilename: String? = nil) {
		let refreshFolderURL = library.folderURL
		guard refreshFolderURL != nil || isSQLiteObjectStoreView || isActiveVaultView else { return }
		isRefreshing = true
		let start = Date()
		refreshTask?.cancel()
		refreshTask = Task {
			let clear = Task.detached(priority: .userInitiated) {
				ThumbnailCache.shared.clear()
			}
			_ = await clear.value

			if isSQLiteObjectStoreView {
				await reloadSQLiteObjectStoreContents(start: start, focusFilename: focusFilename, forceThumbnailReload: true)
				return
			}

			if isActiveVaultView {
				do {
					let workingURLs = try await PhotoVault.shared.loadWorkingCopies { completed, total, currentFile, _ in
						await MainActor.run {
							vaultProgressCompleted = completed
							vaultProgressTotal = total
							vaultProgressCurrentFile = currentFile
						}
					}
					let photos = workingURLs.map { PhotoItem(url: $0) }
					let status = await PhotoVault.shared.status()
					let vaultURL = Self.vaultURL(from: status)
					let vaultName = Self.vaultDisplayName(for: vaultURL)
					library.photos = photos
					library.folderURL = vaultURL
					activeFolderNames = [vaultName]
					vaultStatus = status
					forceThumbnailLoading = true
					refreshToken = UUID()
					library.lastScanDate = Date()
					library.lastScanDuration = nil
					clearSelection()
					scheduleSort()
				} catch {
					vaultAlertMessage = error.localizedDescription
					showVaultAlert = true
				}
				lastRefreshDuration = Date().timeIntervalSince(start)
				lastRefreshDate = Date()
				isRefreshing = false
				refreshToken = UUID()
				return
			}

			// Trigger a fresh filesystem scan so newly added files appear in the grid.
			guard let refreshFolderURL else {
				isRefreshing = false
				return
			}
			refreshToken = UUID()
			library.scan(folder: refreshFolderURL)
			lastRefreshDuration = Date().timeIntervalSince(start)
			lastRefreshDate = Date()
			isRefreshing = false
		}
	}

	private func reloadSQLiteObjectStoreContents(start: Date, focusFilename: String? = nil, forceThumbnailReload: Bool = false) async {
		let storeName = await MainActor.run { activeSQLiteStoreName ?? SQLiteObjectStore.configuredStoreName }
		let databaseFilename = SQLiteObjectStore.databaseFilename(forStoreName: storeName)
		await MainActor.run {
			isVaultWorking = true
			vaultProgressMessage = "Refreshing SQLite store \(databaseFilename)..."
			vaultProgressCompleted = 0
			vaultProgressTotal = 0
			sqliteLoadStartDate = start
			sqliteLastLoadDuration = nil
			sqliteLastThumbnailLoadDuration = nil
			library.photos = []
			displayedPhotos = []
			vaultStoreTask?.cancel()
		}
		do {
			logger.log("sqlite ui: refresh begin filename=\(databaseFilename, privacy: .public) forceThumbnailReload=\(forceThumbnailReload, privacy: .public)")
			await MainActor.run {
				registerSQLiteThumbnailRefreshHandler(for: storeName)
			}
			let thumbnailProgress = SQLiteThumbnailRefreshSupport.progressHandler(for: storeName)
			let urls = try await SQLiteObjectStore.shared.loadObjectWorkingFiles(
				storeName: storeName,
				progress: { completed, total, batch in
					guard !batch.isEmpty else { return }
					await MainActor.run {
						let photos = batch.map { PhotoItem(url: $0) }
						library.photos = photos
						displayedPhotos = photos
						vaultProgressCompleted = completed
						vaultProgressTotal = total
						isVaultWorking = false
						vaultStoreTask = nil
						sqliteLoadStartDate = nil
						lastRefreshDate = Date()
						forceThumbnailLoading = forceThumbnailReload
						applyOpenedSQLiteStoreSort()
					}
				},
				thumbnailProgress: thumbnailProgress
			)
			await MainActor.run {
				let duration = Date().timeIntervalSince(start)
				sqliteLastLoadDuration = duration
				lastRefreshDuration = duration
				vaultProgressCompleted = urls.count
				vaultProgressTotal = urls.count
				if forceThumbnailReload {
					refreshToken = UUID()
				}
				if let focusFilename {
					pendingSQLiteFocusFilename = focusFilename
				} else {
					clearSelection()
				}
				focusPendingSQLiteObjectIfPossible()
				logger.log("sqlite ui: refresh complete filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeName), privacy: .public) objects=\(urls.count, privacy: .public) duration=\(duration, privacy: .public)")
			}
			if !forceThumbnailReload, await SQLiteObjectStore.shared.thumbnailsNeedHydration(storeName: storeName) {
				let thumbnailStart = Date()
				logger.log("sqlite ui: background thumbnail hydration begin filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeName), privacy: .public)")
				let count = try await SQLiteObjectStore.shared.hydrateStoredThumbnailsForLoadedObjects(
					storeName: storeName,
					progress: thumbnailProgress
				)
				await MainActor.run {
					let thumbnailDuration = Date().timeIntervalSince(thumbnailStart)
					if isSQLiteObjectStoreView && activeSQLiteStoreName == storeName {
						sqliteLastThumbnailLoadDuration = thumbnailDuration
					}
					logger.log("sqlite ui: background thumbnail hydration complete filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeName), privacy: .public) thumbnails=\(count, privacy: .public) duration=\(thumbnailDuration, privacy: .public)")
				}
			}
		} catch {
			await MainActor.run {
				isVaultWorking = false
				vaultStoreTask = nil
				sqliteLoadStartDate = nil
				vaultAlertMessage = "Could not refresh SQLite object store: \(error.localizedDescription)"
				showVaultAlert = true
				logger.error("sqlite object store: refresh failed error=\(error.localizedDescription, privacy: .public)")
			}
		}
		await MainActor.run {
			lastRefreshDuration = Date().timeIntervalSince(start)
			lastRefreshDate = Date()
			isRefreshing = false
			refreshToken = UUID()
			focusPendingSQLiteObjectIfPossible()
		}
	}

	private func requestDeleteConfirmation(urls: [URL], source: String) {
		let unique = Array(Set(urls))
		guard !unique.isEmpty else { return }
		pendingDeleteURLs = unique
		logger.log("requestDeleteConfirmation: source=\(source, privacy: .public) count=\(unique.count, privacy: .public)")
		showDeleteConfirmation = true
	}

	private func performDelete(urls: [URL]) {
		if isSQLiteObjectStoreView {
			performSQLiteDelete(urls: urls)
			return
		}
		deleteResults = Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as Bool?) })
		deleteErrorMessages = Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
		deleteProgressCount = 0
		isDeleting = true
		deletingURLs = urls
		logger.log("performDelete: attempting permanent delete of \(urls.count) items")
		deleteTask?.cancel()
		deleteTask = Task.detached(priority: .utility) {
			let fm = FileManager.default
			for u in urls {
				if Task.isCancelled { break }
				var success = false
				var errorMsg: String? = nil
				let exists = fm.fileExists(atPath: u.path)
				let accessOk = await Self.ensureSecurityScopedAccess(for: u)
				await MainActor.run {
					self.logger.log("performDelete: exists=\(exists, privacy: .public) accessOk=\(accessOk, privacy: .public)")
				}
				do {
					if !exists {
						throw NSError(domain: "PictureViewer.Delete", code: 2, userInfo: [NSLocalizedDescriptionKey: "File does not exist on disk."])
					}
					if !accessOk {
						throw NSError(domain: "PictureViewer.Delete", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing folder permission. Re-select the folder and try again."])
					}
					try fm.removeItem(at: u)
					await PhotoVault.shared.deleteEncryptedCounterpartIfNeeded(for: u)
					success = true
					await MainActor.run { self.logger.log("performDelete: deleted item") }
				} catch {
					success = false
					let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
					errorMsg = localized.isEmpty ? "Unknown delete error." : localized
					await MainActor.run { self.logger.error("performDelete: failed to trash item: \(error.localizedDescription, privacy: .public)") }
				}

				let res = success
				let errorCopy = errorMsg
				await MainActor.run {
					deleteResults[u] = res
					deleteErrorMessages[u] = errorCopy
					deleteProgressCount += 1
					if res {
						selectedItems.remove(u)
						library.photos.removeAll { $0.url == u }
						displayedPhotos.removeAll { $0.url == u }
					}
				}
			}

			// Build a review summary for all delete results so the user can
			// always inspect what happened.
			await MainActor.run {
				var successCount = 0
				var failureCount = 0
				var detailLines: [String] = []
				for u in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
					let res = deleteResults[u] ?? nil
					if res == true {
						successCount += 1
						detailLines.append("[OK] \(u.lastPathComponent)")
					} else {
						failureCount += 1
						let msg = (deleteErrorMessages[u] ?? nil) ?? "Unknown delete error."
						detailLines.append("[FAIL] \(u.lastPathComponent): \(msg)")
					}
				}
				deleteHadFailures = failureCount > 0
				deleteErrorSummary = (["Requested: \(urls.count), Deleted: \(successCount), Failed: \(failureCount)"] + detailLines).joined(separator: "\n")
				showDeleteErrorSummary = true
				// clear deletingURLs when done
				deletingURLs = []
				isDeleting = false
			}
		}
	}

	/// Deletes the supplied items from the SQLite object-store database only.
	/// The matching working file in the temporary directory is removed (it's
	/// a transient cache) but the *original* imported source on disk — the
	/// file the user picked when they synced into the store — is never
	/// touched. We just drop the row from the `objects` table.
	private func performSQLiteDelete(urls: [URL]) {
		guard !urls.isEmpty else { return }
		deleteResults = Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as Bool?) })
		deleteErrorMessages = Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
		deleteProgressCount = 0
		isDeleting = true
		deletingURLs = urls
		logger.log("performSQLiteDelete: removing \(urls.count) records from SQLite store")
		deleteTask?.cancel()
		deleteTask = Task.detached(priority: .utility) {
			var deletedURLs: Set<URL> = []
			var failureMessage: String? = nil
			do {
				deletedURLs = try await SQLiteObjectStore.shared.deleteObjects(at: urls)
			} catch {
				failureMessage = error.localizedDescription
				await MainActor.run {
					self.logger.error("performSQLiteDelete: delete failed: \(error.localizedDescription, privacy: .public)")
				}
			}
			let fm = FileManager.default
			for u in deletedURLs {
				try? fm.removeItem(at: u)
			}
			let resolvedFailureMessage = failureMessage
			let resolvedDeletedURLs = deletedURLs
			await MainActor.run {
				var successCount = 0
				var failureCount = 0
				for u in urls {
					let succeeded = resolvedFailureMessage == nil && resolvedDeletedURLs.contains(u)
					deleteResults[u] = succeeded
					deleteErrorMessages[u] = succeeded ? nil : (resolvedFailureMessage ?? "Could not remove object from SQLite store.")
					deleteProgressCount += 1
					if succeeded {
						successCount += 1
						selectedItems.remove(u)
						library.photos.removeAll { $0.url == u }
						displayedPhotos.removeAll { $0.url == u }
					} else {
						failureCount += 1
					}
				}
				var detailLines: [String] = []
				let sorted = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
				for u in sorted {
					if resolvedDeletedURLs.contains(u) {
						detailLines.append("[OK] \(u.lastPathComponent)")
					} else {
						let errorText = (deleteErrorMessages[u] ?? nil) ?? "Unknown delete error."
						detailLines.append("[FAIL] \(u.lastPathComponent): \(errorText)")
					}
				}
				deleteHadFailures = failureCount > 0
				deleteErrorSummary = (["Requested: \(urls.count), Removed from SQLite: \(successCount), Failed: \(failureCount)"] + detailLines).joined(separator: "\n")
				showDeleteErrorSummary = true
				deletingURLs = []
				isDeleting = false
				if successCount > 0 {
					NotificationCenter.default.post(name: .sqliteObjectStoreDidChange, object: tabID)
				}
			}
		}
	}

	// MARK: - Sorting

	private func applyPersonFilter(_ active: PersonFilterState.Active?) {
		guard let active else {
			personFilterID = nil
			personFilterPaths = nil
			scheduleSort()
			return
		}
		personFilterID = active.personID
		Task {
			let paths = await FaceProcessor.shared.sourcePathsForPerson(personID: active.personID)
			await MainActor.run {
				// Ignore stale results if the filter changed while we were loading.
				guard personFilterID == active.personID else { return }
				personFilterPaths = Set(paths)
				scheduleSort()
			}
		}
	}

	private func applyOpenedSQLiteStoreSort() {
		let filter = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
		if filter.isEmpty, activeSortMode == .alphaAsc {
			displayedPhotos = library.photos
			displayedPhotoSections = shouldGroupGridByDescription
				? buildQuickPhotoSections(from: library.photos, sortMode: activeSortMode)
				: []
			return
		}
		scheduleSort()
	}

	private func syncDisplayedPhotosDuringScan() {
		if let paths = personFilterPaths {
			displayedPhotos = library.photos.filter { paths.contains($0.url.path) }
		} else {
			displayedPhotos = library.photos
		}
		displayedPhotoSections = []
	}

	private func scheduleSort() {
		// Cancel any in-flight sort work and start a new background task.
		// Provide an immediate, cheap filename-only filter so the UI feels
		// responsive while a debounced, full metadata-aware filter runs in
		// the background. Also debounce the full work to avoid starting a
		// heavy task on every single keystroke.
		sortTask?.cancel()
		let allPhotos = library.photos
		let photos: [PhotoItem]
		if let paths = personFilterPaths {
			photos = allPhotos.filter { paths.contains($0.url.path) }
		} else {
			photos = allPhotos
		}
		let mode = activeSortMode
		let filter = searchText
		let groupByDescription = shouldGroupGridByDescription

		if library.isScanning {
			syncDisplayedPhotosDuringScan()
			return
		}

		// Quick-pass: update displayedPhotos with a filename-only match
		// performed on the main actor so typing feels snappy.
		if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			switch mode {
			case .alphaAsc:
				displayedPhotos = photos.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
			case .alphaDesc:
				displayedPhotos = photos.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedDescending }
			case .fileDate, .imageDate, .descriptionAsc, .descriptionDesc:
				displayedPhotos = photos
			}
		} else {
			// Quick pass uses cached filename + description + metadata when
			// available; the debounced pass fills in uncached items.
			if let regex = try? NSRegularExpression(pattern: filter, options: [.caseInsensitive]) {
				let quick = photos.filter { p in
					Self.matchesRegex(regex, in: MetadataCache.shared.cachedSearchCandidate(for: p.url))
				}
				displayedPhotos = quick
			} else {
				let needle = filter.lowercased()
				displayedPhotos = photos.filter { p in
					MetadataCache.shared.cachedSearchCandidate(for: p.url).lowercased().contains(needle)
				}
			}
		}

		if groupByDescription {
			displayedPhotoSections = buildQuickPhotoSections(from: displayedPhotos, sortMode: mode)
		} else {
			displayedPhotoSections = []
		}

		// Debounced full filter/sort task (metadata-aware). Small sleep
		// reduces churn while typing.
		sortTask = Task.detached(priority: .userInitiated) {
			// Short debounce window to avoid firing for every keystroke.
			try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
			if Task.isCancelled { return }
			let sorted = await Self.computeSorted(photos: photos, mode: mode, filter: filter)
			if Task.isCancelled { return }
			let sections = groupByDescription
				? await Self.buildPhotoSections(from: sorted, sortMode: mode)
				: []
			await MainActor.run {
				displayedPhotos = sorted
				displayedPhotoSections = sections
			}
		}
	}

	private func buildQuickPhotoSections(from photos: [PhotoItem], sortMode: SortMode) -> [PhotoGridSection] {
		var buckets: [String: [PhotoItem]] = [:]
		var insertionOrder: [String] = []
		for photo in photos {
			let raw = MetadataCache.shared.cachedDescription(for: photo.url)?
				.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			let key = raw.isEmpty ? Self.noDescriptionSectionKey : raw
			if buckets[key] == nil {
				insertionOrder.append(key)
				buckets[key] = []
			}
			buckets[key]?.append(photo)
		}
		return Self.orderedPhotoSections(
			buckets: buckets,
			insertionOrder: insertionOrder,
			sortMode: sortMode
		)
	}

	private static func buildPhotoSections(from photos: [PhotoItem], sortMode: SortMode) async -> [PhotoGridSection] {
		var buckets: [String: [PhotoItem]] = [:]
		var insertionOrder: [String] = []
		for photo in photos {
			let raw = await MetadataCache.shared.description(for: photo.url)?
				.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			let key = raw.isEmpty ? noDescriptionSectionKey : raw
			if buckets[key] == nil {
				insertionOrder.append(key)
				buckets[key] = []
			}
			buckets[key]?.append(photo)
		}
		return orderedPhotoSections(
			buckets: buckets,
			insertionOrder: insertionOrder,
			sortMode: sortMode
		)
	}

	private static func orderedPhotoSections(
		buckets: [String: [PhotoItem]],
		insertionOrder: [String],
		sortMode: SortMode
	) -> [PhotoGridSection] {
		let namedKeys = insertionOrder.filter { $0 != noDescriptionSectionKey }
		var orderedKeys: [String]
		switch sortMode {
		case .descriptionAsc:
			orderedKeys = namedKeys.sorted {
				$0.localizedCaseInsensitiveCompare($1) == .orderedAscending
			}
		case .descriptionDesc:
			orderedKeys = namedKeys.sorted {
				$0.localizedCaseInsensitiveCompare($1) == .orderedDescending
			}
		default:
			orderedKeys = namedKeys
		}
		if buckets[noDescriptionSectionKey] != nil {
			orderedKeys.append(noDescriptionSectionKey)
		}
		return orderedKeys.compactMap { key in
			guard let sectionPhotos = buckets[key], !sectionPhotos.isEmpty else { return nil }
			return PhotoGridSection(
				id: key,
				title: key == noDescriptionSectionKey ? "No Description" : key,
				photos: sectionPhotos
			)
		}
	}

	private func queueMetadataRefresh(for url: URL) {
		pendingMetadataRefreshURLs.insert(url)
		metadataRefreshTask?.cancel()
		metadataRefreshTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 16_000_000)
			if Task.isCancelled { return }
			let urls = pendingMetadataRefreshURLs
			pendingMetadataRefreshURLs.removeAll(keepingCapacity: true)
			for url in urls {
				metadataRefreshTokens[url] = UUID()
			}
			metadataRefreshTask = nil
		}
	}

	private func refreshMetadataAfterWrite(for urls: [URL]) {
		guard !urls.isEmpty else { return }
		for url in urls {
			MetadataCache.shared.invalidate(for: url)
			queueMetadataRefresh(for: url)
		}
		scheduleSort()
	}

	private func queuePhotoChangeRefresh() {
		photoChangeTask?.cancel()
		photoChangeTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 16_000_000)
			if Task.isCancelled { return }
			scheduleSort()
			updateTabRegistry()
			photoChangeTask = nil
		}
	}

	private func queueThumbnailFrameUpdate(_ frames: [URL: CGRect]) {
		pendingThumbnailFrames = frames
		thumbnailFrameTask?.cancel()
		thumbnailFrameTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 16_000_000)
			if Task.isCancelled { return }
			thumbnailFrames = pendingThumbnailFrames
			thumbnailFrameTask = nil
			focusPendingSQLiteObjectIfPossible()
		}
	}

	private func focusPendingSQLiteObjectIfPossible() {
		guard let filename = pendingSQLiteFocusFilename else { return }
		guard let targetURL = displayedPhotos.first(where: { $0.url.lastPathComponent == filename })?.url
				?? library.photos.first(where: { $0.url.lastPathComponent == filename })?.url else {
			queuePendingSQLiteFocusRetry()
			return
		}

		selectSinglePhoto(targetURL)
		photoGridScrollRequest = PhotoGridScrollRequest(url: targetURL)
		_ = scrollGridToPhoto(targetURL)
		pendingSQLiteFocusFilename = nil
		pendingSQLiteFocusTask?.cancel()
		pendingSQLiteFocusTask = nil
	}

	@discardableResult
	private func scrollGridToPhoto(_ url: URL) -> Bool {
		guard let scrollView = gridScrollView,
			  let documentView = scrollView.documentView,
			  let frame = thumbnailFrames[url] else {
			return false
		}

		let visibleRect = scrollView.contentView.bounds
		let documentBounds = documentView.bounds
		let maxY = max(documentBounds.minY, documentBounds.maxY - visibleRect.height)
		let centeredY = visibleRect.origin.y + frame.midY - (visibleRect.height / 2)
		let nextY = min(max(centeredY, documentBounds.minY), maxY)
		let nextOrigin = NSPoint(x: visibleRect.origin.x, y: nextY)
		scrollView.contentView.scroll(to: nextOrigin)
		scrollView.reflectScrolledClipView(scrollView.contentView)
		return true
	}

	private func queuePendingSQLiteFocusRetry() {
		guard pendingSQLiteFocusTask == nil else { return }
		pendingSQLiteFocusTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 50_000_000)
			pendingSQLiteFocusTask = nil
			if !Task.isCancelled {
				focusPendingSQLiteObjectIfPossible()
			}
		}
	}

	private static func matchesRegex(_ regex: NSRegularExpression, in text: String) -> Bool {
		let range = NSRange(text.startIndex..<text.endIndex, in: text)
		return regex.firstMatch(in: text, options: [], range: range) != nil
	}

	private static func computeSorted(photos: [PhotoItem], mode: SortMode, filter: String) async -> [PhotoItem] {
		// If no filter provided, just sort normally.
		let filtered: [PhotoItem]
		if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			filtered = photos
		} else {
			// Attempt to compile the filter as a regular expression. If
			// compilation fails, fall back to a case-insensitive substring
			// match on filename, description, and other metadata.
			if let regex = try? NSRegularExpression(pattern: filter, options: [.caseInsensitive]) {
				var matches: [PhotoItem] = []
				for p in photos {
					let filename = p.url.lastPathComponent
					if matchesRegex(regex, in: filename) {
						matches.append(p)
						continue
					}
					if let description = await MetadataCache.shared.description(for: p.url),
					   !description.isEmpty,
					   matchesRegex(regex, in: description) {
						matches.append(p)
						continue
					}
					let fullCandidate = await MetadataCache.shared.candidateString(for: p.url)
					if matchesRegex(regex, in: fullCandidate) {
						matches.append(p)
					}
				}
				filtered = matches
			} else {
				let needle = filter.lowercased()
				var matches: [PhotoItem] = []
				for p in photos {
					let filename = p.url.lastPathComponent.lowercased()
					if filename.contains(needle) {
						matches.append(p)
						continue
					}
					if let description = await MetadataCache.shared.description(for: p.url),
					   description.lowercased().contains(needle) {
						matches.append(p)
						continue
					}
					let full = await MetadataCache.shared.candidateString(for: p.url)
					if full.lowercased().contains(needle) {
						matches.append(p)
					}
				}
				filtered = matches
			}
		}

		return await Self.sortPhotos(filtered, mode: mode)
	}

	private static func sortPhotos(_ photos: [PhotoItem], mode: SortMode) async -> [PhotoItem] {
		switch mode {
		case .alphaAsc:
			return photos.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
		case .alphaDesc:
			return photos.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedDescending }
		case .fileDate:
			// Fetch file modification dates off the main thread.
			return photos.sorted { a, b in
				let da = (try? a.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
				let db = (try? b.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
				return da > db
			}
		case .imageDate:
			// Try to read embedded image date metadata (EXIF/TIFF) and fall back
			// to the file modification date.
			let formatter = DateFormatter()
			formatter.locale = Locale(identifier: "en_US_POSIX")
			formatter.timeZone = .current
			formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

			func imageDate(for url: URL) -> Date? {
				guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
				guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
				// EXIF
				if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
					if let dt = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let d = formatter.date(from: dt) { return d }
				}
				// TIFF
				if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
					if let dt = tiff[kCGImagePropertyTIFFDateTime] as? String, let d = formatter.date(from: dt) { return d }
				}
				return nil
			}

			return photos.sorted { a, b in
				let da = imageDate(for: a.url) ?? (try? a.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
				let db = imageDate(for: b.url) ?? (try? b.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
				return da > db
			}
		case .descriptionAsc, .descriptionDesc:
			var descriptions: [String: String] = [:]
			for photo in photos {
				descriptions[photo.url.path] = await MetadataCache.shared.description(for: photo.url) ?? ""
			}
			return photos.sorted { a, b in
				let da = descriptions[a.url.path] ?? ""
				let db = descriptions[b.url.path] ?? ""
				let aEmpty = da.isEmpty
				let bEmpty = db.isEmpty
				if aEmpty != bEmpty {
					return !aEmpty && bEmpty
				}
				let cmp = da.localizedCaseInsensitiveCompare(db)
				return mode == .descriptionAsc ? cmp == .orderedAscending : cmp == .orderedDescending
			}
		}
	}

	/// Builds a concatenated candidate string of filename and common image
	/// metadata fields for regex matching. This may perform a lightweight
	/// read of image properties and should be invoked off the main actor.
	private static func buildMetadataCandidate(for url: URL, filename: String) async -> String {
		var pieces: [String] = [filename]
		guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
			return pieces.joined(separator: " ")
		}
		guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
			return pieces.joined(separator: " ")
		}
		func appendDict(_ key: CFString) {
			if let dict = props[key] as? [CFString: Any] {
				for (_, value) in dict {
					if let s = value as? String {
						pieces.append(s)
					} else if let arr = value as? [String] {
						pieces.append(contentsOf: arr)
					}
				}
			}
		}
		appendDict(kCGImagePropertyExifDictionary)
		appendDict(kCGImagePropertyTIFFDictionary)
		appendDict(kCGImagePropertyIPTCDictionary)
		// Also include any general title/description fields if present.
		if let t = props[kCGImagePropertyPNGDictionary] as? [CFString: Any], let text = t[kCGImagePropertyPNGTitle] as? String {
			pieces.append(text)
		}
		// Note: sidecars are not considered for search — keywords are only
		// matched from embedded image metadata per application policy.

		return pieces.joined(separator: " ")
	}

	/// Writes IPTC keywords to the image at `url`. Returns true on success.
	/// This performs a best-effort rewrite of the image file with updated
	/// metadata. It should be invoked off the main actor.
	static func writeKeywords(to url: URL, keywords: [String]) async -> Bool {
		await updateKeywords(on: url, keywords: keywords, mode: .append)
	}

	static func replaceKeywords(on url: URL, keywords: [String]) async -> Bool {
		await updateKeywords(on: url, keywords: keywords, mode: .replace)
	}

	static func readKeywords(from url: URL) async -> [String] {
		await Task.detached(priority: .utility) {
			guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
				  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
				  let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
			else {
				return []
			}
			return Self.mergedKeywords([], Self.keywordStrings(from: iptc[kCGImagePropertyIPTCKeywords]))
		}.value
	}

	private enum KeywordWriteMode: Sendable {
		case append
		case replace
	}

	private static func updateKeywords(on url: URL, keywords: [String], mode: KeywordWriteMode) async -> Bool {
		let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
		let targetURL: URL
		if SQLiteObjectStore.isWorkingCopyURL(url) {
			_ = AppWorkingDirectory.ensureAccess()
			do {
				targetURL = try await SQLiteObjectStore.shared.materializeWorkingCopyIfNeeded(url)
			} catch {
				logger.error("writeKeywords: failed to materialize sqlite working copy filename=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
				return false
			}
		} else {
			targetURL = url
		}
		// Ensure security-scoped access if available
		_ = await Self.ensureSecurityScopedAccess(for: targetURL)
		// Read source
		guard let src = CGImageSourceCreateWithURL(targetURL as CFURL, nil), let type = CGImageSourceGetType(src) else {
			logger.log("writeKeywords: cannot create CGImageSource")
			return false
		}

		guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
			logger.log("writeKeywords: cannot copy properties")
			return false
		}

		var metadata = props
		var iptc = (metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
		let existingKeywords = Self.keywordStrings(from: iptc[kCGImagePropertyIPTCKeywords])
		let nextKeywords: [String]
		switch mode {
		case .append:
			nextKeywords = Self.mergedKeywords(existingKeywords, keywords)
		case .replace:
			nextKeywords = Self.mergedKeywords([], keywords)
		}
		iptc[kCGImagePropertyIPTCKeywords] = nextKeywords as CFArray
		metadata[kCGImagePropertyIPTCDictionary] = iptc as CFDictionary

		// Create a temporary file next to the original so moves are atomic
		// and don't fail across volumes. Use a hidden filename to avoid
		// exposing partial artifacts.
		let fm = FileManager.default
		let dir = targetURL.deletingLastPathComponent()
		let tempFilename = ".pvtmp-\(UUID().uuidString)"
		let tempURL = dir.appendingPathComponent(tempFilename).appendingPathExtension(targetURL.pathExtension)

		guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else {
			logger.error("writeKeywords: cannot create CGImageDestination")
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": targetURL.path, "op": "writeKeywords", "message": "CGImageDestinationCreateWithURL failed when attempting to write embedded metadata."])
			// Embedded write failed; do not fall back to sidecar per policy.
			return false
		}

		CGImageDestinationAddImageFromSource(dest, src, 0, metadata as CFDictionary)
		if !CGImageDestinationFinalize(dest) {
			logger.error("writeKeywords: CGImageDestinationFinalize failed")
			try? fm.removeItem(at: tempURL)
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": targetURL.path, "op": "writeKeywords", "message": "CGImageDestinationFinalize failed when attempting to write embedded metadata."])
			// Finalize failed; do not write sidecar – report failure so caller
			// can surface an error or request additional permissions.
			return false
		}

		do {
			// Replace original file with temp file
			let backupURL = targetURL.appendingPathExtension("backup")
			if fm.fileExists(atPath: backupURL.path) { try? fm.removeItem(at: backupURL) }
			try fm.moveItem(at: targetURL, to: backupURL)
			try fm.moveItem(at: tempURL, to: targetURL)
			try? fm.removeItem(at: backupURL)
			await PhotoVault.shared.reencryptWorkingCopyIfNeeded(targetURL)
			if SQLiteObjectStore.isWorkingCopyURL(url) {
				try await SQLiteObjectStore.shared.storeObjectFile(at: targetURL)
				// Bytes are safely re-stored in the .sqlite database, so the
				// materialized working copy doesn't need to persist on disk.
				try? fm.removeItem(at: targetURL)
			}
			return true
		} catch {
			logger.error("writeKeywords: failed to replace original file: \(error.localizedDescription, privacy: .public)")
			// Attempt to cleanup
			try? fm.removeItem(at: tempURL)
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": targetURL.path, "op": "writeKeywords", "message": "Failed to replace original file after writing temp file: \(error.localizedDescription)"])
			// Do not fall back to sidecar; surface failure to caller.
			return false
		}
	}

	private nonisolated static func keywordStrings(from value: Any?) -> [String] {
		if let strings = value as? [String] {
			return strings
		}
		if let array = value as? [Any] {
			return array.compactMap { $0 as? String }
		}
		if let array = value as? NSArray {
			return array.compactMap { $0 as? String }
		}
		if let string = value as? String {
			return [string]
		}
		return []
	}

	private nonisolated static func mergedKeywords(_ existing: [String], _ appended: [String]) -> [String] {
		var result: [String] = []
		var seen: Set<String> = []
		for keyword in existing + appended {
			let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { continue }
			let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			if seen.insert(key).inserted {
				result.append(trimmed)
			}
		}
		return result
	}

	// MARK: - Description (person name) metadata writing

	/// Writes (overwrites) the DESCRIPTION / caption metadata for the image.
	/// Person names (manual assignment or via recognition) are stored here.
	/// Sets TIFF ImageDescription and IPTC Caption/Abstract.
	static func writeDescription(to url: URL, description: String) async -> Bool {
		await updateDescription(on: url, description: description)
	}

	private static func updateDescription(on url: URL, description: String) async -> Bool {
		let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
		let targetURL: URL
		if SQLiteObjectStore.isWorkingCopyURL(url) {
			_ = AppWorkingDirectory.ensureAccess()
			do {
				targetURL = try await SQLiteObjectStore.shared.materializeWorkingCopyIfNeeded(url)
			} catch {
				logger.error("writeDescription: failed to materialize sqlite working copy filename=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
				return false
			}
		} else {
			targetURL = url
		}
		_ = await Self.ensureSecurityScopedAccess(for: targetURL)

		guard let src = CGImageSourceCreateWithURL(targetURL as CFURL, nil),
			  let type = CGImageSourceGetType(src) else {
			logger.log("writeDescription: cannot create CGImageSource")
			return false
		}

		guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
			logger.log("writeDescription: cannot copy properties")
			return false
		}

		var metadata = props

		// Primary: TIFF ImageDescription (surfaced by app in thumbnails/search and commonly used for description)
		var tiff = (metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
		tiff[kCGImagePropertyTIFFImageDescription] = description
		metadata[kCGImagePropertyTIFFDictionary] = tiff as CFDictionary

		// Also set standard IPTC caption field for interoperability with other tools
		var iptc = (metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
		iptc[kCGImagePropertyIPTCCaptionAbstract] = description
		metadata[kCGImagePropertyIPTCDictionary] = iptc as CFDictionary

		// Create temp + atomic replace (same pattern as keywords)
		let fm = FileManager.default
		let dir = targetURL.deletingLastPathComponent()
		let tempFilename = ".pvtmp-\(UUID().uuidString)"
		let tempURL = dir.appendingPathComponent(tempFilename).appendingPathExtension(targetURL.pathExtension)

		guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else {
			logger.error("writeDescription: cannot create CGImageDestination")
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": targetURL.path, "op": "writeDescription", "message": "CGImageDestinationCreateWithURL failed when attempting to write embedded metadata."])
			return false
		}

		CGImageDestinationAddImageFromSource(dest, src, 0, metadata as CFDictionary)
		if !CGImageDestinationFinalize(dest) {
			logger.error("writeDescription: CGImageDestinationFinalize failed")
			try? fm.removeItem(at: tempURL)
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": targetURL.path, "op": "writeDescription", "message": "CGImageDestinationFinalize failed when attempting to write embedded metadata."])
			return false
		}

		do {
			let backupURL = targetURL.appendingPathExtension("backup")
			if fm.fileExists(atPath: backupURL.path) { try? fm.removeItem(at: backupURL) }
			try fm.moveItem(at: targetURL, to: backupURL)
			try fm.moveItem(at: tempURL, to: targetURL)
			try? fm.removeItem(at: backupURL)
			await PhotoVault.shared.reencryptWorkingCopyIfNeeded(targetURL)
			if SQLiteObjectStore.isWorkingCopyURL(url) {
				try await SQLiteObjectStore.shared.storeObjectFile(at: targetURL)
				// Bytes are safely re-stored in the .sqlite database, so the
				// materialized working copy doesn't need to persist on disk.
				try? fm.removeItem(at: targetURL)
			}
			return true
		} catch {
			logger.error("writeDescription: failed to replace original file: \(error.localizedDescription, privacy: .public)")
			try? fm.removeItem(at: tempURL)
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": targetURL.path, "op": "writeDescription", "message": "Failed to replace original file after writing temp file: \(error.localizedDescription)"])
			return false
		}
	}

	private func restoreSavedWindowsIfNeeded(skipSavedFolder: Bool) {
		logger.log("launch saved-state restore: saveOpenWindows=\(self.saveOpenWindows, privacy: .public) disableAutoRestore=\(self.disableAutoRestoreWindows, privacy: .public) skipSavedFolder=\(skipSavedFolder, privacy: .public)")
		// Only the first ContentView at launch consumes the persisted
		// session. New windows opened later (File → New, Cmd+N) start
		// blank and prompt the user for a folder.
		guard saveOpenWindows else {
			logger.log("launch saved-state restore: result=skipped reason=saveOpenWindows-disabled")
			return
		}
		guard WindowStateStore.shared.consumeLaunchRestoration() else {
			logger.log("launch saved-state restore: result=skipped reason=already-consumed")
			return
		}

		// Quick test switch: if auto-restore of photo windows is disabled
		// via the AppStorage flag, skip opening saved photo windows. This is
		// a temporary diagnostic toggle to help isolate main-thread work at
		// startup. Set the UserDefault key "disableAutoRestoreWindows"
		// to false to re-enable restoring windows.
		if disableAutoRestoreWindows {
			logger.log("launch saved-state restore: photoWindowRestore=disabled")
		}

		if skipSavedFolder {
			logger.log("launch folder restore: source=saved-window-state result=skipped reason=bookmark-restore-already-loaded-folder")
		} else if let folder = WindowStateStore.shared.resolveSavedFolder() {
			// Try to restore a previously saved snapshot of file paths for
			// this folder so the UI can populate immediately without a
			// potentially expensive re-scan. If no snapshot exists we fall
			// back to leaving the library empty and the user can manually
			// choose a folder (or initiate a scan).
			Task.detached {
				if let urls = PhotoLibrary.loadCachedSnapshot(for: folder) {
					// Build a deduplicated list off the main thread, then
					// publish it to the UI in small batches so the main thread
					// doesn't get blocked by a single large assignment.
					var deduped: [URL] = []
					deduped.reserveCapacity(urls.count)
					var seen: Set<String> = []
					for u in urls {
						let name = u.lastPathComponent.lowercased()
						if seen.insert(name).inserted {
							deduped.append(u)
						}
					}
					deduped.sort {
						$0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
					}
					let dedupedCount = deduped.count
					await MainActor.run {
						logger.log("launch folder restore: source=saved-window-state storage=cache folder=\(folder.path, privacy: .public) cachedFiles=\(urls.count, privacy: .public) uniqueFiles=\(dedupedCount, privacy: .public)")
					}
					// Publish in batches to avoid a big main-thread spike.
					let batchSize = 512
					await MainActor.run {
						library.photos = []
						library.folderURL = folder
						activeFolderNames = [folder.lastPathComponent]
					}
					var idx = 0
					while idx < deduped.count {
						let end = min(idx + batchSize, deduped.count)
						let slice = deduped[idx..<end].map { PhotoItem(url: $0) }
						await MainActor.run {
							library.photos.append(contentsOf: slice)
							library.lastScanDate = Date()
						}
						warmFilesystemThumbnails(for: slice)
						idx = end
						try? await Task.sleep(nanoseconds: 10_000_000) // 10ms gap between batches
					}
					// Kick off a low-priority background refresh scan so the
					// UI is populated quickly from the snapshot but the on-disk
					// state is reconciled afterwards. This keeps the app
					// responsive while ensuring the snapshot is eventually
					// refreshed. The refresh is cancellable and runs at
					// background priority.
					Task.detached(priority: .background) {
						// Small delay to let the UI stabilize and avoid
						// contention on startup.
						try? await Task.sleep(nanoseconds: 1_000_000_000)
						await MainActor.run {
							// Ensure we still have the same folder before
							// starting a potentially expensive re-scan.
							if library.folderURL == folder {
								if UserDefaults.standard.bool(forKey: "deferAtLaunchBackgroundWork") {
									logger.log("launch folder refresh: source=saved-window-state storage=filesystem result=deferred folder=\(folder.path, privacy: .public)")
								} else {
									logger.log("launch folder refresh: source=saved-window-state storage=filesystem result=started folder=\(folder.path, privacy: .public)")
									library.scan(folder: folder)
								}
							}
						}
					}
				} else {
					// No cached snapshot available; retain current behavior
					// of not auto-scanning at launch.
					await MainActor.run {
						logger.log("launch folder restore: source=saved-window-state storage=cache result=miss folder=\(folder.path, privacy: .public)")
						library.folderURL = folder
						activeFolderNames = [folder.lastPathComponent]
					}
				}
			}
		} else {
			logger.log("launch folder restore: source=saved-window-state result=none")
		}
		// Restore previously-open photo windows but avoid creating a large
		// number of windows synchronously at startup which can freeze the
		// UI. Stagger window creation on a background task and limit the
		// number of windows restored to a reasonable cap.
		let saved = WindowStateStore.shared.openPhotoURLs()
		logger.log("launch photo-window restore: source=saved-window-state count=\(saved.count, privacy: .public)")
		let maxOpen = 8
		if !saved.isEmpty && !disableAutoRestoreWindows {
			logger.log("launch photo-window restore: result=started scheduledLimit=\(maxOpen, privacy: .public) savedCount=\(saved.count, privacy: .public)")
			Task.detached(priority: .background) {
				for (i, url) in saved.prefix(maxOpen).enumerated() {
					// Small stagger to avoid UI contention when creating many
					// windows at once. Increase delay for larger index.
					let delay = UInt64(min(i, 5)) * 200_000_000 // 0..1s
					try? await Task.sleep(nanoseconds: delay)
					await MainActor.run {
						openWindow(id: "photo-viewer", value: url)
						if AppLogLevel.current.allows(.debug) {
							logger.debug("launch photo-window restore: opened path=\(url.path, privacy: .public)")
						}
					}
				}
				logger.log("launch photo-window restore: result=scheduled scheduledCount=\(min(saved.count, maxOpen), privacy: .public)")
			}
		} else if !saved.isEmpty {
			logger.log("launch photo-window restore: result=skipped reason=disabled savedCount=\(saved.count, privacy: .public)")
		}
	}
}
