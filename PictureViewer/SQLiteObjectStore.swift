//
//  SQLiteObjectStore.swift
//  PictureViewer
//

import Foundation
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
    case databaseWriteFailed
    case databaseReadFailed

    var errorDescription: String? {
        switch self {
        case .directoryMissing: "Create or open a SQLite object store first."
        case .passwordMissing: "The SQLite object-store encryption key could not be created."
        case .databaseOpenFailed: "The SQLite object database could not be opened."
        case .databaseWriteFailed: "The SQLite object database could not be written."
        case .databaseReadFailed: "The SQLite object database could not be read."
        }
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
        let isEncrypted: Bool
        let outputURL: URL
    }

    private struct LazyWorkingFile: Sendable {
        let id: Int64
        let isEncrypted: Bool
        let dbURL: URL
    }

    struct PendingObject: Sendable {
        let objectData: Data
        let originalURL: URL
        let contentHash: String
        let contentTypeIdentifier: String?
        let thumbnailData: Data?

        init(
            objectData: Data,
            originalURL: URL,
            contentHash: String,
            contentTypeIdentifier: String?,
            thumbnailData: Data?
        ) {
            self.objectData = objectData
            self.originalURL = originalURL
            self.contentHash = contentHash
            self.contentTypeIdentifier = contentTypeIdentifier
            self.thumbnailData = thumbnailData
        }
    }

    private var lazyWorkingFiles: [String: LazyWorkingFile] = [:]
    private var lazyWorkingURLsByID: [Int64: URL] = [:]
    private var lazyWorkingThumbnailOrder: [Int64] = []

    private init() {}

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

    func setDirectory(_ url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: Self.directoryBookmarkKey)
        UserDefaults.standard.set(url.path, forKey: Self.directoryPathKey)
    }

    func setDatabaseFile(_ url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: Self.databaseBookmarkKey)
        UserDefaults.standard.set(url.path, forKey: Self.databasePathKey)
        try persistDirectoryReference(for: url.deletingLastPathComponent())
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.storeNameKey)
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
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.storeNameKey)
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
        storeName: String? = nil
    ) throws {
        guard Self.isEnabled else { return }
        let shouldEncrypt = Self.encryptsBlobs
        let storedData: Data
        if shouldEncrypt {
            let keyData = try accessKeyData()
            guard let combined = try AES.GCM.seal(objectData, using: SymmetricKey(data: keyData)).combined else {
                throw SQLiteObjectStoreError.databaseWriteFailed
            }
            storedData = combined
        } else {
            storedData = objectData
        }

        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        let objectMetadata = Self.objectMetadata(from: objectData, originalURL: originalURL, contentTypeIdentifier: contentTypeIdentifier)
        let fileValues = try? originalURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
        try withDatabase(at: dbURL) { db in
            try Self.createSchema(in: db)
            let objectID = try Self.upsertObject(
                in: db,
                filename: originalURL.lastPathComponent,
                originalPath: originalURL.path,
                contentHash: contentHash,
                contentTypeIdentifier: objectMetadata.contentType,
                fileExtension: originalURL.pathExtension,
                fileSize: fileValues?.fileSize ?? objectData.count,
                pixelWidth: objectMetadata.pixelWidth,
                pixelHeight: objectMetadata.pixelHeight,
                createdAt: fileValues?.creationDate,
                modifiedAt: fileValues?.contentModificationDate,
                importedAt: Date(),
                isEncrypted: shouldEncrypt,
                blobData: storedData,
                thumbnailData: thumbnailData
            )
            try Self.replaceKeywords(objectMetadata.keywords, forObjectID: objectID, in: db)
        }
        logger.log("sqlite object store: stored filename=\(originalURL.lastPathComponent, privacy: .public) encrypted=\(shouldEncrypt, privacy: .public)")
    }

    func storeObjectBatchThrowing(_ objects: [PendingObject], storeName: String? = nil) throws -> Int {
        guard Self.isEnabled, !objects.isEmpty else { return 0 }
        let batchStart = Date()
        let shouldEncrypt = Self.encryptsBlobs
        let keyData = shouldEncrypt ? try accessKeyData() : nil
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        var storedCount = 0

        try withDatabase(at: dbURL) { db in
            try Self.createSchema(in: db)
            try Self.exec("BEGIN IMMEDIATE TRANSACTION;", in: db)
            do {
                for object in objects {
                    let storedData: Data
                    if shouldEncrypt {
                        guard let keyData,
                              let combined = try AES.GCM.seal(object.objectData, using: SymmetricKey(data: keyData)).combined
                        else {
                            throw SQLiteObjectStoreError.databaseWriteFailed
                        }
                        storedData = combined
                    } else {
                        storedData = object.objectData
                    }

                    let objectMetadata = Self.objectMetadata(
                        from: object.objectData,
                        originalURL: object.originalURL,
                        contentTypeIdentifier: object.contentTypeIdentifier
                    )
                    let fileValues = try? object.originalURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
                    let objectID = try Self.upsertObject(
                        in: db,
                        filename: object.originalURL.lastPathComponent,
                        originalPath: object.originalURL.path,
                        contentHash: object.contentHash,
                        contentTypeIdentifier: objectMetadata.contentType,
                        fileExtension: object.originalURL.pathExtension,
                        fileSize: fileValues?.fileSize ?? object.objectData.count,
                        pixelWidth: objectMetadata.pixelWidth,
                        pixelHeight: objectMetadata.pixelHeight,
                        createdAt: fileValues?.creationDate,
                        modifiedAt: fileValues?.contentModificationDate,
                        importedAt: Date(),
                        isEncrypted: shouldEncrypt,
                        blobData: storedData,
                        thumbnailData: object.thumbnailData
                    )
                    try Self.replaceKeywords(objectMetadata.keywords, forObjectID: objectID, in: db)
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
        let data = try Data(contentsOf: url)
        let contentHash = Self.contentHash(of: data)
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
            ?? UTType(filenameExtension: url.pathExtension)?.identifier
        let thumbnailData = await MainActor.run {
            ThumbnailCache.shared.jpegData(for: url)
        }
        try storeObjectDataThrowing(
            data,
            originalURL: url,
            contentHash: contentHash,
            contentTypeIdentifier: contentType,
            thumbnailData: thumbnailData
        )
    }

    func loadObjectWorkingFiles(
        storeName: String? = nil,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ urls: [URL]) async -> Void)? = nil
    ) async throws -> [URL] {
        guard Self.isEnabled else { return [] }
        let loadStart = Date()
        logger.log("sqlite object store: load begin storeName=\(storeName ?? Self.configuredStoreName, privacy: .public)")
        let dbURL = try resolvedDatabaseURL(storeName: storeName)
        logger.log("sqlite object store: resolved database path=\(dbURL.path, privacy: .public) elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
        let workingDirectory = try Self.prepareWorkingDirectory()
        logger.log("sqlite object store: prepared working directory path=\(workingDirectory.path, privacy: .public) elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
        lazyWorkingFiles.removeAll()

        let rows: [ObjectWorkingFileRow] = try await withDatabase(at: dbURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX) { db in
            let dbOpenElapsed = Date().timeIntervalSince(loadStart)
            logger.log("sqlite object store: db open complete path=\(dbURL.path, privacy: .public) elapsed=\(dbOpenElapsed, privacy: .public)")
            let total = try Self.objectCount(in: db)
            logger.log("sqlite object store: sql complete command=\"SELECT COUNT(*) FROM objects;\" rows=\(total, privacy: .public) elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
            guard total > 0 else { return [] as [ObjectWorkingFileRow] }
            logger.log("sqlite object store: schema check skipped thumbnail blobs during open elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")

            let sql = """
            SELECT id, original_filename, file_extension, is_encrypted
            FROM objects
            ORDER BY original_filename COLLATE NOCASE, id;
            """
            logger.log("sqlite object store: sql prepare command=\(sql, privacy: .public)")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw SQLiteObjectStoreError.databaseReadFailed
            }
            logger.log("sqlite object store: sql prepare complete elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
            defer { sqlite3_finalize(statement) }

            var usedFilenames: Set<String> = []
            var rows: [ObjectWorkingFileRow] = []
            await progress?(0, total, [])
            let stepStart = Date()

            while sqlite3_step(statement) == SQLITE_ROW {
                try Task.checkCancellation()
                let id = sqlite3_column_int64(statement, 0)
                let filename = Self.columnText(statement, 1) ?? "object"
                let fileExtension = Self.columnText(statement, 2)
                let isEncrypted = sqlite3_column_int(statement, 3) == 1
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
                    isEncrypted: isEncrypted,
                    outputURL: outputURL
                ))

            }
            logger.log("sqlite object store: sql step complete command=\"metadata select\" rows=\(rows.count, privacy: .public) duration=\(Date().timeIntervalSince(stepStart), privacy: .public) elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
            return rows
        }

        guard !rows.isEmpty else { return [] }
        let urls = rows.map(\.outputURL)
        let registryStart = Date()
        lazyWorkingURLsByID.removeAll()
        lazyWorkingThumbnailOrder = []
        for row in rows {
            self.lazyWorkingFiles[Self.workingCopyKey(for: row.outputURL)] = LazyWorkingFile(
                id: row.id,
                isEncrypted: row.isEncrypted,
                dbURL: dbURL
            )
            self.lazyWorkingURLsByID[row.id] = row.outputURL
            self.lazyWorkingThumbnailOrder.append(row.id)
        }
        logger.log("sqlite object store: lazy registry complete count=\(rows.count, privacy: .public) duration=\(Date().timeIntervalSince(registryStart), privacy: .public) elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
        let metadataBatchSize = 256
        let publishStart = Date()
        for batchStart in stride(from: 0, to: urls.count, by: metadataBatchSize) {
            let batchEnd = min(batchStart + metadataBatchSize, urls.count)
            await progress?(batchEnd, rows.count, Array(urls[batchStart..<batchEnd]))
        }
        logger.log("sqlite object store: progress publish complete batches=\((urls.count + metadataBatchSize - 1) / metadataBatchSize, privacy: .public) duration=\(Date().timeIntervalSince(publishStart), privacy: .public) elapsed=\(Date().timeIntervalSince(loadStart), privacy: .public)")
        logger.log("sqlite object store: load complete metadataOnly=true objects=\(rows.count, privacy: .public) lazyWorkingFiles=\(rows.count, privacy: .public) totalDuration=\(Date().timeIntervalSince(loadStart), privacy: .public)")
        return urls
    }

    func materializeWorkingCopyIfNeeded(_ url: URL) async throws -> URL {
        guard Self.isWorkingCopyURL(url) else { return url }
        if FileManager.default.fileExists(atPath: url.path) {
            logger.log("sqlite object store: materialize skipped existing filename=\(url.lastPathComponent, privacy: .public)")
            return url
        }
        guard let lazyFile = lazyWorkingFiles[Self.workingCopyKey(for: url)] else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }

        let materializeStart = Date()
        logger.log("sqlite object store: materialize begin filename=\(url.lastPathComponent, privacy: .public)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existingThumbnail = await MainActor.run {
            ThumbnailCache.shared.memoryImage(for: url)
        }
        logger.log("sqlite object store: materialize thumbnail lookup complete elapsed=\(Date().timeIntervalSince(materializeStart), privacy: .public)")
        let keyData = lazyFile.isEncrypted ? try accessKeyData() : nil
        logger.log("sqlite object store: materialize key ready encrypted=\(lazyFile.isEncrypted, privacy: .public) elapsed=\(Date().timeIntervalSince(materializeStart), privacy: .public)")
        let objectData = try Self.objectData(
            id: lazyFile.id,
            isEncrypted: lazyFile.isEncrypted,
            keyData: keyData,
            dbURL: lazyFile.dbURL
        )
        logger.log("sqlite object store: materialize blob read complete bytes=\(objectData.count, privacy: .public) elapsed=\(Date().timeIntervalSince(materializeStart), privacy: .public)")
        try objectData.write(to: url, options: .atomic)
        if let existingThumbnail {
            await MainActor.run {
                ThumbnailCache.shared.store(existingThumbnail, for: url)
            }
        }
        logger.log("sqlite object store: materialize complete filename=\(url.lastPathComponent, privacy: .public) bytes=\(objectData.count, privacy: .public) duration=\(Date().timeIntervalSince(materializeStart), privacy: .public)")
        return url
    }

    func hydrateStoredThumbnailsForLoadedObjects(
        progress: (@Sendable (_ decoded: Int, _ total: Int) async -> Void)? = nil
    ) async throws -> Int {
        let thumbnailURLsByID = lazyWorkingURLsByID
        guard !thumbnailURLsByID.isEmpty else { return 0 }
        guard let dbURL = lazyWorkingFiles.values.first?.dbURL else { return 0 }
        let orderedIDs = lazyWorkingThumbnailOrder.filter { thumbnailURLsByID[$0] != nil }
        guard !orderedIDs.isEmpty else { return 0 }

        let hydrateStart = Date()
        logger.log("sqlite object store: async thumbnail hydration begin candidates=\(orderedIDs.count, privacy: .public)")

        let hasThumbnailData = try withDatabase(at: dbURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX) { db in
            guard Self.columnExists("thumbnail_data", inTable: "objects", db: db) else {
                return false
            }
            return true
        }
        guard hasThumbnailData else { return 0 }

        let batchSize = 1
        var decodedTotal = 0
        for batchStart in stride(from: 0, to: orderedIDs.count, by: batchSize) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + batchSize, orderedIDs.count)
            let batchIDs = Array(orderedIDs[batchStart..<batchEnd])
            let batchReadStart = Date()
            let thumbnails: [(URL, Data)] = try withDatabase(at: dbURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX) { db in
                let sql = "SELECT thumbnail_data FROM objects WHERE id = ?;"
                logger.log("sqlite object store: async thumbnail batch sql prepare command=\(sql, privacy: .public) batchStart=\(batchStart, privacy: .public) batchEnd=\(batchEnd, privacy: .public)")
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                    throw SQLiteObjectStoreError.databaseReadFailed
                }
                defer { sqlite3_finalize(statement) }

                var result: [(URL, Data)] = []
                for id in batchIDs {
                    try Task.checkCancellation()
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_int64(statement, 1, id)
                    if sqlite3_step(statement) == SQLITE_ROW,
                       let url = thumbnailURLsByID[id] {
                        let thumbnailData = Self.columnData(statement, 0)
                        if !thumbnailData.isEmpty {
                            result.append((url, thumbnailData))
                        }
                    }
                }
                return result
            }

            let decodedBatchCount = await MainActor.run {
                var count = 0
                for (url, data) in thumbnails {
                    if let image = ThumbnailCache.image(fromJPEGData: data) {
                        ThumbnailCache.shared.store(image, for: url)
                        count += 1
                    }
                }
                return count
            }
            decodedTotal += decodedBatchCount
            logger.log("sqlite object store: async thumbnail batch complete batchStart=\(batchStart, privacy: .public) batchEnd=\(batchEnd, privacy: .public) decodedBatch=\(decodedBatchCount, privacy: .public) decodedTotal=\(decodedTotal, privacy: .public) duration=\(Date().timeIntervalSince(batchReadStart), privacy: .public) elapsed=\(Date().timeIntervalSince(hydrateStart), privacy: .public)")
            await progress?(decodedTotal, orderedIDs.count)
        }

        logger.log("sqlite object store: async thumbnail hydration complete decoded=\(decodedTotal, privacy: .public) duration=\(Date().timeIntervalSince(hydrateStart), privacy: .public)")
        return decodedTotal
    }

    /// Deletes objects from the SQLite store identified by the working-file
    /// URLs returned from `loadObjectWorkingFiles`. The working file's content
    /// is the same data we stored (after decryption when applicable), so its
    /// SHA-256 maps 1:1 to the `content_hash` column. Records are removed
    /// from the database; the original imported source file on disk is never
    /// touched.
    func deleteObjects(at urls: [URL]) async throws -> Int {
        guard Self.isEnabled, !urls.isEmpty else { return 0 }
        let dbURL = try resolvedDatabaseURL()
        let hashes = urls.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return Self.contentHash(of: data)
        }
        guard !hashes.isEmpty else { return 0 }
        return try withDatabase(at: dbURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) { db in
            var deleted = 0
            for hash in hashes {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM objects WHERE content_hash = ?;", -1, &statement, nil) == SQLITE_OK,
                      let statement else { continue }
                Self.bindText(hash, at: 1, in: statement)
                if sqlite3_step(statement) == SQLITE_DONE {
                    deleted += Int(sqlite3_changes(db))
                }
                sqlite3_finalize(statement)
            }
            return deleted
        }
    }

    func storeThumbnailData(_ thumbnailData: Data, forWorkingFile url: URL) async throws {
        guard Self.isEnabled, Self.isWorkingCopyURL(url), !thumbnailData.isEmpty else { return }
        let objectData = try Data(contentsOf: url)
        let contentHash = Self.contentHash(of: objectData)
        let dbURL = try resolvedDatabaseURL()
        try withDatabase(at: dbURL, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX) { db in
            try Self.createSchema(in: db)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE objects SET thumbnail_data = ? WHERE content_hash = ?;", -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SQLiteObjectStoreError.databaseWriteFailed
            }
            defer { sqlite3_finalize(statement) }
            Self.bindBlob(thumbnailData, at: 1, in: statement)
            Self.bindText(contentHash, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteObjectStoreError.databaseWriteFailed
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

    private func withDatabase(at url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, body)
    }

    private func withDatabase<T>(
        at url: URL,
        flags: Int32,
        _ body: (OpaquePointer) async throws -> T
    ) async throws -> T {
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
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let db = try openDatabaseConnection(at: url, flags: flags)
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func openDatabaseConnection(at url: URL, flags: Int32) throws -> OpaquePointer {
        let start = Date()
        logger.log("sqlite object store: sqlite3_open_v2 begin path=\(url.path, privacy: .public) flags=\(flags, privacy: .public)")
        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            if let db {
                sqlite3_close(db)
            }
            let message = String(cString: sqlite3_errstr(result))
            logger.error("sqlite object store: open failed path=\(url.path, privacy: .public) error=\(message, privacy: .public)")
            throw SQLiteObjectStoreError.databaseOpenFailed
        }
        logger.log("sqlite object store: sqlite3_open_v2 complete path=\(url.path, privacy: .public) duration=\(Date().timeIntervalSince(start), privacy: .public)")
        logger.log("sqlite object store: pragma begin command=\"PRAGMA journal_mode=MEMORY;\"")
        sqlite3_exec(db, "PRAGMA journal_mode=MEMORY;", nil, nil, nil)
        logger.log("sqlite object store: pragma complete command=\"PRAGMA journal_mode=MEMORY;\" elapsed=\(Date().timeIntervalSince(start), privacy: .public)")
        logger.log("sqlite object store: pragma begin command=\"PRAGMA synchronous=NORMAL;\"")
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        logger.log("sqlite object store: pragma complete command=\"PRAGMA synchronous=NORMAL;\" elapsed=\(Date().timeIntervalSince(start), privacy: .public)")
        return db
    }

    private func persistDirectoryReference(for directory: URL) throws {
        UserDefaults.standard.set(directory.path, forKey: Self.directoryPathKey)
        let started = directory.startAccessingSecurityScopedResource()
        defer { if started { directory.stopAccessingSecurityScopedResource() } }
        if let bookmark = try? directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.directoryBookmarkKey)
        }
    }

    private nonisolated static func createSchema(in db: OpaquePointer) throws {
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
        if !columnExists("thumbnail_data", inTable: "objects", db: db) {
            try exec("ALTER TABLE objects ADD COLUMN thumbnail_data BLOB;", in: db)
        }
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
        createdAt: Date?,
        modifiedAt: Date?,
        importedAt: Date,
        isEncrypted: Bool,
        blobData: Data,
        thumbnailData: Data?
    ) throws -> Int64 {
        let sql = """
        INSERT INTO objects (
            original_filename, original_path, content_hash, content_type,
            file_extension, file_size, pixel_width, pixel_height,
            created_at, modified_at, imported_at, is_encrypted, blob_data, thumbnail_data
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(content_hash) DO UPDATE SET
            original_filename=excluded.original_filename,
            original_path=excluded.original_path,
            content_type=excluded.content_type,
            file_extension=excluded.file_extension,
            file_size=excluded.file_size,
            pixel_width=excluded.pixel_width,
            pixel_height=excluded.pixel_height,
            created_at=excluded.created_at,
            modified_at=excluded.modified_at,
            imported_at=excluded.imported_at,
            is_encrypted=excluded.is_encrypted,
            blob_data=excluded.blob_data,
            thumbnail_data=COALESCE(excluded.thumbnail_data, objects.thumbnail_data);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteObjectStoreError.databaseWriteFailed
        }
        defer { sqlite3_finalize(statement) }
        bindText(filename, at: 1, in: statement)
        bindText(originalPath, at: 2, in: statement)
        bindText(contentHash, at: 3, in: statement)
        bindText(contentTypeIdentifier, at: 4, in: statement)
        bindText(fileExtension, at: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(fileSize))
        bindInt(pixelWidth, at: 7, in: statement)
        bindInt(pixelHeight, at: 8, in: statement)
        bindDate(createdAt, at: 9, in: statement)
        bindDate(modifiedAt, at: 10, in: statement)
        sqlite3_bind_double(statement, 11, importedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 12, isEncrypted ? 1 : 0)
        _ = blobData.withUnsafeBytes { bytes in
            sqlite3_bind_blob64(statement, 13, bytes.baseAddress, sqlite3_uint64(blobData.count), sqliteTransientDestructor())
        }
        bindBlob(thumbnailData, at: 14, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteObjectStoreError.databaseWriteFailed
        }
        return findObjectID(contentHash: contentHash, in: db)
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
            throw SQLiteObjectStoreError.databaseWriteFailed
        }
        bindText(keyword, at: 1, in: insert)
        defer { sqlite3_finalize(insert) }
        guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteObjectStoreError.databaseWriteFailed }

        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM keywords WHERE keyword = ? COLLATE NOCASE;", -1, &query, nil) == SQLITE_OK,
              let query else {
            throw SQLiteObjectStoreError.databaseWriteFailed
        }
        bindText(keyword, at: 1, in: query)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw SQLiteObjectStoreError.databaseWriteFailed }
        return sqlite3_column_int64(query, 0)
    }

    private nonisolated static func findObjectID(contentHash: String, in db: OpaquePointer) -> Int64 {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM objects WHERE content_hash = ?;", -1, &query, nil) == SQLITE_OK,
              let query else {
            return sqlite3_last_insert_rowid(db)
        }
        bindText(contentHash, at: 1, in: query)
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
        dbURL: URL
    ) throws -> Data {
        let started = dbURL.startAccessingSecurityScopedResource()
        defer { if started { dbURL.stopAccessingSecurityScopedResource() } }

        var db: OpaquePointer?
        let result = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let db else {
            if let db {
                sqlite3_close(db)
            }
            throw SQLiteObjectStoreError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT blob_data FROM objects WHERE id = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteObjectStoreError.databaseReadFailed
        }
        let storedData = columnData(statement, 0)
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

    private nonisolated static func prepareWorkingDirectory() throws -> URL {
        let directory = workingDirectoryURL()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private nonisolated static func uniqueWorkingURL(
        filename: String,
        fallbackExtension: String?,
        directory: URL,
        usedFilenames: inout Set<String>
    ) -> URL {
        var cleanName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty {
            cleanName = "object"
        }
        cleanName = cleanName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if URL(fileURLWithPath: cleanName).pathExtension.isEmpty,
           let fallbackExtension,
           !fallbackExtension.isEmpty {
            cleanName += ".\(fallbackExtension)"
        }

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
        let directory = workingDirectoryURL()
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated static func isWorkingCopyURL(_ url: URL) -> Bool {
        let workingDirectory = workingDirectoryURL().standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath == workingDirectory || candidatePath.hasPrefix(workingDirectory + "/")
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

    private nonisolated static func bindBlob(_ data: Data?, at index: Int32, in statement: OpaquePointer) {
        guard let data, !data.isEmpty else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob64(statement, index, bytes.baseAddress, sqlite3_uint64(data.count), sqliteTransientDestructor())
        }
    }

    private nonisolated static func exec(_ sql: String, in db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            sqlite3_free(error)
            throw SQLiteObjectStoreError.databaseWriteFailed
        }
    }

    private nonisolated static func objectMetadata(
        from data: Data,
        originalURL: URL,
        contentTypeIdentifier: String?
    ) -> (contentType: String?, pixelWidth: Int?, pixelHeight: Int?, keywords: [String]) {
        let detectedType = contentTypeIdentifier ?? UTType(filenameExtension: originalURL.pathExtension)?.identifier
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (detectedType, nil, nil, [])
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int
        let height = props[kCGImagePropertyPixelHeight] as? Int
        var keywords: [String] = []
        if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
           let values = iptc[kCGImagePropertyIPTCKeywords] {
            keywords.append(contentsOf: keywordStrings(from: values))
        }
        return (detectedType, width, height, normalizedKeywords(keywords))
    }

    private nonisolated static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
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

    private nonisolated static func bindText(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor())
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

private nonisolated func sqliteTransientDestructor() -> sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
