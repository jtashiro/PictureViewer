//
//  ThumbnailLoader.swift
//  PictureViewer

import Foundation
import AppKit
import QuickLookThumbnailing
import os

private nonisolated let tlLogger = Logger(subsystem: "com.example.PictureViewer", category: "thumbnail-loader")

private nonisolated let kDefaultMemoryLimitBytes: UInt64 = 5 * 1024 * 1024 * 1024  // 5 GB

/// Priority-queue-based thumbnail loader.  Call `enqueue(_:)` to add URLs,
/// then `loadAllThumbnails()` to batch-generate them with bounded concurrency.
actor ThumbnailLoader {

    private let maxConcurrentTasks: Int = 8
    private let batchSize: Int = 1024
    private let memoryLimitBytes: UInt64 = kDefaultMemoryLimitBytes

    /// URLs in load order.
    private var priorityQueue: [URL] = []
    /// In-memory cache of generated thumbnails.
    private var loadedImages: [URL: NSImage] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: UserDefaults.thumbnailLoadOrderKey) {
            do {
                let urls = try JSONDecoder().decode([URL].self, from: data)
                priorityQueue.append(contentsOf: urls)
                tlLogger.log("ThumbnailLoader: restored \(urls.count) priority URLs")
            } catch {
                tlLogger.error("ThumbnailLoader: failed to decode priority queue: \(error)")
            }
        }
    }

    // MARK: - Public API

    func enqueue(_ urls: [URL]) {
        priorityQueue.append(contentsOf: urls)
    }

    func loadAllThumbnails(maxMemoryBytes: UInt64? = nil) async -> [URL: NSImage] {
        let memoryLimit = maxMemoryBytes ?? memoryLimitBytes
        let start = Date()
        let total = priorityQueue.count

        for batchStart in stride(from: 0, to: total, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, total)
            let batch = Array(priorityQueue[batchStart..<batchEnd])

            tlLogger.log("ThumbnailLoader: batch \(batchStart+1)–\(batchEnd) of \(total)")

            let results = await processBatch(batch)
            for (url, image) in results {
                loadedImages[url] = image
            }
            releaseMemoryIfNeeded(maxMemoryBytes: memoryLimit)
        }

        let duration = Date().timeIntervalSince(start)
        tlLogger.log("ThumbnailLoader: loaded \(self.loadedImages.count) thumbnails in \(duration.formatted())")
        return loadedImages
    }

    // MARK: - Private helpers

    private func processBatch(_ urls: [URL]) async -> [URL: NSImage] {
        let limiter = AsyncLimiter(capacity: maxConcurrentTasks)
        return await withTaskGroup(of: (URL, NSImage?).self) { group in
            for url in urls {
                await limiter.acquire()
                group.addTask {
                    defer { Task { await limiter.release() } }
                    let image = await Self.generateThumbnail(for: url)
                    return (url, image)
                }
            }
            var out: [URL: NSImage] = [:]
            for await (url, image) in group {
                if let image { out[url] = image }
            }
            return out
        }
    }

    private static func generateThumbnail(for url: URL) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = CGSize(width: 256, height: 256)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2,
            representationTypes: .thumbnail
        )
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return rep.nsImage
        } catch {
            tlLogger.error("ThumbnailLoader: thumbnail failed for \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func releaseMemoryIfNeeded(maxMemoryBytes: UInt64) {
        let usage = currentMemoryBytes()
        guard usage > maxMemoryBytes else { return }
        tlLogger.log("ThumbnailLoader: releasing memory (usage≈\(usage) limit=\(maxMemoryBytes))")
        var released = 0
        for key in loadedImages.keys.sorted(by: { $0.path < $1.path }) {
            guard released < 100 else { break }
            loadedImages.removeValue(forKey: key)
            released += 1
        }
    }

    private func currentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

}

// MARK: - UserDefaults helper

extension UserDefaults {
    nonisolated static let thumbnailLoadOrderKey = "thumbnailLoadOrder"

    nonisolated static func saveRecentAccess(urls: [URL], maxCount: Int = 100) {
        let recent = Array(urls.prefix(maxCount))
        guard let data = try? JSONEncoder().encode(recent) else { return }
        UserDefaults.standard.set(data, forKey: thumbnailLoadOrderKey)
    }
}
