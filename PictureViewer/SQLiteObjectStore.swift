//
//  SQLiteObjectStore.swift
//  PictureViewer
//

import Foundation
import AppKit
import CryptoKit
import ImageIO
import SQLite3
import Security
import UniformTypeIdentifiers
import os

enum SQLiteObjectStoreError: LocalizedError {
    case directoryMissing
    case passwordMissing
    case databaseOpenFailed
    case databaseWriteFailed(reason: String? = nil)
    case databaseReadFailed

    var errorDescription: String? {
        switch self {
        case .directoryMissing: "Create or open a SQLite object store first."
        case .passwordMissing: "The SQLite object-store encryption key could not be created."
        case .databaseOpenFailed: "The SQLite object database could not be opened."
        case .databaseWriteFailed(let reason):
            if let reason, !reason.isEmpty {
                "The SQLite object database could not be written: \(reason)"
            } else {
                "The SQLite object database could not be written."
            }
        case .databaseReadFailed: "The SQLite object database could not be read."
        }
    }
}

/// Synchronous in-memory registry of hydrated SQLite thumbnail JPEG bytes.
/// Lets grid cells peek thumbnails without awaiting the actor during batch hydration.
enum HydratedThumbnailJPEGRegistry {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var dataByURLPath: [String: Data] = [:]

    nonisolated static func store(_ data: Data, for url: URL) {
        guard !data.isEmpty else { return }
        let key = url.standardizedFileURL.path
        lock.lock()
        dataByURLPath[key] = data
        lock.unlock()
    }

    nonisolated static func peek(for url: URL) -> Data? {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return dataByURLPath[key]
    }

    nonisolated static func remove(for url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock()
        dataByURLPath.removeValue(forKey: key)
        lock.unlock()
    }
}

