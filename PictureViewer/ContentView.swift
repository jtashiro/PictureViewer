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

struct ContentView: View {
	@StateObject private var library = PhotoLibrary()
	@StateObject private var faceScanProgress = FaceScanProgress.shared
	@StateObject private var personFilterState = PersonFilterState.shared
	@State private var thumbnailSize: CGFloat = 160
	@AppStorage("sortMode") private var sortModeRaw: Int = 0
	private enum SortMode: Int, CaseIterable, Identifiable {
		case alphaAsc = 0
		case alphaDesc = 1
		case fileDate = 2
		case imageDate = 3

		var id: Int { rawValue }
		var title: String {
			switch self {
			case .alphaAsc: return "Name ↑"
			case .alphaDesc: return "Name ↓"
			case .fileDate: return "File Date"
			case .imageDate: return "Image Date"
			}
		}
	}

	@State private var initialFolderURL: URL?
	@State private var initialSQLiteStoreName: String?
	@State private var tabID = UUID()
	@State private var registeredGalleryFolderURL: URL?
	@State private var registeredSQLiteStoreName: String?
	@State private var activeSQLiteStoreName: String?

	init(initialFolder: URL? = nil, initialSQLiteStoreName: String? = nil) {
		_initialFolderURL = State(initialValue: initialFolder)
		_initialSQLiteStoreName = State(initialValue: initialSQLiteStoreName)
	}

