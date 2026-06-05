//
//  ThumbnailCache.swift
//  PictureViewer
//

import Foundation
@preconcurrency import AppKit
import CryptoKit
import os

private let thumbnailLogger = Logger(subsystem: "com.example.PictureViewer", category: "thumbnail-cache")

/// Two-tier (memory + disk) thumbnail cache. Disk entries survive across
/// launches, are keyed by a hash of the source file's absolute path, and
/// are validated against the source's modification date before use.
final class ThumbnailCache: @unchecked Sendable {
	static let shared = ThumbnailCache()

	/// Thumbnails are generated at this canonical pixel size. SwiftUI scales
	/// them to the current slider value, so we only need to cache one size
	/// per source file.
	static let canonicalSize: CGFloat = 512

	private let memCache = NSCache<NSString, NSImage>()
	let cacheDirectory: URL
	private let writeQueue = DispatchQueue(
		label: "ThumbnailCache.write",
		qos: .utility,
		attributes: .concurrent
	)

	private init() {
		let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSTemporaryDirectory())
		cacheDirectory = caches.appendingPathComponent("PictureViewer/Thumbnails", isDirectory: true)
		try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
		memCache.countLimit = 1024
		// Size the in-memory cache relative to system memory (up to a sensible cap).
		let physical = ProcessInfo.processInfo.physicalMemory
		// Use up to 1/8 of physical memory for thumbnail cache, but cap at 1GB.
		let limit = min(UInt64(1_000_000_000), physical / 8)
		memCache.totalCostLimit = Int(limit)
	}

	/// Synchronous lookup. Returns nil on miss / stale entry. Safe to call
	/// from any context; disk reads happen on the calling thread, so callers
	/// running on the main actor should `await` a detached task to avoid
	/// blocking UI.
	///
	/// `namespace` is an optional user-provided string (for example a tab
	/// title) that is incorporated into the cache key so different tabs can
	/// maintain separate caches if desired. If nil the behaviour is the
	/// same as before (keyed only by source path).
	func image(for url: URL, namespace: String? = nil) -> NSImage? {
		if AppLogLevel.current.allows(.debug) {
			thumbnailLogger.debug("thumbnailCache:image(for:) called for \(url.path, privacy: .public) main=\(Thread.isMainThread, privacy: .public)")
		}
		let key = self.key(for: url, namespace: namespace)
		if let mem = memCache.object(forKey: key as NSString) {
			return mem
		}
		let file = cacheFile(forKey: key)
		guard FileManager.default.fileExists(atPath: file.path) else { return nil }
		guard isFresh(cache: file, source: url) else {
			try? FileManager.default.removeItem(at: file)
			return nil
		}
		guard let image = NSImage(contentsOf: file) else { return nil }
		memCache.setObject(image, forKey: key as NSString, cost: cost(of: image))
		return image
	}

	/// Stores a thumbnail in both memory and disk caches. Disk write is
	/// dispatched asynchronously and never blocks the caller.
	func store(_ image: NSImage, for url: URL, namespace: String? = nil) {
		let key = self.key(for: url, namespace: namespace)
		memCache.setObject(image, forKey: key as NSString, cost: cost(of: image))
		let file = cacheFile(forKey: key)
		writeQueue.async {
			guard
				let tiff = image.tiffRepresentation,
				let rep = NSBitmapImageRep(data: tiff),
				let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
			else { return }
			try? data.write(to: file, options: .atomic)
		}
	}

	/// Clears both memory and disk caches.
	func clear() {
		memCache.removeAllObjects()
		let dir = cacheDirectory
		writeQueue.async(flags: .barrier) {
			try? FileManager.default.removeItem(at: dir)
			try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		}
	}

	/// Migrate cached thumbnail entries from one namespace to another for the
	/// provided list of source URLs. This moves on-disk files and updates the
	/// in-memory NSCache entries. Safe to call from any thread.
	func migrateNamespace(from oldNamespace: String?, to newNamespace: String?, for urls: [URL]) {
		// No-op if namespaces are equal
		if oldNamespace == newNamespace { return }
		writeQueue.async(flags: .barrier) {
			for url in urls {
				let oldKey = self.key(for: url, namespace: oldNamespace)
				let newKey = self.key(for: url, namespace: newNamespace)
				let oldFile = self.cacheFile(forKey: oldKey)
				let newFile = self.cacheFile(forKey: newKey)
				// Move on-disk file if present and destination missing
				if FileManager.default.fileExists(atPath: oldFile.path) {
					if !FileManager.default.fileExists(atPath: newFile.path) {
						try? FileManager.default.moveItem(at: oldFile, to: newFile)
					} else {
						// Destination exists; remove the old file to avoid duplicates
						try? FileManager.default.removeItem(at: oldFile)
					}
				}
				// Migrate in-memory cache entries
				let oldKeyStr = oldKey as NSString
				let newKeyStr = newKey as NSString
				if let img = self.memCache.object(forKey: oldKeyStr) {
					self.memCache.setObject(img, forKey: newKeyStr, cost: self.cost(of: img))
					self.memCache.removeObject(forKey: oldKeyStr)
				}
			}
		}
	}

	/// Removes cached files that haven't been touched in `olderThanDays`
	/// to keep the cache bounded. Intended to run on app launch.
	func sweepStale(olderThanDays days: Int = 30) {
		let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
		let keys: [URLResourceKey] = [.contentAccessDateKey, .contentModificationDateKey]
		guard let entries = try? FileManager.default.contentsOfDirectory(
			at: cacheDirectory,
			includingPropertiesForKeys: keys,
			options: [.skipsHiddenFiles]
		) else { return }

		for entry in entries {
			guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
			let when = values.contentAccessDate
				?? values.contentModificationDate
				?? .distantPast
			if when < cutoff {
				try? FileManager.default.removeItem(at: entry)
			}
		}
	}

	/// Approximate on-disk cache size in bytes.
	func diskUsage() -> Int64 {
		guard let entries = try? FileManager.default.contentsOfDirectory(
			at: cacheDirectory,
			includingPropertiesForKeys: [.fileSizeKey],
			options: []
		) else { return 0 }
		var total: Int64 = 0
		for entry in entries {
			if let size = try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize {
				total += Int64(size)
			}
		}
		return total
	}

	// MARK: - Internals

	private func key(for url: URL, namespace: String? = nil) -> String {
		// Incorporate an optional namespace into the key so tabs can have
		// separate caches. Use a stable encoding of "namespace:path" to
		// generate the hash.
		let prefix = (namespace ?? "")
		let combined = prefix + ":" + url.path
		let data = Data(combined.utf8)
		let hash = SHA256.hash(data: data)
		return hash.compactMap { String(format: "%02x", $0) }.joined()
	}

	private func cacheFile(forKey key: String) -> URL {
		cacheDirectory.appendingPathComponent(key).appendingPathExtension("jpg")
	}

	private func isFresh(cache: URL, source: URL) -> Bool {
		guard
			let cv = try? cache.resourceValues(forKeys: [.contentModificationDateKey]),
			let sv = try? source.resourceValues(forKeys: [.contentModificationDateKey]),
			let cacheDate = cv.contentModificationDate,
			let srcDate = sv.contentModificationDate
		else {
			return false
		}
		return cacheDate >= srcDate
	}

	private func cost(of image: NSImage) -> Int {
		// Try to compute an accurate in-memory byte size by using a
		// CGImage if available (provides bytesPerRow * height). Fall
		// back to an NSBitmapImageRep if that is present, and finally
		// to a conservative 4 bytes-per-pixel estimate.
		if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
			return cg.bytesPerRow * cg.height
		}
		if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
			return rep.bytesPerRow * rep.pixelsHigh
		}
		let pixels = Int(image.size.width * image.size.height)
		return max(1, pixels * 4)
	}
}
