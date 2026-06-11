//
//  AppWorkingDirectory.swift
//  PictureViewer
//

import Foundation
import os

enum AppWorkingDirectory {
    nonisolated static let directoryPathKey = "appWorkingDirectoryPath"
    nonisolated static let directoryBookmarkKey = "appWorkingDirectoryBookmark"
    nonisolated static let userChosenKey = "appWorkingDirectoryUserChosen"

    nonisolated private static let logger = Logger(subsystem: "com.example.PictureViewer", category: "working-directory")

    nonisolated static var defaultBaseURL: URL {
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport.appendingPathComponent("PictureViewer", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    nonisolated static var baseURL: URL {
        if let bookmark = UserDefaults.standard.data(forKey: directoryBookmarkKey) {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                _ = url.startAccessingSecurityScopedResource()
                if isLegacyTemporaryDefault(url) {
                    logger.log("working directory: ignoring legacy tmp bookmark path=\(url.path, privacy: .public)")
                    resetToDefault()
                    return defaultBaseURL
                }
                if stale {
                    setBaseURL(url, userChosen: isUserChosen)
                }
                return url
            } catch {
                logger.error("working directory: failed to resolve bookmark error=\(error.localizedDescription, privacy: .public)")
                UserDefaults.standard.removeObject(forKey: directoryBookmarkKey)
            }
        }

        if let path = UserDefaults.standard.string(forKey: directoryPathKey), !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if isLegacyTemporaryDefault(url) {
                logger.log("working directory: ignoring legacy tmp path=\(path, privacy: .public)")
                resetToDefault()
                return defaultBaseURL
            }
            return url
        }

        return defaultBaseURL
    }

    /// Earlier builds defaulted to `temporaryDirectory/PictureViewer`, which is
    /// ephemeral inside the sandbox container. Treat that as unset.
    nonisolated private static func isLegacyTemporaryDefault(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/tmp/PictureViewer")
            || path.hasSuffix("/tmp/PictureViewer")
    }

    nonisolated static var legacyTemporaryDefaultBaseURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PictureViewer", isDirectory: true)
    }

    nonisolated static var isUserChosen: Bool {
        UserDefaults.standard.bool(forKey: userChosenKey)
    }

    nonisolated static func setBaseURL(_ url: URL, userChosen: Bool = true) {
        UserDefaults.standard.set(userChosen, forKey: userChosenKey)
        UserDefaults.standard.set(url.path, forKey: directoryPathKey)
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: directoryBookmarkKey)
        }
    }

    nonisolated static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: directoryPathKey)
        UserDefaults.standard.removeObject(forKey: directoryBookmarkKey)
        UserDefaults.standard.set(false, forKey: userChosenKey)
    }

    @discardableResult
    nonisolated static func ensureAccess() -> Bool {
        if isWritableWorkingRoot(baseURL) {
            return true
        }
        _ = SecurityScopedResourceAccess.ensureAccess(for: baseURL)
        return isWritableWorkingRoot(baseURL)
    }

    nonisolated private static func isWritableWorkingRoot(_ directory: URL) -> Bool {
        do {
            try ensureDirectory(directory)
        } catch {
            logger.error("working directory: ensureDirectory failed path=\(directory.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
        return SecurityScopedResourceAccess.probesWritableDirectory(directory)
    }

    /// Application-owned persistent data stored under the working directory.
    nonisolated static func appDataURL() -> URL {
        baseURL.appendingPathComponent("AppData", isDirectory: true)
    }

    nonisolated static func thumbnailsCacheURL() -> URL {
        appDataURL().appendingPathComponent("Thumbnails", isDirectory: true)
    }

    nonisolated static func metadataSidecarsURL() -> URL {
        appDataURL().appendingPathComponent("Sidecars", isDirectory: true)
    }

    nonisolated static func facesDataURL() -> URL {
        appDataURL().appendingPathComponent("Faces", isDirectory: true)
    }

    nonisolated static func sqliteManifestsURL() -> URL {
        appDataURL().appendingPathComponent("SQLiteManifests", isDirectory: true)
    }

    nonisolated static func vaultContentHashesURL() -> URL {
        appDataURL().appendingPathComponent("Vault", isDirectory: true)
            .appendingPathComponent("content-hashes.json", isDirectory: false)
    }

    nonisolated static func sqliteObjectStoreURL() -> URL {
        baseURL.appendingPathComponent("SQLiteObjectStore", isDirectory: true)
    }

    nonisolated static func vaultWorkingURL() -> URL {
        baseURL.appendingPathComponent("VaultWorking", isDirectory: true)
    }

    nonisolated static func scratchURL() -> URL {
        baseURL.appendingPathComponent("Scratch", isDirectory: true)
    }

    nonisolated static func thumbnailBackfillScratchURL(sessionID: String = UUID().uuidString) -> URL {
        scratchURL()
            .appendingPathComponent("ThumbnailBackfill", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    @discardableResult
    nonisolated static func ensureAppDataDirectories() -> Bool {
        guard ensureAccess() else { return false }
        do {
            try ensureDirectory(appDataURL())
            try ensureDirectory(thumbnailsCacheURL())
            try ensureDirectory(metadataSidecarsURL())
            try ensureDirectory(facesDataURL())
            try ensureDirectory(sqliteManifestsURL())
            try ensureDirectory(vaultContentHashesURL().deletingLastPathComponent())
            return true
        } catch {
            logger.error("working directory: ensureAppDataDirectories failed error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    nonisolated static func legacyCachesThumbnailsURL() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches.appendingPathComponent("PictureViewer/Thumbnails", isDirectory: true)
    }

    nonisolated static func legacyMetadataSidecarsURL() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return appSupport
            .appendingPathComponent("PictureViewer", isDirectory: true)
            .appendingPathComponent("Sidecars", isDirectory: true)
    }

    nonisolated static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    nonisolated static func deleteExistingWorkingDirectories() throws {
        let fm = FileManager.default
        let base = baseURL
        _ = base.startAccessingSecurityScopedResource()
        let directories = [
            sqliteObjectStoreURL(),
            vaultWorkingURL(),
            scratchURL(),
            legacyTemporaryDefaultBaseURL.appendingPathComponent("SQLiteObjectStore", isDirectory: true),
            legacyTemporaryDefaultBaseURL.appendingPathComponent("VaultWorking", isDirectory: true),
            legacyTemporaryDefaultBaseURL.appendingPathComponent("Scratch", isDirectory: true)
        ]

        for directory in Set(directories.map(\.standardizedFileURL)) {
            if fm.fileExists(atPath: directory.path) {
                try fm.removeItem(at: directory)
            }
        }
        try ensureDirectory(base)
        logger.log("working directory: deleted existing working directories base=\(base.path, privacy: .public)")
    }
}