actor SQLiteObjectStore {
    static let shared = SQLiteObjectStore()

    static let enabledKey = "sqliteObjectStoreEnabled"
    static let encryptBlobsKey = "sqliteObjectStoreEncryptBlobs"
    static let directoryBookmarkKey = "sqliteObjectStoreDirectoryBookmark"
    static let directoryPathKey = "sqliteObjectStoreDirectoryPath"
    static let databaseBookmarkKey = "sqliteObjectStoreDatabaseBookmark"
    static let databasePathKey = "sqliteObjectStoreDatabasePath"
    static let passwordSaltKey = "sqliteObjectStorePasswordSalt"
    static let passwordVerifierKey = "sqliteObjectStorePasswordVerifier"
    static let storeNameKey = "sqliteObjectStoreName"
    static let defaultStoreName = "PictureViewerObjects"

    private nonisolated static let keychainService = "com.fiospace.PictureViewer.sqliteObjectStore"
    private nonisolated static let keychainAccount = "objectStoreAccessKey"
    private nonisolated let logger = Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
    private let keyIterations = 120_000

    private struct ObjectWorkingFileRow: Sendable {
        let id: Int64
        let filename: String
        let fileExtension: String?
        let contentHash: String?
        let isEncrypted: Bool
        let outputURL: URL
    }

    private struct LazyWorkingFile: Sendable {
        let id: Int64
        let originalFilename: String
        let fileExtension: String?
        let contentHash: String?
        let isEncrypted: Bool
        let dbURL: URL
    }

    private struct StoreManifestEntry: Codable, Sendable {
        let id: Int64
        let filename: String
        let fileExtension: String?
        let isEncrypted: Bool
        let contentHash: String?
    }

    private struct StoreManifest: Codable, Sendable {
        static let currentVersion = 1

        let version: Int
        let storeName: String
        let databasePath: String
        let databaseModifiedAt: TimeInterval
        let databaseFileSize: Int?
        let entries: [StoreManifestEntry]
    }

    struct StoredObjectMetadata: Sendable {
        let description: String?
        let keywords: [String]
    }

    struct ExtractedObjectMetadata: Sendable {
        let contentType: String?
        let pixelWidth: Int?
        let pixelHeight: Int?
        let keywords: [String]
        let description: String?
    }

    struct PendingObject: Sendable {
        let objectData: Data
        let originalURL: URL
        let contentHash: String
        let contentTypeIdentifier: String?
        let thumbnailData: Data?
        let extractedMetadata: ExtractedObjectMetadata?
        let sourceFileSize: Int?
        let sourceCreatedAt: Date?
        let sourceModifiedAt: Date?

        init(
            objectData: Data,
            originalURL: URL,
            contentHash: String,
            contentTypeIdentifier: String?,
            thumbnailData: Data?,
            extractedMetadata: ExtractedObjectMetadata? = nil,
            sourceFileSize: Int? = nil,
            sourceCreatedAt: Date? = nil,
            sourceModifiedAt: Date? = nil
        ) {
            self.objectData = objectData
            self.originalURL = originalURL
            self.contentHash = contentHash
            self.contentTypeIdentifier = contentTypeIdentifier
            self.thumbnailData = thumbnailData
            self.extractedMetadata = extractedMetadata
            self.sourceFileSize = sourceFileSize
            self.sourceCreatedAt = sourceCreatedAt
            self.sourceModifiedAt = sourceModifiedAt
        }
    }

    private struct LoadedStoreContext {
        let dbURL: URL
        var lazyWorkingFiles: [String: LazyWorkingFile] = [:]
        var lazyWorkingURLsByID: [Int64: URL] = [:]
        var lazyWorkingThumbnailOrder: [Int64] = []
        var displayFilenamesLowercased: Set<String> = []
        var thumbnailsHydrated = false
        var metadataCacheByObjectID: [Int64: StoredObjectMetadata] = [:]
        var thumbnailJPEGDataByObjectID: [Int64: Data] = [:]
    }

    private struct MaterializePlan: Sendable {
        let url: URL
        let objectID: Int64
        let isEncrypted: Bool
        let dbURL: URL
        let keyData: Data?
    }

    private struct ThumbnailRow: Sendable {
        let objectID: Int64
        let url: URL
        let data: Data
    }

    private static let playbackMaterializeThresholdBytes = 4 * 1024 * 1024
    private static let materializeStreamChunkBytes = 1024 * 1024
    private nonisolated static let noopPlaybackReady: @Sendable () -> Void = {}

    private final class MaterializePlaybackSignal: @unchecked Sendable {
        static let shared = MaterializePlaybackSignal()
        private let lock = NSLock()
        nonisolated(unsafe) private var ready: [String: URL] = [:]

        nonisolated func mark(key: String, url: URL) {
            lock.lock()
            ready[key] = url
            lock.unlock()
        }

        nonisolated func url(for key: String) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return ready[key]
        }

        nonisolated func remove(key: String) {
            lock.lock()
            ready.removeValue(forKey: key)
            lock.unlock()
        }
    }

    private var loadedStoreContexts: [String: LoadedStoreContext] = [:]
    private var materializeTasks: [String: Task<URL, Error>] = [:]
    private var sessionReadDBURL: URL?
    private var sessionReadDBHandle: OpaquePointer?
    private var sessionReadDBSecurityScoped = false

    private struct SyncWriteSession {
        let dbURL: URL
        let db: OpaquePointer
        let upsertStatement: OpaquePointer
        let shouldEncrypt: Bool
        let keyData: Data?
        let securityScopedStarted: Bool
    }

    private var syncWriteSession: SyncWriteSession?
    /// Bumped when sync needs exclusive store access; in-flight thumbnail hydration cooperatively exits.
    private var hydrationGeneration: UInt64 = 0
    /// Off-actor hydration reads keep their own sqlite handles; drain before opening write sessions.
    private var hydrationDatabaseReaders = 0
    private var hydrationDatabaseReaderDrainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Shared with in-flight hydration queries so sync can call sqlite3_interrupt and
    /// unblock a full-table scan instead of waiting up to 2 minutes for it to finish.
    private let hydrationInterruptHandle = InterruptibleDatabaseHandle()

    final class InterruptibleDatabaseHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var db: OpaquePointer?

        func register(_ handle: OpaquePointer?) {
            lock.lock()
            db = handle
            lock.unlock()
        }

        func interrupt() {
            lock.lock()
            let handle = db
            lock.unlock()
            if let handle {
                sqlite3_interrupt(handle)
            }
        }
    }

    private init() {}

    private func storeContextKey(for dbURL: URL) -> String {
        dbURL.standardizedFileURL.path
    }

    private func findLazyFile(for url: URL) -> (dbKey: String, file: LazyWorkingFile)? {
        let workingKey = Self.workingCopyKey(for: url)
        for (dbKey, context) in loadedStoreContexts {
            if let file = context.lazyWorkingFiles[workingKey] {
                return (dbKey, file)
            }
            for registeredURL in context.lazyWorkingURLsByID.values {
                guard Self.workingCopyKey(for: registeredURL) == workingKey,
                      let file = context.lazyWorkingFiles[Self.workingCopyKey(for: registeredURL)] else {
                    continue
                }
                return (dbKey, file)
            }
        }
        return nil
    }

    private func clearStoreContextCaches(for dbURL: URL) {
        let dbKey = storeContextKey(for: dbURL)
        guard var context = loadedStoreContexts[dbKey] else { return }
        context.metadataCacheByObjectID.removeAll()
        context.thumbnailJPEGDataByObjectID.removeAll(keepingCapacity: true)
        context.thumbnailsHydrated = false
        loadedStoreContexts[dbKey] = context
    }

    nonisolated static var isEnabled: Bool {
        true
    }

    nonisolated static var encryptsBlobs: Bool {
        UserDefaults.standard.bool(forKey: encryptBlobsKey)
    }

    nonisolated static var configuredDirectoryPath: String? {
        UserDefaults.standard.string(forKey: directoryPathKey)
    }

    nonisolated static var hasPassword: Bool {
        true
    }

    nonisolated static var configuredStoreName: String {
        let raw = UserDefaults.standard.string(forKey: storeNameKey) ?? defaultStoreName
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultStoreName : trimmed
    }

    nonisolated static var configuredDatabaseFilename: String {
        databaseFilename(forStoreName: configuredStoreName)
    }

    nonisolated static func databaseFilename(forStoreName storeName: String) -> String {
        let raw = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (raw.isEmpty ? defaultStoreName : raw)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return name.hasSuffix(".sqlite") ? name : "\(name).sqlite"
    }

    nonisolated static func normalizedStoreName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultStoreName }
        let lowered = trimmed.lowercased()
        if lowered.hasSuffix(".sqlite3") {
            return String(trimmed.dropLast(8))
        }
        if lowered.hasSuffix(".sqlite") {
            return String(trimmed.dropLast(7))
        }
        if lowered.hasSuffix(".db") {
            return String(trimmed.dropLast(3))
        }
        return trimmed
    }

    nonisolated static func storeNamesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return normalizedStoreName(lhs) == normalizedStoreName(rhs)
    }

    nonisolated static func openToken(storeName: String, requestID: UUID) -> String {
        "\(normalizedStoreName(storeName))|\(requestID.uuidString)"
    }

    nonisolated static func storeName(fromOpenToken token: String) -> String {
        let base = token.split(separator: "|", maxSplits: 1).first.map(String.init) ?? token
        return normalizedStoreName(base)
    }

    nonisolated static func requestID(fromOpenToken token: String) -> UUID? {
        guard let idPart = token.split(separator: "|", maxSplits: 1).dropFirst().first else { return nil }
        return UUID(uuidString: String(idPart))
    }

    func setDirectory(_ url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: Self.directoryBookmarkKey)
        UserDefaults.standard.set(url.path, forKey: Self.directoryPathKey)
    }

    func setDatabaseFile(_ url: URL) throws {
        guard SecurityScopedResourceAccess.ensureAccess(for: url) else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        _ = SecurityScopedResourceAccess.ensureAccess(for: url.deletingLastPathComponent())

        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: Self.databaseBookmarkKey)
        UserDefaults.standard.set(url.path, forKey: Self.databasePathKey)
        try persistDirectoryReference(for: url.deletingLastPathComponent())
        UserDefaults.standard.set(Self.normalizedStoreName(url.deletingPathExtension().lastPathComponent), forKey: Self.storeNameKey)
    }

    func createDatabaseFile(_ url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        let db = try openDatabaseConnection(at: url, flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        do {
            try Self.createSchema(in: db)
        } catch {
            sqlite3_close(db)
            throw error
        }
        sqlite3_close(db)

        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: Self.databaseBookmarkKey)
        UserDefaults.standard.set(url.path, forKey: Self.databasePathKey)
        try persistDirectoryReference(for: url.deletingLastPathComponent())
        UserDefaults.standard.set(Self.normalizedStoreName(url.deletingPathExtension().lastPathComponent), forKey: Self.storeNameKey)
    }

    func setPassword(_ password: String) throws {
        guard !password.isEmpty else { throw SQLiteObjectStoreError.passwordMissing }
        let salt = randomData(count: 16)
        let keyData = deriveKeyData(password: password, salt: salt)
        let verifier = Data(SHA256.hash(data: keyData + Data("sqlite-object-verifier".utf8)))
        UserDefaults.standard.set(salt, forKey: Self.passwordSaltKey)
        UserDefaults.standard.set(verifier, forKey: Self.passwordVerifierKey)
        try Self.storeKeychainKeyData(keyData)
    }

    func storeObjectData(
        _ objectData: Data,
        originalURL: URL,
        contentHash: String,
        contentTypeIdentifier: String?,
        thumbnailData: Data? = nil
    ) async {
        do {
            try storeObjectDataThrowing(
                objectData,
                originalURL: originalURL,
                contentHash: contentHash,
                contentTypeIdentifier: contentTypeIdentifier,
                thumbnailData: thumbnailData
            )
        } catch {
            logger.error("sqlite object store: failed filename=\(originalURL.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func storeObjectDataThrowing(
        _ objectData: Data,
        originalURL: URL,
        contentHash: String,
        contentTypeIdentifier: String?,
        thumbnailData: Data? = nil,
        storeName: String? = nil,
        replacingObjectID: Int64? = nil,
        databaseURL: URL? = nil
    ) throws {
        guard Self.isEnabled else { return }
        let lazyFile = findLazyFile(for: originalURL)?.file
        let dbURL = try databaseURL ?? lazyFile?.dbURL ?? resolvedDatabaseURL(storeName: storeName)
        invalidateSessionReadConnection()
        clearStoreContextCaches(for: dbURL)
        let shouldEncrypt = Self.encryptsBlobs
        let storedData: Data
        if shouldEncrypt {
            let keyData = try accessKeyData()
            guard let combined = try AES.GCM.seal(objectData, using: SymmetricKey(data: keyData)).combined else {
                throw SQLiteObjectStoreError.databaseWriteFailed()
            }
            storedData = combined
        } else {
            storedData = objectData
        }
        let objectIDToReplace = replacingObjectID ?? lazyFile?.id
        let objectMetadata = Self.objectMetadata(from: objectData, originalURL: originalURL, contentTypeIdentifier: contentTypeIdentifier)
        let fileValues = try? originalURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
        try withDatabase(at: dbURL) { db in
            try Self.createSchema(in: db)
            let objectID: Int64
            if let objectIDToReplace {
                try Self.updateObject(
                    in: db,
                    objectID: objectIDToReplace,
                    filename: originalURL.lastPathComponent,
                    originalPath: originalURL.path,
                    contentHash: contentHash,
                    contentTypeIdentifier: objectMetadata.contentType,
                    fileExtension: originalURL.pathExtension,
                    fileSize: fileValues?.fileSize ?? objectData.count,
                    pixelWidth: objectMetadata.pixelWidth,
                    pixelHeight: objectMetadata.pixelHeight,
                    description: objectMetadata.description,
                    createdAt: fileValues?.creationDate,
                    modifiedAt: fileValues?.contentModificationDate,
                    importedAt: Date(),
                    isEncrypted: shouldEncrypt,
                    blobData: storedData,
                    thumbnailData: thumbnailData
                )
                objectID = objectIDToReplace
            } else {
                objectID = try Self.upsertObject(
                    in: db,
                    filename: originalURL.lastPathComponent,
                    originalPath: originalURL.path,
                    contentHash: contentHash,
                    contentTypeIdentifier: objectMetadata.contentType,
                    fileExtension: originalURL.pathExtension,
                    fileSize: fileValues?.fileSize ?? objectData.count,
                    pixelWidth: objectMetadata.pixelWidth,
                    pixelHeight: objectMetadata.pixelHeight,
                    description: objectMetadata.description,
                    createdAt: fileValues?.creationDate,
                    modifiedAt: fileValues?.contentModificationDate,
                    importedAt: Date(),
                    isEncrypted: shouldEncrypt,
                    blobData: storedData,
                    thumbnailData: thumbnailData
                )
            }
            try Self.replaceKeywords(objectMetadata.keywords, forObjectID: objectID, in: db)
        }
        logger.log("sqlite object store: stored filename=\(originalURL.lastPathComponent, privacy: .public) encrypted=\(shouldEncrypt, privacy: .public) replacedExisting=\(objectIDToReplace != nil, privacy: .public)")
    }

    func storeObjectBatchThrowing(_ objects: [PendingObject], storeName: String? = nil) throws -> Int {
        guard Self.isEnabled, !objects.isEmpty else { return 0 }
        if syncWriteSession != nil {
            return try appendToSyncWriteSession(objects)
        }
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        try ensureWritableDatabaseAccess(for: dbURL)
        invalidateSessionReadConnection()
        clearStoreContextCaches(for: dbURL)
        let batchStart = Date()
        let shouldEncrypt = Self.encryptsBlobs
        let keyData = shouldEncrypt ? try accessKeyData() : nil
        var storedCount = 0

        try withDatabase(at: dbURL) { db in
            try Self.createSchema(in: db)
            try Self.exec("BEGIN IMMEDIATE TRANSACTION;", in: db)
            var upsertStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, Self.batchUpsertSQL, -1, &upsertStatement, nil) == SQLITE_OK,
                  let upsertStatement else {
                throw SQLiteObjectStoreError.databaseWriteFailed()
            }
            defer { sqlite3_finalize(upsertStatement) }

            do {
                for object in objects {
                    let objectID = try Self.storePendingObject(
                        object,
                        in: db,
                        statement: upsertStatement,
                        shouldEncrypt: shouldEncrypt,
                        keyData: keyData
                    )
                    let keywords = object.extractedMetadata?.keywords
                        ?? Self.objectMetadata(
                            from: object.objectData,
                            originalURL: object.originalURL,
                            contentTypeIdentifier: object.contentTypeIdentifier
                        ).keywords
                    try Self.replaceKeywords(keywords, forObjectID: objectID, in: db)
                    storedCount += 1
                }
                try Self.exec("COMMIT;", in: db)
            } catch {
                try? Self.exec("ROLLBACK;", in: db)
                throw error
            }
        }

        logger.log("sqlite object store: stored batch count=\(storedCount, privacy: .public) requested=\(objects.count, privacy: .public) encrypted=\(shouldEncrypt, privacy: .public) duration=\(Date().timeIntervalSince(batchStart), privacy: .public)")
        return storedCount
    }

    func storeObjectFile(at url: URL) async throws {
        guard Self.isEnabled else { return }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let lazyFile = findLazyFile(for: url)?.file
        let data = try Data(contentsOf: url)
        let contentHash = Self.contentHash(of: data)
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
            ?? UTType(filenameExtension: url.pathExtension)?.identifier
        let thumbnailData = await resolvedThumbnailData(for: url)
        try storeObjectDataThrowing(
            data,
            originalURL: url,
            contentHash: contentHash,
            contentTypeIdentifier: contentType,
            thumbnailData: thumbnailData,
            replacingObjectID: lazyFile?.id,
            databaseURL: lazyFile?.dbURL
        )
    }

    /// Returns a JPEG thumbnail for `url`, generating one on demand if the
    /// ThumbnailCache is cold. This matters for video formats whose thumbnail
    /// cascade takes time (e.g. .flv/.wmv must fall through QuickLook and
    /// AVFoundation before VLC can produce a frame), since sync may run
    /// before the grid view has populated the cache.
    nonisolated func cachedThumbnailJPEGData(for url: URL) -> Data? {
        ThumbnailCache.shared.cachedJPEGData(for: url)
    }

    nonisolated static func peekHydratedThumbnailJPEGData(for url: URL, namespace: String? = nil) -> Data? {
        _ = namespace
        return HydratedThumbnailJPEGRegistry.peek(for: url)
    }

    nonisolated static func extractObjectMetadata(
        from data: Data,
        originalURL: URL,
        contentTypeIdentifier: String?
    ) -> ExtractedObjectMetadata {
        let metadata = objectMetadata(from: data, originalURL: originalURL, contentTypeIdentifier: contentTypeIdentifier)
        return ExtractedObjectMetadata(
            contentType: metadata.contentType,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            keywords: metadata.keywords,
            description: metadata.description
        )
    }

    nonisolated static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Streams a source file to compute the object-store content hash without loading it into memory.
    nonisolated static func contentHash(ofFile url: URL) throws -> String {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: incrementalBlobWriteChunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Files larger than this are streamed to sidecar storage instead of inline SQLite blobs.
    nonisolated static let largeObjectStreamThresholdBytes = 2_000_000_000

    nonisolated func resolvedThumbnailData(for url: URL) async -> Data? {
        if let cached = await existingThumbnailJPEGDataFromSource(for: url) {
            return cached
        }
        do {
            let image = try await ThumbnailGenerator.shared.generateThumbnail(for: url)
            await MainActor.run { ThumbnailCache.shared.store(image, for: url) }
            return await MainActor.run { ThumbnailCache.jpegData(from: image) }
        } catch {
            if PhotoLibrary.isVideoMediaFile(url) {
                let fallback = await MainActor.run {
                    ThumbnailCache.jpegData(from: ThumbnailGenerator.genericVideoThumbnail(for: url))
                }
                if let fallback {
                    await MainActor.run { ThumbnailCache.shared.storeJPEGData(fallback, for: url) }
                    return fallback
                }
            }
            logger.error("sqlite object store: on-demand thumbnail failed url=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Thumbnail lookup for bulk SQLite sync. Reuses thumbnails already shown
    /// in the source tab (memory/disk cache or SQLite hydration). Never
    /// generates a new preview during sync — use Backfill for missing ones.
    nonisolated func resolvedThumbnailDataForSync(for url: URL) async -> Data? {
        await existingThumbnailJPEGDataFromSource(for: url)
    }

    private nonisolated func existingThumbnailJPEGDataFromSource(for url: URL) async -> Data? {
        let filename = url.lastPathComponent
        if let hydrated = Self.peekHydratedThumbnailJPEGData(for: url) {
            logger.log("sqlite sync thumbnail: source=hydrated-registry filename=\(filename, privacy: .public) bytes=\(hydrated.count, privacy: .public)")
            return hydrated
        }
        if let cached = cachedThumbnailJPEGData(for: url) {
            logger.log("sqlite sync thumbnail: source=memory-cache filename=\(filename, privacy: .public) bytes=\(cached.count, privacy: .public)")
            return cached
        }
        if let cached = await MainActor.run(body: { ThumbnailCache.shared.existingJPEGData(for: url) }) {
            logger.log("sqlite sync thumbnail: source=thumbnail-cache filename=\(filename, privacy: .public) bytes=\(cached.count, privacy: .public)")
            return cached
        }
        if Self.isWorkingCopyURL(url),
           let stored = await SQLiteObjectStore.shared.thumbnailJPEGData(forWorkingFile: url),
           !stored.isEmpty {
            logger.log("sqlite sync thumbnail: source=sqlite-blob filename=\(filename, privacy: .public) bytes=\(stored.count, privacy: .public)")
            return stored
        }
        logger.log("sqlite sync thumbnail: source=unavailable filename=\(filename, privacy: .public)")
        return nil
    }

    func thumbnailsNeedHydration(storeName: String? = nil) -> Bool {
        guard let dbURL = try? resolvedDatabaseURL(storeName: storeName) else { return false }
        let dbKey = storeContextKey(for: dbURL)
        return loadedStoreContexts[dbKey]?.thumbnailsHydrated == false
    }

    /// Returns which tab filenames already exist in the target store.
    /// Opens a short-lived read-only connection (no blobs, no actor session cache).
    func existingFilenamesAmongTabFilenames(
        _ tabFilenames: Set<String>,
        storeName: String? = nil,
        requestedAt: Date? = nil
    ) throws -> Set<String> {
        let checkStart = Date()
        guard Self.isEnabled, !tabFilenames.isEmpty else {
            logger.log("sqlite duplicate check: skipped empty tabFilenames duration=\(Date().timeIntervalSince(checkStart), privacy: .public)")
            return []
        }
        let effectiveStoreName = storeName ?? Self.configuredStoreName
        if let requestedAt {
            logger.log("sqlite duplicate check: begin store=\(effectiveStoreName, privacy: .public) tabFilenames=\(tabFilenames.count, privacy: .public) actorWait=\(Date().timeIntervalSince(requestedAt), privacy: .public)")
        } else {
            logger.log("sqlite duplicate check: begin store=\(effectiveStoreName, privacy: .public) tabFilenames=\(tabFilenames.count, privacy: .public)")
        }
        let resolveStart = Date()
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        logger.log("sqlite duplicate check: resolved database path=\(dbURL.path, privacy: .public) duration=\(Date().timeIntervalSince(resolveStart), privacy: .public) elapsed=\(Date().timeIntervalSince(checkStart), privacy: .public)")
        let accessStart = Date()
        try ensureSecurityScopedAccess(for: dbURL)
        logger.log("sqlite duplicate check: security scope ready path=\(dbURL.path, privacy: .public) duration=\(Date().timeIntervalSince(accessStart), privacy: .public) elapsed=\(Date().timeIntervalSince(checkStart), privacy: .public)")
        let queryStart = Date()
        let dbKey = storeContextKey(for: dbURL)
        let existing: Set<String>
        let source: String
        if let displayNames = loadedStoreContexts[dbKey]?.displayFilenamesLowercased, !displayNames.isEmpty {
            existing = tabFilenames.intersection(displayNames)
            source = "in-memory"
        } else {
            let identity = Self.databaseIdentity(for: dbURL)
            if let manifest = Self.loadManifest(forDatabaseURL: dbURL, storeName: effectiveStoreName),
               Self.manifestMatchesDatabase(manifest, identity: identity) {
                existing = Self.existingFilenamesAmong(tabFilenames: tabFilenames, manifestEntries: manifest.entries)
                source = "manifest"
            } else {
                existing = try Self.existingFilenamesAmong(tabFilenames: tabFilenames, databaseURL: dbURL)
                source = "database"
            }
        }
        logger.log("sqlite duplicate check: complete store=\(effectiveStoreName, privacy: .public) source=\(source, privacy: .public) matched=\(existing.count, privacy: .public) queryDuration=\(Date().timeIntervalSince(queryStart), privacy: .public) totalDuration=\(Date().timeIntervalSince(checkStart), privacy: .public)")
        return existing
    }

    func resolvedDatabaseURLForSync(storeName: String? = nil) throws -> URL {
        try resolvedDatabaseURL(storeName: storeName)
    }

    /// Stops background thumbnail hydration so sync can acquire the store actor and database.
    func cancelThumbnailHydrationForSync() {
        hydrationGeneration &+= 1
        // Bumping the generation only signals the post-query cooperative check.
        // The in-flight SELECT scans the entire objects table and ignores Task
        // cancellation, so we also call sqlite3_interrupt on the active
        // hydration connection to abort the step loop immediately.
        hydrationInterruptHandle.interrupt()
        logger.log("sqlite object store: thumbnail hydration cancelled for sync generation=\(self.hydrationGeneration, privacy: .public)")
    }

    /// Closes any cached read-only session before opening a sync write session.
    func prepareForSyncWrite(storeName: String? = nil) async throws {
        let prepareStart = Date()
        cancelThumbnailHydrationForSync()
        logger.log("sqlite object store: prepareForSyncWrite cancelHydration elapsed=\(Date().timeIntervalSince(prepareStart), privacy: .public)")
        let drainStart = Date()
        let pendingReaders = hydrationDatabaseReaders
        await waitForHydrationDatabaseReadersToDrain()
        logger.log("sqlite object store: prepareForSyncWrite drainReaders pendingAtStart=\(pendingReaders, privacy: .public) elapsed=\(Date().timeIntervalSince(drainStart), privacy: .public)")
        let closeStart = Date()
        forceCloseSyncWriteSession()
        logger.log("sqlite object store: prepareForSyncWrite forceCloseSession elapsed=\(Date().timeIntervalSince(closeStart), privacy: .public)")
        let resolveStart = Date()
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        try ensureWritableDatabaseAccess(for: dbURL)
        invalidateSessionReadConnection()
        logger.log("sqlite object store: prepareForSyncWrite resolveAndInvalidate elapsed=\(Date().timeIntervalSince(resolveStart), privacy: .public)")
        logger.log("sqlite object store: prepareForSyncWrite total elapsed=\(Date().timeIntervalSince(prepareStart), privacy: .public)")
    }

    private func forceCloseSyncWriteSession() {
        guard syncWriteSession != nil else { return }
        logger.log("sqlite object store: closing stale sync write session")
        try? endSyncWriteSession(commit: false)
    }

    private func hydrationDatabaseReaderDidBegin() {
        hydrationDatabaseReaders += 1
    }

    private func hydrationDatabaseReaderDidEnd() {
        hydrationDatabaseReaders = max(0, hydrationDatabaseReaders - 1)
        guard hydrationDatabaseReaders == 0 else { return }
        let waiters = hydrationDatabaseReaderDrainWaiters
        hydrationDatabaseReaderDrainWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForHydrationDatabaseReadersToDrain() async {
        guard hydrationDatabaseReaders > 0 else { return }
        await withCheckedContinuation { continuation in
            hydrationDatabaseReaderDrainWaiters.append(continuation)
        }
    }

    func beginSyncWriteSession(storeName: String? = nil) throws {
        let beginStart = Date()
        if syncWriteSession != nil {
            logger.error("sqlite object store: unexpected open sync write session; closing before reopen")
            forceCloseSyncWriteSession()
        }
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        try ensureWritableDatabaseAccess(for: dbURL)
        invalidateSessionReadConnection()

        let openStart = Date()
        let started = dbURL.startAccessingSecurityScopedResource()
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(
            dbURL.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            if started { dbURL.stopAccessingSecurityScopedResource() }
            let message = String(cString: sqlite3_errstr(openResult))
            logger.error("sqlite object store: sync write session open failed path=\(dbURL.path, privacy: .public) error=\(message, privacy: .public)")
            throw SQLiteObjectStoreError.databaseOpenFailed
        }
        logger.log("sqlite object store: beginSyncWriteSession sqlite3_open_v2 elapsed=\(Date().timeIntervalSince(openStart), privacy: .public)")
        sqlite3_busy_timeout(db, 120_000)
        do {
            let pragmaStart = Date()
            try Self.configureWriteConnectionPragmas(in: db, databaseURL: dbURL)
            logger.log("sqlite object store: beginSyncWriteSession configurePragmas elapsed=\(Date().timeIntervalSince(pragmaStart), privacy: .public)")
            let migrationStart = Date()
            try Self.applySchemaMigrations(in: db, ensureFilenameIndex: false)
            logger.log("sqlite object store: beginSyncWriteSession applyMigrations elapsed=\(Date().timeIntervalSince(migrationStart), privacy: .public)")
            let txnStart = Date()
            try Self.exec("BEGIN IMMEDIATE TRANSACTION;", in: db)
            logger.log("sqlite object store: beginSyncWriteSession beginImmediate elapsed=\(Date().timeIntervalSince(txnStart), privacy: .public)")
            let prepareStart = Date()
            let upsertSQL = Self.batchUpsertSQL
            var upsertStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, upsertSQL, -1, &upsertStatement, nil) == SQLITE_OK,
                  let upsertStatement else {
                throw SQLiteObjectStoreError.databaseWriteFailed()
            }
            logger.log("sqlite object store: beginSyncWriteSession prepareUpsert elapsed=\(Date().timeIntervalSince(prepareStart), privacy: .public)")
            let shouldEncrypt = Self.encryptsBlobs
            let keyData = shouldEncrypt ? try accessKeyData() : nil
            syncWriteSession = SyncWriteSession(
                dbURL: dbURL,
                db: db,
                upsertStatement: upsertStatement,
                shouldEncrypt: shouldEncrypt,
                keyData: keyData,
                securityScopedStarted: started
            )
            logger.log("sqlite object store: sync write session opened path=\(dbURL.path, privacy: .public) totalElapsed=\(Date().timeIntervalSince(beginStart), privacy: .public)")
        } catch {
            sqlite3_close(db)
            if started { dbURL.stopAccessingSecurityScopedResource() }
            syncWriteSession = nil
            throw error
        }
    }

    func appendToSyncWriteSession(_ objects: [PendingObject]) throws -> Int {
        guard !objects.isEmpty else { return 0 }
        guard let session = syncWriteSession else {
            throw SQLiteObjectStoreError.databaseWriteFailed(reason: "sync write session is not open")
        }
        var storedCount = 0
        for object in objects {
            let objectID = try Self.storePendingObject(
                object,
                in: session.db,
                statement: session.upsertStatement,
                shouldEncrypt: session.shouldEncrypt,
                keyData: session.keyData
            )
            let keywords = object.extractedMetadata?.keywords
                ?? Self.objectMetadata(
                    from: object.objectData,
                    originalURL: object.originalURL,
                    contentTypeIdentifier: object.contentTypeIdentifier
                ).keywords
            try Self.replaceKeywords(keywords, forObjectID: objectID, in: session.db)
            storedCount += 1
        }
        return storedCount
    }

    func endSyncWriteSession(commit: Bool) throws {
        guard let session = syncWriteSession else { return }
        defer {
            sqlite3_finalize(session.upsertStatement)
            sqlite3_close(session.db)
            if session.securityScopedStarted {
                session.dbURL.stopAccessingSecurityScopedResource()
            }
            syncWriteSession = nil
        }
        if commit {
            try Self.exec("COMMIT;", in: session.db)
            logger.log("sqlite object store: sync write session committed path=\(session.dbURL.path, privacy: .public)")
            // Truncate the WAL so the next open doesn't pay a multi-minute checkpoint
            // cost (especially on USB volumes). Best-effort: a busy reader will block
            // truncation but the commit is already durable.
            let checkpointStart = Date()
            var error: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(session.db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, &error)
            if result != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? Self.sqliteErrorMessage(from: session.db)
                logger.log("sqlite object store: wal checkpoint skipped path=\(session.dbURL.path, privacy: .public) reason=\(message, privacy: .public)")
            } else {
                logger.log("sqlite object store: wal checkpoint complete path=\(session.dbURL.path, privacy: .public) duration=\(Date().timeIntervalSince(checkpointStart), privacy: .public)")
            }
            if let error { sqlite3_free(error) }
        } else {
            try? Self.exec("ROLLBACK;", in: session.db)
            logger.log("sqlite object store: sync write session rolled back path=\(session.dbURL.path, privacy: .public)")
        }
    }

    /// Ingests legacy `ExternalBlobs/{hash}.bin` sidecar files into the new chunked
    /// storage table so the .sqlite database is fully self-contained for backup.
    /// Safe to run more than once; rows already chunked are skipped.
    @discardableResult
    func migrateExternalBlobsToChunks(
        storeName: String? = nil,
        progress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async throws -> (migrated: Int, skipped: Int) {
        guard Self.isEnabled else { return (0, 0) }
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        try ensureWritableDatabaseAccess(for: dbURL)
        let migrationStart = Date()
        var migrated = 0
        var skipped = 0
        var deletedFiles: [URL] = []

        try await withDatabase(at: dbURL, flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) { db in
            try Self.createSchema(in: db)

            // Rows whose payload lives in the legacy ExternalBlobs sidecar are
            // identified by an empty inline blob, a non-empty content hash, and
            // no rows already in object_blob_chunks.
            let sql = """
            SELECT id, content_hash FROM objects
            WHERE LENGTH(blob_data) = 0
              AND content_hash IS NOT NULL
              AND content_hash != ''
              AND NOT EXISTS (
                SELECT 1 FROM object_blob_chunks WHERE object_id = objects.id
              );
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw SQLiteObjectStoreError.databaseReadFailed
            }
            var rows: [(id: Int64, contentHash: String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let hash = Self.columnText(stmt, 1) ?? ""
                if !hash.isEmpty {
                    rows.append((id, hash))
                }
            }
            sqlite3_finalize(stmt)

            self.logger.log("sqlite object store: external blob migration begin total=\(rows.count, privacy: .public)")
            let total = rows.count
            for (idx, row) in rows.enumerated() {
                try Task.checkCancellation()
                let relativePath = Self.externalBlobRelativePath(contentHash: row.contentHash)
                let externalURL = Self.externalBlobFileURL(relativePath: relativePath, databaseURL: dbURL)
                guard FileManager.default.fileExists(atPath: externalURL.path) else {
                    skipped += 1
                    self.logger.log("sqlite object store: external blob migration skipped missing file objectID=\(row.id, privacy: .public) path=\(relativePath, privacy: .public)")
                    continue
                }
                let filename = externalURL.lastPathComponent
                try Self.exec("BEGIN IMMEDIATE TRANSACTION;", in: db)
                do {
                    try Self.writeChunkedBlobFromFile(
                        sourceURL: externalURL,
                        objectID: row.id,
                        db: db,
                        filename: filename,
                        shouldEncrypt: false,
                        keyData: nil
                    )
                    try Self.exec("COMMIT;", in: db)
                } catch {
                    try? Self.exec("ROLLBACK;", in: db)
                    self.logger.error("sqlite object store: external blob migration failed objectID=\(row.id, privacy: .public) path=\(relativePath, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    throw error
                }
                deletedFiles.append(externalURL)
                migrated += 1
                if let progress {
                    await progress(idx + 1, total)
                }
            }
        }

        // Only remove sidecar files after the chunked write transactions committed.
        for url in deletedFiles {
            try? FileManager.default.removeItem(at: url)
        }
        // If ExternalBlobs/ is now empty, clear the directory itself.
        if let firstFile = deletedFiles.first {
            let dir = firstFile.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        logger.log("sqlite object store: external blob migration complete migrated=\(migrated, privacy: .public) skipped=\(skipped, privacy: .public) duration=\(Date().timeIntervalSince(migrationStart), privacy: .public)")
        return (migrated, skipped)
    }

    func loadObjectWorkingFiles(
        storeName: String? = nil,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ urls: [URL]) async -> Void)? = nil,
        thumbnailProgress: (@Sendable (_ decoded: Int, _ total: Int) async -> Void)? = nil
    ) async throws -> [URL] {
        guard Self.isEnabled else { return [] }
        guard AppWorkingDirectory.ensureAccess() else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        let loadStart = Date()
        let effectiveStoreName = storeName ?? Self.configuredStoreName
        logger.log("sqlite object store: load begin storeName=\(effectiveStoreName, privacy: .public)")
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        try ensureSecurityScopedAccess(for: dbURL)
        let databaseIdentity = Self.databaseIdentity(for: dbURL)
        logger.log("sqlite object store: resolved database path=\(dbURL.path, privacy: .public) elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
        let workingDirectory = try Self.ensureWorkingDirectory()
        logger.log("sqlite object store: ensured working directory path=\(workingDirectory.path, privacy: .public) elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
        let dbKey = storeContextKey(for: dbURL)
        let previousContext = loadedStoreContexts[dbKey]
        loadedStoreContexts[dbKey] = LoadedStoreContext(dbURL: dbURL)
        invalidateSessionReadConnection()

        let rows: [ObjectWorkingFileRow]
        let loadSource: String
        if let manifest = Self.loadManifest(forDatabaseURL: dbURL, storeName: effectiveStoreName),
           Self.manifestMatchesDatabase(manifest, identity: databaseIdentity),
           !manifest.entries.isEmpty,
           Self.manifestContentMatchesDatabase(entries: manifest.entries, databaseURL: dbURL) {
            rows = Self.rowsFromManifest(manifest, workingDirectory: workingDirectory)
            loadSource = "manifest"
            logger.log("sqlite object store: manifest hit storeName=\(effectiveStoreName, privacy: .public) objects=\(rows.count, privacy: .public) elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
        } else {
            if let manifest = Self.loadManifest(forDatabaseURL: dbURL, storeName: effectiveStoreName) {
                logger.log("sqlite object store: manifest stale storeName=\(effectiveStoreName, privacy: .public) manifestPath=\(manifest.databasePath, privacy: .public) manifestModified=\(manifest.databaseModifiedAt, privacy: .public) fileModified=\(databaseIdentity.modifiedAt ?? -1, privacy: .public) manifestSize=\(manifest.databaseFileSize ?? -1, privacy: .public) fileSize=\(databaseIdentity.fileSize ?? -1, privacy: .public) manifestEntries=\(manifest.entries.count, privacy: .public)")
                Self.removeManifest(forDatabasePath: databaseIdentity.path)
            } else {
                logger.log("sqlite object store: manifest miss storeName=\(effectiveStoreName, privacy: .public) path=\(databaseIdentity.path, privacy: .public)")
            }
            rows = try await loadRowsFromDatabase(
                dbURL: dbURL,
                workingDirectory: workingDirectory,
                loadStart: loadStart
            )
            loadSource = "database"
            if !rows.isEmpty {
                Self.persistManifest(
                    storeName: effectiveStoreName,
                    databaseURL: dbURL,
                    identity: databaseIdentity,
                    rows: rows
                )
            }
        }

        guard !rows.isEmpty else { return [] }
        let urls = applyLoadedRows(rows, dbURL: dbURL, loadStart: loadStart)
        let preloadedFromDisk = await Self.preloadDiskCachedThumbnails(rows: rows)
        if preloadedFromDisk > 0 {
            logger.log("sqlite object store: thumbnail disk-cache preload matched=\(preloadedFromDisk, privacy: .public) loadedRows=\(rows.count, privacy: .public)")
        }
        restoreThumbnailHydrationState(from: previousContext, for: dbKey, rows: rows)
        await progress?(urls.count, urls.count, urls)
        try await preloadMetadataCacheForStore(
            rows: rows,
            dbURL: dbURL
        )
        logger.log("sqlite object store: load complete source=\(loadSource, privacy: .public) metadataOnly=true objects=\(rows.count, privacy: .public) lazyWorkingFiles=\(rows.count, privacy: .public) thumbnailsHydrated=\(self.loadedStoreContexts[dbKey]?.thumbnailsHydrated == true, privacy: .public) totalDuration=\(Date().timeIntervalSince(loadStart), privacy: .public)")
        return urls
    }

    private func loadRowsFromDatabase(
        dbURL: URL,
        workingDirectory: URL,
        loadStart: Date
    ) async throws -> [ObjectWorkingFileRow] {
        try withSessionReadDatabase(at: dbURL) { db in
            let dbOpenElapsed = Date().timeIntervalSince(loadStart)
            logger.log("sqlite object store: db open complete path=\(dbURL.path, privacy: .public) elapsed=\(dbOpenElapsed, privacy: .public)")

            let sql = """
            SELECT id, original_filename, file_extension, content_hash, is_encrypted
            FROM objects
            ORDER BY original_filename COLLATE NOCASE, id;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw SQLiteObjectStoreError.databaseReadFailed
            }
            defer { sqlite3_finalize(statement) }

            var usedFilenames: Set<String> = []
            var rows: [ObjectWorkingFileRow] = []
            let stepStart = Date()

            while sqlite3_step(statement) == SQLITE_ROW {
                try Task.checkCancellation()
                let id = sqlite3_column_int64(statement, 0)
                let filename = Self.columnText(statement, 1) ?? "object"
                let fileExtension = Self.columnText(statement, 2)
                let contentHash = Self.columnText(statement, 3)
                let isEncrypted = sqlite3_column_int(statement, 4) == 1
                let outputURL = Self.uniqueWorkingURL(
                    filename: filename,
                    fallbackExtension: fileExtension,
                    directory: workingDirectory,
                    usedFilenames: &usedFilenames
                )
                rows.append(ObjectWorkingFileRow(
                    id: id,
                    filename: filename,
                    fileExtension: fileExtension,
                    contentHash: contentHash,
                    isEncrypted: isEncrypted,
                    outputURL: outputURL
                ))
            }
            logger.log("sqlite object store: sql step complete command=\"metadata select\" rows=\(rows.count, privacy: .public) duration=\(Date().timeIntervalSince(stepStart), privacy: .public) elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
            return rows
        }
    }

    private func preloadMetadataCacheForStore(
        rows: [ObjectWorkingFileRow],
        dbURL: URL
    ) async throws {
        try withSessionReadDatabase(at: dbURL) { db in
            try preloadMetadataCache(db: db, rows: rows, dbURL: dbURL)
        }
    }

    private func preloadMetadataCache(
        db: OpaquePointer,
        rows: [ObjectWorkingFileRow],
        dbURL: URL
    ) throws {
        let dbKey = storeContextKey(for: dbURL)
        let preloadStart = Date()
        var descriptionsByID: [Int64: String] = [:]
        if Self.columnExists("description", inTable: "objects", db: db) {
            var descriptionStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id, description FROM objects;", -1, &descriptionStatement, nil) == SQLITE_OK,
                  let descriptionStatement else {
                throw SQLiteObjectStoreError.databaseReadFailed
            }
            defer { sqlite3_finalize(descriptionStatement) }
            while sqlite3_step(descriptionStatement) == SQLITE_ROW {
                let id = sqlite3_column_int64(descriptionStatement, 0)
                descriptionsByID[id] = Self.columnText(descriptionStatement, 1)
            }
        }

        var keywordsByID: [Int64: [String]] = [:]
        let keywordSQL = """
        SELECT ok.object_id, k.keyword
        FROM object_keywords ok
        JOIN keywords k ON k.id = ok.keyword_id
        ORDER BY ok.object_id, k.keyword COLLATE NOCASE;
        """
        var keywordStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, keywordSQL, -1, &keywordStatement, nil) == SQLITE_OK,
           let keywordStatement {
            defer { sqlite3_finalize(keywordStatement) }
            while sqlite3_step(keywordStatement) == SQLITE_ROW {
                let id = sqlite3_column_int64(keywordStatement, 0)
                guard let keyword = Self.columnText(keywordStatement, 1) else { continue }
                keywordsByID[id, default: []].append(keyword)
            }
        }

        var descriptionSeeds: [(URL, String?)] = []
        descriptionSeeds.reserveCapacity(rows.count)
        var context = loadedStoreContexts[dbKey] ?? LoadedStoreContext(dbURL: dbURL)
        for row in rows {
            let metadata = StoredObjectMetadata(
                description: descriptionsByID[row.id],
                keywords: keywordsByID[row.id] ?? []
            )
            context.metadataCacheByObjectID[row.id] = metadata
            descriptionSeeds.append((row.outputURL, metadata.description))
        }
        loadedStoreContexts[dbKey] = context
        MetadataCache.shared.seedDescriptions(descriptionSeeds)
        logger.log("sqlite object store: metadata preload complete objects=\(rows.count, privacy: .public) duration=\(Date().timeIntervalSince(preloadStart), privacy: .public)")
    }

    private func restoreThumbnailHydrationState(
        from previousContext: LoadedStoreContext?,
        for dbKey: String,
        rows: [ObjectWorkingFileRow]
    ) {
        guard let previousContext,
              previousContext.thumbnailsHydrated,
              !previousContext.thumbnailJPEGDataByObjectID.isEmpty,
              var context = loadedStoreContexts[dbKey] else {
            return
        }
        var restoredCount = 0
        for row in rows {
            guard let data = previousContext.thumbnailJPEGDataByObjectID[row.id], !data.isEmpty else {
                continue
            }
            context.thumbnailJPEGDataByObjectID[row.id] = data
            HydratedThumbnailJPEGRegistry.store(data, for: row.outputURL)
            ThumbnailCache.shared.storeJPEGData(data, for: row.outputURL)
            restoredCount += 1
        }
        if restoredCount == rows.count {
            context.thumbnailsHydrated = true
        }
        loadedStoreContexts[dbKey] = context
        if restoredCount > 0 {
            logger.log("sqlite object store: restored thumbnail hydration cache count=\(restoredCount, privacy: .public) total=\(rows.count, privacy: .public) fullyHydrated=\(context.thumbnailsHydrated, privacy: .public)")
        }
    }

    private func applyLoadedRows(
        _ rows: [ObjectWorkingFileRow],
        dbURL: URL,
        loadStart: Date
    ) -> [URL] {
        let urls = rows.map(\.outputURL)
        let registryStart = Date()
        let dbKey = storeContextKey(for: dbURL)
        var context = LoadedStoreContext(dbURL: dbURL)
        for row in rows {
            context.lazyWorkingFiles[Self.workingCopyKey(for: row.outputURL)] = LazyWorkingFile(
                id: row.id,
                originalFilename: row.filename,
                fileExtension: row.fileExtension,
                contentHash: row.contentHash,
                isEncrypted: row.isEncrypted,
                dbURL: dbURL
            )
            context.lazyWorkingURLsByID[row.id] = row.outputURL
            context.lazyWorkingThumbnailOrder.append(row.id)
            let displayName = Self.displayFilename(
                originalFilename: row.filename,
                fileExtension: row.fileExtension
            ).lowercased()
            context.displayFilenamesLowercased.insert(displayName)
        }
        loadedStoreContexts[dbKey] = context
        logger.log("sqlite object store: lazy registry complete count=\(rows.count, privacy: .public) duration=\(Date().timeIntervalSince(registryStart), privacy: .public) elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
        return urls
    }

    func shouldDeferIndividualThumbnailLookup(for url: URL) -> Bool {
        guard let match = findLazyFile(for: url),
              let context = loadedStoreContexts[match.dbKey] else {
            return false
        }
        if context.thumbnailsHydrated { return false }
        return context.thumbnailJPEGDataByObjectID[match.file.id] == nil
    }

    func thumbnailJPEGData(forWorkingFile url: URL) async -> Data? {
        guard Self.isWorkingCopyURL(url),
              let match = findLazyFile(for: url) else {
            return nil
        }
        let lazyFile = match.file
        let dbKey = match.dbKey
        let shouldLogSource = loadedStoreContexts[dbKey]?.thumbnailsHydrated != true
        if let cached = loadedStoreContexts[dbKey]?.thumbnailJPEGDataByObjectID[lazyFile.id] {
            if shouldLogSource {
                logger.log("sqlite thumbnail: source=memory-cache filename=\(url.lastPathComponent, privacy: .public) bytes=\(cached.count, privacy: .public)")
            }
            return cached
        }
        do {
            let data = try await Self.readThumbnailData(
                objectID: lazyFile.id,
                databaseURL: lazyFile.dbURL
            )
            guard let data, !data.isEmpty else {
                if shouldLogSource {
                    logger.log("sqlite thumbnail: source=unavailable reason=no-database-blob filename=\(url.lastPathComponent, privacy: .public)")
                }
                return nil
            }
            if var context = loadedStoreContexts[dbKey] {
                context.thumbnailJPEGDataByObjectID[lazyFile.id] = data
                loadedStoreContexts[dbKey] = context
            }
            HydratedThumbnailJPEGRegistry.store(data, for: url)
            if shouldLogSource {
                logger.log("sqlite thumbnail: source=database-blob filename=\(url.lastPathComponent, privacy: .public) bytes=\(data.count, privacy: .public)")
            }
            return data
        } catch {
            if shouldLogSource {
                logger.error("sqlite thumbnail: source=unavailable reason=lookup-failed filename=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    func thumbnailImage(forWorkingFile url: URL) async -> NSImage? {
        guard let data = await thumbnailJPEGData(forWorkingFile: url) else { return nil }
        return ThumbnailCache.image(fromJPEGData: data)
    }

    func metadataForWorkingFile(_ url: URL) async -> StoredObjectMetadata? {
        guard Self.isWorkingCopyURL(url),
              let match = findLazyFile(for: url) else {
            return nil
        }
        let lazyFile = match.file
        let dbKey = match.dbKey
        if let cached = loadedStoreContexts[dbKey]?.metadataCacheByObjectID[lazyFile.id] {
            return cached
        }
        do {
            let keyData = lazyFile.isEncrypted ? try accessKeyData() : nil
            let metadata = try withSessionReadDatabase(at: lazyFile.dbURL) { db in
                var description = try Self.objectDescription(id: lazyFile.id, in: db)
                let keywords = try Self.objectKeywords(id: lazyFile.id, in: db)
                if description == nil,
                   let objectData = try? Self.objectData(
                       id: lazyFile.id,
                       isEncrypted: lazyFile.isEncrypted,
                       keyData: keyData,
                       db: db
                   ) {
                    description = Self.objectMetadata(
                        from: objectData,
                        originalURL: url,
                        contentTypeIdentifier: nil
                    ).description
                }
                return StoredObjectMetadata(description: description, keywords: keywords)
            }
            if var context = loadedStoreContexts[dbKey] {
                context.metadataCacheByObjectID[lazyFile.id] = metadata
                loadedStoreContexts[dbKey] = context
            }
            MetadataCache.shared.seedDescription(metadata.description, for: url)
            return metadata
        } catch {
            logger.error("sqlite object store: metadata lookup failed filename=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func materializeWorkingCopyIfNeeded(_ url: URL) async throws -> URL {
        guard Self.isWorkingCopyURL(url) else { return url }
        let workingKey = Self.workingCopyKey(for: url)
        if FileManager.default.fileExists(atPath: url.path) {
            if try await isCompleteWorkingCopy(at: url) {
                logger.log("sqlite object store: materialize skipped existing filename=\(url.lastPathComponent, privacy: .public)")
                return url
            }
            try? FileManager.default.removeItem(at: url)
        }

        let playbackThreshold = Self.isLikelyVideoWorkingCopy(url) ? Self.playbackMaterializeThresholdBytes : nil
        if let existingTask = materializeTasks[workingKey] {
            return try await waitForMaterializedURL(
                key: workingKey,
                task: existingTask,
                playbackThresholdBytes: playbackThreshold
            )
        }

        guard let match = findLazyFile(for: url) else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        let lazyFile = match.file
        let keyData = lazyFile.isEncrypted ? try accessKeyData() : nil
        let plan = MaterializePlan(
            url: url,
            objectID: lazyFile.id,
            isEncrypted: lazyFile.isEncrypted,
            dbURL: lazyFile.dbURL,
            keyData: keyData
        )
        let existingThumbnail = await MainActor.run {
            ThumbnailCache.shared.memoryImage(for: url)
        }

        let task = Self.startMaterializationTask(
            plan: plan,
            workingKey: workingKey,
            existingThumbnail: existingThumbnail,
            playbackThreshold: playbackThreshold
        )
        materializeTasks[workingKey] = task
        defer {
            materializeTasks.removeValue(forKey: workingKey)
            MaterializePlaybackSignal.shared.remove(key: workingKey)
        }
        return try await waitForMaterializedURL(
            key: workingKey,
            task: task,
            playbackThresholdBytes: playbackThreshold
        )
    }

    private func waitForMaterializedURL(
        key: String,
        task: Task<URL, Error>,
        playbackThresholdBytes: Int?
    ) async throws -> URL {
        guard playbackThresholdBytes != nil else {
            return try await task.value
        }
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    if let ready = MaterializePlaybackSignal.shared.url(for: key) {
                        return ready
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                throw CancellationError()
            }
            group.addTask {
                try await task.value
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func startMaterializationTask(
        plan: MaterializePlan,
        workingKey: String,
        existingThumbnail: NSImage?,
        playbackThreshold: Int?
    ) -> Task<URL, Error> {
        let signalKey = workingKey
        let signalURL = plan.url
        let threshold = playbackThreshold
        return Task.detached(priority: .userInitiated) {
            try await Self.performMaterialization(
                plan,
                existingThumbnail: existingThumbnail,
                playbackThresholdBytes: threshold,
                signalKey: signalKey,
                signalURL: signalURL
            )
        }
    }

    private func isCompleteWorkingCopy(at url: URL) async throws -> Bool {
        guard let match = findLazyFile(for: url) else { return false }
        let expectedSize = try Self.expectedObjectByteCount(
            objectID: match.file.id,
            databaseURL: match.file.dbURL
        )
        guard let actualSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return false
        }
        return actualSize == expectedSize
    }

    private nonisolated static func performMaterialization(
        _ plan: MaterializePlan,
        existingThumbnail: NSImage?,
        playbackThresholdBytes: Int? = nil,
        signalKey: String? = nil,
        signalURL: URL? = nil
    ) async throws -> URL {
        let notifyPlaybackReady: @Sendable () -> Void = {
            guard let signalKey, let signalURL else { return }
            MaterializePlaybackSignal.shared.mark(key: signalKey, url: signalURL)
        }
        let materializeStart = Date()
        let filename = plan.url.lastPathComponent
        let logger = Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
        logger.log("sqlite object store: materialize begin filename=\(filename, privacy: .public)")
        guard AppWorkingDirectory.ensureAccess() else {
            logger.error("sqlite object store: materialize failed missing working-directory access filename=\(filename, privacy: .public)")
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        let parentDirectory = plan.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: parentDirectory.path) else {
            logger.error("sqlite object store: materialize failed working directory is not writable path=\(parentDirectory.path, privacy: .public) filename=\(filename, privacy: .public)")
            throw SQLiteObjectStoreError.databaseWriteFailed()
        }

        let bytesWritten: Int
        if !plan.isEncrypted,
           let playbackThresholdBytes,
           signalKey != nil {
            bytesWritten = try streamObjectBlobToFile(
                objectID: plan.objectID,
                databaseURL: plan.dbURL,
                destinationURL: plan.url,
                playbackThresholdBytes: playbackThresholdBytes,
                onPlaybackReady: notifyPlaybackReady
            )
        } else {
            let objectData = try readObjectDataOffActor(
                objectID: plan.objectID,
                isEncrypted: plan.isEncrypted,
                keyData: plan.keyData,
                databaseURL: plan.dbURL
            )
            try Task.checkCancellation()
            logger.log("sqlite object store: materialize blob read complete filename=\(filename, privacy: .public) bytes=\(objectData.count, privacy: .public) elapsed=\(Date().timeIntervalSince(materializeStart), privacy: .public)")
            try writeMaterializedData(objectData, to: plan.url)
            bytesWritten = objectData.count
            if let playbackThresholdBytes,
               bytesWritten >= playbackThresholdBytes,
               signalKey != nil {
                notifyPlaybackReady()
            }
        }

        if let existingThumbnail {
            await MainActor.run {
                ThumbnailCache.shared.store(existingThumbnail, for: plan.url)
            }
        }
        logger.log("sqlite object store: materialize complete filename=\(filename, privacy: .public) bytes=\(bytesWritten, privacy: .public) duration=\(Date().timeIntervalSince(materializeStart), privacy: .public)")
        return plan.url
    }

    private nonisolated static func writeMaterializedData(_ data: Data, to url: URL) throws {
        if data.count > playbackMaterializeThresholdBytes {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private nonisolated static func streamObjectBlobToFile(
        objectID: Int64,
        databaseURL: URL,
        destinationURL: URL,
        playbackThresholdBytes: Int,
        onPlaybackReady: @escaping @Sendable () -> Void
    ) throws -> Int {
        let started = databaseURL.startAccessingSecurityScopedResource()
        defer { if started { databaseURL.stopAccessingSecurityScopedResource() } }
        let db = try openReadOnlyDatabaseConnection(at: databaseURL)
        defer { sqlite3_close(db) }

        // Chunked storage (preferred for files > SQLITE_LIMIT_LENGTH) is checked before
        // ExternalBlobs sidecar files. Both code paths coexist during migration.
        if objectHasChunks(objectID: objectID, in: db) {
            return try streamChunksToFile(
                objectID: objectID,
                db: db,
                destinationURL: destinationURL,
                keyData: nil,
                playbackThresholdBytes: playbackThresholdBytes,
                onPlaybackReady: onPlaybackReady
            )
        }

        if let contentHash = try contentHash(forObjectID: objectID, in: db),
           let sourceURL = resolvedExternalBlobFileURL(contentHash: contentHash, databaseURL: databaseURL),
           FileManager.default.fileExists(atPath: sourceURL.path) {
            return try streamFileToFile(
                from: sourceURL,
                to: destinationURL,
                playbackThresholdBytes: playbackThresholdBytes,
                onPlaybackReady: onPlaybackReady
            )
        }

        var rowStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rowid FROM objects WHERE id = ?;", -1, &rowStatement, nil) == SQLITE_OK,
              let rowStatement else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(rowStatement) }
        sqlite3_bind_int64(rowStatement, 1, objectID)
        guard sqlite3_step(rowStatement) == SQLITE_ROW else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        let rowID = sqlite3_column_int64(rowStatement, 0)

        var blob: OpaquePointer?
        guard sqlite3_blob_open(db, "main", "objects", "blob_data", rowID, 0, &blob) == SQLITE_OK,
              let blob else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_blob_close(blob) }

        let totalBytes = Int(sqlite3_blob_bytes(blob))
        guard totalBytes > 0 else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var offset: Int32 = 0
        var bytesWritten = 0
        var signaledPlaybackReady = false
        var chunk = [UInt8](repeating: 0, count: materializeStreamChunkBytes)
        while offset < Int32(totalBytes) {
            try Task.checkCancellation()
            let remaining = Int32(totalBytes) - offset
            let toRead = Int32(min(materializeStreamChunkBytes, Int(remaining)))
            let readResult = sqlite3_blob_read(blob, &chunk, toRead, offset)
            guard readResult == SQLITE_OK else {
                throw SQLiteObjectStoreError.databaseReadFailed
            }
            let data = Data(bytes: chunk, count: Int(toRead))
            try handle.write(contentsOf: data)
            offset += toRead
            bytesWritten += Int(toRead)
            if !signaledPlaybackReady, bytesWritten >= playbackThresholdBytes {
                signaledPlaybackReady = true
                onPlaybackReady()
            }
        }
        return bytesWritten
    }

    private nonisolated static func contentHash(forObjectID objectID: Int64, in db: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT content_hash FROM objects WHERE id = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, objectID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        return columnText(statement, 0)
    }

    private nonisolated static func resolvedExternalBlobFileURL(contentHash: String, databaseURL: URL) -> URL? {
        let url = externalBlobFileURL(
            relativePath: externalBlobRelativePath(contentHash: contentHash),
            databaseURL: databaseURL
        )
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated static func streamFileToFile(
        from sourceURL: URL,
        to destinationURL: URL,
        playbackThresholdBytes: Int,
        onPlaybackReady: @escaping @Sendable () -> Void
    ) throws -> Int {
        let started = sourceURL.startAccessingSecurityScopedResource()
        defer { if started { sourceURL.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let readHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? readHandle.close() }
        let writeHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? writeHandle.close() }

        var bytesWritten = 0
        var signaledPlaybackReady = false
        while true {
            try Task.checkCancellation()
            guard let chunk = try readHandle.read(upToCount: materializeStreamChunkBytes), !chunk.isEmpty else {
                break
            }
            try writeHandle.write(contentsOf: chunk)
            bytesWritten += chunk.count
            if !signaledPlaybackReady, bytesWritten >= playbackThresholdBytes {
                signaledPlaybackReady = true
                onPlaybackReady()
            }
        }
        return bytesWritten
    }

    private nonisolated static func expectedObjectByteCount(
        objectID: Int64,
        databaseURL: URL
    ) throws -> Int {
        let started = databaseURL.startAccessingSecurityScopedResource()
        defer { if started { databaseURL.stopAccessingSecurityScopedResource() } }
        let db = try openReadOnlyDatabaseConnection(at: databaseURL)
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT file_size, LENGTH(blob_data) FROM objects WHERE id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, objectID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        let storedFileSize = sqlite3_column_int64(statement, 0)
        if storedFileSize > 0 {
            return Int(storedFileSize)
        }
        return Int(sqlite3_column_int64(statement, 1))
    }

    nonisolated static func isLikelyVideoWorkingCopy(_ url: URL) -> Bool {
        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        return PhotoLibrary.isVideoMediaFile(url, contentType: contentType)
    }

    private nonisolated static func readObjectDataOffActor(
        objectID: Int64,
        isEncrypted: Bool,
        keyData: Data?,
        databaseURL: URL
    ) throws -> Data {
        let started = databaseURL.startAccessingSecurityScopedResource()
        defer { if started { databaseURL.stopAccessingSecurityScopedResource() } }
        let db = try openReadOnlyDatabaseConnection(at: databaseURL)
        defer { sqlite3_close(db) }
        return try objectData(id: objectID, isEncrypted: isEncrypted, keyData: keyData, db: db)
    }

    private nonisolated static func readThumbnailData(
        objectID: Int64,
        databaseURL: URL
    ) async throws -> Data? {
        try await Task.detached(priority: .utility) {
            let started = databaseURL.startAccessingSecurityScopedResource()
            defer { if started { databaseURL.stopAccessingSecurityScopedResource() } }
            let db = try openReadOnlyDatabaseConnection(at: databaseURL)
            defer { sqlite3_close(db) }
            return try thumbnailData(id: objectID, in: db)
        }.value
    }

    func hydrateStoredThumbnailsForLoadedObjects(
        storeName: String? = nil,
        progress: (@Sendable (_ decoded: Int, _ total: Int) async -> Void)? = nil
    ) async throws -> Int {
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        let dbKey = storeContextKey(for: dbURL)
        guard var context = loadedStoreContexts[dbKey], !context.thumbnailsHydrated else {
            logger.log("sqlite object store: async thumbnail hydration skipped alreadyHydrated=true")
            return 0
        }
        let thumbnailURLsByID = context.lazyWorkingURLsByID
        guard !thumbnailURLsByID.isEmpty else { return 0 }
        let hydrateTotal = context.lazyWorkingThumbnailOrder.count
        guard hydrateTotal > 0 else { return 0 }

        let hydrateStart = Date()
        let generationAtStart = hydrationGeneration
        logger.log("sqlite object store: async thumbnail hydration begin candidates=\(hydrateTotal, privacy: .public) generation=\(generationAtStart, privacy: .public)")

        // Read blobs off the actor so sync and other store work are not blocked on a full-table scan.
        hydrationDatabaseReaderDidBegin()
        defer { hydrationDatabaseReaderDidEnd() }
        let interruptHandle = hydrationInterruptHandle
        let rows = try await Task(priority: .utility) {
            try Self.fetchThumbnailRows(dbURL: dbURL, urlByID: thumbnailURLsByID, interruptHandle: interruptHandle)
        }.value
        try Task.checkCancellation()
        guard generationAtStart == hydrationGeneration else {
            logger.log("sqlite object store: async thumbnail hydration aborted after query reason=sync-preempted generation=\(self.hydrationGeneration, privacy: .public)")
            return 0
        }
        logger.log("sqlite object store: async thumbnail hydration query complete blobRows=\(rows.count, privacy: .public) candidates=\(hydrateTotal, privacy: .public) source=database-blob-batch duration=\(Date().timeIntervalSince(hydrateStart), privacy: .public)")
        let decodeBatchSize = 64
        var decoded = 0
        var batchStart = 0
        while batchStart < rows.count {
            try Task.checkCancellation()
            guard generationAtStart == hydrationGeneration else {
                logger.log("sqlite object store: async thumbnail hydration aborted during decode reason=sync-preempted decoded=\(decoded, privacy: .public)")
                break
            }
            let batchEnd = min(batchStart + decodeBatchSize, rows.count)
            let batch = Array(rows[batchStart..<batchEnd])
            batchStart = batchEnd
            let batchStartTime = Date()

            decoded += await Self.decodeAndStoreThumbnails(batch.map { ($0.url, $0.data) })
            for row in batch {
                context.thumbnailJPEGDataByObjectID[row.objectID] = row.data
                HydratedThumbnailJPEGRegistry.store(row.data, for: row.url)
            }
            loadedStoreContexts[dbKey] = context
            if let progress {
                await progress(decoded, hydrateTotal)
            }
            logger.log("sqlite object store: async thumbnail hydration batch complete decoded=\(decoded, privacy: .public) total=\(hydrateTotal, privacy: .public) batchSize=\(batch.count, privacy: .public) duration=\(Date().timeIntervalSince(batchStartTime), privacy: .public)")
            await Task.yield()
        }

        if generationAtStart == hydrationGeneration, !Task.isCancelled {
            context.thumbnailsHydrated = true
            loadedStoreContexts[dbKey] = context
            if let progress, decoded > 0 {
                await progress(decoded, hydrateTotal)
            }
        }
        logger.log("sqlite object store: async thumbnail hydration complete decoded=\(decoded, privacy: .public) duration=\(Date().timeIntervalSince(hydrateStart), privacy: .public) hydrated=\(context.thumbnailsHydrated, privacy: .public)")
        invalidateSessionReadConnection()
        return decoded
    }

    private nonisolated static func fetchThumbnailRows(
        dbURL: URL,
        urlByID: [Int64: URL],
        interruptHandle: InterruptibleDatabaseHandle? = nil
    ) throws -> [ThumbnailRow] {
        try withEphemeralReadDatabase(at: dbURL) { db in
            interruptHandle?.register(db)
            defer { interruptHandle?.register(nil) }
            guard columnExists("thumbnail_data", inTable: "objects", db: db) else {
                return []
            }
            let sql = "SELECT id, thumbnail_data FROM objects WHERE thumbnail_data IS NOT NULL AND length(thumbnail_data) > 0;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }

            var rows: [ThumbnailRow] = []
            while true {
                let stepResult = sqlite3_step(statement)
                if stepResult == SQLITE_ROW {
                    try Task.checkCancellation()
                    let id = sqlite3_column_int64(statement, 0)
                    if let url = urlByID[id] {
                        let thumbnailData = columnData(statement, 1)
                        if !thumbnailData.isEmpty {
                            rows.append(ThumbnailRow(objectID: id, url: url, data: thumbnailData))
                        }
                    }
                } else {
                    // SQLITE_DONE on natural completion; SQLITE_INTERRUPT when sync
                    // preempted the scan. In both cases return what we have so far.
                    break
                }
            }
            return rows
        }
    }

    private nonisolated static func decodeAndStoreThumbnails(_ thumbnails: [(URL, Data)]) async -> Int {
        guard !thumbnails.isEmpty else { return 0 }
        return await Task.detached(priority: .userInitiated) {
            var stored = 0
            for (url, data) in thumbnails {
                HydratedThumbnailJPEGRegistry.store(data, for: url)
                ThumbnailCache.shared.storeJPEGData(data, for: url)
                stored += 1
            }
            return stored
        }.value
    }

    private nonisolated static func preloadDiskCachedThumbnails(rows: [ObjectWorkingFileRow]) async -> Int {
        await Task.detached(priority: .utility) {
            var matched = 0
            for row in rows {
                guard let data = ThumbnailCache.shared.cachedJPEGBytesFromDisk(for: row.outputURL),
                      !data.isEmpty else { continue }
                HydratedThumbnailJPEGRegistry.store(data, for: row.outputURL)
                ThumbnailCache.shared.storeJPEGData(data, for: row.outputURL)
                matched += 1
            }
            return matched
        }.value
    }

    /// Deletes objects from the SQLite store identified by the working-file
    /// URLs returned from `loadObjectWorkingFiles`. Lazy working files may not
    /// exist on disk yet, so deletion resolves object IDs from the in-memory
    /// registry first and only falls back to content-hash matching when a
    /// materialized working copy is present.
    func deleteObjects(at urls: [URL]) async throws -> Set<URL> {
        guard Self.isEnabled, !urls.isEmpty else { return [] }
        invalidateSessionReadConnection()
        await waitForHydrationDatabaseReadersToDrain()

        struct PendingDelete {
            let url: URL
            let objectID: Int64?
            let originalFilename: String?
            let fileExtension: String?
            let contentHash: String?
            let dbURL: URL
        }

        let defaultDBURL = try resolvedDatabaseURL()
        var pending: [PendingDelete] = []
        for url in urls {
            if let lazyFile = findLazyFile(for: url)?.file {
                pending.append(
                    PendingDelete(
                        url: url,
                        objectID: lazyFile.id,
                        originalFilename: lazyFile.originalFilename,
                        fileExtension: lazyFile.fileExtension,
                        contentHash: lazyFile.contentHash,
                        dbURL: lazyFile.dbURL
                    )
                )
            } else if FileManager.default.fileExists(atPath: url.path),
                      let contentHash = try? Self.contentHash(ofFile: url) {
                let basename = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? nil : url.pathExtension
                pending.append(
                    PendingDelete(
                        url: url,
                        objectID: nil,
                        originalFilename: basename,
                        fileExtension: ext,
                        contentHash: contentHash,
                        dbURL: defaultDBURL
                    )
                )
            } else {
                logger.error("sqlite object store: delete skipped unresolved working file filename=\(url.lastPathComponent, privacy: .public)")
            }
        }
        guard !pending.isEmpty else { return [] }

        var deletedURLs: Set<URL> = []
        var manifestInvalidatedDBs: Set<String> = []
        let grouped = Dictionary(grouping: pending, by: \.dbURL)
        for (dbURL, items) in grouped {
            var removedFromDB = 0
            var purgedOrphans = 0
            try withDatabase(at: dbURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) { db in
                for item in items {
                    let didDelete = Self.deleteStoredObject(
                        objectID: item.objectID,
                        contentHash: item.contentHash,
                        originalFilename: item.originalFilename,
                        fileExtension: item.fileExtension,
                        in: db
                    )
                    let stillExists = Self.storedObjectExists(
                        objectID: item.objectID,
                        contentHash: item.contentHash,
                        originalFilename: item.originalFilename,
                        fileExtension: item.fileExtension,
                        in: db
                    )
                    if didDelete {
                        removedFromDB += 1
                        deletedURLs.insert(item.url)
                    } else if !stillExists {
                        purgedOrphans += 1
                        deletedURLs.insert(item.url)
                        logger.log("sqlite object store: delete purged stale registry entry filename=\(item.url.lastPathComponent, privacy: .public) objectID=\(item.objectID ?? -1, privacy: .public)")
                    } else {
                        logger.error("sqlite object store: delete matched no rows filename=\(item.url.lastPathComponent, privacy: .public) objectID=\(item.objectID ?? -1, privacy: .public) contentHash=\(item.contentHash ?? "nil", privacy: .public)")
                    }
                }
            }
            if removedFromDB > 0 || purgedOrphans > 0 {
                manifestInvalidatedDBs.insert(dbURL.standardizedFileURL.path)
            }
            logger.log("sqlite object store: deleted count=\(removedFromDB, privacy: .public) purgedOrphans=\(purgedOrphans, privacy: .public) database=\(dbURL.lastPathComponent, privacy: .public)")
        }
        for dbPath in manifestInvalidatedDBs {
            Self.removeManifest(forDatabasePath: dbPath)
        }

        for url in deletedURLs {
            guard let match = findLazyFile(for: url),
                  var context = loadedStoreContexts[match.dbKey] else { continue }
            let key = Self.workingCopyKey(for: url)
            guard let lazyFile = context.lazyWorkingFiles.removeValue(forKey: key) else { continue }
            context.lazyWorkingURLsByID.removeValue(forKey: lazyFile.id)
            context.lazyWorkingThumbnailOrder.removeAll { $0 == lazyFile.id }
            context.metadataCacheByObjectID.removeValue(forKey: lazyFile.id)
            context.thumbnailJPEGDataByObjectID.removeValue(forKey: lazyFile.id)
            loadedStoreContexts[match.dbKey] = context
        }

        return deletedURLs
    }

    struct ThumbnailBackfillResult: Sendable {
        let candidates: Int
        let filled: Int
        let failed: Int
    }

    private struct MissingThumbnailObject: Sendable {
        let id: Int64
        let filename: String
        let fileExtension: String?
        let isEncrypted: Bool
    }

    func countObjectsMissingThumbnails(storeName: String? = nil) async throws -> Int {
        guard Self.isEnabled else { return 0 }
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        return try withSessionReadDatabase(at: dbURL) { db in
            try Self.objectsMissingThumbnails(in: db).count
        }
    }

    func backfillMissingThumbnails(
        storeName: String? = nil,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ currentFilename: String) async -> Void)? = nil
    ) async throws -> ThumbnailBackfillResult {
        guard Self.isEnabled else {
            return ThumbnailBackfillResult(candidates: 0, filled: 0, failed: 0)
        }

        let backfillStart = Date()
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        invalidateSessionReadConnection()

        let candidates = try withSessionReadDatabase(at: dbURL) { db in
            try Self.objectsMissingThumbnails(in: db)
        }
        guard !candidates.isEmpty else {
            logger.log("sqlite object store: thumbnail backfill skipped no-missing-thumbnails path=\(dbURL.path, privacy: .public)")
            return ThumbnailBackfillResult(candidates: 0, filled: 0, failed: 0)
        }

        let workerCount = min(4, max(1, PhotoLibrary.workerCount))
        logger.log("sqlite object store: thumbnail backfill begin candidates=\(candidates.count, privacy: .public) workers=\(workerCount, privacy: .public) path=\(dbURL.path, privacy: .public)")
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PictureViewerThumbnailBackfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let backfillLogger = logger
        var nextIndex = 0
        var inFlight = 0
        var filled = 0
        var failed = 0

        await withTaskGroup(of: (String, Bool).self) { group in
            func enqueueNext() {
                guard nextIndex < candidates.count else { return }
                let candidate = candidates[nextIndex]
                nextIndex += 1
                inFlight += 1
                group.addTask {
                    let filename = candidate.filename
                    let objectID = candidate.id
                    backfillLogger.log("sqlite object store: thumbnail backfill item begin id=\(objectID, privacy: .public) filename=\(filename, privacy: .public) encrypted=\(candidate.isEncrypted, privacy: .public)")
                    do {
                        let tempURL = Self.temporaryObjectURL(
                            id: objectID,
                            filename: candidate.filename,
                            fileExtension: candidate.fileExtension,
                            in: tempDirectory
                        )
                        let bytesWritten: Int
                        if candidate.isEncrypted {
                            let blob = try await SQLiteObjectStore.shared.fetchObjectBlobForThumbnail(
                                objectID: objectID,
                                isEncrypted: candidate.isEncrypted,
                                databaseURL: dbURL
                            )
                            backfillLogger.log("sqlite object store: thumbnail backfill blob read id=\(objectID, privacy: .public) filename=\(filename, privacy: .public) bytes=\(blob.count, privacy: .public)")
                            try Self.writeMaterializedData(blob, to: tempURL)
                            bytesWritten = blob.count
                        } else {
                            bytesWritten = try Self.streamObjectBlobToFile(
                                objectID: objectID,
                                databaseURL: dbURL,
                                destinationURL: tempURL,
                                playbackThresholdBytes: Int.max,
                                onPlaybackReady: Self.noopPlaybackReady
                            )
                            backfillLogger.log("sqlite object store: thumbnail backfill blob streamed id=\(objectID, privacy: .public) filename=\(filename, privacy: .public) bytes=\(bytesWritten, privacy: .public)")
                        }
                        defer { try? FileManager.default.removeItem(at: tempURL) }
                        let image = try await ThumbnailGenerator.shared.generateThumbnail(for: tempURL)
                        guard let jpeg = ThumbnailCache.jpegData(from: image) else {
                            backfillLogger.error("sqlite object store: thumbnail backfill encode failed id=\(objectID, privacy: .public) filename=\(filename, privacy: .public)")
                            return (filename, false)
                        }
                        try await SQLiteObjectStore.shared.persistThumbnailBackfill(
                            objectID: objectID,
                            thumbnailData: jpeg,
                            databaseURL: dbURL
                        )
                        backfillLogger.log("sqlite object store: thumbnail backfill item stored id=\(objectID, privacy: .public) filename=\(filename, privacy: .public) jpegBytes=\(jpeg.count, privacy: .public)")
                        return (filename, true)
                    } catch {
                        backfillLogger.error("sqlite object store: thumbnail backfill item failed id=\(objectID, privacy: .public) filename=\(filename, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                        return (filename, false)
                    }
                }
            }

            while nextIndex < candidates.count && inFlight < workerCount {
                enqueueNext()
            }

            while inFlight > 0 {
                guard let (filename, succeeded) = await group.next() else { break }
                inFlight -= 1
                if succeeded {
                    filled += 1
                } else {
                    failed += 1
                }
                backfillLogger.log("sqlite object store: thumbnail backfill progress completed=\(filled + failed, privacy: .public) total=\(candidates.count, privacy: .public) filled=\(filled, privacy: .public) failed=\(failed, privacy: .public) last=\(filename, privacy: .public)")
                if let progress {
                    let completed = filled + failed
                    if completed == candidates.count || completed.isMultiple(of: 4) {
                        await progress(completed, candidates.count, filename)
                    }
                }
                enqueueNext()
            }
        }

        let dbKey = storeContextKey(for: dbURL)
        if var context = loadedStoreContexts[dbKey] {
            context.thumbnailsHydrated = false
            loadedStoreContexts[dbKey] = context
        }
        logger.log("sqlite object store: thumbnail backfill complete candidates=\(candidates.count, privacy: .public) filled=\(filled, privacy: .public) failed=\(failed, privacy: .public) duration=\(Date().timeIntervalSince(backfillStart), privacy: .public)")
        return ThumbnailBackfillResult(candidates: candidates.count, filled: filled, failed: failed)
    }

    func fetchObjectBlobForThumbnail(
        objectID: Int64,
        isEncrypted: Bool,
        databaseURL: URL
    ) async throws -> Data {
        let keyData = isEncrypted ? try accessKeyData() : nil
        return try withSessionReadDatabase(at: databaseURL) { db in
            try Self.objectData(id: objectID, isEncrypted: isEncrypted, keyData: keyData, db: db)
        }
    }

    func persistThumbnailBackfill(
        objectID: Int64,
        thumbnailData: Data,
        databaseURL: URL
    ) async throws {
        guard !thumbnailData.isEmpty else { return }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) { db in
            try Self.createSchema(in: db)
            try Self.execPrepared(in: db, sql: "UPDATE objects SET thumbnail_data = ? WHERE id = ?;") { stmt, storage in
                try storage.bindBlob(thumbnailData, at: 1, in: stmt)
                sqlite3_bind_int64(stmt, 2, objectID)
            }
        }
        let dbKey = storeContextKey(for: databaseURL)
        if var context = loadedStoreContexts[dbKey] {
            context.thumbnailJPEGDataByObjectID[objectID] = thumbnailData
            loadedStoreContexts[dbKey] = context
        }
        if let workingURL = loadedStoreContexts[dbKey]?.lazyWorkingURLsByID[objectID] {
            await MainActor.run {
                ThumbnailCache.shared.storeJPEGData(thumbnailData, for: workingURL)
            }
        }
    }

    func storeThumbnailData(_ thumbnailData: Data, forWorkingFile url: URL) async throws {
        guard Self.isEnabled, Self.isWorkingCopyURL(url), !thumbnailData.isEmpty else { return }
        let lazyFile = findLazyFile(for: url)?.file
        let dbURL = try lazyFile?.dbURL ?? resolvedDatabaseURL()
        try withDatabase(at: dbURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) { db in
            try Self.createSchema(in: db)
            if let objectID = lazyFile?.id {
                try Self.execPrepared(in: db, sql: "UPDATE objects SET thumbnail_data = ? WHERE id = ?;") { stmt, storage in
                    try storage.bindBlob(thumbnailData, at: 1, in: stmt)
                    sqlite3_bind_int64(stmt, 2, objectID)
                }
                let dbKey = storeContextKey(for: dbURL)
                if var context = loadedStoreContexts[dbKey] {
                    context.thumbnailJPEGDataByObjectID[objectID] = thumbnailData
                    loadedStoreContexts[dbKey] = context
                }
            } else {
                let objectData = try Data(contentsOf: url)
                let contentHash = Self.contentHash(of: objectData)
                try Self.execPrepared(in: db, sql: "UPDATE objects SET thumbnail_data = ? WHERE content_hash = ?;") { stmt, storage in
                    try storage.bindBlob(thumbnailData, at: 1, in: stmt)
                    try storage.bindText(contentHash, at: 2, in: stmt)
                }
            }
            let changed = sqlite3_changes(db)
            if changed > 0 {
                logger.log("sqlite object store: stored thumbnail data filename=\(url.lastPathComponent, privacy: .public) bytes=\(thumbnailData.count, privacy: .public)")
            }
        }
    }

    func reindexDatabase(storeName: String? = nil) async throws {
        guard Self.isEnabled else { return }
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        let startedAt = Date()
        logger.log("sqlite object store: maintenance begin path=\(dbURL.path, privacy: .public)")

        do {
            try withDatabase(at: dbURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) { db in
                try Self.createSchema(in: db)
                let objectCount = try Self.objectCount(in: db)
                logger.log("sqlite object store: maintenance object-count path=\(dbURL.path, privacy: .public) objects=\(objectCount, privacy: .public)")

                logger.log("sqlite object store: maintenance reindex begin path=\(dbURL.path, privacy: .public)")
                try Self.exec("REINDEX;", in: db)
                logger.log("sqlite object store: maintenance reindex complete path=\(dbURL.path, privacy: .public)")

                logger.log("sqlite object store: maintenance optimize begin path=\(dbURL.path, privacy: .public)")
                try Self.exec("PRAGMA optimize;", in: db)
                logger.log("sqlite object store: maintenance optimize complete path=\(dbURL.path, privacy: .public)")
            }

            logger.log("sqlite object store: maintenance complete path=\(dbURL.path, privacy: .public) duration=\(Date().timeIntervalSince(startedAt), privacy: .public)")
        } catch {
            logger.error("sqlite object store: maintenance failed path=\(dbURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func ensureSecurityScopedAccess(for databaseURL: URL) throws {
        let standardized = databaseURL.standardizedFileURL
        if SecurityScopedResourceAccess.ensureAccess(for: standardized) {
            return
        }
        _ = SecurityScopedResourceAccess.ensureAccess(for: standardized.deletingLastPathComponent())
        guard FileManager.default.isReadableFile(atPath: standardized.path) else {
            logger.error("sqlite object store: security scope unavailable path=\(standardized.path, privacy: .public)")
            throw SQLiteObjectStoreError.databaseReadFailed
        }
    }

    private func ensureWritableDatabaseAccess(for databaseURL: URL) throws {
        let standardized = databaseURL.standardizedFileURL
        let directory = standardized.deletingLastPathComponent()
        let externalBlobsDirectory = directory.appendingPathComponent("ExternalBlobs", isDirectory: true)
        _ = SecurityScopedResourceAccess.ensureAccess(for: standardized)
        _ = SecurityScopedResourceAccess.ensureAccess(for: directory)
        _ = SecurityScopedResourceAccess.ensureAccess(for: externalBlobsDirectory)
        SecurityScopedResourceAccess.registerSecurityScopedURL(directory)
        guard SecurityScopedResourceAccess.probesWritableDirectory(directory) else {
            logger.error("sqlite object store: database directory is not writable path=\(directory.path, privacy: .public)")
            throw SQLiteObjectStoreError.databaseWriteFailed(reason: "The database directory is not writable.")
        }
        guard SecurityScopedResourceAccess.probesWritableDirectory(externalBlobsDirectory) else {
            logger.error("sqlite object store: external blob directory is not writable path=\(externalBlobsDirectory.path, privacy: .public)")
            throw SQLiteObjectStoreError.databaseWriteFailed(reason: "The ExternalBlobs directory is not writable.")
        }
    }

    private func resolvedDirectory() throws -> URL {
        if let bookmark = UserDefaults.standard.data(forKey: Self.directoryBookmarkKey) {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale {
                    try setDirectory(url)
                }
                return url
            } catch {
                logger.error("sqlite object store: directory bookmark resolve failed error=\(error.localizedDescription, privacy: .public)")
                UserDefaults.standard.removeObject(forKey: Self.directoryBookmarkKey)
            }
        }
        if let path = UserDefaults.standard.string(forKey: Self.directoryPathKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        throw SQLiteObjectStoreError.directoryMissing
    }

    private func resolvedDatabaseURL(storeName: String? = nil) throws -> URL {
        if let storeName {
            let requestedFilename = Self.databaseFilename(forStoreName: storeName)
            if let databasePath = UserDefaults.standard.string(forKey: Self.databasePathKey),
               URL(fileURLWithPath: databasePath).lastPathComponent == requestedFilename {
                return try resolvedDatabaseURL()
            }
            let directory = try resolvedDirectory()
            return directory.appendingPathComponent(Self.databaseFilename(forStoreName: storeName), isDirectory: false)
        }
        if let bookmark = UserDefaults.standard.data(forKey: Self.databaseBookmarkKey) {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale {
                    try setDatabaseFile(url)
                }
                return url
            } catch {
                logger.error("sqlite object store: database bookmark resolve failed error=\(error.localizedDescription, privacy: .public)")
                UserDefaults.standard.removeObject(forKey: Self.databaseBookmarkKey)
            }
        }
        if let path = UserDefaults.standard.string(forKey: Self.databasePathKey) {
            return URL(fileURLWithPath: path, isDirectory: false)
        }
        let directory = try resolvedDirectory()
        return directory.appendingPathComponent(Self.configuredDatabaseFilename, isDirectory: false)
    }

    private func accessKeyData() throws -> Data {
        if let keyData = Self.keychainKeyData() {
            return keyData
        }
        let keyData = randomData(count: 32)
        try Self.storeKeychainKeyData(keyData)
        return keyData
    }

    private func invalidateSessionReadConnection() {
        if sessionReadDBSecurityScoped, let url = sessionReadDBURL {
            url.stopAccessingSecurityScopedResource()
        }
        if let db = sessionReadDBHandle {
            sqlite3_close(db)
        }
        sessionReadDBURL = nil
        sessionReadDBHandle = nil
        sessionReadDBSecurityScoped = false
    }

    private func withEphemeralReadDatabase<T>(
        at url: URL,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        try Self.withEphemeralReadDatabase(at: url, body)
    }

    private nonisolated static func withEphemeralReadDatabase<T>(
        at url: URL,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let db = try openEphemeralReadDatabase(at: url)
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private nonisolated static func withEphemeralReadDatabase<T>(
        at url: URL,
        _ body: (OpaquePointer) async throws -> T
    ) async throws -> T {
        let db = try openEphemeralReadDatabase(at: url)
        defer { sqlite3_close(db) }
        return try await body(db)
    }

    private nonisolated static let readOnlyDatabaseOpenFlags: Int32 =
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI

    /// Read-only URI open avoids requiring a `-wal` sidecar after
    /// `PRAGMA wal_checkpoint(TRUNCATE)` leaves the DB in WAL mode without one.
    private nonisolated static func readOnlyDatabaseURI(for url: URL) -> String {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.standardizedFileURL.path
        components.queryItems = [
            URLQueryItem(name: "mode", value: "ro"),
            URLQueryItem(name: "immutable", value: "1"),
        ]
        return components.string ?? "file:\(url.standardizedFileURL.path)?mode=ro&immutable=1"
    }

    private nonisolated static func openReadOnlyDatabaseConnection(at url: URL) throws -> OpaquePointer {
        let standardized = url.standardizedFileURL
        if !SecurityScopedResourceAccess.ensureAccess(for: standardized) {
            _ = SecurityScopedResourceAccess.ensureAccess(for: standardized.deletingLastPathComponent())
        }
        guard FileManager.default.isReadableFile(atPath: standardized.path) else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        var db: OpaquePointer?
        let uri = readOnlyDatabaseURI(for: standardized)
        var openResult = sqlite3_open_v2(uri, &db, readOnlyDatabaseOpenFlags, nil)
        if openResult != SQLITE_OK {
            if let db {
                sqlite3_close(db)
            }
            db = nil
            openResult = sqlite3_open_v2(
                standardized.path,
                &db,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            )
        }
        guard openResult == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        return db
    }

    private nonisolated static func openEphemeralReadDatabase(at url: URL) throws -> OpaquePointer {
        try openReadOnlyDatabaseConnection(at: url)
    }

    private func openSessionReadDatabase(at url: URL) throws -> OpaquePointer {
        let standardized = url.standardizedFileURL
        if sessionReadDBURL == standardized, let db = sessionReadDBHandle {
            logger.log("sqlite object store: session read connection reused path=\(standardized.path, privacy: .public)")
            return db
        }
        invalidateSessionReadConnection()
        let started = standardized.startAccessingSecurityScopedResource()
        sessionReadDBSecurityScoped = started
        sessionReadDBURL = standardized
        let db = try openDatabaseConnection(at: standardized, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        sessionReadDBHandle = db
        return db
    }

    private func withSessionReadDatabase<T>(
        at url: URL,
        _ body: (OpaquePointer) async throws -> T
    ) async throws -> T {
        if syncWriteSession != nil {
            return try await Self.withEphemeralReadDatabase(at: url) { db in
                try await body(db)
            }
        }
        let db = try openSessionReadDatabase(at: url)
        return try await body(db)
    }

    private func withSessionReadDatabase<T>(
        at url: URL,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        if syncWriteSession != nil {
            return try Self.withEphemeralReadDatabase(at: url, body)
        }
        let db = try openSessionReadDatabase(at: url)
        return try body(db)
    }

    private func withDatabase(at url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, body)
    }

    private func withDatabase<T>(
        at url: URL,
        flags: Int32,
        _ body: (OpaquePointer) async throws -> T
    ) async throws -> T {
        let isReadOnly = (flags & SQLITE_OPEN_READONLY) != 0
        if isReadOnly {
            return try await withSessionReadDatabase(at: url, body)
        }
        invalidateSessionReadConnection()
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let db = try openDatabaseConnection(at: url, flags: flags)
        defer { sqlite3_close(db) }
        return try await body(db)
    }

    private func withDatabase<T>(
        at url: URL,
        flags: Int32,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let isReadOnly = (flags & SQLITE_OPEN_READONLY) != 0
        if isReadOnly {
            return try withSessionReadDatabase(at: url, body)
        }
        invalidateSessionReadConnection()
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let db = try openDatabaseConnection(at: url, flags: flags)
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func openDatabaseConnection(at url: URL, flags: Int32) throws -> OpaquePointer {
        let start = Date()
        let isReadOnly = (flags & SQLITE_OPEN_READONLY) != 0
        logger.log("sqlite object store: sqlite3_open_v2 begin path=\(url.path, privacy: .public) flags=\(flags, privacy: .public) readOnlyURI=\(isReadOnly, privacy: .public)")
        let db: OpaquePointer
        if isReadOnly {
            db = try Self.openReadOnlyDatabaseConnection(at: url)
        } else {
            var rawDB: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &rawDB, flags, nil)
            guard result == SQLITE_OK, let rawDB else {
                if let rawDB {
                    sqlite3_close(rawDB)
                }
                let message = String(cString: sqlite3_errstr(result))
                logger.error("sqlite object store: open failed path=\(url.path, privacy: .public) error=\(message, privacy: .public)")
                throw SQLiteObjectStoreError.databaseOpenFailed
            }
            sqlite3_busy_timeout(rawDB, 120_000)
            try Self.configureWriteConnectionPragmas(in: rawDB, databaseURL: url)
            db = rawDB
        }
        logger.log("sqlite object store: sqlite3_open_v2 complete path=\(url.path, privacy: .public) duration=\(Date().timeIntervalSince(start), privacy: .public)")
        return db
    }

    @discardableResult
    private nonisolated static func deleteStoredObject(
        objectID: Int64?,
        contentHash: String?,
        originalFilename: String?,
        fileExtension: String?,
        in db: OpaquePointer
    ) -> Bool {
        var hashesToTry: [String] = []
        if let contentHash, !contentHash.isEmpty {
            hashesToTry.append(contentHash)
        }
        if let objectID {
            if let resolvedHash = try? Self.contentHash(forObjectID: objectID, in: db),
               !resolvedHash.isEmpty,
               !hashesToTry.contains(resolvedHash) {
                hashesToTry.append(resolvedHash)
            }
        }

        for hash in hashesToTry {
            if runPreparedUpdate(
                in: db,
                sql: "DELETE FROM objects WHERE content_hash = ?;"
            ) { stmt, storage in
                try storage.bindText(hash, at: 1, in: stmt)
            } {
                return true
            }
        }

        if let objectID,
           runPreparedUpdate(
               in: db,
               sql: "DELETE FROM objects WHERE id = ?;"
           ) { stmt, _ in
               sqlite3_bind_int64(stmt, 1, objectID)
           } {
            return true
        }

        if let originalFilename, !originalFilename.isEmpty {
            let normalizedExtension = fileExtension ?? ""
            if runPreparedUpdate(
                in: db,
                sql: """
                DELETE FROM objects WHERE id = (
                    SELECT id FROM objects
                    WHERE original_filename = ? COLLATE NOCASE
                      AND IFNULL(file_extension, '') = ? COLLATE NOCASE
                    LIMIT 1
                );
                """
            ) { stmt, storage in
                try storage.bindText(originalFilename, at: 1, in: stmt)
                try storage.bindText(normalizedExtension, at: 2, in: stmt)
            } {
                return true
            }
        }

        return false
    }

    private nonisolated static func storedObjectExists(
        objectID: Int64?,
        contentHash: String?,
        originalFilename: String?,
        fileExtension: String?,
        in db: OpaquePointer
    ) -> Bool {
        if let objectID,
           runPreparedQuery(
               in: db,
               sql: "SELECT 1 FROM objects WHERE id = ? LIMIT 1;"
           ) { stmt, _ in
               sqlite3_bind_int64(stmt, 1, objectID)
           } {
            return true
        }

        if let contentHash, !contentHash.isEmpty,
           runPreparedQuery(
               in: db,
               sql: "SELECT 1 FROM objects WHERE content_hash = ? LIMIT 1;"
           ) { stmt, storage in
               try storage.bindText(contentHash, at: 1, in: stmt)
           } {
            return true
        }

        if let originalFilename, !originalFilename.isEmpty {
            let normalizedExtension = fileExtension ?? ""
            if runPreparedQuery(
                in: db,
                sql: """
                SELECT 1 FROM objects
                WHERE original_filename = ? COLLATE NOCASE
                  AND IFNULL(file_extension, '') = ? COLLATE NOCASE
                LIMIT 1;
                """
            ) { stmt, storage in
                try storage.bindText(originalFilename, at: 1, in: stmt)
                try storage.bindText(normalizedExtension, at: 2, in: stmt)
            } {
                return true
            }
        }

        return false
    }

    private nonisolated static func objectTableStats(at databaseURL: URL) throws -> (count: Int, maxID: Int64) {
        try withEphemeralReadDatabase(at: databaseURL) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*), IFNULL(MAX(id), 0) FROM objects;", -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SQLiteObjectStoreError.databaseReadFailed
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SQLiteObjectStoreError.databaseReadFailed
            }
            return (Int(sqlite3_column_int64(statement, 0)), sqlite3_column_int64(statement, 1))
        }
    }

    private nonisolated static func manifestContentMatchesDatabase(
        entries: [StoreManifestEntry],
        databaseURL: URL
    ) -> Bool {
        guard let stats = try? objectTableStats(at: databaseURL) else { return false }
        guard entries.count == stats.count else { return false }
        guard let manifestMaxID = entries.map(\.id).max(), manifestMaxID == stats.maxID else { return false }
        return true
    }

    private nonisolated static func removeManifest(forDatabasePath path: String) {
        guard let fileURL = manifestFileURL(forDatabasePath: path) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private nonisolated static func configureWriteConnectionPragmas(
        in db: OpaquePointer,
        databaseURL: URL
    ) throws {
        _ = databaseURL
        // Always WAL: toggling journal_mode (especially MEMORY ↔ WAL) on a connection
        // that inherits a stale -wal sidecar forces a full WAL checkpoint, which is
        // catastrophically slow on external/USB volumes. Sticking with WAL means the
        // pragma is a no-op once the DB is established.
        try exec("PRAGMA journal_mode=WAL;", in: db)
        try exec("PRAGMA synchronous=NORMAL;", in: db)
    }

    private func persistDirectoryReference(for directory: URL) throws {
        UserDefaults.standard.set(directory.path, forKey: Self.directoryPathKey)
        let started = directory.startAccessingSecurityScopedResource()
        defer { if started { directory.stopAccessingSecurityScopedResource() } }
        if let bookmark = try? directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.directoryBookmarkKey)
        }
    }

    private nonisolated static func schemaObjectExists(in db: OpaquePointer, name: String, type: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        var bindStorage = SQLiteBindStorage()
        do {
            try bindStorage.bindText(type, at: 1, in: statement)
            try bindStorage.bindText(name, at: 2, in: statement)
        } catch {
            return false
        }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private nonisolated static func applySchemaMigrations(
        in db: OpaquePointer,
        ensureFilenameIndex: Bool
    ) throws {
        if !schemaObjectExists(in: db, name: "objects", type: "table") {
            try exec("""
        CREATE TABLE IF NOT EXISTS objects (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            original_filename TEXT NOT NULL,
            original_path TEXT,
            content_hash TEXT NOT NULL UNIQUE,
            content_type TEXT,
            file_extension TEXT,
            file_size INTEGER,
            pixel_width INTEGER,
            pixel_height INTEGER,
            created_at REAL,
            modified_at REAL,
            imported_at REAL NOT NULL,
            is_encrypted INTEGER NOT NULL,
            blob_data BLOB NOT NULL,
            thumbnail_data BLOB
        );
        CREATE TABLE IF NOT EXISTS keywords (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            keyword TEXT NOT NULL UNIQUE COLLATE NOCASE
        );
        CREATE TABLE IF NOT EXISTS object_keywords (
            object_id INTEGER NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
            keyword_id INTEGER NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
            PRIMARY KEY (object_id, keyword_id)
        );
        """, in: db)
        }
        if !columnExists("thumbnail_data", inTable: "objects", db: db) {
            try exec("ALTER TABLE objects ADD COLUMN thumbnail_data BLOB;", in: db)
        }
        if !columnExists("description", inTable: "objects", db: db) {
            try exec("ALTER TABLE objects ADD COLUMN description TEXT;", in: db)
        }
        // Chunked storage for blobs larger than SQLITE_LIMIT_LENGTH. Keeps the
        // database self-contained instead of spilling into sidecar files that
        // can be lost during backup/copy.
        if !schemaObjectExists(in: db, name: "object_blob_chunks", type: "table") {
            try exec("""
        CREATE TABLE IF NOT EXISTS object_blob_chunks (
            object_id INTEGER NOT NULL REFERENCES objects(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            bytes BLOB NOT NULL,
            PRIMARY KEY (object_id, ordinal)
        );
        """, in: db)
        }
        if ensureFilenameIndex,
           !schemaObjectExists(in: db, name: "idx_objects_original_filename", type: "index") {
            Self.ensureOriginalFilenameIndex(in: db)
        }
    }

    private nonisolated static func createSchema(in db: OpaquePointer) throws {
        try applySchemaMigrations(in: db, ensureFilenameIndex: true)
    }

    private nonisolated static func ensureOriginalFilenameIndex(in db: OpaquePointer) {
        let sql = "CREATE INDEX IF NOT EXISTS idx_objects_original_filename ON objects(original_filename COLLATE NOCASE);"
        do {
            try exec(sql, in: db)
        } catch {
            Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
                .error("sqlite object store: index ensure failed; duplicate checks will use table scan sql=\(sql, privacy: .public)")
        }
    }

    private nonisolated static let batchUpsertSQL = """
    INSERT INTO objects (
        original_filename, original_path, content_hash, content_type,
        file_extension, file_size, pixel_width, pixel_height, description,
        created_at, modified_at, imported_at, is_encrypted, blob_data, thumbnail_data
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(content_hash) DO UPDATE SET
        original_filename=excluded.original_filename,
        original_path=excluded.original_path,
        content_type=excluded.content_type,
        file_extension=excluded.file_extension,
        file_size=excluded.file_size,
        pixel_width=excluded.pixel_width,
        pixel_height=excluded.pixel_height,
        description=COALESCE(excluded.description, objects.description),
        created_at=excluded.created_at,
        modified_at=excluded.modified_at,
        imported_at=excluded.imported_at,
        is_encrypted=excluded.is_encrypted,
        blob_data=excluded.blob_data,
        thumbnail_data=COALESCE(excluded.thumbnail_data, objects.thumbnail_data);
    """

    /// Uses zeroblob(?) so object payloads larger than a single bind chunk but still within
    /// SQLITE_LIMIT_LENGTH can be written incrementally via sqlite3_blob_write after the row upsert.
    /// zeroblob(0) marks rows whose bytes live in ExternalBlobs/{content_hash}.bin sidecar files.
    private nonisolated static let batchUpsertZeroBlobSQL = """
    INSERT INTO objects (
        original_filename, original_path, content_hash, content_type,
        file_extension, file_size, pixel_width, pixel_height, description,
        created_at, modified_at, imported_at, is_encrypted, blob_data, thumbnail_data
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, zeroblob(?), ?)
    ON CONFLICT(content_hash) DO UPDATE SET
        original_filename=excluded.original_filename,
        original_path=excluded.original_path,
        content_type=excluded.content_type,
        file_extension=excluded.file_extension,
        file_size=excluded.file_size,
        pixel_width=excluded.pixel_width,
        pixel_height=excluded.pixel_height,
        description=COALESCE(excluded.description, objects.description),
        created_at=excluded.created_at,
        modified_at=excluded.modified_at,
        imported_at=excluded.imported_at,
        is_encrypted=excluded.is_encrypted,
        blob_data=excluded.blob_data,
        thumbnail_data=COALESCE(excluded.thumbnail_data, objects.thumbnail_data);
    """

    private nonisolated static let incrementalBlobWriteChunkSize = 8 * 1024 * 1024
    private nonisolated static let incrementalBlobBindThresholdBytes = 1_000_000_000
    private nonisolated static let externalBlobProgressLogIntervalBytes = 64 * 1024 * 1024

    private nonisolated static func storePendingObject(
        _ object: PendingObject,
        in db: OpaquePointer,
        statement: OpaquePointer,
        shouldEncrypt: Bool,
        keyData: Data?
    ) throws -> Int64 {
        let payloadByteCount = object.sourceFileSize ?? object.objectData.count
        let useChunkedStorage = requiresExternalBlobStorage(byteCount: payloadByteCount, in: db)

        let storedData: Data
        if useChunkedStorage {
            // Chunked path encrypts per chunk during streaming; the inline blob_data column
            // is bound to zeroblob(0) and `object.objectData` is typically empty for files
            // routed through the streaming sync path.
            storedData = Data()
        } else if shouldEncrypt {
            guard let keyData,
                  let combined = try AES.GCM.seal(object.objectData, using: SymmetricKey(data: keyData)).combined
            else {
                throw SQLiteObjectStoreError.databaseWriteFailed()
            }
            storedData = combined
        } else {
            storedData = object.objectData
        }

        let objectMetadata: (contentType: String?, pixelWidth: Int?, pixelHeight: Int?, keywords: [String], description: String?)
        if let extracted = object.extractedMetadata {
            objectMetadata = (
                extracted.contentType,
                extracted.pixelWidth,
                extracted.pixelHeight,
                extracted.keywords,
                extracted.description
            )
        } else {
            objectMetadata = Self.objectMetadata(
                from: object.objectData,
                originalURL: object.originalURL,
                contentTypeIdentifier: object.contentTypeIdentifier
            )
        }
        let fileSize: Int
        let createdAt: Date?
        let modifiedAt: Date?
        if let sourceFileSize = object.sourceFileSize {
            fileSize = sourceFileSize
            createdAt = object.sourceCreatedAt
            modifiedAt = object.sourceModifiedAt
        } else {
            let fileValues = try? object.originalURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
            fileSize = fileValues?.fileSize ?? object.objectData.count
            createdAt = fileValues?.creationDate
            modifiedAt = fileValues?.contentModificationDate
        }
        if useChunkedStorage {
            let objectID = try stepUpsertObject(
                in: db,
                statement: statement,
                filename: object.originalURL.lastPathComponent,
                originalPath: object.originalURL.path,
                contentHash: object.contentHash,
                contentTypeIdentifier: objectMetadata.contentType,
                fileExtension: object.originalURL.pathExtension,
                fileSize: fileSize,
                pixelWidth: objectMetadata.pixelWidth,
                pixelHeight: objectMetadata.pixelHeight,
                description: objectMetadata.description,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                importedAt: Date(),
                isEncrypted: shouldEncrypt,
                blobData: Data(),
                thumbnailData: object.thumbnailData,
                storesBlobExternally: true
            )
            try writeChunkedBlobFromFile(
                sourceURL: object.originalURL,
                objectID: objectID,
                db: db,
                filename: object.originalURL.lastPathComponent,
                shouldEncrypt: shouldEncrypt,
                keyData: keyData
            )
            return objectID
        }
        return try stepUpsertObject(
            in: db,
            statement: statement,
            filename: object.originalURL.lastPathComponent,
            originalPath: object.originalURL.path,
            contentHash: object.contentHash,
            contentTypeIdentifier: objectMetadata.contentType,
            fileExtension: object.originalURL.pathExtension,
            fileSize: fileSize,
            pixelWidth: objectMetadata.pixelWidth,
            pixelHeight: objectMetadata.pixelHeight,
            description: objectMetadata.description,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            importedAt: Date(),
            isEncrypted: shouldEncrypt,
            blobData: storedData,
            thumbnailData: object.thumbnailData,
            storesBlobExternally: false
        )
    }

    private nonisolated static func existingFilenamesAmong(
        tabFilenames: Set<String>,
        manifestEntries: [StoreManifestEntry]
    ) -> Set<String> {
        var existing = Set<String>()
        existing.reserveCapacity(min(tabFilenames.count, manifestEntries.count))
        for entry in manifestEntries {
            let displayName = displayFilename(
                originalFilename: entry.filename,
                fileExtension: entry.fileExtension
            ).lowercased()
            if tabFilenames.contains(displayName) {
                existing.insert(displayName)
                if existing.count == tabFilenames.count {
                    break
                }
            }
        }
        return existing
    }

    nonisolated static func existingFilenamesAmong(
        tabFilenames: Set<String>,
        databaseURL: URL
    ) throws -> Set<String> {
        let queryLogger = Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
        let queryStart = Date()
        guard !tabFilenames.isEmpty else { return [] }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            queryLogger.log("sqlite duplicate check: database missing path=\(databaseURL.path, privacy: .public)")
            return []
        }
        queryLogger.log("sqlite duplicate check: query begin path=\(databaseURL.path, privacy: .public) tabFilenames=\(tabFilenames.count, privacy: .public)")
        _ = SecurityScopedResourceAccess.ensureAccess(for: databaseURL)
        _ = SecurityScopedResourceAccess.ensureAccess(for: databaseURL.deletingLastPathComponent())

        let openStart = Date()
        let db: OpaquePointer
        do {
            db = try openReadOnlyDatabaseConnection(at: databaseURL)
        } catch {
            queryLogger.error("sqlite duplicate check: db open failed path=\(databaseURL.path, privacy: .public) duration=\(Date().timeIntervalSince(openStart), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
        defer { sqlite3_close(db) }
        queryLogger.log("sqlite duplicate check: db open ok path=\(databaseURL.path, privacy: .public) duration=\(Date().timeIntervalSince(openStart), privacy: .public) elapsed=\(Date().timeIntervalSince(queryStart), privacy: .public)")

        let sql = "SELECT original_filename, file_extension FROM objects;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }

        let scanStart = Date()
        var existing = Set<String>()
        var rowsScanned = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            rowsScanned += 1
            let originalFilename = columnText(statement, 0) ?? "object"
            let fileExtension = columnText(statement, 1)
            let displayName = displayFilename(originalFilename: originalFilename, fileExtension: fileExtension).lowercased()
            if tabFilenames.contains(displayName) {
                existing.insert(displayName)
                if existing.count == tabFilenames.count {
                    break
                }
            }
        }
        queryLogger.log("sqlite duplicate check: query complete path=\(databaseURL.path, privacy: .public) rowsScanned=\(rowsScanned, privacy: .public) matched=\(existing.count, privacy: .public) scanDuration=\(Date().timeIntervalSince(scanStart), privacy: .public) totalDuration=\(Date().timeIntervalSince(queryStart), privacy: .public)")
        return existing
    }

    private nonisolated static func upsertObject(
        in db: OpaquePointer,
        filename: String,
        originalPath: String,
        contentHash: String,
        contentTypeIdentifier: String?,
        fileExtension: String,
        fileSize: Int,
        pixelWidth: Int?,
        pixelHeight: Int?,
        description: String?,
        createdAt: Date?,
        modifiedAt: Date?,
        importedAt: Date,
        isEncrypted: Bool,
        blobData: Data,
        thumbnailData: Data?
    ) throws -> Int64 {
        var statement: OpaquePointer?
        let sql = requiresIncrementalBlobWrite(byteCount: blobData.count, in: db) ? batchUpsertZeroBlobSQL : batchUpsertSQL
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteObjectStoreError.databaseWriteFailed()
        }
        defer { sqlite3_finalize(statement) }
        return try stepUpsertObject(
            in: db,
            statement: statement,
            filename: filename,
            originalPath: originalPath,
            contentHash: contentHash,
            contentTypeIdentifier: contentTypeIdentifier,
            fileExtension: fileExtension,
            fileSize: fileSize,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            description: description,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            importedAt: importedAt,
            isEncrypted: isEncrypted,
            blobData: blobData,
            thumbnailData: thumbnailData
        )
    }

    private nonisolated static func stepUpsertObject(
        in db: OpaquePointer,
        statement: OpaquePointer,
        filename: String,
        originalPath: String,
        contentHash: String,
        contentTypeIdentifier: String?,
        fileExtension: String,
        fileSize: Int,
        pixelWidth: Int?,
        pixelHeight: Int?,
        description: String?,
        createdAt: Date?,
        modifiedAt: Date?,
        importedAt: Date,
        isEncrypted: Bool,
        blobData: Data,
        thumbnailData: Data?,
        storesBlobExternally: Bool = false
    ) throws -> Int64 {
        let useExternalBlob = storesBlobExternally
        let useIncrementalBlob = !useExternalBlob && requiresIncrementalBlobWrite(byteCount: blobData.count, in: db)
        let useZeroBlobPlaceholder = useExternalBlob || useIncrementalBlob
        if useExternalBlob {
            Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
                .log("sqlite object store: external blob upsert begin filename=\(filename, privacy: .public) bytes=\(fileSize, privacy: .public) path=\(externalBlobRelativePath(contentHash: contentHash), privacy: .public) limit=\(maxSQLiteBlobBytes(in: db), privacy: .public)")
        } else if useIncrementalBlob {
            Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
                .log("sqlite object store: incremental blob upsert begin filename=\(filename, privacy: .public) bytes=\(blobData.count, privacy: .public) limit=\(maxSQLiteBlobBytes(in: db), privacy: .public)")
        }

        let activeStatement: OpaquePointer
        let ownsStatement: Bool
        if useZeroBlobPlaceholder {
            var zeroStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, batchUpsertZeroBlobSQL, -1, &zeroStatement, nil) == SQLITE_OK,
                  let zeroStatement else {
                throw SQLiteObjectStoreError.databaseWriteFailed(reason: sqliteErrorMessage(from: db))
            }
            activeStatement = zeroStatement
            ownsStatement = true
        } else {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            activeStatement = statement
            ownsStatement = false
        }
        // Function-scoped finalize: a nested `if ownsStatement { defer ... }` would fire
        // at the end of the if block, finalizing the statement before bind/step run
        // and corrupting the upsert for files routed through external/incremental blob.
        defer {
            if ownsStatement {
                sqlite3_finalize(activeStatement)
            }
        }

        var bindStorage = SQLiteBindStorage()
        try bindUpsertMetadata(
            statement: activeStatement,
            filename: filename,
            originalPath: originalPath,
            contentHash: contentHash,
            contentTypeIdentifier: contentTypeIdentifier,
            fileExtension: fileExtension,
            fileSize: fileSize,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            description: description,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            importedAt: importedAt,
            isEncrypted: isEncrypted,
            blobData: useZeroBlobPlaceholder ? nil : blobData,
            zeroBlobSize: useExternalBlob ? 0 : (useIncrementalBlob ? blobData.count : nil),
            thumbnailData: thumbnailData,
            db: db,
            storage: &bindStorage
        )
        let stepResult = sqlite3_step(activeStatement)
        guard stepResult == SQLITE_DONE else {
            logSQLiteFailure(db: db, operation: "upsert object step=\(stepResult)", filename: filename)
            throw SQLiteObjectStoreError.databaseWriteFailed(reason: sqliteErrorMessage(from: db))
        }

        let objectID = try findObjectID(contentHash: contentHash, in: db)
        if useIncrementalBlob {
            try writeIncrementalBlob(blobData, objectID: objectID, in: db, filename: filename)
            Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
                .log("sqlite object store: incremental blob upsert complete filename=\(filename, privacy: .public) bytes=\(blobData.count, privacy: .public) objectID=\(objectID, privacy: .public)")
        } else if useExternalBlob {
            Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
                .log("sqlite object store: external blob upsert complete filename=\(filename, privacy: .public) bytes=\(fileSize, privacy: .public) objectID=\(objectID, privacy: .public) path=\(externalBlobRelativePath(contentHash: contentHash), privacy: .public)")
        }
        return objectID
    }

    private nonisolated static func maxSQLiteBlobBytes(in db: OpaquePointer) -> Int64 {
        Int64(sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1))
    }

    private nonisolated static func requiresExternalBlobStorage(byteCount: Int, in db: OpaquePointer) -> Bool {
        Int64(byteCount) > maxSQLiteBlobBytes(in: db)
    }

    private nonisolated static func requiresIncrementalBlobWrite(byteCount: Int, in db: OpaquePointer) -> Bool {
        let size = Int64(byteCount)
        let limit = maxSQLiteBlobBytes(in: db)
        return size > incrementalBlobBindThresholdBytes && size <= limit
    }

    // MARK: Chunked blob storage
    //
    // Files larger than SQLite's per-row BLOB limit are stored as N chunk rows in
    // object_blob_chunks instead of an ExternalBlobs/{hash}.bin sidecar file. This
    // keeps the database file self-contained so backups can't lose the payload.

    private nonisolated static let chunkedBlobChunkBytes = 64 * 1024 * 1024

    private nonisolated static func objectHasChunks(objectID: Int64, in db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM object_blob_chunks WHERE object_id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, objectID)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private nonisolated static func deleteChunks(forObjectID objectID: Int64, in db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM object_blob_chunks WHERE object_id = ?;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw SQLiteObjectStoreError.databaseWriteFailed(reason: sqliteErrorMessage(from: db))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, objectID)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteObjectStoreError.databaseWriteFailed(reason: sqliteErrorMessage(from: db))
        }
    }

    private nonisolated static func insertChunk(
        objectID: Int64,
        ordinal: Int,
        bytes: Data,
        in db: OpaquePointer
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO object_blob_chunks (object_id, ordinal, bytes) VALUES (?, ?, ?);", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw SQLiteObjectStoreError.databaseWriteFailed(reason: sqliteErrorMessage(from: db))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, objectID)
        sqlite3_bind_int64(stmt, 2, Int64(ordinal))
        var storage = SQLiteBindStorage()
        try storage.bindBlob(bytes, at: 3, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteObjectStoreError.databaseWriteFailed(reason: sqliteErrorMessage(from: db))
        }
    }

    private nonisolated static func sealChunkIfNeeded(
        _ chunk: Data,
        shouldEncrypt: Bool,
        keyData: Data?
    ) throws -> Data {
        guard shouldEncrypt else { return chunk }
        guard let keyData,
              let combined = try AES.GCM.seal(chunk, using: SymmetricKey(data: keyData)).combined else {
            throw SQLiteObjectStoreError.databaseWriteFailed(reason: "chunk encryption failed")
        }
        return combined
    }

    @discardableResult
    private nonisolated static func writeChunkedBlobFromFile(
        sourceURL: URL,
        objectID: Int64,
        db: OpaquePointer,
        filename: String,
        shouldEncrypt: Bool,
        keyData: Data?
    ) throws -> Int {
        if objectHasChunks(objectID: objectID, in: db) {
            Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
                .log("sqlite object store: chunked blob write skipped existing chunks present filename=\(filename, privacy: .public) objectID=\(objectID, privacy: .public)")
            return 0
        }
        let started = sourceURL.startAccessingSecurityScopedResource()
        defer { if started { sourceURL.stopAccessingSecurityScopedResource() } }
        let readHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? readHandle.close() }

        let logger = Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
        let writeStart = Date()
        var ordinal = 0
        var totalWritten = 0
        var lastLoggedBytes = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try readHandle.read(upToCount: chunkedBlobChunkBytes), !chunk.isEmpty else {
                break
            }
            let payload = try sealChunkIfNeeded(chunk, shouldEncrypt: shouldEncrypt, keyData: keyData)
            try insertChunk(objectID: objectID, ordinal: ordinal, bytes: payload, in: db)
            ordinal += 1
            totalWritten += chunk.count
            if totalWritten - lastLoggedBytes >= externalBlobProgressLogIntervalBytes {
                lastLoggedBytes = totalWritten
                logger.log("sqlite object store: chunked blob write progress filename=\(filename, privacy: .public) bytes=\(totalWritten, privacy: .public) chunks=\(ordinal, privacy: .public)")
            }
        }
        logger.log("sqlite object store: chunked blob write complete filename=\(filename, privacy: .public) bytes=\(totalWritten, privacy: .public) chunks=\(ordinal, privacy: .public) duration=\(Date().timeIntervalSince(writeStart), privacy: .public)")
        return totalWritten
    }

    @discardableResult
    private nonisolated static func writeChunkedBlobFromData(
        _ data: Data,
        objectID: Int64,
        db: OpaquePointer,
        filename: String,
        shouldEncrypt: Bool,
        keyData: Data?
    ) throws -> Int {
        try deleteChunks(forObjectID: objectID, in: db)
        let logger = Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
        let writeStart = Date()
        var ordinal = 0
        var offset = 0
        var lastLoggedBytes = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + chunkedBlobChunkBytes, data.count)
            let chunk = data.subdata(in: offset..<end)
            let payload = try sealChunkIfNeeded(chunk, shouldEncrypt: shouldEncrypt, keyData: keyData)
            try insertChunk(objectID: objectID, ordinal: ordinal, bytes: payload, in: db)
            ordinal += 1
            offset = end
            if offset - lastLoggedBytes >= externalBlobProgressLogIntervalBytes {
                lastLoggedBytes = offset
                logger.log("sqlite object store: chunked blob write progress filename=\(filename, privacy: .public) bytes=\(offset, privacy: .public) chunks=\(ordinal, privacy: .public)")
            }
        }
        logger.log("sqlite object store: chunked blob write complete filename=\(filename, privacy: .public) bytes=\(data.count, privacy: .public) chunks=\(ordinal, privacy: .public) duration=\(Date().timeIntervalSince(writeStart), privacy: .public)")
        return data.count
    }

    /// Streams chunked bytes for `objectID` to a destination file. Returns total bytes
    /// written. Decrypts each chunk if `keyData` is supplied. Returns 0 if no chunks.
    private nonisolated static func streamChunksToFile(
        objectID: Int64,
        db: OpaquePointer,
        destinationURL: URL,
        keyData: Data?,
        playbackThresholdBytes: Int? = nil,
        onPlaybackReady: @escaping @Sendable () -> Void = {}
    ) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT bytes FROM object_blob_chunks WHERE object_id = ? ORDER BY ordinal;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK, let stmt else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, objectID)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? writeHandle.close() }

        var bytesWritten = 0
        var signaledPlaybackReady = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            try Task.checkCancellation()
            let chunk = columnData(stmt, 0)
            guard !chunk.isEmpty else { continue }
            let payload: Data
            if let keyData {
                let sealedBox = try AES.GCM.SealedBox(combined: chunk)
                payload = try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
            } else {
                payload = chunk
            }
            try writeHandle.write(contentsOf: payload)
            bytesWritten += payload.count
            if let playbackThresholdBytes, !signaledPlaybackReady, bytesWritten >= playbackThresholdBytes {
                signaledPlaybackReady = true
                onPlaybackReady()
            }
        }
        return bytesWritten
    }

    /// Reads all chunked bytes for `objectID` into a single Data. Used by code paths
    /// that need the full payload in memory (small/medium chunked objects).
    private nonisolated static func readChunkedBlobAsData(
        objectID: Int64,
        db: OpaquePointer,
        keyData: Data?
    ) throws -> Data {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT bytes FROM object_blob_chunks WHERE object_id = ? ORDER BY ordinal;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK, let stmt else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, objectID)

        var accumulated = Data()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chunk = columnData(stmt, 0)
            guard !chunk.isEmpty else { continue }
            if let keyData {
                let sealedBox = try AES.GCM.SealedBox(combined: chunk)
                let plain = try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
                accumulated.append(plain)
            } else {
                accumulated.append(chunk)
            }
        }
        return accumulated
    }

    private nonisolated static func databaseURL(for db: OpaquePointer) -> URL? {
        guard let path = sqlite3_db_filename(db, "main") else { return nil }
        return URL(fileURLWithPath: String(cString: path))
    }

    private nonisolated static func externalBlobRelativePath(contentHash: String) -> String {
        "ExternalBlobs/\(contentHash).bin"
    }

    private nonisolated static func externalBlobFileURL(relativePath: String, databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent(relativePath)
    }

    private nonisolated static func writeExternalBlobFile(
        from sourceURL: URL,
        contentHash: String,
        databaseURL: URL,
        filename: String
    ) throws -> String {
        let relativePath = externalBlobRelativePath(contentHash: contentHash)
        let destinationURL = externalBlobFileURL(relativePath: relativePath, databaseURL: databaseURL)
        let directory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sourceSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if sourceSize > 0,
           FileManager.default.fileExists(atPath: destinationURL.path),
           let existingSize = try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           existingSize == sourceSize {
            Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
                .log("sqlite object store: external blob write skipped existing complete filename=\(filename, privacy: .public) bytes=\(existingSize, privacy: .public) path=\(relativePath, privacy: .public)")
            return relativePath
        }

        let started = sourceURL.startAccessingSecurityScopedResource()
        defer { if started { sourceURL.stopAccessingSecurityScopedResource() } }

        let readHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? readHandle.close() }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? writeHandle.close() }

        let logger = Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
        let writeStart = Date()
        var totalWritten = 0
        var lastLoggedBytes = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try readHandle.read(upToCount: incrementalBlobWriteChunkSize), !chunk.isEmpty else {
                break
            }
            try writeHandle.write(contentsOf: chunk)
            totalWritten += chunk.count
            if totalWritten - lastLoggedBytes >= externalBlobProgressLogIntervalBytes {
                lastLoggedBytes = totalWritten
                logger.log("sqlite object store: external blob write progress filename=\(filename, privacy: .public) bytes=\(totalWritten, privacy: .public)")
            }
        }
        logger.log("sqlite object store: external blob write complete filename=\(filename, privacy: .public) bytes=\(totalWritten, privacy: .public) path=\(relativePath, privacy: .public) duration=\(Date().timeIntervalSince(writeStart), privacy: .public)")
        return relativePath
    }

    private nonisolated static func bindUpsertMetadata(
        statement: OpaquePointer,
        filename: String,
        originalPath: String,
        contentHash: String,
        contentTypeIdentifier: String?,
        fileExtension: String,
        fileSize: Int,
        pixelWidth: Int?,
        pixelHeight: Int?,
        description: String?,
        createdAt: Date?,
        modifiedAt: Date?,
        importedAt: Date,
        isEncrypted: Bool,
        blobData: Data?,
        zeroBlobSize: Int?,
        thumbnailData: Data?,
        db: OpaquePointer,
        storage: inout SQLiteBindStorage
    ) throws {
        try storage.bindText(filename, at: 1, in: statement)
        try storage.bindText(originalPath, at: 2, in: statement)
        try storage.bindText(contentHash, at: 3, in: statement)
        try storage.bindText(contentTypeIdentifier, at: 4, in: statement)
        try storage.bindText(fileExtension, at: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(fileSize))
        bindInt(pixelWidth, at: 7, in: statement)
        bindInt(pixelHeight, at: 8, in: statement)
        try storage.bindText(description, at: 9, in: statement)
        bindDate(createdAt, at: 10, in: statement)
        bindDate(modifiedAt, at: 11, in: statement)
        sqlite3_bind_double(statement, 12, importedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 13, isEncrypted ? 1 : 0)
        if let zeroBlobSize {
            sqlite3_bind_int64(statement, 14, Int64(zeroBlobSize))
        } else if let blobData {
            try storage.bindLargeBlob(blobData, at: 14, in: statement, db: db)
        } else {
            sqlite3_bind_null(statement, 14)
        }
        try storage.bindBlob(thumbnailData, at: 15, in: statement)
    }

    private nonisolated static func writeIncrementalBlob(
        _ data: Data,
        objectID: Int64,
        in db: OpaquePointer,
        filename: String
    ) throws {
        var blob: OpaquePointer?
        let openResult = sqlite3_blob_open(db, "main", "objects", "blob_data", objectID, 1, &blob)
        guard openResult == SQLITE_OK, let blob else {
            let message = sqliteErrorMessage(from: db)
            Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
                .error("sqlite object store: blob open failed filename=\(filename, privacy: .public) objectID=\(objectID, privacy: .public) error=\(message, privacy: .public)")
            throw SQLiteObjectStoreError.databaseWriteFailed(reason: message)
        }
        defer { sqlite3_blob_close(blob) }

        let writeStart = Date()
        var offset = 0
        var lastLoggedBytes = 0
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw SQLiteObjectStoreError.databaseWriteFailed(reason: "blob buffer unavailable")
            }
            while offset < data.count {
                let length = min(incrementalBlobWriteChunkSize, data.count - offset)
                let writeResult = sqlite3_blob_write(blob, baseAddress.advanced(by: offset), Int32(length), Int32(offset))
                guard writeResult == SQLITE_OK else {
                    let message = sqliteErrorMessage(from: db)
                    Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
                        .error("sqlite object store: blob write failed filename=\(filename, privacy: .public) objectID=\(objectID, privacy: .public) offset=\(offset, privacy: .public) length=\(length, privacy: .public) error=\(message, privacy: .public)")
                    throw SQLiteObjectStoreError.databaseWriteFailed(reason: message)
                }
                offset += length
                if offset - lastLoggedBytes >= externalBlobProgressLogIntervalBytes {
                    lastLoggedBytes = offset
                    Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
                        .log("sqlite object store: blob write progress filename=\(filename, privacy: .public) objectID=\(objectID, privacy: .public) bytes=\(offset, privacy: .public) total=\(data.count, privacy: .public)")
                }
            }
        }
        Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
            .log("sqlite object store: blob write complete filename=\(filename, privacy: .public) objectID=\(objectID, privacy: .public) bytes=\(data.count, privacy: .public) duration=\(Date().timeIntervalSince(writeStart), privacy: .public)")
    }

    private nonisolated static func updateObject(
        in db: OpaquePointer,
        objectID: Int64,
        filename: String,
        originalPath: String,
        contentHash: String,
        contentTypeIdentifier: String?,
        fileExtension: String,
        fileSize: Int,
        pixelWidth: Int?,
        pixelHeight: Int?,
        description: String?,
        createdAt: Date?,
        modifiedAt: Date?,
        importedAt: Date,
        isEncrypted: Bool,
        blobData: Data,
        thumbnailData: Data?
    ) throws {
        let sql = """
        UPDATE objects SET
            original_filename = ?,
            original_path = ?,
            content_hash = ?,
            content_type = ?,
            file_extension = ?,
            file_size = ?,
            pixel_width = ?,
            pixel_height = ?,
            description = ?,
            created_at = ?,
            modified_at = ?,
            imported_at = ?,
            is_encrypted = ?,
            blob_data = ?,
            thumbnail_data = COALESCE(?, thumbnail_data)
        WHERE id = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteObjectStoreError.databaseWriteFailed()
        }
        defer { sqlite3_finalize(statement) }
        var bindStorage = SQLiteBindStorage()
        try bindStorage.bindText(filename, at: 1, in: statement)
        try bindStorage.bindText(originalPath, at: 2, in: statement)
        try bindStorage.bindText(contentHash, at: 3, in: statement)
        try bindStorage.bindText(contentTypeIdentifier, at: 4, in: statement)
        try bindStorage.bindText(fileExtension, at: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(fileSize))
        bindInt(pixelWidth, at: 7, in: statement)
        bindInt(pixelHeight, at: 8, in: statement)
        try bindStorage.bindText(description, at: 9, in: statement)
        bindDate(createdAt, at: 10, in: statement)
        bindDate(modifiedAt, at: 11, in: statement)
        sqlite3_bind_double(statement, 12, importedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 13, isEncrypted ? 1 : 0)
        try bindStorage.bindLargeBlob(blobData, at: 14, in: statement, db: db)
        try bindStorage.bindBlob(thumbnailData, at: 15, in: statement)
        sqlite3_bind_int64(statement, 16, objectID)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) > 0 else {
            throw SQLiteObjectStoreError.databaseWriteFailed()
        }
    }

    private nonisolated static func replaceKeywords(_ keywords: [String], forObjectID objectID: Int64, in db: OpaquePointer) throws {
        try exec("DELETE FROM object_keywords WHERE object_id = \(objectID);", in: db)
        for keyword in keywords {
            let keywordID = try upsertKeyword(keyword, in: db)
            try exec("INSERT OR IGNORE INTO object_keywords (object_id, keyword_id) VALUES (\(objectID), \(keywordID));", in: db)
        }
    }

    private nonisolated static func upsertKeyword(_ keyword: String, in db: OpaquePointer) throws -> Int64 {
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO keywords (keyword) VALUES (?);", -1, &insert, nil) == SQLITE_OK,
              let insert else {
            throw SQLiteObjectStoreError.databaseWriteFailed()
        }
        var insertStorage = SQLiteBindStorage()
        try insertStorage.bindText(keyword, at: 1, in: insert)
        defer { sqlite3_finalize(insert) }
        guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteObjectStoreError.databaseWriteFailed() }

        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM keywords WHERE keyword = ? COLLATE NOCASE;", -1, &query, nil) == SQLITE_OK,
              let query else {
            throw SQLiteObjectStoreError.databaseWriteFailed()
        }
        var queryStorage = SQLiteBindStorage()
        try queryStorage.bindText(keyword, at: 1, in: query)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw SQLiteObjectStoreError.databaseWriteFailed() }
        return sqlite3_column_int64(query, 0)
    }

    private nonisolated static func findObjectID(contentHash: String, in db: OpaquePointer) throws -> Int64 {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM objects WHERE content_hash = ?;", -1, &query, nil) == SQLITE_OK,
              let query else {
            return sqlite3_last_insert_rowid(db)
        }
        var bindStorage = SQLiteBindStorage()
        try bindStorage.bindText(contentHash, at: 1, in: query)
        defer { sqlite3_finalize(query) }
        if sqlite3_step(query) == SQLITE_ROW {
            return sqlite3_column_int64(query, 0)
        }
        return sqlite3_last_insert_rowid(db)
    }

    private nonisolated static func objectData(
        id: Int64,
        isEncrypted: Bool,
        keyData: Data?,
        db: OpaquePointer
    ) throws -> Data {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT blob_data, content_hash, file_size FROM objects WHERE id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        let inlineData = columnData(statement, 0)
        let contentHash = columnText(statement, 1) ?? ""
        let recordedFileSize = Int(sqlite3_column_int64(statement, 2))
        if inlineData.isEmpty, objectHasChunks(objectID: id, in: db) {
            // Chunked path: per-chunk decryption is applied inside the reader. We
            // do not run the outer AES.GCM.open below because each chunk was sealed
            // independently with its own nonce.
            return try readChunkedBlobAsData(
                objectID: id,
                db: db,
                keyData: isEncrypted ? keyData : nil
            )
        }
        if inlineData.isEmpty,
           !contentHash.isEmpty,
           let databaseURL = databaseURL(for: db),
           let externalURL = resolvedExternalBlobFileURL(contentHash: contentHash, databaseURL: databaseURL) {
            let storedData = try Data(contentsOf: externalURL)
            if isEncrypted {
                guard let keyData else { throw SQLiteObjectStoreError.passwordMissing }
                let sealedBox = try AES.GCM.SealedBox(combined: storedData)
                return try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
            }
            return storedData
        }
        if inlineData.isEmpty, recordedFileSize > 0, !contentHash.isEmpty {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        let storedData = inlineData
        if isEncrypted {
            guard let keyData else { throw SQLiteObjectStoreError.passwordMissing }
            let sealedBox = try AES.GCM.SealedBox(combined: storedData)
            return try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
        }
        return storedData
    }

    private nonisolated static func objectCount(in db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM objects;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteObjectStoreError.databaseReadFailed }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private nonisolated static func columnExists(_ columnName: String, inTable tableName: String, db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(tableName));", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, 1) == columnName {
                return true
            }
        }
        return false
    }

    private nonisolated static func manifestDirectoryURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let directory = appSupport
            .appendingPathComponent("PictureViewer", isDirectory: true)
            .appendingPathComponent("SQLiteManifests", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private struct DatabaseIdentity: Sendable {
        let path: String
        let modifiedAt: TimeInterval?
        let fileSize: Int?
    }

    private nonisolated static func databaseIdentity(for url: URL) -> DatabaseIdentity {
        let standardized = url.standardizedFileURL
        let values = try? standardized.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return DatabaseIdentity(
            path: standardized.path,
            modifiedAt: values?.contentModificationDate?.timeIntervalSince1970,
            fileSize: values?.fileSize
        )
    }

    private nonisolated static func manifestMatchesDatabase(
        _ manifest: StoreManifest,
        identity: DatabaseIdentity
    ) -> Bool {
        guard manifest.databasePath == identity.path else { return false }
        if let manifestSize = manifest.databaseFileSize,
           let fileSize = identity.fileSize,
           manifestSize != fileSize {
            return false
        }
        if let fileModified = identity.modifiedAt {
            return abs(manifest.databaseModifiedAt - fileModified) < 1.0
        }
        return true
    }

    private nonisolated static func manifestFileURL(forDatabasePath path: String) -> URL? {
        guard let directory = manifestDirectoryURL() else { return nil }
        let key = safeManifestFilename(for: path)
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private nonisolated static func legacyManifestFileURL(forStoreName storeName: String) -> URL? {
        guard let directory = manifestDirectoryURL() else { return nil }
        let key = safeManifestFilename(for: storeName)
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private nonisolated static func safeManifestFilename(for key: String) -> String {
        let data = Data(key.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    private nonisolated static func decodeManifest(from data: Data) -> StoreManifest? {
        guard let manifest = try? JSONDecoder().decode(StoreManifest.self, from: data),
              manifest.version == StoreManifest.currentVersion else {
            return nil
        }
        return manifest
    }

    private nonisolated static func loadManifest(forDatabaseURL databaseURL: URL, storeName: String) -> StoreManifest? {
        let path = databaseURL.standardizedFileURL.path
        if let fileURL = manifestFileURL(forDatabasePath: path),
           let data = try? Data(contentsOf: fileURL),
           let manifest = decodeManifest(from: data) {
            return manifest
        }
        if let legacyURL = legacyManifestFileURL(forStoreName: storeName),
           let data = try? Data(contentsOf: legacyURL),
           let manifest = decodeManifest(from: data),
           manifest.databasePath == path {
            return manifest
        }
        return nil
    }

    private nonisolated static func persistManifest(
        storeName: String,
        databaseURL: URL,
        identity: DatabaseIdentity,
        rows: [ObjectWorkingFileRow]
    ) {
        guard let modifiedAt = identity.modifiedAt,
              let fileURL = manifestFileURL(forDatabasePath: identity.path) else {
            return
        }
        let manifest = StoreManifest(
            version: StoreManifest.currentVersion,
            storeName: storeName,
            databasePath: identity.path,
            databaseModifiedAt: modifiedAt,
            databaseFileSize: identity.fileSize,
            entries: rows.map {
                StoreManifestEntry(
                    id: $0.id,
                    filename: $0.filename,
                    fileExtension: $0.fileExtension,
                    isEncrypted: $0.isEncrypted,
                    contentHash: $0.contentHash
                )
            }
        )
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private nonisolated static func rowsFromManifest(
        _ manifest: StoreManifest,
        workingDirectory: URL
    ) -> [ObjectWorkingFileRow] {
        var usedFilenames: Set<String> = []
        return manifest.entries.map { entry in
            let outputURL = uniqueWorkingURL(
                filename: entry.filename,
                fallbackExtension: entry.fileExtension,
                directory: workingDirectory,
                usedFilenames: &usedFilenames
            )
            return ObjectWorkingFileRow(
                id: entry.id,
                filename: entry.filename,
                fileExtension: entry.fileExtension,
                contentHash: entry.contentHash,
                isEncrypted: entry.isEncrypted,
                outputURL: outputURL
            )
        }
    }

    private nonisolated static func ensureWorkingDirectory() throws -> URL {
        guard AppWorkingDirectory.ensureAccess() else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        let directory = workingDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static func displayFilename(originalFilename: String, fileExtension: String?) -> String {
        var cleanName = originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty {
            cleanName = "object"
        }
        cleanName = cleanName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if URL(fileURLWithPath: cleanName).pathExtension.isEmpty,
           let fileExtension,
           !fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanName += ".\(fileExtension)"
        }
        return cleanName
    }

    private nonisolated static func uniqueWorkingURL(
        filename: String,
        fallbackExtension: String?,
        directory: URL,
        usedFilenames: inout Set<String>
    ) -> URL {
        var cleanName = displayFilename(originalFilename: filename, fileExtension: fallbackExtension)

        let baseURL = URL(fileURLWithPath: cleanName)
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        var candidate = cleanName
        var suffix = 2
        while usedFilenames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(baseName)-\(suffix)" : "\(baseName)-\(suffix).\(ext)"
            suffix += 1
        }
        usedFilenames.insert(candidate.lowercased())
        return directory.appendingPathComponent(candidate, isDirectory: false)
    }

    nonisolated static func workingDirectoryURL() -> URL {
        AppWorkingDirectory.sqliteObjectStoreURL()
    }

    nonisolated static func clearWorkingCopiesOnDisk() {
        guard AppWorkingDirectory.ensureAccess() else { return }
        let directory = workingDirectoryURL()
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated static func isWorkingCopyURL(_ url: URL) -> Bool {
        let workingDirectory = workingDirectoryURL().standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath == workingDirectory || candidatePath.hasPrefix(workingDirectory + "/")
    }

    /// True when a lazy SQLite working copy still needs to be written to disk.
    /// Callers that only need a readable filesystem path can skip the actor
    /// when this returns false.
    nonisolated static func needsMaterialization(_ url: URL) -> Bool {
        isWorkingCopyURL(url) && !FileManager.default.fileExists(atPath: url.path)
    }

    private nonisolated static func workingCopyKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private nonisolated static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private nonisolated static func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data {
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: byteCount)
    }

    private struct SQLiteBindStorage {
        mutating func bindText(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
            guard let value else {
                sqlite3_bind_null(statement, index)
                return
            }
            let result = value.withCString { cString in
                pv_sqlite_bind_text_transient(statement, index, cString)
            }
            guard result == SQLITE_OK else {
                throw SQLiteObjectStoreError.databaseWriteFailed(reason: "bindText failed at index \(index) rc=\(result)")
            }
        }

        mutating func bindBlob(_ data: Data?, at index: Int32, in statement: OpaquePointer) throws {
            guard let data, !data.isEmpty else {
                sqlite3_bind_null(statement, index)
                return
            }
            let byteCount = data.count
            let result = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return SQLITE_ERROR }
                return pv_sqlite_bind_blob64_transient(
                    statement,
                    index,
                    base,
                    sqlite3_uint64(byteCount)
                )
            }
            guard result == SQLITE_OK else {
                throw SQLiteObjectStoreError.databaseWriteFailed(reason: "bindBlob failed at index \(index) rc=\(result)")
            }
        }

        mutating func bindLargeBlob(
            _ data: Data,
            at index: Int32,
            in statement: OpaquePointer,
            db: OpaquePointer
        ) throws {
            try bindBlob(data, at: index, in: statement)
        }
    }

    private nonisolated static func exec(_ sql: String, in db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? sqliteErrorMessage(from: db)
            if let error { sqlite3_free(error) }
            Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
                .error("sqlite object store: exec failed sql=\(sql, privacy: .public) error=\(message, privacy: .public)")
            throw SQLiteObjectStoreError.databaseWriteFailed(reason: message)
        }
    }

    private nonisolated static func sqliteErrorMessage(from db: OpaquePointer) -> String {
        guard let message = sqlite3_errmsg(db) else { return "unknown sqlite error" }
        return String(cString: message)
    }

    private nonisolated static func logSQLiteFailure(db: OpaquePointer, operation: String, filename: String) {
        Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
            .error("sqlite object store: \(operation, privacy: .public) failed filename=\(filename, privacy: .public) error=\(sqliteErrorMessage(from: db), privacy: .public)")
    }

    private nonisolated static func objectMetadata(
        from data: Data,
        originalURL: URL,
        contentTypeIdentifier: String?
    ) -> (contentType: String?, pixelWidth: Int?, pixelHeight: Int?, keywords: [String], description: String?) {
        let detectedType = contentTypeIdentifier ?? UTType(filenameExtension: originalURL.pathExtension)?.identifier
        let detectedUTType = detectedType.flatMap { UTType($0) }
        if PhotoLibrary.isVideoMediaFile(originalURL, contentType: detectedUTType) {
            return (detectedType, nil, nil, [], nil)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (detectedType, nil, nil, [], nil)
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int
        let height = props[kCGImagePropertyPixelHeight] as? Int
        let embedded = ImageEmbeddedMetadataReader.read(from: props)
        return (detectedType, width, height, embedded.keywords, embedded.description)
    }

    private nonisolated static func objectsMissingThumbnails(in db: OpaquePointer) throws -> [MissingThumbnailObject] {
        guard columnExists("thumbnail_data", inTable: "objects", db: db) else { return [] }
        let sql = """
        SELECT id, original_filename, file_extension, is_encrypted
        FROM objects
        WHERE thumbnail_data IS NULL OR length(thumbnail_data) = 0
        ORDER BY id;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }

        var objects: [MissingThumbnailObject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            objects.append(MissingThumbnailObject(
                id: sqlite3_column_int64(statement, 0),
                filename: columnText(statement, 1) ?? "object",
                fileExtension: columnText(statement, 2),
                isEncrypted: sqlite3_column_int(statement, 3) == 1
            ))
        }
        return objects
    }

    private nonisolated static func temporaryObjectURL(
        id: Int64,
        filename: String,
        fileExtension: String?,
        in directory: URL
    ) -> URL {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = trimmed.isEmpty ? "object-\(id)" : trimmed
        if URL(fileURLWithPath: candidate).pathExtension.isEmpty,
           let fileExtension,
           !fileExtension.isEmpty {
            candidate += ".\(fileExtension)"
        }
        let sanitized = candidate
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("\(id)-\(sanitized)", isDirectory: false)
    }

    private nonisolated static func thumbnailData(id: Int64, in db: OpaquePointer) throws -> Data? {
        guard columnExists("thumbnail_data", inTable: "objects", db: db) else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT thumbnail_data FROM objects WHERE id = ? AND thumbnail_data IS NOT NULL AND length(thumbnail_data) > 0;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let data = columnData(statement, 0)
        return data.isEmpty ? nil : data
    }

    private nonisolated static func objectDescription(id: Int64, in db: OpaquePointer) throws -> String? {
        guard columnExists("description", inTable: "objects", db: db) else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT description FROM objects WHERE id = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    private nonisolated static func objectKeywords(id: Int64, in db: OpaquePointer) throws -> [String] {
        let sql = """
        SELECT k.keyword
        FROM keywords k
        JOIN object_keywords ok ON ok.keyword_id = k.id
        WHERE ok.object_id = ?
        ORDER BY k.keyword COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        var keywords: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let keyword = columnText(statement, 0) {
                keywords.append(keyword)
            }
        }
        return keywords
    }

    private nonisolated static func keywordStrings(from value: Any) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [Any] { return values.compactMap { $0 as? String } }
        if let values = value as? NSArray { return values.compactMap { $0 as? String } }
        if let value = value as? String { return [value] }
        return []
    }

    private nonisolated static func normalizedKeywords(_ keywords: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for keyword in keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    private nonisolated static func execPrepared(
        in db: OpaquePointer,
        sql: String,
        bind: (OpaquePointer, inout SQLiteBindStorage) throws -> Void
    ) throws {
        var rawStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &rawStatement, nil) == SQLITE_OK,
              let stmt = rawStatement else {
            throw SQLiteObjectStoreError.databaseWriteFailed()
        }
        defer { sqlite3_finalize(stmt) }
        var storage = SQLiteBindStorage()
        try bind(stmt, &storage)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteObjectStoreError.databaseWriteFailed()
        }
    }

    @discardableResult
    private nonisolated static func runPreparedUpdate(
        in db: OpaquePointer,
        sql: String,
        bind: (OpaquePointer, inout SQLiteBindStorage) throws -> Void
    ) -> Bool {
        var rawStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &rawStatement, nil) == SQLITE_OK,
              let stmt = rawStatement else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        var storage = SQLiteBindStorage()
        do {
            try bind(stmt, &storage)
        } catch {
            return false
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    private nonisolated static func runPreparedQuery(
        in db: OpaquePointer,
        sql: String,
        bind: (OpaquePointer, inout SQLiteBindStorage) throws -> Void
    ) -> Bool {
        var rawStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &rawStatement, nil) == SQLITE_OK,
              let stmt = rawStatement else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        var storage = SQLiteBindStorage()
        do {
            try bind(stmt, &storage)
        } catch {
            return false
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private nonisolated static func bindInt(_ value: Int?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private nonisolated static func bindDate(_ value: Date?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private func deriveKeyData(password: String, salt: Data) -> Data {
        var data = Data()
        data.append(salt)
        data.append(Data(password.utf8))
        for _ in 0..<keyIterations {
            data = Data(SHA256.hash(data: data))
        }
        return data
    }

    private nonisolated static func keychainKeyData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private nonisolated static func storeKeychainKeyData(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data
        ]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw SQLiteObjectStoreError.passwordMissing
        }
    }
}

@_silgen_name("pv_sqlite_bind_text_transient")
private func pv_sqlite_bind_text_transient(_ statement: OpaquePointer?, _ index: Int32, _ text: UnsafePointer<CChar>?) -> Int32

@_silgen_name("pv_sqlite_bind_blob64_transient")
private func pv_sqlite_bind_blob64_transient(
    _ statement: OpaquePointer?,
    _ index: Int32,
    _ bytes: UnsafeRawPointer?,
    _ length: sqlite3_uint64
) -> Int32
