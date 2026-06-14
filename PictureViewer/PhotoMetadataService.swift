//
//  PhotoMetadataService.swift
//  PictureViewer
//

import Foundation
import ImageIO
import os

enum PhotoMetadataService {
    private enum KeywordWriteMode: Sendable {
        case append
        case replace
    }

    static func parseKeywordInput(_ input: String) -> [String] {
        var keywords: [String] = []
        var seen: Set<String> = []
        for part in input.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" }) {
            let keyword = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty else { continue }
            let key = keyword.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if seen.insert(key).inserted {
                keywords.append(keyword)
            }
        }
        return keywords
    }

    static func writeKeywords(to url: URL, keywords: [String]) async -> Bool {
        await updateKeywords(on: url, keywords: keywords, mode: .append)
    }

    static func replaceKeywords(on url: URL, keywords: [String]) async -> Bool {
        await updateKeywords(on: url, keywords: keywords, mode: .replace)
    }

    static func readKeywords(from url: URL) async -> [String] {
        await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
            else {
                return []
            }
            return mergedKeywords([], keywordStrings(from: iptc[kCGImagePropertyIPTCKeywords]))
        }.value
    }

    static func writeDescription(to url: URL, description: String) async -> Bool {
        await updateDescription(on: url, description: description)
    }

    private static func updateKeywords(on url: URL, keywords: [String], mode: KeywordWriteMode) async -> Bool {
        let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
        let targetURL: URL
        if SQLiteObjectStore.isWorkingCopyURL(url) {
            _ = AppWorkingDirectory.ensureAccess()
            do {
                targetURL = try await SQLiteObjectStore.shared.materializeWorkingCopyIfNeeded(url)
            } catch {
                logger.error("writeKeywords: failed to materialize sqlite working copy filename=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return false
            }
        } else {
            targetURL = url
        }

        _ = SecurityScopedResourceAccess.ensureAccess(for: targetURL)
        guard let src = CGImageSourceCreateWithURL(targetURL as CFURL, nil), let type = CGImageSourceGetType(src) else {
            logger.log("writeKeywords: cannot create CGImageSource")
            return false
        }

        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            logger.log("writeKeywords: cannot copy properties")
            return false
        }

        var metadata = props
        var iptc = (metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        let existingKeywords = keywordStrings(from: iptc[kCGImagePropertyIPTCKeywords])
        let nextKeywords: [String]
        switch mode {
        case .append:
            nextKeywords = mergedKeywords(existingKeywords, keywords)
        case .replace:
            nextKeywords = mergedKeywords([], keywords)
        }
        iptc[kCGImagePropertyIPTCKeywords] = nextKeywords as CFArray
        metadata[kCGImagePropertyIPTCDictionary] = iptc as CFDictionary

        return await writeMetadata(
            metadata,
            source: src,
            type: type,
            originalURL: url,
            targetURL: targetURL,
            operation: "writeKeywords",
            logger: logger
        )
    }

    private static func updateDescription(on url: URL, description: String) async -> Bool {
        let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
        let targetURL: URL
        if SQLiteObjectStore.isWorkingCopyURL(url) {
            _ = AppWorkingDirectory.ensureAccess()
            do {
                targetURL = try await SQLiteObjectStore.shared.materializeWorkingCopyIfNeeded(url)
            } catch {
                logger.error("writeDescription: failed to materialize sqlite working copy filename=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return false
            }
        } else {
            targetURL = url
        }

        _ = SecurityScopedResourceAccess.ensureAccess(for: targetURL)
        guard let src = CGImageSourceCreateWithURL(targetURL as CFURL, nil),
              let type = CGImageSourceGetType(src) else {
            logger.log("writeDescription: cannot create CGImageSource")
            return false
        }

        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            logger.log("writeDescription: cannot copy properties")
            return false
        }

        var metadata = props
        var tiff = (metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFImageDescription] = description
        metadata[kCGImagePropertyTIFFDictionary] = tiff as CFDictionary

        var iptc = (metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        iptc[kCGImagePropertyIPTCCaptionAbstract] = description
        metadata[kCGImagePropertyIPTCDictionary] = iptc as CFDictionary

        return await writeMetadata(
            metadata,
            source: src,
            type: type,
            originalURL: url,
            targetURL: targetURL,
            operation: "writeDescription",
            logger: logger
        )
    }

    private static func writeMetadata(
        _ metadata: [CFString: Any],
        source: CGImageSource,
        type: CFString,
        originalURL: URL,
        targetURL: URL,
        operation: String,
        logger: Logger
    ) async -> Bool {
        let fileManager = FileManager.default
        let directory = targetURL.deletingLastPathComponent()
        let tempFilename = ".pvtmp-\(UUID().uuidString)"
        let tempURL = directory.appendingPathComponent(tempFilename).appendingPathExtension(targetURL.pathExtension)

        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else {
            logger.error("\(operation, privacy: .public): cannot create CGImageDestination")
            postEmbedWriteFailure(
                url: targetURL,
                operation: operation,
                message: "CGImageDestinationCreateWithURL failed when attempting to write embedded metadata."
            )
            return false
        }

        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            logger.error("\(operation, privacy: .public): CGImageDestinationFinalize failed")
            try? fileManager.removeItem(at: tempURL)
            postEmbedWriteFailure(
                url: targetURL,
                operation: operation,
                message: "CGImageDestinationFinalize failed when attempting to write embedded metadata."
            )
            return false
        }

        do {
            let backupURL = targetURL.appendingPathExtension("backup")
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }
            try fileManager.moveItem(at: targetURL, to: backupURL)
            try fileManager.moveItem(at: tempURL, to: targetURL)
            try? fileManager.removeItem(at: backupURL)
            await PhotoVault.shared.reencryptWorkingCopyIfNeeded(targetURL)
            if SQLiteObjectStore.isWorkingCopyURL(originalURL) {
                try await SQLiteObjectStore.shared.storeObjectFile(at: targetURL)
                try? fileManager.removeItem(at: targetURL)
            }
            return true
        } catch {
            logger.error("\(operation, privacy: .public): failed to replace original file: \(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: tempURL)
            postEmbedWriteFailure(
                url: targetURL,
                operation: operation,
                message: "Failed to replace original file after writing temp file: \(error.localizedDescription)"
            )
            return false
        }
    }

    private static func postEmbedWriteFailure(url: URL, operation: String, message: String) {
        NotificationCenter.default.post(
            name: .embedWriteFailed,
            object: nil,
            userInfo: ["url": url.path, "op": operation, "message": message]
        )
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
}
