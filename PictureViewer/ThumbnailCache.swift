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
    func image(for url: URL) -> NSImage? {
        thumbnailLogger.log("thumbnailCache:image(for:) called for \(url.path, privacy: .public) main=\(Thread.isMainThread, privacy: .public)")
        let key = self.key(for: url)
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
    func store(_ image: NSImage, for url: URL) {
        let key = self.key(for: url)
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

    private func key(for url: URL) -> String {
        let data = Data(url.path.utf8)
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
        let pixels = Int(image.size.width * image.size.height)
        return pixels * 4
    }
}
