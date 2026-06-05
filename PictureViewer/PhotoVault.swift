//
//  PhotoVault.swift
//  PictureViewer
//

import Foundation
import CryptoKit
import AppKit
import UniformTypeIdentifiers
import os

enum PhotoVaultError: LocalizedError {
    case locationMissing
    case passwordMissing
    case passwordIncorrect
    case invalidEncryptedFile
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .locationMissing: "Choose an encrypted storage location in Settings first."
        case .passwordMissing: "Enter the encrypted storage password in Settings first."
        case .passwordIncorrect: "The encrypted storage password is incorrect."
        case .invalidEncryptedFile: "The encrypted file is not a Picture Viewer vault file."
        case .unsupportedFile: "The file is not a supported image."
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

actor PhotoVault {
    static let shared = PhotoVault()

    static let locationBookmarkKey = "photoVaultLocationBookmark"
    static let locationPathKey = "photoVaultLocationPath"
    static let passwordSaltKey = "photoVaultPasswordSalt"
    static let passwordVerifierKey = "photoVaultPasswordVerifier"
    static let workingMapKey = "photoVaultWorkingMap"
    static let encryptedExtension = "pvencrypted"

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
    }

    private let logger = Logger(subsystem: "com.example.PictureViewer", category: "vault")
    private let magic = Data("PVENC1\n".utf8)
    private let keyIterations = 120_000
    private var key: SymmetricKey?
    private var locationURL: URL?

    private struct Header: Codable {
        let version: Int
        let originalFilename: String
        let originalRelativePath: String?
        let importedAt: Date
        let contentTypeIdentifier: String?
    }

    private init() {}

    func status() -> PhotoVaultStatus {
        let location = resolvedLocationURL()
        let hasPassword = UserDefaults.standard.data(forKey: Self.passwordSaltKey) != nil
        return PhotoVaultStatus(
            isConfigured: location != nil && hasPassword,
            hasLocation: location != nil,
            hasPassword: hasPassword,
            isUnlocked: key != nil,
            locationPath: location?.path ?? UserDefaults.standard.string(forKey: Self.locationPathKey)
        )
    }

    func setLocation(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: Self.locationBookmarkKey)
        UserDefaults.standard.set(url.path, forKey: Self.locationPathKey)
        locationURL = url
        _ = url.startAccessingSecurityScopedResource()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func configureNewVaultPassword(_ password: String) throws {
        guard resolvedLocationURL() != nil else { throw PhotoVaultError.locationMissing }
        try setPassword(password)
    }

    func setPassword(_ password: String) throws {
        guard !password.isEmpty else { throw PhotoVaultError.passwordMissing }
        let salt = randomData(count: 16)
        let verifier = deriveKeyData(password: password, salt: salt, iterations: keyIterations)
        UserDefaults.standard.set(salt, forKey: Self.passwordSaltKey)
        UserDefaults.standard.set(verifier, forKey: Self.passwordVerifierKey)
        key = SymmetricKey(data: verifier)
    }

    func unlock(password: String) throws {
        guard let salt = UserDefaults.standard.data(forKey: Self.passwordSaltKey),
              let verifier = UserDefaults.standard.data(forKey: Self.passwordVerifierKey)
        else {
            try setPassword(password)
            return
        }
        let candidate = deriveKeyData(password: password, salt: salt, iterations: keyIterations)
        guard candidate == verifier else { throw PhotoVaultError.passwordIncorrect }
        key = SymmetricKey(data: candidate)
    }

