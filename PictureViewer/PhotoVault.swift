//
//  PhotoVault.swift
//  PictureViewer
//

import Foundation
import CryptoKit
import AppKit
import UniformTypeIdentifiers
import os

extension Notification.Name {
    nonisolated static let photoVaultStatusChanged = Notification.Name("com.example.PictureViewer.photoVaultStatusChanged")
}

enum PhotoVaultError: LocalizedError {
    case locationMissing
    case passwordMissing
    case passwordIncorrect
    case invalidEncryptedFile
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .locationMissing: "Choose a vault location in Settings first."
        case .passwordMissing: "Enter the vault password in Settings first."
        case .passwordIncorrect: "The vault password is incorrect."
        case .invalidEncryptedFile: "The encrypted file is not a Picture Viewer vault file."
        case .unsupportedFile: "The file is not a supported media file."
        }
    }
}

struct PhotoVaultStatus: Sendable {
    let isConfigured: Bool
    let hasLocation: Bool
    let hasPassword: Bool
    let isUnlocked: Bool
    let locationPath: String?
}

struct KnownVault: Identifiable, Hashable, Sendable {
    let url: URL

    var id: String { url.standardizedFileURL.path }
    var displayName: String {
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Vault*" : "\(name)*"
    }
    var path: String { url.path }
}

struct PhotoVaultImportResult: Sendable {
    let workingURLs: [URL]
    let duplicateCount: Int
    let failedCount: Int
}

private actor ContentHashReservation {
    private var hashes: Set<String>

    init(_ hashes: Set<String>) {
        self.hashes = hashes
    }

    func reserve(_ hash: String) -> Bool {
        if hashes.contains(hash) { return false }
        hashes.insert(hash)
        return true
    }

    func release(_ hash: String) {
        hashes.remove(hash)
    }
}

