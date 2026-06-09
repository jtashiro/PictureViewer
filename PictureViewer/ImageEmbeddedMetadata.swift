//
//  ImageEmbeddedMetadata.swift
//  PictureViewer
//

import Foundation
import ImageIO

struct ImageEmbeddedMetadata: Sendable {
	let keywords: [String]
	let description: String?

	var hasEmbeddedMetadata: Bool {
		!keywords.isEmpty || !(description?.isEmpty ?? true)
	}
}

enum ImageEmbeddedMetadataReader {
	nonisolated static func read(from url: URL) -> ImageEmbeddedMetadata {
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
		      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
		else {
			return ImageEmbeddedMetadata(keywords: [], description: nil)
		}
		return read(from: props)
	}

	nonisolated static func read(from props: [CFString: Any]) -> ImageEmbeddedMetadata {
		var keywords: [String] = []
		if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
		   let values = iptc[kCGImagePropertyIPTCKeywords] {
			keywords.append(contentsOf: keywordStrings(from: values))
		}
		return ImageEmbeddedMetadata(
			keywords: normalizedKeywords(keywords),
			description: embeddedDescription(from: props)
		)
	}

	nonisolated static func embeddedDescription(from props: [CFString: Any]) -> String? {
		if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
		   let description = trimmedMetadataString(tiff[kCGImagePropertyTIFFImageDescription]) {
			return description
		}
		if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
		   let description = trimmedMetadataString(iptc[kCGImagePropertyIPTCCaptionAbstract]) {
			return description
		}
		if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
		   let description = trimmedMetadataString(exif[kCGImagePropertyExifUserComment]) {
			return description
		}
		return nil
	}

	nonisolated private static func trimmedMetadataString(_ value: Any?) -> String? {
		guard let value = value as? String else { return nil }
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	nonisolated private static func keywordStrings(from value: Any) -> [String] {
		if let values = value as? [String] { return values }
		if let values = value as? [Any] { return values.compactMap { $0 as? String } }
		if let values = value as? NSArray { return values.compactMap { $0 as? String } }
		if let value = value as? String { return [value] }
		return []
	}

	nonisolated private static func normalizedKeywords(_ keywords: [String]) -> [String] {
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
}