    func importFiles(
        _ urls: [URL],
        progress: (@Sendable (Int, Int, String) async -> Void)? = nil
    ) async throws -> [URL] {
        guard !urls.isEmpty else { return [] }
        let destination = try vaultLocation()
        let activeKey = try unlockedKey()
        var workingURLs: [URL] = []
        logger.log("vault import:start requested=\(urls.count, privacy: .public) destination=\(destination.path, privacy: .public)")
        for (index, url) in urls.enumerated() {
            if Task.isCancelled { break }
            await progress?(index, urls.count, url.lastPathComponent)
            do {
                guard isImageFile(url) else {
                    logger.error("vault import:unsupported file=\(url.path, privacy: .public)")
                    continue
                }
                let encryptedURL = uniqueEncryptedURL(for: url.lastPathComponent, in: destination)
                try encryptFile(at: url, to: encryptedURL, key: activeKey)
                let workingURL = try decryptFile(at: encryptedURL, key: activeKey)
                setEncryptedURL(encryptedURL, forWorkingURL: workingURL)
                workingURLs.append(workingURL)
                logger.log("vault import:file success source=\(url.lastPathComponent, privacy: .public) encrypted=\(encryptedURL.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("vault import:file failed source=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        await progress?(urls.count, urls.count, "")
        logger.log("vault import:finished requested=\(urls.count, privacy: .public) stored=\(workingURLs.count, privacy: .public)")
        return workingURLs
    }

    func loadWorkingCopies() async throws -> [URL] {
        let destination = try vaultLocation()
        let activeKey = try unlockedKey()
        try clearWorkingDirectory()
        var urls: [URL] = []
        let contents = try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for encryptedURL in contents where encryptedURL.pathExtension == Self.encryptedExtension {
            if Task.isCancelled { break }
            do {
                let workingURL = try decryptFile(at: encryptedURL, key: activeKey)
                setEncryptedURL(encryptedURL, forWorkingURL: workingURL)
                urls.append(workingURL)
            } catch {
                logger.error("loadWorkingCopies: failed for \(encryptedURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return urls.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
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
        try? FileManager.default.removeItem(at: encryptedURL)
        removeMapping(forWorkingURL: workingURL)
    }

    func clearWorkingCopiesForShutdown() {
        Self.clearWorkingCopiesOnDisk()
    }

    private func encryptFile(at sourceURL: URL, to encryptedURL: URL, key: SymmetricKey) throws {
        let values = try sourceURL.resourceValues(forKeys: [.contentTypeKey])
        guard values.contentType?.conforms(to: .image) == true || isImageFile(sourceURL) else {
            throw PhotoVaultError.unsupportedFile
        }
        let data = try Data(contentsOf: sourceURL)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw PhotoVaultError.invalidEncryptedFile }
        let header = Header(
            version: 1,
            originalFilename: sourceURL.lastPathComponent,
            originalRelativePath: nil,
            importedAt: Date(),
            contentTypeIdentifier: values.contentType?.identifier
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

    private func decryptFile(at encryptedURL: URL, key: SymmetricKey) throws -> URL {
        let (data, header) = try decryptPayload(at: encryptedURL, key: key)
        let workingURL = try uniqueWorkingURL(for: header.originalFilename)
        try data.write(to: workingURL, options: .atomic)
        return workingURL
    }

    private func decryptPayload(at encryptedURL: URL, key: SymmetricKey) throws -> (Data, Header) {
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

    private func workingDirectory() throws -> URL {
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
        UserDefaults.standard.removeObject(forKey: Self.workingMapKey)
    }

    private func uniqueWorkingURL(for filename: String) throws -> URL {
        uniquePlainURL(for: "\(UUID().uuidString)_\(filename)", in: try workingDirectory())
    }

    private func uniquePlainURL(for filename: String, in folder: URL) -> URL {
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

    private func uniqueEncryptedURL(for filename: String, in folder: URL) -> URL {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let safeStem = stem.isEmpty ? UUID().uuidString : PhotoLibrary.safeFilename(for: stem)
        var candidate = folder.appendingPathComponent(safeStem).appendingPathExtension(Self.encryptedExtension)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(safeStem)-\(index)").appendingPathExtension(Self.encryptedExtension)
            index += 1
        }
        return candidate
    }

    private func isImageFile(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           values.contentType?.conforms(to: .image) == true {
            return true
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private func encryptedURL(forWorkingURL workingURL: URL) -> URL? {
        workingMap()[workingURL.path].map { URL(fileURLWithPath: $0) }
    }

    private func setEncryptedURL(_ encryptedURL: URL, forWorkingURL workingURL: URL) {
        var map = workingMap()
        map[workingURL.path] = encryptedURL.path
        UserDefaults.standard.set(map, forKey: Self.workingMapKey)
    }

    private func removeMapping(forWorkingURL workingURL: URL) {
        var map = workingMap()
        map.removeValue(forKey: workingURL.path)
        UserDefaults.standard.set(map, forKey: Self.workingMapKey)
    }

    private func workingMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.workingMapKey) as? [String: String] ?? [:]
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
