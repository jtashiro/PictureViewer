//
//  ContentView.swift
//  PictureViewer
//
//  Created by John Tashiro on 6/3/26.
//

import SwiftUI
import AppKit
import ImageIO
import CryptoKit
import os

extension Notification.Name {
	static let embedWriteFailed = Notification.Name("com.example.PictureViewer.embedWriteFailed")
}

struct ContentView: View {
	@State private var library = PhotoLibrary()
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

	/// Restore a persisted security-scoped bookmark (if present) and start
	/// accessing the resource so the app can write into the folder while
	/// sandboxed. This is safe to call at startup.
	private static func restoreFolderBookmarkIfNeeded(library: PhotoLibrary, logger: Logger) async {
		let fm = FileManager.default

		// Prefer multi-bookmark list if available.
		if let arr = UserDefaults.standard.array(forKey: Self.kLastFolderBookmarks) as? [Data], !arr.isEmpty {
			// Resolve all bookmarks and attempt to restore cached snapshots
			// for each. Combine and dedupe the restored file list before
			// publishing to the UI.
			var resolvedFolders: [URL] = []
			for bm in arr {
				var stale = false
				do {
					let url = try URL(resolvingBookmarkData: bm, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
					if stale { logger.log("restoreFolderBookmarkIfNeeded: bookmark is stale for \(url.path, privacy: .public)") }
					if url.startAccessingSecurityScopedResource() {
						logger.log("restoreFolderBookmarkIfNeeded: started security access for \(url.path, privacy: .public)")
						resolvedFolders.append(url)
						if !Self.activeSecurityScopedURLs.contains(url) { Self.activeSecurityScopedURLs.append(url) }
					} else {
						logger.log("restoreFolderBookmarkIfNeeded: failed to start security access for \(url.path, privacy: .public)")
					}
				} catch {
					logger.error("restoreFolderBookmarkIfNeeded: failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
				}
			}

			guard !resolvedFolders.isEmpty else { return }

			// If a combined snapshot exists that matches these folders, prefer
			// restoring it as it provides a faster single-file restore path.
			if let (combinedURLs, combinedFolders) = PhotoLibrary.loadCombinedSnapshot() {
				let resolvedPaths = Set(resolvedFolders.map { $0.path })
				let combinedFolderPaths = Set(combinedFolders.map { $0.path })
				if combinedFolderPaths.isSubset(of: resolvedPaths) {
					// Use the combined snapshot directly
					await MainActor.run {
						library.photos = combinedURLs.map { PhotoItem(url: $0) }
						library.folderURL = resolvedFolders.first
						library.lastScanDate = Date()
					}
					// Also kick off per-folder reconciliation scans in background
					for folder in resolvedFolders {
						library.appendScan(folder: folder)
					}
					return
				}
			}

			Task.detached {
				var combined: [URL] = []
				var seen: Set<String> = []
				for folder in resolvedFolders {
					if let urls = PhotoLibrary.loadCachedSnapshot(for: folder) {
						for u in urls {
							let name = u.lastPathComponent.lowercased()
							if seen.insert(name).inserted { combined.append(u) }
						}
					}
				}

				if combined.isEmpty {
					// No snapshots available; publish primary folder only.
					await MainActor.run { library.folderURL = resolvedFolders.first }
					return
				}

				let batchSize = 256
				await MainActor.run { library.photos = []; library.folderURL = resolvedFolders.first }
				var idx = 0
				while idx < combined.count {
					let end = min(idx + batchSize, combined.count)
					let slice = combined[idx..<end].map { PhotoItem(url: $0) }
					await MainActor.run {
						library.photos.append(contentsOf: slice)
						library.lastScanDate = Date()
					}

					// Schedule face processing and warm thumbnails per-batch as before.
					let faceEnabled = UserDefaults.standard.bool(forKey: "enableFaceRecognition")
					if faceEnabled {
						Task.detached(priority: .utility) {
							await MainActor.run { logger.log("scheduling face processing for restoration batch of \(slice.count, privacy: .public) items") }
							for item in slice {
								if Task.isCancelled { break }
								_ = await FaceProcessor.shared.process(file: item.url)
							}
						}
					} else {
						await MainActor.run { logger.log("face processing for restoration skipped (enableFaceRecognition=false)") }
					}

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
					try? await Task.sleep(nanoseconds: 10_000_000)
				}

				// For multi-folder restores we do not automatically kick off a
				// full `library.scan(folder:)` because that API assumes a single
				// canonical folder and would clobber the combined view. Instead
				// start per-folder reconciliation scans that append discovered
				// items into the combined view. This allows us to reconcile on
				// disk changes without replacing the published list.
				for folder in resolvedFolders {
					library.appendScan(folder: folder)
				}
			}
			return
		}

		// Fallback to single-bookmark behavior for backward compatibility.
		guard let bm = UserDefaults.standard.data(forKey: Self.kLastFolderBookmark) else { return }
		var stale = false
		do {
			let url = try URL(resolvingBookmarkData: bm, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
			if stale { logger.log("restoreFolderBookmarkIfNeeded: bookmark is stale for \(url.path, privacy: .public)") }
			if url.startAccessingSecurityScopedResource() {
				logger.log("restoreFolderBookmarkIfNeeded: started security access for \(url.path, privacy: .public)")
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
						let batchSize = 256
						await MainActor.run { library.photos = [] }
						var idx = 0
						while idx < deduped.count {
							let end = min(idx + batchSize, deduped.count)
							let slice = deduped[idx..<end].map { PhotoItem(url: $0) }
							await MainActor.run {
								library.photos.append(contentsOf: slice)
								library.lastScanDate = Date()
							}
							// Schedule face processing for the restored batch so cached
							// thumbnails get analyzed even when we don't run a full
							// re-scan. FaceProcessor internally deduplicates/short-
							// circuits via the DB actor, so it's safe to call for
							// every restored item.
							let faceEnabled = UserDefaults.standard.bool(forKey: "enableFaceRecognition")
							if faceEnabled {
								Task.detached(priority: .utility) {
									await MainActor.run { logger.log("scheduling face processing for restoration batch of \(slice.count, privacy: .public) items") }
									for item in slice {
										if Task.isCancelled { break }
										_ = await FaceProcessor.shared.process(file: item.url)
									}
								}
							} else {
								await MainActor.run { logger.log("face processing for restoration skipped (enableFaceRecognition=false)") }
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
									if deferAtLaunchBackgroundWork {
										logger.log("At-launch scan deferred by deferAtLaunchBackgroundWork flag; skipping scan for folder=\(url.path, privacy: .public)")
									} else {
										library.scan(folder: url)
									}
								}
							}
						}
					} else {
						// No cached snapshot available; retain current behavior
						// of not auto-scanning at launch.
						await MainActor.run { library.folderURL = url }
					}
				}
			} else {
				logger.log("restoreFolderBookmarkIfNeeded: failed to start security access for \(url.path, privacy: .public)")
			}
		} catch {
			logger.error("restoreFolderBookmarkIfNeeded: failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
		}
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
			logger.log("repairMetadata: successfully repaired metadata for \(url.path, privacy: .public)")
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
			logger.log("writeSidecar: wrote sidecar for \(url.path, privacy: .public) -> \(scURL.path, privacy: .public)")
			return true
		} catch {
			// Clean up any temp file we may have created
			try? fm.removeItem(at: tempFile)
			logger.error("writeSidecar: adjacent write failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
					logger.log("writeSidecar: wrote app-support sidecar for \(url.path, privacy: .public) -> \(appSidecar.path, privacy: .public)")
					return true
				}
			} catch {
				logger.error("writeSidecar: app-support fallback failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
					if stale { logger.log("ensureSecurityScopedAccess: bookmark stale for \(resolved.path, privacy: .public)") }
					if resolved.startAccessingSecurityScopedResource() {
						logger.log("ensureSecurityScopedAccess: started security access for \(resolved.path, privacy: .public)")
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
			if stale { logger.log("ensureSecurityScopedAccess: bookmark stale for \(resolved.path, privacy: .public)") }
				if resolved.startAccessingSecurityScopedResource() {
					logger.log("ensureSecurityScopedAccess: started security access for \(resolved.path, privacy: .public)")
					if !Self.activeSecurityScopedURLs.contains(resolved) { Self.activeSecurityScopedURLs.append(resolved) }
					return url.path.hasPrefix(resolved.path)
				} else {
				logger.error("ensureSecurityScopedAccess: failed to start accessing security scoped resource for \(resolved.path, privacy: .public)")
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
		let accessOk = await Self.ensureSecurityScopedAccess(for: url)
		logger.log("rotateImageFile: security access for \(url.path, privacy: .public)=\(accessOk, privacy: .public)")

		guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
			logger.log("rotateImageFile: cannot create CGImageSource for \(url.path, privacy: .public)")
			return false
		}
		guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
			logger.log("rotateImageFile: cannot create CGImage for \(url.path, privacy: .public)")
			return false
		}

		let radians = Double(deg) * Double.pi / 180.0
		var destWidth = cg.width
		var destHeight = cg.height
		if deg == 90 || deg == 270 {
			destWidth = cg.height
			destHeight = cg.width
		}

		guard let colorSpace = cg.colorSpace else { logger.log("rotateImageFile: missing colorSpace for \(url.path, privacy: .public)"); return false }
		guard let ctx = CGContext(data: nil, width: destWidth, height: destHeight, bitsPerComponent: cg.bitsPerComponent, bytesPerRow: 0, space: colorSpace, bitmapInfo: cg.bitmapInfo.rawValue) else { logger.log("rotateImageFile: cannot create CGContext"); return false }

		ctx.translateBy(x: CGFloat(destWidth)/2.0, y: CGFloat(destHeight)/2.0)
		ctx.rotate(by: CGFloat(radians))
		ctx.translateBy(x: -CGFloat(cg.width)/2.0, y: -CGFloat(cg.height)/2.0)
		ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))

		guard let rotated = ctx.makeImage() else { logger.log("rotateImageFile: makeImage failed"); return false }

		let fm = FileManager.default
		let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
		let dir = url.deletingLastPathComponent()
		let tempURL = dir.appendingPathComponent(".pvtmp-\(UUID().uuidString)").appendingPathExtension(url.pathExtension)

		guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else {
			logger.error("rotateImageFile: cannot create destination for tempURL=\(tempURL.path, privacy: .public)")
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
			logger.error("rotateImageFile: finalize failed for \(tempURL.path, privacy: .public)")
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
			return true
		} catch {
			try? fm.removeItem(at: tempURL)
			logger.error("rotateImageFile: failed to replace original file \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "rotateImageFile", "message": "Failed to replace original file after writing temp file: \(error.localizedDescription)"])
			// Do not fall back to sidecar; surface failure.
			return false
		}
	}

	// Displayed (sorted) snapshot of photos. Computed in background when
	// the underlying library or the sort mode changes.
	@State private var displayedPhotos: [PhotoItem] = []
	@State private var sortTask: Task<Void, Never>? = nil
	@State private var refreshToken = UUID()
	@State private var searchText: String = ""
	@State private var isRefreshing = false
	@State private var selectionMode: Bool = false
	@State private var selectedItems: Set<URL> = []
	@State private var isEditingKeywords: Bool = false
	@State private var editKeywordsText: String = ""
	@State private var isApplyingKeywords: Bool = false
	@State private var editProgressCount: Int = 0
	@State private var editingResults: [URL: Bool?] = [:]
	@State private var showDeleteConfirmation: Bool = false
	@State private var isDeleting: Bool = false
	@State private var deleteProgressCount: Int = 0
	@State private var deleteResults: [URL: Bool?] = [:]
	@State private var deleteErrorMessages: [URL: String?] = [:]
	@State private var showDeleteErrorSummary: Bool = false
	@State private var deleteErrorSummary: String = ""
	@State private var deletingURLs: [URL] = []
	@State private var selectedRotations: [URL: Int] = [:]
	@State private var isShowingRotationSheet: Bool = false
	@State private var isApplyingRotations: Bool = false
	@State private var rotProgressCount: Int = 0
	@State private var rotationResults: [URL: Bool?] = [:]
	// Use a dedicated window for People; open via `openWindow(id:value:)`
	@State private var lastRefreshDuration: TimeInterval?
	@State private var lastRefreshDate: Date?
	@AppStorage("saveOpenWindows") private var saveOpenWindows: Bool = false
	@Environment(\.openWindow) private var openWindow
	@AppStorage("disableAutoRestoreWindows") private var disableAutoRestoreWindows: Bool = true
	@AppStorage("deferAtLaunchBackgroundWork") private var deferAtLaunchBackgroundWork: Bool = true

	private let logger = Logger(subsystem: "com.example.PictureViewer", category: "ui")
	// Persisted security-scoped bookmark keys
	static let kLastFolderBookmark = "lastFolderBookmark"
	// New key that holds an array of bookmarks when the user selects
	// multiple folders. Kept for backward compatibility with the single
	// bookmark key above.
	static let kLastFolderBookmarks = "lastFolderBookmarks"
	// Active resolved security-scoped URLs (kept open for the app lifetime)
	private static var activeSecurityScopedURLs: [URL] = []
	@State private var folderSecurityURL: URL? = nil // resolved security-scoped URL (if any)
	@State private var repairResultMessage: String? = nil
	@State private var showRepairResult: Bool = false
	@State private var showEmbedWriteAlert: Bool = false
	@State private var embedFailMessage: String? = nil
	@State private var embedFailURL: URL? = nil

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				statusBar
					.fixedSize(horizontal: false, vertical: true)
				Divider()
				contentBody
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			.navigationTitle(library.folderURL?.lastPathComponent ?? "Picture Viewer")
			.toolbar { toolbarItems }
		}
		.frame(minWidth: 760, minHeight: 540)
		// Attach a WindowAccessor so we can set window-level defaults like
		// preferring tabs for this app's windows.
		.background(WindowAccessor { window in
			// Prefer tabbed windows for the main content window as well.
			window?.tabbingMode = .preferred
		})
		.onAppear {
			// Initialize displayed photos immediately so the UI shows
			// something, but defer heavier startup work (sorting and
			// session restoration) briefly to avoid blocking the main
			// thread right after authentication. This helps prevent a
			// startup "beach ball" when the system is busy handling the
			// auth transition.
			displayedPhotos = library.photos
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
					await Self.restoreFolderBookmarkIfNeeded(library: library, logger: self.logger)
					await MainActor.run {
						restoreSavedWindowsIfNeeded()
					}
				}
			}
		}
		.onChange(of: library.photos) { _ in scheduleSort() }
		.onChange(of: sortModeRaw) { _ in scheduleSort() }
		.onChange(of: searchText) { _ in scheduleSort() }
		.sheet(isPresented: $isEditingKeywords) {
			VStack(spacing: 12) {
				Text("Edit Keywords for \(selectedItems.count) photos")
					.font(.headline)
				TextField("Keywords (comma-separated)", text: $editKeywordsText)
					.textFieldStyle(.roundedBorder)
					.padding(.horizontal)

				// Results list + progress
				let urls = Array(selectedItems)
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
							let urls = Array(selectedItems)
							editingResults = Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as Bool?) })
							editProgressCount = 0
							isApplyingKeywords = true
							// Run writes sequentially in background so disk I/O is moderated.
							Task.detached(priority: .utility) {
								for u in urls {
									if Task.isCancelled { break }
									let ok = await Self.writeKeywords(to: u, keywords: parts)
									await MainActor.run {
										editingResults[u] = ok
										editProgressCount += 1
										logger.log("writeKeywords: url=\(u.path, privacy: .public) success=\(ok, privacy: .public)")
									}
								}
								await MainActor.run {
									// Remove successful items from selection to indicate completion
									for (u, res) in editingResults {
										if res == true { selectedItems.remove(u) }
									}
									isApplyingKeywords = false
								}
							}
						}
						.disabled(editKeywordsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedItems.isEmpty)
					}
				}
				.padding(.horizontal)
			}
			.padding()
			.frame(minWidth: 420, minHeight: 200)
		}
		.alert(isPresented: $showDeleteConfirmation) {
			Alert(
				title: Text("Delete selected files?"),
				message: Text("This will move the selected files to the Trash. You can recover them from the Trash if needed."),
				primaryButton: .destructive(Text("Delete")) {
					let urls = Array(selectedItems)
					performDelete(urls: urls)
				},
				secondaryButton: .cancel()
			)
		}
		.alert(isPresented: $showDeleteErrorSummary) {
			// Offer a retry for failed deletions
			Alert(
				title: Text("Some deletions failed"),
				message: Text(deleteErrorSummary),
				primaryButton: .default(Text("Retry")) {
					// Collect URLs that failed and retry
					let failed = deleteResults.compactMap { (k, v) -> URL? in
						if let ok = v, ok == false { return k }
						return nil
					}
					if !failed.isEmpty {
						performDelete(urls: failed)
					}
				},
				secondaryButton: .cancel()
			)
		}
		.alert(isPresented: $showRepairResult) {
			Alert(title: Text("Repair Metadata"), message: Text(repairResultMessage ?? ""), dismissButton: .default(Text("OK")))
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
						if !failed.isEmpty { performDelete(urls: failed) }
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
				Text("Apply Rotations to \(selectedItems.count) photos")
					.font(.headline)

				let urls = Array(selectedItems)
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
							let urls = Array(selectedItems)
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
											selectedItems.remove(u)
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
						.disabled(selectedItems.isEmpty)
					}
				}
				.padding(.horizontal)
			}
			.padding()
			.frame(minWidth: 420, minHeight: 200)
		}
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
		if library.isScanning || isRefreshing {
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
				Text("\(library.photos.count.formatted()) found")
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
		} else if let date = library.lastScanDate {
			HStack(spacing: 6) {
				Text("\(library.photos.count.formatted()) photo\(library.photos.count == 1 ? "" : "s")")
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
		if library.folderURL == nil {
			emptyState
		} else if library.isScanning && library.photos.isEmpty {
			VStack(spacing: 12) {
				ProgressView()
				Text("Scanning \(library.folderURL?.lastPathComponent ?? "")…")
					.foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else if library.photos.isEmpty {
			ContentUnavailableView(
				"No Photos Found",
				systemImage: "photo.on.rectangle.angled",
				description: Text("This folder doesn't contain any supported image files.")
			)
		} else {
			photoGrid
		}
	}

	private var emptyState: some View {
		ContentUnavailableView {
			Label("No Folder Selected", systemImage: "folder.badge.questionmark")
		} description: {
			Text("Pick a folder to recursively browse photos.")
		} actions: {
			Button("Choose Folder…") { chooseFolder() }
				.buttonStyle(.borderedProminent)
		}
	}

	private var photoGrid: some View {
		ScrollView {
			LazyVGrid(
				columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize * 1.4), spacing: 10)],
				spacing: 10
			) {
				ForEach(displayedPhotos) { photo in
					Button {
						if selectionMode {
							// Toggle selection
							if selectedItems.contains(photo.url) {
								selectedItems.remove(photo.url)
							} else {
								selectedItems.insert(photo.url)
							}
						} else {
							openWindow(id: "photo-viewer", value: photo.url)
						}
					} label: {
						ZStack(alignment: .topTrailing) {
							VStack(spacing: 4) {
								ThumbnailView(
									url: photo.url,
									size: thumbnailSize,
									refreshToken: refreshToken
								)
								// Filename and keywords are rendered by ThumbnailView now.
							}
							if selectionMode {
								// Selection badge
								Group {
									if selectedItems.contains(photo.url) {
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
					}
					.buttonStyle(.plain)
					.contextMenu {
						Button("Show in Finder") {
							NSWorkspace.shared.activateFileViewerSelecting([photo.url])
						}
						Button("Open with Default App") {
							NSWorkspace.shared.open(photo.url)
						}
						Button("Repair metadata") {
							Task.detached(priority: .utility) {
								let (ok, msg) = await Self.repairMetadata(for: photo.url)
								await MainActor.run {
									if ok {
										// Force a thumbnail refresh and log
										refreshToken = UUID()
										logger.log("Repair metadata succeeded for \(photo.url.path, privacy: .public)")
										repairResultMessage = "Repair succeeded for \(photo.url.lastPathComponent)"
									} else {
										logger.error("Repair metadata failed for \(photo.url.path, privacy: .public): \(msg ?? "")")
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
	}

	@ToolbarContentBuilder
	private var toolbarItems: some ToolbarContent {
		ToolbarItem(placement: .primaryAction) {
			Button {
				chooseFolder()
			} label: {
				Label("Choose Folder", systemImage: "folder")
			}
			.help("Choose a folder to browse")
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
				// Edit / selection controls
				Button {
					selectionMode.toggle()
					if !selectionMode { selectedItems.removeAll() }
				} label: {
					Text(selectionMode ? "Done" : "Edit")
				}
				.help("Select multiple thumbnails for bulk operations")
				if selectionMode {
					Button(action: {
						// Show bulk edit keywords sheet
						isEditingKeywords = true
						editKeywordsText = ""
					}) {
						Text("Edit Keywords")
					}
					.disabled(selectedItems.isEmpty)
					.help("Edit keyword metadata for selected photos")
					Button(action: {
						// Rotate selected thumbnails left
						for u in selectedItems {
							let cur = selectedRotations[u] ?? 0
							let next = (cur - 90) % 360
							selectedRotations[u] = next < 0 ? next + 360 : next
						}
					}) {
						Image(systemName: "rotate.left")
					}
					.disabled(selectedItems.isEmpty)
					.help("Rotate selection left 90° (preview)")
					Button(action: {
						// Rotate selected thumbnails right
						for u in selectedItems {
							let cur = selectedRotations[u] ?? 0
							selectedRotations[u] = (cur + 90) % 360
						}
					}) {
						Image(systemName: "rotate.right")
					}
					.disabled(selectedItems.isEmpty)
					.help("Rotate selection right 90° (preview)")
					Button(action: {
						// Trigger delete confirmation
						showDeleteConfirmation = true
					}) {
						Image(systemName: "trash")
					}
					.disabled(selectedItems.isEmpty)
					.help("Move selected files to Trash")
					Button(action: {
						// Show rotation apply sheet
						isShowingRotationSheet = true
					}) {
						Text("Apply Rotations")
					}
					.disabled(selectedItems.isEmpty || selectedRotations.filter { $0.value % 360 != 0 }.isEmpty)
					.help("Persist rotations for selected files")
					Button(action: {
						// Select all displayed
						selectedItems = Set(displayedPhotos.map { $0.url })
					}) {
						Text("Select All")
					}
					.help("Select all displayed thumbnails")
					Button(action: { selectedItems.removeAll() }) {
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

	private func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = true
		panel.message = "Choose one or more folders containing photos"
		panel.prompt = "Choose"
		if panel.runModal() == .OK {
			let urls = panel.urls
			guard !urls.isEmpty else { return }

			// Create bookmarks for each selected folder and persist them as
			// an array so we can restore multiple folders at next launch.
			var bookmarkDatas: [Data] = []
			for url in urls {
				do {
					let bm = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
					bookmarkDatas.append(bm)
				} catch {
					logger.error("chooseFolder: failed to create bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
				}
			}
			if !bookmarkDatas.isEmpty {
				UserDefaults.standard.set(bookmarkDatas, forKey: Self.kLastFolderBookmarks)
				// Maintain legacy single bookmark for compatibility (first one).
				if let first = bookmarkDatas.first {
					UserDefaults.standard.set(first, forKey: Self.kLastFolderBookmark)
				}
			}

			// Try to start security access for each folder. Keep the first as
			// the displayed folder (used for UI title) and as the primary
			// security-scoped URL.
			for (i, url) in urls.enumerated() {
					if url.startAccessingSecurityScopedResource() {
						if i == 0 { folderSecurityURL = url }
						if !Self.activeSecurityScopedURLs.contains(url) { Self.activeSecurityScopedURLs.append(url) }
						logger.log("chooseFolder: started security access for \(url.path, privacy: .public)")
					} else {
					logger.log("chooseFolder: failed to start security access for \(url.path, privacy: .public)")
				}
			}

			// If only one folder selected, reuse the existing scan API which
			// handles state, telemetry and persistence. For multiple folders
			// we perform per-folder scans in the background and append the
			// results into the library so the UI shows a combined view.
			if urls.count == 1, let url = urls.first {
				library.scan(folder: url)
				return
			}

			// Multi-folder scan: clear existing photos and iteratively append
			// batches discovered from each folder. Run as a background task
			// and publish small batches to keep the UI responsive.
			Task.detached(priority: .userInitiated) {
				await MainActor.run {
					library.photos = []
					library.folderURL = urls.first
					library.isScanning = true
					library.scanStartDate = Date()
				}
				let start = Date()

				await withTaskGroup(of: Void.self) { group in
					for folder in urls {
						group.addTask {
							let startedAccess = folder.startAccessingSecurityScopedResource()
							defer { if startedAccess { folder.stopAccessingSecurityScopedResource() } }
							for await batch in PhotoLibrary.scanStream(folder: folder, batchSize: 256) {
								if Task.isCancelled { break }
								await MainActor.run { library.photos.append(contentsOf: batch) }
								// Background work: telemetry, face processing and
								// thumbnail warming for each batch.
								await MainActor.run { Self.logger.log("scan:batch yielded=\(batch.count, privacy: .public) total=\(library.photos.count, privacy: .public)") }
								Task.detached { await Telemetry.shared.recordFound(batch.count) }

								let faceEnabled = UserDefaults.standard.bool(forKey: "enableFaceRecognition")
								if faceEnabled {
									Task.detached(priority: .utility) {
										for item in batch {
											if Task.isCancelled { break }
											_ = await FaceProcessor.shared.process(file: item.url)
										}
									}
								}

								// Warm thumbnails for this batch.
								Task.detached(priority: .utility) {
									for item in batch {
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
				PhotoLibrary.persistCombinedSnapshot(finalPhotos, for: urls)
			}
		}
	}

	private func refreshThumbnails() {
		isRefreshing = true
		let start = Date()
		Task {
			let clear = Task.detached(priority: .userInitiated) {
				await ThumbnailCache.shared.clear()
			}
			_ = await clear.value
			lastRefreshDuration = Date().timeIntervalSince(start)
			lastRefreshDate = Date()
			isRefreshing = false
			refreshToken = UUID()
		}
	}

	private func performDelete(urls: [URL]) {
		deleteResults = Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as Bool?) })
		deleteErrorMessages = Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
		deleteProgressCount = 0
		isDeleting = true
		deletingURLs = urls
		logger.log("performDelete: attempting to move \(urls.count) items to Trash")
		Task.detached(priority: .utility) {
			let fm = FileManager.default
			for u in urls {
				if Task.isCancelled { break }
				var success = false
				var errorMsg: String? = nil
				do {
					var trashed: NSURL? = nil
					try fm.trashItem(at: u, resultingItemURL: &trashed)
					success = true
					if let t = trashed {
						await MainActor.run { self.logger.log("performDelete: trashed \(u.path, privacy: .public) -> \(t.path ?? "", privacy: .public)") }
					} else {
						await MainActor.run { self.logger.log("performDelete: trashed \(u.path, privacy: .public) (resulting URL unknown)") }
					}
				} catch {
					success = false
					errorMsg = error.localizedDescription
					await MainActor.run { self.logger.error("performDelete: failed to trash \(u.path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
				}

				let res = success
				await MainActor.run {
					deleteResults[u] = res
					deleteErrorMessages[u] = errorMsg
					deleteProgressCount += 1
					if res {
						selectedItems.remove(u)
						library.photos.removeAll { $0.url == u }
						displayedPhotos.removeAll { $0.url == u }
					}
				}
			}

			// Build an error summary for any failures so the UI can show it.
			var summaryLines: [String] = []
			await MainActor.run {
				for (u, msg) in deleteErrorMessages.sorted(by: { $0.key.lastPathComponent < $1.key.lastPathComponent }) {
					if let m = msg {
						summaryLines.append("\(u.lastPathComponent): \(m)")
					}
				}
				if !summaryLines.isEmpty {
					deleteErrorSummary = summaryLines.joined(separator: "\n")
					showDeleteErrorSummary = true
				}
				// clear deletingURLs when done
				deletingURLs = []
				isDeleting = false
			}
		}
	}

	// MARK: - Sorting

	private func scheduleSort() {
		// Cancel any in-flight sort work and start a new background task.
		// Provide an immediate, cheap filename-only filter so the UI feels
		// responsive while a debounced, full metadata-aware filter runs in
		// the background. Also debounce the full work to avoid starting a
		// heavy task on every single keystroke.
		sortTask?.cancel()
		let photos = library.photos
		let mode = SortMode(rawValue: sortModeRaw) ?? .alphaAsc
		let filter = searchText

		// Quick-pass: update displayedPhotos with a filename-only match
		// performed on the main actor so typing feels snappy.
		if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			displayedPhotos = photos
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
				// Invalid regex: fallback to substring match on filename
				let needle = filter.lowercased()
				filtered = photos.filter { $0.url.lastPathComponent.lowercased().contains(needle) }
			}
		}

		// Now perform the requested sort on the filtered list.
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
		let accessOk = await Self.ensureSecurityScopedAccess(for: url)
		logger.log("writeKeywords: security access for \(url.path, privacy: .public)=\(accessOk, privacy: .public)")
		// Read source
		guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
			logger.log("writeKeywords: cannot create CGImageSource for \(url.path, privacy: .public)")
			return false
		}

		guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
			logger.log("writeKeywords: cannot copy properties for \(url.path, privacy: .public)")
			return false
		}

		var metadata = props
		var iptc = (metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
		iptc[kCGImagePropertyIPTCKeywords] = keywords as CFArray
		metadata[kCGImagePropertyIPTCDictionary] = iptc as CFDictionary

		// Create a temporary file next to the original so moves are atomic
		// and don't fail across volumes. Use a hidden filename to avoid
		// exposing partial artifacts.
		let fm = FileManager.default
		let dir = url.deletingLastPathComponent()
		let tempFilename = ".pvtmp-\(UUID().uuidString)"
		let tempURL = dir.appendingPathComponent(tempFilename).appendingPathExtension(url.pathExtension)

		guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else {
			logger.error("writeKeywords: cannot create CGImageDestination for tempURL=\(tempURL.path, privacy: .public) type=\(String(describing: type), privacy: .public)")
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "writeKeywords", "message": "CGImageDestinationCreateWithURL failed when attempting to write embedded metadata."])
			// Embedded write failed; do not fall back to sidecar per policy.
			return false
		}

		CGImageDestinationAddImageFromSource(dest, src, 0, metadata as CFDictionary)
		if !CGImageDestinationFinalize(dest) {
			logger.error("writeKeywords: CGImageDestinationFinalize failed for tempURL=\(tempURL.path, privacy: .public)")
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
			return true
		} catch {
			logger.error("writeKeywords: failed to replace original file \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
			// Attempt to cleanup
			try? fm.removeItem(at: tempURL)
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "writeKeywords", "message": "Failed to replace original file after writing temp file: \(error.localizedDescription)"])
			// Do not fall back to sidecar; surface failure to caller.
			return false
		}
	}

	private func restoreSavedWindowsIfNeeded() {
		logger.log("restoreSavedWindowsIfNeeded called; saveOpenWindows=\(self.saveOpenWindows, privacy: .public) disableAutoRestore=\(self.disableAutoRestoreWindows, privacy: .public)")
		// Only the first ContentView at launch consumes the persisted
		// session. New windows opened later (File → New, Cmd+N) start
		// blank and prompt the user for a folder.
		guard saveOpenWindows else { return }
		guard WindowStateStore.shared.consumeLaunchRestoration() else { return }

		// Quick test switch: if auto-restore of photo windows is disabled
		// via the AppStorage flag, skip opening saved photo windows. This is
		// a temporary diagnostic toggle to help isolate main-thread work at
		// startup. Set the UserDefault key "disableAutoRestoreWindows"
		// to false to re-enable restoring windows.
		if disableAutoRestoreWindows {
			logger.log("Auto-restore of photo windows is disabled; skipping window restoration.")
		}

		if let folder = WindowStateStore.shared.resolveSavedFolder() {
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
					// Publish in batches to avoid a big main-thread spike.
					let batchSize = 256
					await MainActor.run {
						library.photos = []
						library.folderURL = folder
					}
					var idx = 0
					while idx < deduped.count {
						let end = min(idx + batchSize, deduped.count)
						let slice = deduped[idx..<end].map { PhotoItem(url: $0) }
						await MainActor.run {
							library.photos.append(contentsOf: slice)
							library.lastScanDate = Date()
						}
						// Schedule face processing for the restored batch so cached
						// thumbnails get analyzed even when we don't run a full
						// re-scan. FaceProcessor internally deduplicates/short-
						// circuits via the DB actor, so it's safe to call for
						// every restored item.
						let faceEnabled = UserDefaults.standard.bool(forKey: "enableFaceRecognition")
						if faceEnabled {
							Task.detached(priority: .utility) {
								await MainActor.run { self.logger.log("scheduling face processing for restoration batch of \(slice.count, privacy: .public) items") }
								for item in slice {
									if Task.isCancelled { break }
									_ = await FaceProcessor.shared.process(file: item.url)
								}
							}
						} else {
							await MainActor.run { self.logger.log("face processing for restoration skipped (enableFaceRecognition=false)") }
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
								if deferAtLaunchBackgroundWork {
									logger.log("At-launch scan deferred by deferAtLaunchBackgroundWork flag; skipping scan for folder=\(folder.path, privacy: .public)")
								} else {
									library.scan(folder: folder)
								}
							}
						}
					}
				} else {
					// No cached snapshot available; retain current behavior
					// of not auto-scanning at launch.
					await MainActor.run {
						library.folderURL = folder
					}
				}
			}
		}
		// Restore previously-open photo windows but avoid creating a large
		// number of windows synchronously at startup which can freeze the
		// UI. Stagger window creation on a background task and limit the
		// number of windows restored to a reasonable cap.
		let saved = WindowStateStore.shared.openPhotoURLs()
		let savedListString = saved.map { $0.path }.joined(separator: ",")
		logger.log("restoreSavedWindowsIfNeeded: saved photo windows count=\(saved.count, privacy: .public) paths=\(savedListString, privacy: .public)")
		let maxOpen = 8
		if !saved.isEmpty && !disableAutoRestoreWindows {
			logger.log("Restoring up to \(maxOpen) saved photo windows (total saved=\(saved.count))")
			Task.detached(priority: .background) {
				for (i, url) in saved.prefix(maxOpen).enumerated() {
					// Small stagger to avoid UI contention when creating many
					// windows at once. Increase delay for larger index.
					let delay = UInt64(min(i, 5)) * 200_000_000 // 0..1s
					try? await Task.sleep(nanoseconds: delay)
					await MainActor.run {
						openWindow(id: "photo-viewer", value: url)
						logger.log("restoreSavedWindowsIfNeeded: opening restored window for \(url.path, privacy: .public)")
					}
				}
				logger.log("Finished scheduling restored photo windows (scheduled=\(min(saved.count, maxOpen)))")
			}
		}
	}
}

#Preview {
	ContentView()
}
