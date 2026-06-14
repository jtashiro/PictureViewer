//
//  ThumbnailWarmService.swift
//  PictureViewer
//

import Foundation

enum ThumbnailWarmService {
    nonisolated static func warmFilesystemThumbnails(for items: [PhotoItem]) {
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
                    let image = try await ThumbnailGenerator.shared.generateThumbnail(for: item.url)
                    ThumbnailCache.shared.store(image, for: item.url)
                } catch { }
            }
        }
    }
}