actor PhotoVault {
    static let shared = PhotoVault()

    static let locationBookmarkKey = "photoVaultLocationBookmark"
    static let locationPathKey = "photoVaultLocationPath"
    static let passwordSaltKey = "photoVaultPasswordSalt"
    static let passwordVerifierKey = "photoVaultPasswordVerifier"
    static let knownVaultBookmarksKey = "photoVaultKnownVaultBookmarks"
    static let workingMapKey = "photoVaultWorkingMap"
    static let workingMapFilename = "photoVaultWorkingMap.json"
    static let contentHashesKey = "photoVaultContentHashes"
    static let contentHashesFilename = "photoVaultContentHashes.json"
    static let encryptedExtension = "pvencrypted"
    static let metadataFilename = ".pictureviewer-vault.json"

    nonisolated static func clearWorkingCopiesOnDisk() {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("PictureViewer/VaultWorking", isDirectory: true)
        else { return }
        if let contents = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for url in contents {
                try? fm.removeItem(at: url)
            }
        }
        UserDefaults.standard.removeObject(forKey: workingMapKey)
        try? fm.removeItem(at: workingMapFileURL())
    }

    private nonisolated let logger = Logger(subsystem: "com.example.PictureViewer", category: "vault")
    private nonisolated let magic = Data("PVENC1\n".utf8)
    private let keyIterations = 120_000
    private var key: SymmetricKey?
    private var locationURL: URL?
    private var contentHashesCache: Set<String>?
    private var contentHashesNeedsSave = false

    private nonisolated static var importWorkerCount: Int {
        max(2, PhotoLibrary.workerCount)
    }

    private struct Header: Codable {
        let version: Int
        let originalFilename: String
        let originalRelativePath: String?
        let importedAt: Date
        let contentTypeIdentifier: String?
        // Optional so files written before this field existed still decode.
        let contentHash: String?
    }

    private struct VaultMetadata: Codable {
        let version: Int
        let salt: String
        let verifier: String
    }

    private init() {}

    func status() -> PhotoVaultStatus {
        let location = resolvedLocationURL()
        let hasPassword = credentialData(for: location) != nil
        return PhotoVaultStatus(
            isConfigured: location != nil && hasPassword,
            hasLocation: location != nil,
            hasPassword: hasPassword,
            isUnlocked: key != nil,
            locationPath: location?.path ?? UserDefaults.standard.string(forKey: Self.locationPathKey)
        )
    }

    func setLocation(_ url: URL) throws {
        let previousPath = locationURL?.standardizedFileURL.path
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: Self.locationBookmarkKey)
        UserDefaults.standard.set(url.path, forKey: Self.locationPathKey)
        try registerKnownVault(url)
        locationURL = url
        if previousPath != url.standardizedFileURL.path {
            key = nil
        }
        _ = url.startAccessingSecurityScopedResource()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        postStatusChange()
    }

    func knownVaults() -> [KnownVault] {
        let bookmarks = knownVaultBookmarkData()
        var resolvedBookmarks: [Data] = []
        var vaults: [KnownVault] = []
        var seenPaths: Set<String> = []

        for bookmark in bookmarks {
            guard let url = resolveBookmark(bookmark) else { continue }
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            _ = url.startAccessingSecurityScopedResource()
            vaults.append(KnownVault(url: url))
            if let refreshedBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                resolvedBookmarks.append(refreshedBookmark)
            } else {
                resolvedBookmarks.append(bookmark)
            }
        }

        if let currentURL = resolvedLocationURL() {
            let currentPath = currentURL.standardizedFileURL.path
            if seenPaths.insert(currentPath).inserted {
                _ = currentURL.startAccessingSecurityScopedResource()
                vaults.append(KnownVault(url: currentURL))
                if let currentBookmark = try? currentURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    resolvedBookmarks.append(currentBookmark)
                }
            }
        }

        if resolvedBookmarks.count != bookmarks.count {
            UserDefaults.standard.set(resolvedBookmarks, forKey: Self.knownVaultBookmarksKey)
        }

        return vaults.sorted {
            $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    func removeKnownVault(_ url: URL) {
        let removedPath = url.standardizedFileURL.path
        let remainingBookmarks = knownVaultBookmarkData().filter { bookmark in
            guard let resolvedURL = resolveBookmark(bookmark) else { return false }
            return resolvedURL.standardizedFileURL.path != removedPath
        }
        UserDefaults.standard.set(remainingBookmarks, forKey: Self.knownVaultBookmarksKey)

        let currentPath = resolvedLocationURL()?.standardizedFileURL.path
        if currentPath == removedPath {
            key = nil
            locationURL = nil
            UserDefaults.standard.removeObject(forKey: Self.locationBookmarkKey)
            UserDefaults.standard.removeObject(forKey: Self.locationPathKey)
            postStatusChange()
        }
    }

    func replaceKnownVault(oldURL: URL, newURL: URL) throws {
        let oldPath = oldURL.standardizedFileURL.path
        let currentPath = resolvedLocationURL()?.standardizedFileURL.path
        removeKnownVault(oldURL)
        if currentPath == oldPath {
            try setLocation(newURL)
        } else {
            try registerKnownVault(newURL)
        }
    }

    func configureNewVaultPassword(_ password: String) throws {
        guard resolvedLocationURL() != nil else { throw PhotoVaultError.locationMissing }
        try setPassword(password)
    }

    func setPassword(_ password: String) throws {
        guard !password.isEmpty else { throw PhotoVaultError.passwordMissing }
        guard let location = resolvedLocationURL() else { throw PhotoVaultError.locationMissing }
        let salt = randomData(count: 16)
        let verifier = deriveKeyData(password: password, salt: salt, iterations: keyIterations)
        try persistCredentialData(salt: salt, verifier: verifier, for: location)
        key = SymmetricKey(data: verifier)
        postStatusChange()
    }

    func unlock(password: String) throws {
        guard let location = resolvedLocationURL() else { throw PhotoVaultError.locationMissing }
        guard let credential = credentialData(for: location) else {
            try setPassword(password)
            return
        }
        let salt = credential.salt
        let verifier = credential.verifier
        let candidate = deriveKeyData(password: password, salt: salt, iterations: keyIterations)
        guard candidate == verifier else { throw PhotoVaultError.passwordIncorrect }
        key = SymmetricKey(data: candidate)
        postStatusChange()
    }

    func lock() {
        guard key != nil else { return }
        key = nil
        postStatusChange()
    }

    private nonisolated func postStatusChange() {
        NotificationCenter.default.post(name: .photoVaultStatusChanged, object: nil)
    }

    private nonisolated func credentialData(for location: URL?) -> (salt: Data, verifier: Data)? {
        guard let location else { return legacyCredentialData() }
        if let metadata = try? readVaultMetadata(from: location),
           let salt = Data(base64Encoded: metadata.salt),
           let verifier = Data(base64Encoded: metadata.verifier) {
            return (salt, verifier)
        }

        let defaults = UserDefaults.standard
        if let salt = defaults.data(forKey: locationScopedKey(Self.passwordSaltKey, for: location)),
           let verifier = defaults.data(forKey: locationScopedKey(Self.passwordVerifierKey, for: location)) {
            return (salt, verifier)
        }

        return legacyCredentialData()
    }

    private nonisolated func legacyCredentialData() -> (salt: Data, verifier: Data)? {
        guard let salt = UserDefaults.standard.data(forKey: Self.passwordSaltKey),
              let verifier = UserDefaults.standard.data(forKey: Self.passwordVerifierKey)
        else {
            return nil
        }
        return (salt, verifier)
    }

    private nonisolated func persistCredentialData(salt: Data, verifier: Data, for location: URL) throws {
        let defaults = UserDefaults.standard
        defaults.set(salt, forKey: locationScopedKey(Self.passwordSaltKey, for: location))
        defaults.set(verifier, forKey: locationScopedKey(Self.passwordVerifierKey, for: location))

        let metadata = VaultMetadata(
            version: 1,
            salt: salt.base64EncodedString(),
            verifier: verifier.base64EncodedString()
        )
        let data = try JSONEncoder().encode(metadata)
        let metadataURL = location.appendingPathComponent(Self.metadataFilename, isDirectory: false)
        try data.write(to: metadataURL, options: .atomic)
    }

    private nonisolated func readVaultMetadata(from location: URL) throws -> VaultMetadata {
        let metadataURL = location.appendingPathComponent(Self.metadataFilename, isDirectory: false)
        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode(VaultMetadata.self, from: data)
    }

    private nonisolated func locationScopedKey(_ key: String, for location: URL) -> String {
        "\(key).\(PhotoLibrary.safeFilename(for: location.standardizedFileURL.path))"
    }

    func importFiles(
        _ urls: [URL],
        ignoreDuplicates: Bool = true,
        keywordsToAppend: [String] = [],
        progress: (@Sendable (Int, Int, String) async -> Void)? = nil
    ) async throws -> PhotoVaultImportResult {
        guard !urls.isEmpty else {
            return PhotoVaultImportResult(workingURLs: [], duplicateCount: 0, failedCount: 0)
        }
        let destination = try vaultLocation()
        let activeKey = try unlockedKey()
        let totalCount = urls.count
        let workers = max(1, min(totalCount, Self.importWorkerCount))
        let existingHashes = ignoreDuplicates ? await currentVaultContentHashes(in: destination, key: activeKey) : []
        let reservations = ContentHashReservation(existingHashes)
        logger.log("vault import:start requested=\(totalCount, privacy: .public) destination=\(destination.path, privacy: .public) workers=\(workers, privacy: .public) ignoreDuplicates=\(ignoreDuplicates, privacy: .public) currentVaultHashes=\(existingHashes.count, privacy: .public)")

        enum Outcome: Sendable {
            case stored(URL)
            case duplicate
            case failed
        }

        var collected: [(Int, URL)] = []
        var completedCount = 0
        var duplicateCount = 0
        var failedCount = 0

        await withTaskGroup(of: (Int, Outcome).self) { group in
            var nextIndex = 0

            func startTask(at idx: Int) {
                let src = urls[idx]
                group.addTask { [self] in
                    if Task.isCancelled { return (idx, .failed) }
                    guard isSupportedMediaFile(src) else {
                        logger.error("vault import:unsupported file=\(src.path, privacy: .public)")
                        return (idx, .failed)
                    }
                    // Read source once, hash it, then dedup before encrypt.
                    let data: Data
                    do {
                        data = try Data(contentsOf: src)
                    } catch {
                        logger.error("vault import:read failed source=\(src.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                        return (idx, .failed)
                    }
                    let sourceHash = Self.contentHash(of: data)
                    let reserved = ignoreDuplicates ? await reservations.reserve(sourceHash) : true
                    if !reserved {
                        logger.log("vault import:duplicate source=\(src.lastPathComponent, privacy: .public) hash=\(sourceHash, privacy: .public)")
                        return (idx, .duplicate)
                    }
                    let contentType = (try? src.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                    let encryptedURL = uniqueEncryptedURL(for: src.lastPathComponent, in: destination)
                    do {
                        let importData = try dataByAppendingKeywordsIfPossible(keywordsToAppend, to: data, contentType: contentType)
                        try encryptData(
                            importData,
                            originalFilename: src.lastPathComponent,
                            contentTypeIdentifier: contentType?.identifier,
                            contentHash: sourceHash,
                            to: encryptedURL,
                            key: activeKey
                        )
                        try preserveFileDates(from: src, to: encryptedURL)
                        if Task.isCancelled {
                            try? FileManager.default.removeItem(at: encryptedURL)
                            if ignoreDuplicates {
                                await reservations.release(sourceHash)
                            }
                            return (idx, .failed)
                        }
                        let workingURL = try writeWorkingCopy(importData, originalFilename: src.lastPathComponent)
                        await setEncryptedURL(encryptedURL, forWorkingURL: workingURL)
                        await SQLiteObjectStore.shared.storeObjectData(
                            importData,
                            originalURL: src,
                            contentHash: sourceHash,
                            contentTypeIdentifier: contentType?.identifier
                        )
                        logger.log("vault import:file success source=\(src.lastPathComponent, privacy: .public) encrypted=\(encryptedURL.lastPathComponent, privacy: .public)")
                        return (idx, .stored(workingURL))
                    } catch {
                        try? FileManager.default.removeItem(at: encryptedURL)
                        if ignoreDuplicates {
                            await reservations.release(sourceHash)
                        }
                        logger.error("vault import:file failed source=\(src.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                        return (idx, .failed)
                    }
                }
            }

            let initial = min(workers, totalCount)
            for _ in 0..<initial {
                startTask(at: nextIndex)
                nextIndex += 1
            }

            while let result = await group.next() {
                completedCount += 1
                let (idx, outcome) = result
                let src = urls[idx]
                switch outcome {
                case .stored(let url):
                    collected.append((idx, url))
                case .duplicate:
                    duplicateCount += 1
                case .failed:
                    failedCount += 1
                }
                await progress?(completedCount, totalCount, src.lastPathComponent)

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if nextIndex < totalCount {
                    startTask(at: nextIndex)
                    nextIndex += 1
                }
            }
        }

        collected.sort { $0.0 < $1.0 }
        let workingURLs = collected.map { $0.1 }
        logger.log("vault import:finished requested=\(totalCount, privacy: .public) stored=\(workingURLs.count, privacy: .public) duplicates=\(duplicateCount, privacy: .public) failed=\(failedCount, privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)")
        return PhotoVaultImportResult(workingURLs: workingURLs, duplicateCount: duplicateCount, failedCount: failedCount)
    }

    func loadWorkingCopies(
        progress: (@Sendable (Int, Int, String, [URL]) async -> Void)? = nil
    ) async throws -> [URL] {
        let destination = try vaultLocation()
        let activeKey = try unlockedKey()
        try clearWorkingDirectory()
        let contents = try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let encryptedFiles = contents
            .filter { $0.pathExtension == Self.encryptedExtension }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        let totalCount = encryptedFiles.count
        let workers = max(1, min(totalCount, Self.importWorkerCount))
        logger.log("loadWorkingCopies:start location=\(destination.path, privacy: .public) encryptedFiles=\(totalCount, privacy: .public) workers=\(workers, privacy: .public)")

        struct LoadResult: Sendable {
            let index: Int
            let encryptedURL: URL
            let workingURL: URL?
            let contentHash: String?
            let errorDescription: String?
        }

        var collected: [(Int, URL)] = []
        var workingMapUpdates: [String: String] = [:]
        var hashesToRegister: [String] = []
        var pendingProgressURLs: [URL] = []
        var completedCount = 0
        var failedCount = 0

        await withTaskGroup(of: LoadResult.self) { group in
            var nextIndex = 0

            func startTask(at index: Int) {
                let encryptedURL = encryptedFiles[index]
                group.addTask { [self] in
                    if Task.isCancelled {
                        return LoadResult(index: index, encryptedURL: encryptedURL, workingURL: nil, contentHash: nil, errorDescription: "Cancelled")
                    }
                    do {
                        let (data, header) = try decryptPayload(at: encryptedURL, key: activeKey)
                        let workingURL = try writeWorkingCopy(data, originalFilename: header.originalFilename)
                        let hash = header.contentHash ?? Self.contentHash(of: data)
                        return LoadResult(index: index, encryptedURL: encryptedURL, workingURL: workingURL, contentHash: hash, errorDescription: nil)
                    } catch {
                        return LoadResult(index: index, encryptedURL: encryptedURL, workingURL: nil, contentHash: nil, errorDescription: error.localizedDescription)
                    }
                }
            }

            let initial = min(workers, totalCount)
            for _ in 0..<initial {
                startTask(at: nextIndex)
                nextIndex += 1
            }

            while let result = await group.next() {
                completedCount += 1
                if let workingURL = result.workingURL {
                    collected.append((result.index, workingURL))
                    workingMapUpdates[workingURL.path] = result.encryptedURL.path
                    pendingProgressURLs.append(workingURL)
                    if let contentHash = result.contentHash {
                        hashesToRegister.append(contentHash)
                    }
                } else {
                    failedCount += 1
                    if let errorDescription = result.errorDescription {
                        logger.error("loadWorkingCopies: failed for \(result.encryptedURL.lastPathComponent, privacy: .public): \(errorDescription, privacy: .public)")
                    }
                }

                if pendingProgressURLs.count >= 128 || completedCount == totalCount {
                    let batch = pendingProgressURLs
                    pendingProgressURLs.removeAll(keepingCapacity: true)
                    await progress?(completedCount, totalCount, result.encryptedURL.lastPathComponent, batch)
                } else if completedCount % 128 == 0 {
                    await progress?(completedCount, totalCount, result.encryptedURL.lastPathComponent, [])
                }

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if nextIndex < totalCount {
                    startTask(at: nextIndex)
                    nextIndex += 1
                }
            }
        }
        setEncryptedURLs(workingMapUpdates)
        registerContentHashes(hashesToRegister)
        collected.sort { $0.0 < $1.0 }
        let urls = collected.map { $0.1 }
        logger.log("loadWorkingCopies:finished loaded=\(urls.count, privacy: .public) failed=\(failedCount, privacy: .public) total=\(totalCount, privacy: .public) cancelled=\(Task.isCancelled, privacy: .public)")
        return urls
    }

    func exportFiles(_ workingURLs: [URL], to folder: URL) async throws -> Int {
        let activeKey = try unlockedKey()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var count = 0
        for workingURL in workingURLs {
            if Task.isCancelled { break }
            if let encryptedURL = encryptedURL(forWorkingURL: workingURL) {
                let (data, header) = try decryptPayload(at: encryptedURL, key: activeKey)
                let outputURL = uniquePlainURL(for: header.originalFilename, in: folder)
                try data.write(to: outputURL, options: .atomic)
                count += 1
            } else {
                let outputURL = uniquePlainURL(for: workingURL.lastPathComponent, in: folder)
                try FileManager.default.copyItem(at: workingURL, to: outputURL)
                count += 1
            }
        }
        return count
    }

    func reencryptWorkingCopyIfNeeded(_ workingURL: URL, sourceWorkingURL: URL? = nil) async {
        guard let activeKey = key else { return }
        guard let location = resolvedLocationURL() else { return }
        let existing = encryptedURL(forWorkingURL: workingURL) ?? sourceWorkingURL.flatMap { encryptedURL(forWorkingURL: $0) }
        let destinationURL = existing ?? uniqueEncryptedURL(for: workingURL.lastPathComponent, in: location)
        do {
            try encryptFile(at: workingURL, to: destinationURL, key: activeKey)
            setEncryptedURL(destinationURL, forWorkingURL: workingURL)
        } catch {
            logger.error("reencryptWorkingCopyIfNeeded: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteEncryptedCounterpartIfNeeded(for workingURL: URL) {
        guard let encryptedURL = encryptedURL(forWorkingURL: workingURL) else { return }
        // Release the content hash so a future re-import of the same content
        // is allowed. Prefer the header-recorded hash; fall back to hashing
        // the decrypted payload if needed.
        if let activeKey = key,
           let (data, header) = try? decryptPayload(at: encryptedURL, key: activeKey) {
            releaseContentHash(header.contentHash ?? Self.contentHash(of: data))
        }
        try? FileManager.default.removeItem(at: encryptedURL)
        removeMapping(forWorkingURL: workingURL)
    }

    func clearWorkingCopiesForShutdown() {
        Self.clearWorkingCopiesOnDisk()
    }

    // MARK: - Content-hash dedup

    nonisolated static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func loadContentHashes() -> Set<String> {
        let fileHashes: Set<String>
        if let data = try? Data(contentsOf: contentHashesFileURL()),
           let hashes = try? JSONDecoder().decode([String].self, from: data) {
            fileHashes = Set(hashes)
        } else {
            fileHashes = []
        }

        let legacyHashes = Set(UserDefaults.standard.array(forKey: Self.contentHashesKey) as? [String] ?? [])
        guard !legacyHashes.isEmpty else { return fileHashes }

        let merged = fileHashes.union(legacyHashes)
        persistContentHashes(merged)
        UserDefaults.standard.removeObject(forKey: Self.contentHashesKey)
        logger.log("contentHash index:migrated legacyCount=\(legacyHashes.count, privacy: .public) total=\(merged.count, privacy: .public)")
        return merged
    }

    private nonisolated func persistContentHashes(_ hashes: Set<String>) {
        do {
            let fileURL = try contentHashesFileURL()
            let data = try JSONEncoder().encode(Array(hashes).sorted())
            try data.write(to: fileURL, options: .atomic)
            UserDefaults.standard.removeObject(forKey: Self.contentHashesKey)
        } catch {
            logger.error("contentHash index:persist failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated func contentHashesFileURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PictureViewer", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(Self.contentHashesFilename, isDirectory: false)
    }

    private func currentContentHashes() -> Set<String> {
        if let contentHashesCache {
            return contentHashesCache
        }
        let hashes = loadContentHashes()
        contentHashesCache = hashes
        return hashes
    }

    private func currentVaultContentHashes(in destination: URL, key: SymmetricKey) async -> Set<String> {
        guard let encryptedFiles = try? FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter({ $0.pathExtension == Self.encryptedExtension }) else {
            return []
        }

        let workers = max(1, min(encryptedFiles.count, Self.importWorkerCount))
        guard workers > 0 else { return [] }

        return await withTaskGroup(of: String?.self) { group in
            var hashes: Set<String> = []
            var nextIndex = 0

            func startTask(at index: Int) {
                let encryptedURL = encryptedFiles[index]
                group.addTask { [self] in
                    do {
                        let (data, header) = try decryptPayload(at: encryptedURL, key: key)
                        return header.contentHash ?? Self.contentHash(of: data)
                    } catch {
                        logger.error("vault duplicate scan: failed file=\(encryptedURL.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
            }

            let initial = min(workers, encryptedFiles.count)
            for _ in 0..<initial {
                startTask(at: nextIndex)
                nextIndex += 1
            }

            while let hash = await group.next() {
                if let hash {
                    hashes.insert(hash)
                }
                if nextIndex < encryptedFiles.count {
                    startTask(at: nextIndex)
                    nextIndex += 1
                }
            }

            return hashes
        }
    }

    private func persistContentHashesIfNeeded() {
        guard contentHashesNeedsSave, let contentHashesCache else { return }
        persistContentHashes(contentHashesCache)
        contentHashesNeedsSave = false
    }

    /// Atomically reserve a content hash. Returns true if the hash was newly
    /// added (caller may proceed with import); false if the hash was already
    /// known and the import should be skipped as a duplicate.
    func tryReserveContentHash(_ hash: String) -> Bool {
        var current = currentContentHashes()
        if current.contains(hash) { return false }
        current.insert(hash)
        contentHashesCache = current
        contentHashesNeedsSave = true
        return true
    }

    func releaseContentHash(_ hash: String) {
        var current = currentContentHashes()
        if current.remove(hash) != nil {
            contentHashesCache = current
            contentHashesNeedsSave = true
            persistContentHashesIfNeeded()
        }
    }

    func releaseReservedContentHash(_ hash: String) {
        var current = currentContentHashes()
        if current.remove(hash) != nil {
            contentHashesCache = current
            contentHashesNeedsSave = true
        }
    }

    private func registerContentHashes(_ hashes: [String]) {
        guard !hashes.isEmpty else { return }
        var current = currentContentHashes()
        let before = current.count
        current.formUnion(hashes)
        if current.count != before {
            contentHashesCache = current
            contentHashesNeedsSave = true
            persistContentHashesIfNeeded()
        }
    }

    private func registerContentHash(_ hash: String) {
        var current = currentContentHashes()
        if current.insert(hash).inserted {
            contentHashesCache = current
            contentHashesNeedsSave = true
        }
    }

    private nonisolated func dataByAppendingKeywordsIfPossible(_ keywords: [String], to data: Data, contentType: UTType?) throws -> Data {
        let normalizedKeywords = Self.normalizedKeywords(keywords)
        guard !normalizedKeywords.isEmpty else { return data }
        guard contentType?.conforms(to: .image) == true else { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            throw PhotoVaultError.unsupportedFile
        }

        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        var iptc = (metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        let existingKeywords = Self.keywordStrings(from: iptc[kCGImagePropertyIPTCKeywords])
        iptc[kCGImagePropertyIPTCKeywords] = Self.mergedKeywords(existingKeywords, normalizedKeywords) as CFArray
        metadata[kCGImagePropertyIPTCDictionary] = iptc as CFDictionary

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw PhotoVaultError.unsupportedFile
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoVaultError.unsupportedFile
        }
        return output as Data
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

    private nonisolated static func normalizedKeywords(_ keywords: [String]) -> [String] {
        mergedKeywords([], keywords)
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

    private nonisolated func encryptFile(at sourceURL: URL, to encryptedURL: URL, key: SymmetricKey) throws {
        let values = try sourceURL.resourceValues(forKeys: [.contentTypeKey])
        guard PhotoLibrary.isSupportedMediaFile(sourceURL, contentType: values.contentType) else {
            throw PhotoVaultError.unsupportedFile
        }
        let data = try Data(contentsOf: sourceURL)
        let hash = Self.contentHash(of: data)
        try encryptData(
            data,
            originalFilename: sourceURL.lastPathComponent,
            contentTypeIdentifier: values.contentType?.identifier,
            contentHash: hash,
            to: encryptedURL,
            key: key
        )
        try preserveFileDates(from: sourceURL, to: encryptedURL)
    }

    private nonisolated func encryptData(
        _ data: Data,
        originalFilename: String,
        contentTypeIdentifier: String?,
        contentHash: String?,
        to encryptedURL: URL,
        key: SymmetricKey
    ) throws {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw PhotoVaultError.invalidEncryptedFile }
        let header = Header(
            version: 1,
            originalFilename: originalFilename,
            originalRelativePath: nil,
            importedAt: Date(),
            contentTypeIdentifier: contentTypeIdentifier,
            contentHash: contentHash
        )
        let headerData = try JSONEncoder().encode(header)
        var output = Data()
        output.append(magic)
        var length = UInt32(headerData.count).bigEndian
        output.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        output.append(headerData)
        output.append(combined)

        let tempURL = encryptedURL.deletingLastPathComponent()
            .appendingPathComponent(".pvtmp-\(UUID().uuidString)")
            .appendingPathExtension(Self.encryptedExtension)
        try output.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: encryptedURL.path) {
            try FileManager.default.removeItem(at: encryptedURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: encryptedURL)
    }

    private nonisolated func preserveFileDates(from sourceURL: URL, to destinationURL: URL) throws {
        let sourceValues = try sourceURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        var destinationValues = URLResourceValues()
        destinationValues.creationDate = sourceValues.creationDate
        destinationValues.contentModificationDate = sourceValues.contentModificationDate

        var mutableDestinationURL = destinationURL
        try mutableDestinationURL.setResourceValues(destinationValues)
    }

    private nonisolated func decryptFile(at encryptedURL: URL, key: SymmetricKey) throws -> URL {
        let (data, header) = try decryptPayload(at: encryptedURL, key: key)
        return try writeWorkingCopy(data, originalFilename: header.originalFilename)
    }

    private nonisolated func writeWorkingCopy(_ data: Data, originalFilename: String) throws -> URL {
        let workingURL = try uniqueWorkingURL(for: originalFilename)
        try data.write(to: workingURL, options: .atomic)
        return workingURL
    }

    private nonisolated func decryptPayload(at encryptedURL: URL, key: SymmetricKey) throws -> (Data, Header) {
        let fileData = try Data(contentsOf: encryptedURL)
        guard fileData.count > magic.count + MemoryLayout<UInt32>.size,
              fileData.prefix(magic.count) == magic
        else {
            throw PhotoVaultError.invalidEncryptedFile
        }
        let lengthStart = magic.count
        let lengthEnd = lengthStart + MemoryLayout<UInt32>.size
        let length = fileData[lengthStart..<lengthEnd].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let headerStart = lengthEnd
        let headerEnd = headerStart + Int(length)
        guard headerEnd < fileData.count else { throw PhotoVaultError.invalidEncryptedFile }
        let header = try JSONDecoder().decode(Header.self, from: fileData[headerStart..<headerEnd])
        let sealedBox = try AES.GCM.SealedBox(combined: fileData[headerEnd...])
        let data = try AES.GCM.open(sealedBox, using: key)
        return (data, header)
    }

    private func vaultLocation() throws -> URL {
        guard let url = resolvedLocationURL() else { throw PhotoVaultError.locationMissing }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func unlockedKey() throws -> SymmetricKey {
        guard let key else { throw PhotoVaultError.passwordMissing }
        return key
    }

    private func resolvedLocationURL() -> URL? {
        if let locationURL { return locationURL }
        guard let bookmark = UserDefaults.standard.data(forKey: Self.locationBookmarkKey) else { return nil }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            _ = url.startAccessingSecurityScopedResource()
            locationURL = url
            return url
        } catch {
            return nil
        }
    }

    private func registerKnownVault(_ url: URL) throws {
        let newPath = url.standardizedFileURL.path
        var bookmarks = knownVaultBookmarkData()
        let alreadyKnown = bookmarks.contains { bookmark in
            guard let resolvedURL = resolveBookmark(bookmark) else { return false }
            return resolvedURL.standardizedFileURL.path == newPath
        }
        guard !alreadyKnown else { return }

        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        bookmarks.append(bookmark)
        UserDefaults.standard.set(bookmarks, forKey: Self.knownVaultBookmarksKey)
    }

    private func knownVaultBookmarkData() -> [Data] {
        UserDefaults.standard.array(forKey: Self.knownVaultBookmarksKey) as? [Data] ?? []
    }

    private func resolveBookmark(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    private nonisolated func workingDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PictureViewer/VaultWorking", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func clearWorkingDirectory() throws {
        let directory = try workingDirectory()
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
        removeWorkingMap()
    }

    private nonisolated func uniqueWorkingURL(for filename: String) throws -> URL {
        // Give each decrypted file its own subdirectory so the working copy
        // keeps the exact original filename. This preserves the name shown
        // throughout the UI (and the name that round-trips back into the
        // vault header on re-encrypt) while still avoiding collisions when
        // multiple vault files share the same original name.
        let base = try workingDirectory()
        let cleanName = filename.isEmpty ? "photo" : filename
        let subdir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        return subdir.appendingPathComponent(cleanName)
    }

    private nonisolated func uniquePlainURL(for filename: String, in folder: URL) -> URL {
        let cleanName = filename.isEmpty ? "photo" : filename
        let base = URL(fileURLWithPath: cleanName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: cleanName).pathExtension
        var candidate = folder.appendingPathComponent(cleanName)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = "\(base)-\(index)"
            candidate = folder.appendingPathComponent(name)
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            index += 1
        }
        return candidate
    }

    private nonisolated func uniqueEncryptedURL(for filename: String, in folder: URL) -> URL {
        let cleanName = filename.isEmpty ? "photo" : URL(fileURLWithPath: filename).lastPathComponent
        let sourceURL = URL(fileURLWithPath: cleanName)
        let base = sourceURL.deletingPathExtension().lastPathComponent.isEmpty
            ? "photo"
            : sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var index = 0

        while true {
            let suffix = index == 0 ? "" : "-\(index)"
            var preservedName = "\(base)\(suffix)"
            if !ext.isEmpty {
                preservedName += ".\(ext)"
            }

            let candidate = folder
                .appendingPathComponent(preservedName)
                .appendingPathExtension(Self.encryptedExtension)

            if FileManager.default.createFile(atPath: candidate.path, contents: nil) {
                return candidate
            }

            index += 1
        }
    }

    private nonisolated func isSupportedMediaFile(_ url: URL) -> Bool {
        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        return PhotoLibrary.isSupportedMediaFile(url, contentType: contentType)
    }

    private func encryptedURL(forWorkingURL workingURL: URL) -> URL? {
        workingMap()[workingURL.path].map { URL(fileURLWithPath: $0) }
    }

    private func setEncryptedURL(_ encryptedURL: URL, forWorkingURL workingURL: URL) {
        var map = workingMap()
        map[workingURL.path] = encryptedURL.path
        persistWorkingMap(map)
    }

    private func setEncryptedURLs(_ updates: [String: String]) {
        guard !updates.isEmpty else { return }
        var map = workingMap()
        map.merge(updates) { _, new in new }
        persistWorkingMap(map)
    }

    private func removeMapping(forWorkingURL workingURL: URL) {
        var map = workingMap()
        map.removeValue(forKey: workingURL.path)
        persistWorkingMap(map)
    }

    private func workingMap() -> [String: String] {
        let fileMap: [String: String]
        if let data = try? Data(contentsOf: Self.workingMapFileURL()),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            fileMap = map
        } else {
            fileMap = [:]
        }

        guard let legacyMap = UserDefaults.standard.dictionary(forKey: Self.workingMapKey) as? [String: String],
              !legacyMap.isEmpty
        else {
            return fileMap
        }

        var merged = fileMap
        merged.merge(legacyMap) { current, _ in current }
        persistWorkingMap(merged)
        UserDefaults.standard.removeObject(forKey: Self.workingMapKey)
        logger.log("workingMap:migrated legacyCount=\(legacyMap.count, privacy: .public) total=\(merged.count, privacy: .public)")
        return merged
    }

    private func persistWorkingMap(_ map: [String: String]) {
        do {
            let data = try JSONEncoder().encode(map)
            try data.write(to: Self.workingMapFileURL(), options: .atomic)
            UserDefaults.standard.removeObject(forKey: Self.workingMapKey)
        } catch {
            logger.error("workingMap:persist failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeWorkingMap() {
        try? FileManager.default.removeItem(at: Self.workingMapFileURL())
        UserDefaults.standard.removeObject(forKey: Self.workingMapKey)
    }

    private nonisolated static func workingMapFileURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PictureViewer", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(Self.workingMapFilename, isDirectory: false)
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private func deriveKeyData(password: String, salt: Data, iterations: Int) -> Data {
        var data = Data()
        data.append(salt)
        data.append(Data(password.utf8))
        for _ in 0..<iterations {
            data = Data(SHA256.hash(data: data))
        }
        return data
    }
}