	/// Restore a persisted security-scoped bookmark (if present) and start
	/// accessing the resource so the app can write into the folder while
	/// sandboxed. This is safe to call at startup.
	private func restoreFolderBookmarkIfNeeded(library: PhotoLibrary, logger: Logger) async -> Bool {
		if saveOpenWindows {
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
								openWindow(id: "sqlite-store", value: storeName)
							}
						}
					}
				}
				return true
			}
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
						await MainActor.run {
							logger.log("launch folder restore: source=legacy-bookmark storage=cache folder=\(url.path, privacy: .public) cachedFiles=\(urls.count, privacy: .public) uniqueFiles=\(deduped.count, privacy: .public)")
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
							// Warm thumbnails for the restored batch in background so
							// the UI can display images quickly without waiting for
							// on-demand generation. The ThumbnailGenerator itself
							// limits concurrency so this is safe to run per-batch.
							Task.detached(priority: .utility) {
								for item in slice {
									if Task.isCancelled { break }
									do {
										let img = try await ThumbnailGenerator.shared.generateThumbnail(for: item.url)
										await ThumbnailCache.shared.store(img, for: item.url)
									} catch { }
								}
							}

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
		let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
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
	@State private var editKeywordsText: String = ""
	@State private var isApplyingKeywords: Bool = false
	@State private var editProgressCount: Int = 0
	@State private var editingResults: [URL: Bool?] = [:]
	@State private var isAssigningPerson: Bool = false
	@State private var assignPersonName: String = ""
	@State private var existingPersonNames: [String] = []
	@State private var isApplyingPersonAssignment: Bool = false
	@State private var showPersonAssignmentResult: Bool = false
	@State private var personAssignmentResultMessage: String = ""
	@State private var isRescanningFaces: Bool = false
	@State private var showFaceRescanResult: Bool = false
	@State private var faceRescanResultMessage: String = ""
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
	@State private var vaultUnlockPassword: String = ""
	@State private var vaultUnlockConfirmation: String = ""
	@State private var vaultUnlockMessage: String?
	@State private var vaultStoreTask: Task<Void, Never>?
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

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				statusBar
					.fixedSize(horizontal: false, vertical: true)
				Divider()
				contentBody
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
						.navigationTitle(
							activeFolderNames.isEmpty ? (library.folderURL?.lastPathComponent ?? "Picture Viewer") : (activeFolderNames.count == 1 ? activeFolderNames.first! : activeFolderNames.joined(separator: " · "))
						)
			.toolbar { toolbarItems }
			.focusedSceneValue(\.vaultCommandActions, VaultCommandActions(
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
				openSQLiteStore: { chooseAndOpenSQLiteObjectStore() },
				copy: { copySelectedFiles() },
				paste: { pasteFilesToVault() },
				selectAll: { selectAllDisplayedPhotos() },
				canCloseVault: isSQLiteObjectStoreView || isActiveVaultView || vaultStatus.isUnlocked,
				canRenameVault: isActiveVaultView && library.folderURL != nil,
				canImportSelected: hasSelectedPhotos,
				canExport: !library.photos.isEmpty,
				canSyncToTab: !library.photos.isEmpty,
				canSyncToSQLiteStore: !library.photos.isEmpty,
				canSyncSelectedToSQLiteStore: hasSelectedPhotos,
				canOpenSQLiteStore: true,
				canCopy: hasSelectedPhotos,
				canPaste: canPasteFilesToVault,
				canSelectAll: !displayedPhotos.isEmpty
			))
		}
		.frame(minWidth: 760, minHeight: 540)
		// Attach a WindowAccessor so we can set window-level defaults like
		// preferring tabs for this app's windows.
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
			if let storeName = initialSQLiteStoreName {
				logger.log("launch sqlite restore: source=initial-sqlite-window store=\(storeName, privacy: .public)")
				openSQLiteObjectStore(named: storeName)
				return
			}
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
					} else {
						// No-op for subsequent ContentView instances.
					}
				}
			}
		}
		.onDisappear {
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
		.onChange(of: library.photos) { _ in
			queuePhotoChangeRefresh()
		}
		.onChange(of: activeFolderNames) { _ in updateTabRegistry() }
		.onChange(of: library.folderURL) { _ in updateTabRegistry() }
		.onChange(of: sortModeRaw) { _ in scheduleSort() }
		.onChange(of: searchText) { _ in scheduleSort() }
		.onChange(of: personFilterState.active) { active in
			applyPersonFilter(active)
		}
		.task {
			applyPersonFilter(personFilterState.active)
		}
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
				Text("Edit Keywords for \(selectedPhotoCount) photos")
					.font(.headline)
				TextField("Keywords (comma-separated)", text: $editKeywordsText)
					.textFieldStyle(.roundedBorder)
					.padding(.horizontal)

				// Results list + progress
				let urls = selectedPhotoURLs
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
									} else {
										if let res = editingResults[u] {
											if res == true {
												Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
											} else {
												Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
											}
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
						// Prevent cancel while applying; otherwise just close
						if !isApplyingKeywords {
							isEditingKeywords = false
						}
					}
					.disabled(isApplyingKeywords)
					Spacer()
					if isApplyingKeywords {
						Button("Close") {
							// allow closing the sheet while apply runs in background
							isEditingKeywords = false
						}
					} else {
						Button("Apply") {
							let parts = editKeywordsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
							guard !parts.isEmpty else { return }
							// Prepare progress state
							let urls = selectedPhotoURLs
							editingResults = Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as Bool?) })
							editProgressCount = 0
							isApplyingKeywords = true
							Task.detached(priority: .utility) {
								let workerCount = max(1, min(urls.count, PhotoLibrary.workerCount))
								await withTaskGroup(of: (URL, Bool).self) { group in
									var nextIndex = 0

									func enqueueNext() {
										guard nextIndex < urls.count else { return }
										let url = urls[nextIndex]
										nextIndex += 1
										group.addTask {
											if Task.isCancelled { return (url, false) }
											let ok = await Self.writeKeywords(to: url, keywords: parts)
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
												queueMetadataRefresh(for: url)
											}
											logger.log("writeKeywords: success=\(ok, privacy: .public)")
										}
										enqueueNext()
									}
								}
								await MainActor.run {
									// Remove successful items from selection to indicate completion
									for (u, res) in editingResults {
										if res == true { removeFromSelection(u) }
									}
									isApplyingKeywords = false
									scheduleSort()
								}
							}
						}
						.disabled(editKeywordsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasSelectedPhotos)
					}
				}
				.padding(.horizontal)
			}
			.padding()
			.frame(minWidth: 420, minHeight: 200)
		}
		.sheet(isPresented: $isAssigningPerson) {
			VStack(spacing: 12) {
				Text("Assign Person Name")
					.font(.headline)
				Text("Apply a person name to faces detected in \(faceActionTargetURLs.count) photo\(faceActionTargetURLs.count == 1 ? "" : "s").")
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
						if !isApplyingPersonAssignment { isAssigningPerson = false }
					}
					.disabled(isApplyingPersonAssignment)
					Spacer()
					if isApplyingPersonAssignment {
						ProgressView().controlSize(.small)
					}
					Button("Apply") {
						applyPersonAssignmentToSelection()
					}
					.disabled(faceActionTargetURLs.isEmpty || assignPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isApplyingPersonAssignment)
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
					Text("\(vaultProgressCompleted) of \(vaultProgressTotal)")
						.font(.caption)
						.foregroundStyle(.secondary)
						.monospacedDigit()
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
							Task.detached(priority: .utility) {
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
							Task.detached(priority: .utility) {
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

	// MARK: - Status bar (single, compact line)

	private var statusBar: some View {
		HStack(spacing: 8) {
			statusIcon
			statusText
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer(minLength: 8)
			Button {
				refreshThumbnails()
			} label: {
				Label("Refresh Thumbnails", systemImage: "arrow.clockwise")
			}
			.controlSize(.small)
			.help("Clear cached thumbnails and regenerate them")
			.disabled(library.photos.isEmpty || isRefreshing)
		}
		.font(.caption)
		.padding(.horizontal, 10)
		.padding(.vertical, 4)
		.background(.bar)
	}

	@ViewBuilder
	private var statusIcon: some View {
		if library.isScanning || isRefreshing || (isSQLiteObjectStoreView && isVaultWorking) {
			ProgressView().controlSize(.mini)
		} else if library.lastScanDate != nil {
			Image(systemName: "photo.stack").foregroundStyle(.secondary)
		} else {
			Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary)
		}
	}

	@ViewBuilder
	private var statusText: some View {
		if library.isScanning {
			HStack(spacing: 6) {
				Text("Scanning \(library.folderURL?.lastPathComponent ?? "")…")
				bullet
				Text("\(mediaStatusSummary(for: library.photos)) found")
					.foregroundStyle(.secondary)
				if let start = library.scanStartDate {
					bullet
					TimelineView(.periodic(from: start, by: 0.5)) { context in
						Text("elapsed \(Self.format(duration: context.date.timeIntervalSince(start)))")
							.foregroundStyle(.secondary)
							.monospacedDigit()
					}
				}
			}
		} else if isRefreshing {
			Text("Refreshing thumbnails…").foregroundStyle(.secondary)
		} else if isSQLiteObjectStoreView {
			HStack(spacing: 6) {
				Text("\(mediaStatusSummary(for: library.photos)) in SQLite store")
					.foregroundStyle(.secondary)
				if isVaultWorking {
					bullet
					Text(vaultProgressMessage.isEmpty ? "Opening SQLite store..." : vaultProgressMessage)
						.foregroundStyle(.secondary)
					if vaultProgressTotal > 0 {
						bullet
						Text("\(vaultProgressCompleted) of \(vaultProgressTotal)")
							.foregroundStyle(.secondary)
							.monospacedDigit()
					}
					if let sqliteLoadStartDate {
						bullet
						TimelineView(.periodic(from: sqliteLoadStartDate, by: 0.5)) { context in
							Text("elapsed \(Self.format(duration: context.date.timeIntervalSince(sqliteLoadStartDate)))")
								.foregroundStyle(.secondary)
								.monospacedDigit()
						}
					}
				} else if let sqliteLastLoadDuration {
					bullet
					Text("loaded in \(Self.format(duration: sqliteLastLoadDuration))")
						.foregroundStyle(.secondary)
						.monospacedDigit()
					if let sqliteLastThumbnailLoadDuration {
						bullet
						Text("thumbnails in \(Self.format(duration: sqliteLastThumbnailLoadDuration))")
							.foregroundStyle(.secondary)
							.monospacedDigit()
					}
				}
			}
		} else if let date = library.lastScanDate {
			HStack(spacing: 6) {
				Text(mediaStatusSummary(for: library.photos))
				bullet
				Text("scanned \(date.formatted(date: .abbreviated, time: .shortened))")
					.foregroundStyle(.secondary)
				if let dur = library.lastScanDuration {
					Text("in \(Self.format(duration: dur))")
						.foregroundStyle(.secondary)
						.monospacedDigit()
				}
				if let rDate = lastRefreshDate, let rDur = lastRefreshDuration {
					bullet
					Text("thumbnails refreshed \(rDate.formatted(date: .omitted, time: .shortened)) in \(Self.format(duration: rDur))")
						.foregroundStyle(.secondary)
						.monospacedDigit()
				}
			}
		} else {
			Text("No folder scanned yet").foregroundStyle(.secondary)
		}
	}

	private var bullet: some View {
		Text("·").foregroundStyle(.tertiary)
	}

	private func mediaStatusSummary(for items: [PhotoItem]) -> String {
		let videoCount = items.reduce(into: 0) { count, item in
			let contentType = try? item.url.resourceValues(forKeys: [.contentTypeKey]).contentType
			if PhotoLibrary.isVideoMediaFile(item.url, contentType: contentType) {
				count += 1
			}
		}
		let totalCount = items.count
		let photoCount = max(0, totalCount - videoCount)
		let totalLabel = totalCount.formatted()
		let photoLabel = "\(photoCount.formatted()) photo\(photoCount == 1 ? "" : "s")"
		let videoLabel = "\(videoCount.formatted()) video\(videoCount == 1 ? "" : "s")"
		return "\(totalLabel) (\(photoLabel), \(videoLabel))"
	}

	private static func format(duration: TimeInterval) -> String {
		if duration < 1 {
			return String(format: "%.0f ms", duration * 1000)
		} else if duration < 60 {
			return String(format: "%.1f s", duration)
		} else {
			let total = Int(duration)
			return "\(total / 60)m \(total % 60)s"
		}
	}

	// MARK: - Main content

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
					performSQLiteSync(sourceURLs: urls, title: "Store Dropped Items in SQLite Store")
				}
			}
			return true
		}
	}

	private nonisolated static func collectFileURLs(from providers: [NSItemProvider]) async -> [URL] {
		await withTaskGroup(of: URL?.self, returning: [URL].self) { group in
			for provider in providers {
				group.addTask {
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
						if loadedURL != nil {
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
			}
			var result: [URL] = []
			var seen: Set<String> = []
			for await url in group {
				if let url, seen.insert(url.standardizedFileURL.path).inserted {
					result.append(url)
				}
			}
			return result
		}
	}

	@ViewBuilder
	private var photoGrid: some View {
		ScrollViewReader { scrollProxy in
			ScrollView {
				LazyVGrid(
					columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize * 1.4), spacing: 10)],
					spacing: 10
				) {
					ForEach(displayedPhotos) { photo in
						let isSelected = isPhotoSelected(photo.url)
						ZStack(alignment: .topTrailing) {
							VStack(spacing: 4) {
								ThumbnailView(
									url: photo.url,
									size: thumbnailSize,
									refreshToken: refreshToken,
									metadataRefreshToken: metadataRefreshTokens[photo.url] ?? refreshToken,
									forceLoad: forceThumbnailLoading
								)
								// Filename and keywords are rendered by ThumbnailView now.
							}
							.overlay {
								RoundedRectangle(cornerRadius: 8)
									.stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
							}
							if selectionMode {
								// Selection badge
								Group {
									if isSelected {
										Image(systemName: "checkmark.circle.fill")
											.foregroundStyle(.white, .blue)
											.background(Circle().fill(Color.blue))
									} else {
										Image(systemName: "circle")
											.foregroundStyle(.secondary)
									}
								}
								.padding(6)
							}
						}
						.id(photo.url)
						.background {
							GeometryReader { proxy in
								Color.clear
									.preference(key: ThumbnailFramePreferenceKey.self, value: [photo.url: proxy.frame(in: .named("photoGridArea"))])
							}
						}
						.contentShape(Rectangle())
						.onTapGesture {
							handleThumbnailSingleClick(photo.url)
						}
						.onTapGesture(count: 2) {
							openPhotoViewer(photo.url)
						}
						.contextMenu {
							let contextURLs = contextActionURLs(for: photo.url)
							Button(contextURLs.count > 1 ? "Show Selected in Finder" : "Show in Finder") {
								NSWorkspace.shared.activateFileViewerSelecting(contextURLs)
							}
							Button(contextURLs.count > 1 ? "Open Selected with Default App" : "Open with Default App") {
								for url in contextURLs { NSWorkspace.shared.open(url) }
							}
							Button(contextURLs.count > 1 ? "Copy Selected Files" : "Copy File") {
								copyFilesToPasteboard(contextURLs)
							}
							Divider()
							Button("Repair metadata") {
								Task.detached(priority: .utility) {
									let (ok, msg) = await Self.repairMetadata(for: photo.url)
									await MainActor.run {
										if ok {
											// Force a thumbnail refresh and log
											refreshToken = UUID()
											repairResultMessage = "Repair succeeded for \(photo.url.lastPathComponent)"
										} else {
											logger.error("Repair metadata failed: \(msg ?? "")")
											repairResultMessage = "Repair failed for \(photo.url.lastPathComponent): \(msg ?? "Unknown error")"
										}
										showRepairResult = true
									}
								}
							}
						}
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
		ToolbarItem(placement: .primaryAction) {
			Button {
				toggleVaultLock()
			} label: {
				Label(
					vaultStatus.isUnlocked ? "Lock Vault" : "Unlock Vault",
					systemImage: vaultStatus.isUnlocked ? "lock.open.fill" : "lock.fill"
				)
				.foregroundStyle(vaultStatus.isUnlocked ? Color.green : Color.secondary)
			}
			.help(vaultStatus.isUnlocked ? "Vault is unlocked — click to lock" : "Vault is locked — click to unlock")
		}
		ToolbarItem(placement: .primaryAction) {
			Button {
				chooseFolder()
			} label: {
				Label("Choose Folder", systemImage: "folder")
			}
			.help("Choose a folder to browse")
		}
		ToolbarItem(placement: .primaryAction) {
			Menu {
				Button("Import Folder to Vault…") {
					importFolderToVault()
				}
				Button("Store Selected Images in Vault") {
					importSelectedImagesToVault()
				}
				.disabled(!hasSelectedPhotos)
				Button("Open Vault") {
					openVault()
				}
				Button(hasSelectedPhotos ? "Export Selected…" : "Export All Displayed…") {
					exportVaultSelection()
				}
				.disabled(library.photos.isEmpty)
			} label: {
				Label("Vault", systemImage: "lock.doc")
			}
			.help("Import, open, or export vault photos")
		}
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
					// Open the dedicated People window.
					openWindow(id: "people")
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
					if !selectionMode { clearSelection() }
				} label: {
					Text(selectionMode ? "Done" : "Edit")
				}
				.help("Select multiple thumbnails for bulk operations")
				Button(action: {
					loadExistingPersonNamesForAssignment()
					isAssigningPerson = true
				}) {
					Text("Assign Person")
				}
				.disabled(faceActionTargetURLs.isEmpty)
				.help("Assign faces from selected photos, or all loaded photos when none are selected")
				Button(action: {
					rescanFaceRecognitionForSelection()
				}) {
					Text("Rescan Faces")
				}
				.disabled(faceActionTargetURLs.isEmpty || isRescanningFaces || faceScanProgress.isActive)
				.help("Rescan selected photos, or all loaded photos when none are selected")
				if selectionMode {
					Button(action: {
						// Show bulk edit keywords sheet
						isEditingKeywords = true
						editKeywordsText = ""
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
				// filename and image metadata. Runs filtering in the
				// background via `scheduleSort()`.
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
		return library.photos.map { $0.url }
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

	private func applyPersonAssignmentToSelection() {
		let name = assignPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
		let urls = faceActionTargetURLs
		guard !name.isEmpty, !urls.isEmpty else { return }
		let totalPhotos = urls.count
		isApplyingPersonAssignment = true
		Task.detached(priority: .utility) {
			let result = await FaceProcessor.shared.assignPerson(named: name, toFiles: urls)
			await MainActor.run {
				isApplyingPersonAssignment = false
				isAssigningPerson = false
				if result.facesAssigned > 0 {
					let faces = result.facesAssigned
					let photosUsed = result.photosWithFaces
					let skipped = totalPhotos - photosUsed
					var message = "Assigned \(faces) face\(faces == 1 ? "" : "s") from \(photosUsed) of \(totalPhotos) photo\(totalPhotos == 1 ? "" : "s") to \"\(name)\"."
					if skipped > 0 {
						message += " \(skipped) photo\(skipped == 1 ? "" : "s") had no detectable face."
					}
					personAssignmentResultMessage = message
				} else {
					personAssignmentResultMessage = "No detectable faces were found in the selected photos."
				}
				showPersonAssignmentResult = true
			}
		}
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
		performSQLiteSync(sourceURLs: library.photos.map(\.url), title: "Sync Tab to SQLite Store")
	}

	private func syncSelectedMediaToSQLiteStore() {
		performSQLiteSync(sourceURLs: selectedPhotoURLs, title: "Store Selected in SQLite Store")
	}

	private func performSQLiteSync(sourceURLs: [URL], title: String) {
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
		alert.messageText = title
		alert.informativeText = "Sync \(sourceURLs.count) object\(sourceURLs.count == 1 ? "" : "s") to the selected SQLite store using up to \(workers) worker\(workers == 1 ? "" : "s")."
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
		vaultProgressMessage = "Syncing to \(databaseFilename)..."
		vaultProgressCompleted = 0
		vaultProgressTotal = sourceURLs.count
		vaultStoreTask?.cancel()
		let task = Task.detached(priority: .userInitiated) {
			struct PreparedSQLiteObject: Sendable {
				let index: Int
				let filename: String
				let pendingObject: SQLiteObjectStore.PendingObject
			}

			var failedCount = 0
			var completedCount = 0
			var storedCount = 0
			var firstStoredFilename: String?
			var cancelledBeforeStartCount = 0
			let syncStart = Date()
			let chunkSize = max(1, min(workers, 8))
			logger.log("sqlite sync: begin database=\(databaseFilename, privacy: .public) requested=\(sourceURLs.count, privacy: .public) workers=\(workers, privacy: .public) chunkSize=\(chunkSize, privacy: .public)")

			for chunkStart in stride(from: 0, to: sourceURLs.count, by: chunkSize) {
				if Task.isCancelled {
					cancelledBeforeStartCount += sourceURLs.count - chunkStart
					break
				}
				let chunkEnd = min(chunkStart + chunkSize, sourceURLs.count)
				let chunk = Array(sourceURLs[chunkStart..<chunkEnd])
				let chunkStartDate = Date()
				logger.log("sqlite sync: chunk begin range=\(chunkStart + 1, privacy: .public)-\(chunkEnd, privacy: .public) of=\(sourceURLs.count, privacy: .public)")

				let preparedObjects: [PreparedSQLiteObject] = await withTaskGroup(of: PreparedSQLiteObject?.self) { group in
					for (offset, url) in chunk.enumerated() {
						let index = chunkStart + offset
						group.addTask {
							if Task.isCancelled { return nil }
							let itemStart = Date()
							logger.log("sqlite sync: item read begin index=\(index + 1, privacy: .public) of=\(sourceURLs.count, privacy: .public) filename=\(url.lastPathComponent, privacy: .public)")
							do {
								let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey])
								guard PhotoLibrary.isSupportedMediaFile(url, contentType: resourceValues?.contentType) else {
									logger.error("sqlite sync: unsupported media index=\(index + 1, privacy: .public) of=\(sourceURLs.count, privacy: .public) url=\(url.path, privacy: .public)")
									return nil
								}
								let started = url.startAccessingSecurityScopedResource()
								defer { if started { url.stopAccessingSecurityScopedResource() } }
								let data = try Data(contentsOf: url)
								try Task.checkCancellation()
								let contentHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
								let contentType = resourceValues?.contentType?.identifier
									?? UTType(filenameExtension: url.pathExtension)?.identifier
								let thumbnailData = await Self.sqliteThumbnailDataForSyncSource(url)
								logger.log("sqlite sync: item read complete index=\(index + 1, privacy: .public) of=\(sourceURLs.count, privacy: .public) filename=\(url.lastPathComponent, privacy: .public) bytes=\(data.count, privacy: .public) duration=\(Date().timeIntervalSince(itemStart), privacy: .public)")
								return PreparedSQLiteObject(
									index: index,
									filename: url.lastPathComponent,
									pendingObject: SQLiteObjectStore.PendingObject(
										objectData: data,
										originalURL: url,
										contentHash: contentHash,
										contentTypeIdentifier: contentType,
										thumbnailData: thumbnailData
									)
								)
							} catch is CancellationError {
								logger.log("sqlite sync: item cancelled index=\(index + 1, privacy: .public) of=\(sourceURLs.count, privacy: .public) filename=\(url.lastPathComponent, privacy: .public)")
								return nil
							} catch {
								logger.error("sqlite sync: item read failed index=\(index + 1, privacy: .public) of=\(sourceURLs.count, privacy: .public) url=\(url.path, privacy: .public) duration=\(Date().timeIntervalSince(itemStart), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
								return nil
							}
						}
					}

					var prepared: [PreparedSQLiteObject] = []
					for await object in group {
						if let object {
							prepared.append(object)
						}
					}
					return prepared.sorted { $0.index < $1.index }
				}

				let chunkFailedCount = chunk.count - preparedObjects.count
				failedCount += chunkFailedCount
				if !preparedObjects.isEmpty {
					do {
						let writeStart = Date()
						let pendingObjects = preparedObjects.map(\.pendingObject)
						logger.log("sqlite sync: chunk write begin range=\(chunkStart + 1, privacy: .public)-\(chunkEnd, privacy: .public) prepared=\(pendingObjects.count, privacy: .public)")
						let writtenCount = try await SQLiteObjectStore.shared.storeObjectBatchThrowing(pendingObjects, storeName: targetStoreName)
						storedCount += writtenCount
						completedCount += writtenCount
						if firstStoredFilename == nil {
							firstStoredFilename = preparedObjects.first?.filename
						}
						let writeFailedCount = max(0, preparedObjects.count - writtenCount)
						failedCount += writeFailedCount
						completedCount += writeFailedCount
						logger.log("sqlite sync: chunk write complete range=\(chunkStart + 1, privacy: .public)-\(chunkEnd, privacy: .public) written=\(writtenCount, privacy: .public) writeFailed=\(writeFailedCount, privacy: .public) duration=\(Date().timeIntervalSince(writeStart), privacy: .public)")
					} catch {
						failedCount += preparedObjects.count
						completedCount += preparedObjects.count
						logger.error("sqlite sync: chunk write failed range=\(chunkStart + 1, privacy: .public)-\(chunkEnd, privacy: .public) prepared=\(preparedObjects.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
					}
				}
				completedCount += chunkFailedCount
				let processedCount = completedCount + cancelledBeforeStartCount
				logger.log("sqlite sync: progress processed=\(processedCount, privacy: .public) of=\(sourceURLs.count, privacy: .public) stored=\(storedCount, privacy: .public) failed=\(failedCount, privacy: .public) skipped=\(cancelledBeforeStartCount, privacy: .public) chunkDuration=\(Date().timeIntervalSince(chunkStartDate), privacy: .public) elapsed=\(Date().timeIntervalSince(syncStart), privacy: .public)")
				await MainActor.run {
					vaultProgressCompleted = processedCount
					vaultProgressTotal = sourceURLs.count
				}
			}
			let wasCancelled = Task.isCancelled
			let finalFailedCount = failedCount
			let finalStoredCount = storedCount
			let finalProcessedCount = completedCount
			let finalSkippedCount = cancelledBeforeStartCount
			let finalFocusFilename = finalStoredCount == 1 ? firstStoredFilename : nil
			logger.log("sqlite sync: complete database=\(databaseFilename, privacy: .public) requested=\(sourceURLs.count, privacy: .public) processed=\(finalProcessedCount, privacy: .public) stored=\(finalStoredCount, privacy: .public) failed=\(finalFailedCount, privacy: .public) skipped=\(finalSkippedCount, privacy: .public) cancelled=\(wasCancelled, privacy: .public) duration=\(Date().timeIntervalSince(syncStart), privacy: .public)")
			await MainActor.run {
				isVaultWorking = false
				vaultStoreTask = nil
				vaultAlertMessage = sqliteSyncSummary(
					stored: finalStoredCount,
					processed: finalProcessedCount,
					requested: sourceURLs.count,
					failed: finalFailedCount,
					skipped: finalSkippedCount,
					cancelled: wasCancelled,
					databaseFilename: databaseFilename
				)
				showVaultAlert = true
				if finalStoredCount > 0 {
					if isSQLiteObjectStoreView && activeSQLiteStoreName == targetStoreName {
						refreshThumbnails(focusFilename: finalFocusFilename)
					}
					NotificationCenter.default.post(
						name: .sqliteObjectStoreDidChange,
						object: tabID,
						userInfo: ["storeName": targetStoreName]
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

	private nonisolated static func sqliteThumbnailDataForSyncSource(_ url: URL) async -> Data? {
		await SQLiteObjectStore.shared.resolvedThumbnailData(for: url)
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
		cancelled: Bool,
		databaseFilename: String
	) -> String {
		var pieces: [String] = []
		let objectSuffix = requested == 1 ? "" : "s"
		if cancelled {
			pieces.append("Cancelled.")
		}
		pieces.append("Synced \(stored) of \(requested) object\(objectSuffix) to \(databaseFilename).")
		if processed != requested {
			pieces.append("Processed \(processed) before cancellation.")
		}
		if skipped > 0 {
			pieces.append("\(skipped) object\(skipped == 1 ? " was" : "s were") not started.")
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

	private func openSQLiteObjectStore(fileURL: URL) {
		Task {
			do {
				try await SQLiteObjectStore.shared.setDatabaseFile(fileURL)
				await MainActor.run {
					activeSQLiteStoreName = SQLiteObjectStore.configuredStoreName
				}
				await MainActor.run {
					openWindow(id: "sqlite-store", value: fileURL.lastPathComponent)
				}
			} catch {
				await MainActor.run {
					vaultAlertMessage = "Could not open SQLite store: \(error.localizedDescription)"
					showVaultAlert = true
				}
			}
		}
	}

	private func openSQLiteObjectStore(named storeName: String? = nil) {
		var storeNameForOpen = SQLiteObjectStore.configuredStoreName
		if let storeName {
			let trimmed = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
			if !trimmed.isEmpty {
				UserDefaults.standard.set(trimmed, forKey: SQLiteObjectStore.storeNameKey)
				let requestedFilename = SQLiteObjectStore.databaseFilename(forStoreName: trimmed)
				if let savedPath = UserDefaults.standard.string(forKey: SQLiteObjectStore.databasePathKey),
				   URL(fileURLWithPath: savedPath).lastPathComponent != requestedFilename {
					UserDefaults.standard.removeObject(forKey: SQLiteObjectStore.databaseBookmarkKey)
					UserDefaults.standard.removeObject(forKey: SQLiteObjectStore.databasePathKey)
				}
				storeNameForOpen = trimmed
			}
		}
		guard SQLiteObjectStore.configuredDirectoryPath != nil else {
			vaultAlertMessage = "Choose a SQLite store file before opening it."
			showVaultAlert = true
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

		let task = Task.detached(priority: .userInitiated) {
			do {
				logger.log("sqlite ui: open begin filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeNameForOpen), privacy: .public)")
				let urls = try await SQLiteObjectStore.shared.loadObjectWorkingFiles(storeName: storeNameForOpen) { completed, total, batch in
					await MainActor.run {
						if !batch.isEmpty {
							let batchPhotos = batch.map { PhotoItem(url: $0) }
							library.photos.append(contentsOf: batchPhotos)
							displayedPhotos.append(contentsOf: batchPhotos)
							logger.log("sqlite ui: progress batch=\(batch.count, privacy: .public) completed=\(completed, privacy: .public) total=\(total, privacy: .public) displayed=\(displayedPhotos.count, privacy: .public)")
						}
						vaultProgressCompleted = completed
						vaultProgressTotal = total
						lastRefreshDate = Date()
						forceThumbnailLoading = false
					}
				}
				await MainActor.run {
					let duration = Date().timeIntervalSince(sqliteOpenStart)
					library.folderURL = nil
					activeSQLiteStoreName = storeNameForOpen
					activeFolderNames = ["\(storeNameForOpen) (SQLite)"]
					isVaultWorking = false
					vaultStoreTask = nil
					sqliteLoadStartDate = nil
					sqliteLastLoadDuration = duration
					vaultProgressCompleted = urls.count
					vaultProgressTotal = urls.count
					lastRefreshDate = Date()
					forceThumbnailLoading = false
					scheduleSort()
					logger.log("sqlite ui: open complete filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeNameForOpen), privacy: .public) objects=\(urls.count, privacy: .public) duration=\(duration, privacy: .public)")
				}
				Task.detached(priority: .utility) {
					do {
						let thumbnailStart = Date()
						logger.log("sqlite ui: background thumbnail hydration begin filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeNameForOpen), privacy: .public)")
						let count = try await SQLiteObjectStore.shared.hydrateStoredThumbnailsForLoadedObjects { decoded, total in
							await MainActor.run {
								if isSQLiteObjectStoreView && activeSQLiteStoreName == storeNameForOpen && decoded > 0 {
									refreshToken = UUID()
									logger.log("sqlite ui: background thumbnail hydration progress filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeNameForOpen), privacy: .public) decoded=\(decoded, privacy: .public) total=\(total, privacy: .public)")
								}
							}
						}
						await MainActor.run {
							let thumbnailDuration = Date().timeIntervalSince(thumbnailStart)
							if isSQLiteObjectStoreView && activeSQLiteStoreName == storeNameForOpen {
								sqliteLastThumbnailLoadDuration = thumbnailDuration
							}
							logger.log("sqlite ui: background thumbnail hydration complete filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeNameForOpen), privacy: .public) thumbnails=\(count, privacy: .public) duration=\(thumbnailDuration, privacy: .public)")
						}
					} catch {
						logger.error("sqlite ui: background thumbnail hydration failed filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeNameForOpen), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
					}
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
		bookmarkURLs = resolved
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
					openWindow(id: "sqlite-store", value: url.lastPathComponent)
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
		if isSQLiteObjectStoreView {
			let storeName = activeSQLiteStoreName ?? SQLiteObjectStore.configuredStoreName
			vaultStoreTask?.cancel()
			vaultStoreTask = nil
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
			await PhotoVault.shared.lock()
			await refreshVaultStatus()
			await MainActor.run {
				library.photos = []
				displayedPhotos = []
				library.folderURL = nil
				activeFolderNames = []
				clearSelection()
				forceThumbnailLoading = false
				refreshToken = UUID()
				isVaultWorking = false
			}
		}
	}

	private func closeCurrentGalleryTab() {
		let window = hostingWindow ?? NSApp.keyWindow
		DispatchQueue.main.async {
			window?.performClose(nil)
		}
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
			Task.detached(priority: .userInitiated) {
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

							// Warm thumbnails for this batch.
												let warm = batchCopy
												Task.detached(priority: .utility) {
													for item in warm {
														if Task.isCancelled { break }
														do {
															let img = try await ThumbnailGenerator.shared.generateThumbnail(for: item.url)
															await ThumbnailCache.shared.store(img, for: item.url)
														} catch { }
													}
												}
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
		Task {
			let clear = Task.detached(priority: .userInitiated) {
				await ThumbnailCache.shared.clear()
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
			forceThumbnailLoading = false
			library.scan(folder: refreshFolderURL)
			lastRefreshDuration = Date().timeIntervalSince(start)
			lastRefreshDate = Date()
			isRefreshing = false
			refreshToken = UUID()
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
			vaultStoreTask?.cancel()
		}
		do {
			logger.log("sqlite ui: refresh begin filename=\(databaseFilename, privacy: .public) forceThumbnailReload=\(forceThumbnailReload, privacy: .public)")
			let urls = try await SQLiteObjectStore.shared.loadObjectWorkingFiles(storeName: storeName) { completed, total, batch in
				await MainActor.run {
					if !batch.isEmpty {
						let batchPhotos = batch.map { PhotoItem(url: $0) }
						library.photos.append(contentsOf: batchPhotos)
						displayedPhotos.append(contentsOf: batchPhotos)
						logger.log("sqlite ui: refresh progress batch=\(batch.count, privacy: .public) completed=\(completed, privacy: .public) total=\(total, privacy: .public) displayed=\(displayedPhotos.count, privacy: .public)")
					}
					vaultProgressCompleted = completed
					vaultProgressTotal = total
					lastRefreshDate = Date()
					forceThumbnailLoading = forceThumbnailReload
				}
			}
			await MainActor.run {
				let duration = Date().timeIntervalSince(start)
				library.folderURL = nil
				activeSQLiteStoreName = storeName
				activeFolderNames = ["\(storeName) (SQLite)"]
				isVaultWorking = false
				vaultStoreTask = nil
				sqliteLoadStartDate = nil
				sqliteLastLoadDuration = duration
				vaultProgressCompleted = urls.count
				vaultProgressTotal = urls.count
				lastRefreshDate = Date()
				lastRefreshDuration = duration
				forceThumbnailLoading = forceThumbnailReload
				if forceThumbnailReload {
					refreshToken = UUID()
				}
				if let focusFilename {
					pendingSQLiteFocusFilename = focusFilename
				} else {
					clearSelection()
				}
				scheduleSort()
				focusPendingSQLiteObjectIfPossible()
				logger.log("sqlite ui: refresh complete filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeName), privacy: .public) objects=\(urls.count, privacy: .public) duration=\(duration, privacy: .public)")
			}
			if !forceThumbnailReload {
				Task.detached(priority: .utility) {
					do {
						let thumbnailStart = Date()
						logger.log("sqlite ui: background thumbnail hydration begin filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeName), privacy: .public)")
						let count = try await SQLiteObjectStore.shared.hydrateStoredThumbnailsForLoadedObjects { decoded, total in
							await MainActor.run {
								if isSQLiteObjectStoreView && activeSQLiteStoreName == storeName && decoded > 0 {
									refreshToken = UUID()
									logger.log("sqlite ui: background thumbnail hydration progress filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeName), privacy: .public) decoded=\(decoded, privacy: .public) total=\(total, privacy: .public)")
								}
							}
						}
						await MainActor.run {
							let thumbnailDuration = Date().timeIntervalSince(thumbnailStart)
							if isSQLiteObjectStoreView && activeSQLiteStoreName == storeName {
								sqliteLastThumbnailLoadDuration = thumbnailDuration
							}
							logger.log("sqlite ui: background thumbnail hydration complete filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeName), privacy: .public) thumbnails=\(count, privacy: .public) duration=\(thumbnailDuration, privacy: .public)")
						}
					} catch {
						logger.error("sqlite ui: background thumbnail hydration failed filename=\(SQLiteObjectStore.databaseFilename(forStoreName: storeName), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
					}
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
		Task.detached(priority: .utility) {
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
		Task.detached(priority: .utility) {
			var deletedCount = 0
			var failureMessage: String? = nil
			do {
				deletedCount = try await SQLiteObjectStore.shared.deleteObjects(at: urls)
			} catch {
				failureMessage = error.localizedDescription
				await MainActor.run {
					self.logger.error("performSQLiteDelete: delete failed: \(error.localizedDescription, privacy: .public)")
				}
			}
			let fm = FileManager.default
			for u in urls {
				try? fm.removeItem(at: u)
			}
			await MainActor.run {
				let succeeded = failureMessage == nil
				for u in urls {
					deleteResults[u] = succeeded
					deleteErrorMessages[u] = failureMessage
					deleteProgressCount += 1
					if succeeded {
						selectedItems.remove(u)
						library.photos.removeAll { $0.url == u }
						displayedPhotos.removeAll { $0.url == u }
					}
				}
				var detailLines: [String] = []
				let sorted = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
				let successCount = succeeded ? urls.count : 0
				let failureCount = succeeded ? 0 : urls.count
				for u in sorted {
					if succeeded {
						detailLines.append("[OK] \(u.lastPathComponent)")
					} else {
						detailLines.append("[FAIL] \(u.lastPathComponent): \(failureMessage ?? "Unknown delete error.")")
					}
				}
				deleteHadFailures = !succeeded
				deleteErrorSummary = (["Requested: \(urls.count), Removed from SQLite: \(deletedCount), Failed: \(failureCount)"] + detailLines).joined(separator: "\n")
				_ = successCount
				showDeleteErrorSummary = true
				deletingURLs = []
				isDeleting = false
				if deletedCount > 0 {
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
		let mode = SortMode(rawValue: sortModeRaw) ?? .alphaAsc
		let filter = searchText

		// Quick-pass: update displayedPhotos with a filename-only match
		// performed on the main actor so typing feels snappy.
		if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			switch mode {
			case .alphaAsc:
				displayedPhotos = photos.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
			case .alphaDesc:
				displayedPhotos = photos.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedDescending }
			case .fileDate, .imageDate:
				displayedPhotos = photos
			}
		} else {
			// Attempt to compile regex for filename-only check; if invalid,
			// fall back to case-insensitive substring match.
			if let regex = try? NSRegularExpression(pattern: filter, options: [.caseInsensitive]) {
				let quick = photos.filter { p in
					let filename = p.url.lastPathComponent
					let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
					return regex.firstMatch(in: filename, options: [], range: range) != nil
				}
				// Publish quick results immediately.
				displayedPhotos = quick
			} else {
				let needle = filter.lowercased()
				displayedPhotos = photos.filter { $0.url.lastPathComponent.lowercased().contains(needle) }
			}
		}

		// Debounced full filter/sort task (metadata-aware). Small sleep
		// reduces churn while typing.
		sortTask = Task.detached(priority: .userInitiated) {
			// Short debounce window to avoid firing for every keystroke.
			try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
			if Task.isCancelled { return }
			let sorted = await Self.computeSorted(photos: photos, mode: mode, filter: filter)
			if Task.isCancelled { return }
			await MainActor.run {
				displayedPhotos = sorted
			}
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

	private static func computeSorted(photos: [PhotoItem], mode: SortMode, filter: String) async -> [PhotoItem] {
		// If no filter provided, just sort normally.
		let filtered: [PhotoItem]
		if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			filtered = photos
		} else {
			// Attempt to compile the filter as a regular expression. If
			// compilation fails, fall back to a case-insensitive substring
			// match on filename only.
			if let regex = try? NSRegularExpression(pattern: filter, options: [.caseInsensitive]) {
				var matches: [PhotoItem] = []
				for p in photos {
					// First test filename quickly without touching image data.
					let filename = p.url.lastPathComponent
					let fnameRange = NSRange(filename.startIndex..<filename.endIndex, in: filename)
					if regex.firstMatch(in: filename, options: [], range: fnameRange) != nil {
						matches.append(p)
						continue
					}
					// Filename didn't match; only now read lightweight image
					// properties for metadata matching. This avoids expensive
					// CGImageSource work for the majority of items.
					let fullCandidate = await MetadataCache.shared.candidateString(for: p.url)
					let range = NSRange(fullCandidate.startIndex..<fullCandidate.endIndex, in: fullCandidate)
					if regex.firstMatch(in: fullCandidate, options: [], range: range) != nil {
						matches.append(p)
					}
				}
				filtered = matches
			} else {
				// Invalid regex: fallback to case-insensitive substring match
				// against filename _and_ embedded metadata. Previously we only
				// matched the filename here which made invalid-regex cases
				// miss metadata. Use the MetadataCache to obtain the cached
				// candidate string (filename + metadata) for each item.
				let needle = filter.lowercased()
				var matches: [PhotoItem] = []
				for p in photos {
					let filename = p.url.lastPathComponent.lowercased()
					if filename.contains(needle) { matches.append(p); continue }
					// Check cached candidate string (may perform a lightweight
					// ImageIO read if not present in the cache).
					let full = await MetadataCache.shared.candidateString(for: p.url)
									if full.lowercased().contains(needle) { matches.append(p) }
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
	private static func writeKeywords(to url: URL, keywords: [String]) async -> Bool {
		let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
		// Ensure security-scoped access if available
		_ = await Self.ensureSecurityScopedAccess(for: url)
		// Read source
		guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
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
		iptc[kCGImagePropertyIPTCKeywords] = Self.mergedKeywords(existingKeywords, keywords) as CFArray
		metadata[kCGImagePropertyIPTCDictionary] = iptc as CFDictionary

		// Create a temporary file next to the original so moves are atomic
		// and don't fail across volumes. Use a hidden filename to avoid
		// exposing partial artifacts.
		let fm = FileManager.default
		let dir = url.deletingLastPathComponent()
		let tempFilename = ".pvtmp-\(UUID().uuidString)"
		let tempURL = dir.appendingPathComponent(tempFilename).appendingPathExtension(url.pathExtension)

		guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else {
			logger.error("writeKeywords: cannot create CGImageDestination")
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "writeKeywords", "message": "CGImageDestinationCreateWithURL failed when attempting to write embedded metadata."])
			// Embedded write failed; do not fall back to sidecar per policy.
			return false
		}

		CGImageDestinationAddImageFromSource(dest, src, 0, metadata as CFDictionary)
		if !CGImageDestinationFinalize(dest) {
			logger.error("writeKeywords: CGImageDestinationFinalize failed")
			try? fm.removeItem(at: tempURL)
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "writeKeywords", "message": "CGImageDestinationFinalize failed when attempting to write embedded metadata."])
			// Finalize failed; do not write sidecar – report failure so caller
			// can surface an error or request additional permissions.
			return false
		}

		do {
			// Replace original file with temp file
			let backupURL = url.appendingPathExtension("backup")
			if fm.fileExists(atPath: backupURL.path) { try? fm.removeItem(at: backupURL) }
			try fm.moveItem(at: url, to: backupURL)
			try fm.moveItem(at: tempURL, to: url)
			try? fm.removeItem(at: backupURL)
			await PhotoVault.shared.reencryptWorkingCopyIfNeeded(url)
			if SQLiteObjectStore.isWorkingCopyURL(url) {
				try await SQLiteObjectStore.shared.storeObjectFile(at: url)
			}
			return true
		} catch {
			logger.error("writeKeywords: failed to replace original file: \(error.localizedDescription, privacy: .public)")
			// Attempt to cleanup
			try? fm.removeItem(at: tempURL)
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "writeKeywords", "message": "Failed to replace original file after writing temp file: \(error.localizedDescription)"])
			// Do not fall back to sidecar; surface failure to caller.
			return false
		}
	}

	private static func keywordStrings(from value: Any?) -> [String] {
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

	private static func mergedKeywords(_ existing: [String], _ appended: [String]) -> [String] {
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
					await MainActor.run {
						logger.log("launch folder restore: source=saved-window-state storage=cache folder=\(folder.path, privacy: .public) cachedFiles=\(urls.count, privacy: .public) uniqueFiles=\(deduped.count, privacy: .public)")
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
						// Warm thumbnails for the restored batch in background so
						// the UI can display images quickly without waiting for
						// on-demand generation. The ThumbnailGenerator itself
						// limits concurrency so this is safe to run per-batch.
						Task.detached(priority: .utility) {
							for item in slice {
								if Task.isCancelled { break }
								do {
									let img = try await ThumbnailGenerator.shared.generateThumbnail(for: item.url)
									await ThumbnailCache.shared.store(img, for: item.url)
								} catch {
									// Ignore individual thumbnail failures — it's
									// acceptable for some items to fail to generate.
								}
							}
						}
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
