//
//  AppWorkingDirectory.swift
//  PictureViewer
//

import Foundation
import os

enum AppWorkingDirectory {
    nonisolated static let directoryPathKey = "appWorkingDirectoryPath"
    nonisolated static let directoryBookmarkKey = "appWorkingDirectoryBookmark"

    nonisolated private static let logger = Logger(subsystem: "com.example.PictureViewer", category: "working-directory")

    nonisolated static var defaultBaseURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PictureViewer", isDirectory: true)
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
                if stale {
                    setBaseURL(url)
                }
                return url
            } catch {
                logger.error("working directory: failed to resolve bookmark error=\(error.localizedDescription, privacy: .public)")
                UserDefaults.standard.removeObject(forKey: directoryBookmarkKey)
            }
        }

        if let path = UserDefaults.standard.string(forKey: directoryPathKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        return defaultBaseURL
    }

    nonisolated static func setBaseURL(_ url: URL) {
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
    }

    /// Ensures security-scoped access to the configured working directory,
    /// including user-chosen folders on external volumes.
    @discardableResult
    nonisolated static func ensureAccess() -> Bool {
        SecurityScopedResourceAccess.ensureAccess(for: baseURL)
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
            defaultBaseURL.appendingPathComponent("SQLiteObjectStore", isDirectory: true),
            defaultBaseURL.appendingPathComponent("VaultWorking", isDirectory: true),
            defaultBaseURL.appendingPathComponent("Scratch", isDirectory: true)
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
