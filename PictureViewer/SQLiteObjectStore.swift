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
        let name = configuredStoreName
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
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.directoryPathKey)
        UserDefaults.standard.removeObject(forKey: Self.directoryBookmarkKey)
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
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.directoryPathKey)
        UserDefaults.standard.removeObject(forKey: Self.directoryBookmarkKey)
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
        contentTypeIdentifier: String?
    ) async {
        do {
            try storeObjectDataThrowing(
                objectData,
                originalURL: originalURL,
                contentHash: contentHash,
                contentTypeIdentifier: contentTypeIdentifier
            )
        } catch {
            logger.error("sqlite object store: failed filename=\(originalURL.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func storeObjectDataThrowing(
        _ objectData: Data,
        originalURL: URL,
        contentHash: String,
        contentTypeIdentifier: String?
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

        let dbURL = try resolvedDatabaseURL()
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
                blobData: storedData
            )
            try Self.replaceKeywords(objectMetadata.keywords, forObjectID: objectID, in: db)
        }
        logger.log("sqlite object store: stored filename=\(originalURL.lastPathComponent, privacy: .public) encrypted=\(shouldEncrypt, privacy: .public)")
    }

    func storeObjectFile(at url: URL) async throws {
        guard Self.isEnabled else { return }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let contentHash = Self.contentHash(of: data)
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
            ?? UTType(filenameExtension: url.pathExtension)?.identifier
        try storeObjectDataThrowing(
            data,
            originalURL: url,
            contentHash: contentHash,
            contentTypeIdentifier: contentType
        )
    }

    func loadObjectWorkingFiles(
        progress: (@Sendable (_ completed: Int, _ total: Int, _ urls: [URL]) async -> Void)? = nil
    ) async throws -> [URL] {
        guard Self.isEnabled else { return [] }
        let dbURL = try resolvedDatabaseURL()
        let workingDirectory = try Self.prepareWorkingDirectory()

        return try await withDatabase(at: dbURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX) { db in
            let total = try Self.objectCount(in: db)
            guard total > 0 else { return [] }

            let sql = """
            SELECT original_filename, file_extension, is_encrypted, blob_data
            FROM objects
            ORDER BY original_filename COLLATE NOCASE, id;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw SQLiteObjectStoreError.databaseReadFailed
            }
            defer { sqlite3_finalize(statement) }

            var urls: [URL] = []
            var batch: [URL] = []
            var usedFilenames: Set<String> = []
            let key = Self.encryptsBlobs ? SymmetricKey(data: try accessKeyData()) : nil

            while sqlite3_step(statement) == SQLITE_ROW {
                try Task.checkCancellation()
                let filename = Self.columnText(statement, 0) ?? "object"
                let fileExtension = Self.columnText(statement, 1)
                let isEncrypted = sqlite3_column_int(statement, 2) == 1
                let storedData = Self.columnData(statement, 3)
                let objectData: Data
                if isEncrypted {
                    guard let key else { throw SQLiteObjectStoreError.passwordMissing }
                    let sealedBox = try AES.GCM.SealedBox(combined: storedData)
                    objectData = try AES.GCM.open(sealedBox, using: key)
                } else {
                    objectData = storedData
                }

                let outputURL = Self.uniqueWorkingURL(
                    filename: filename,
                    fallbackExtension: fileExtension,
                    directory: workingDirectory,
                    usedFilenames: &usedFilenames
                )
                try objectData.write(to: outputURL, options: .atomic)
                urls.append(outputURL)
                batch.append(outputURL)

                if batch.count >= 512 {
                    let completed = urls.count
                    let emitted = batch
                    batch.removeAll(keepingCapacity: true)
                    await progress?(completed, total, emitted)
                }
            }

            if !batch.isEmpty {
                await progress?(urls.count, total, batch)
            }
            return urls
        }
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

    private func resolvedDatabaseURL() throws -> URL {
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
        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            if let db {
                sqlite3_close(db)
            }
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(result)"
            logger.error("sqlite object store: open failed path=\(url.path, privacy: .public) error=\(message, privacy: .public)")
            throw SQLiteObjectStoreError.databaseOpenFailed
        }
        sqlite3_exec(db, "PRAGMA journal_mode=MEMORY;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        return db
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
            blob_data BLOB NOT NULL
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
        blobData: Data
    ) throws -> Int64 {
        let sql = """
        INSERT INTO objects (
            original_filename, original_path, content_hash, content_type,
            file_extension, file_size, pixel_width, pixel_height,
            created_at, modified_at, imported_at, is_encrypted, blob_data
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            blob_data=excluded.blob_data;
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
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PictureViewer", isDirectory: true)
            .appendingPathComponent("SQLiteObjectStore", isDirectory: true)
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
