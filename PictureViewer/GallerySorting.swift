//
//  GallerySorting.swift
//  PictureViewer
//

import Foundation
import ImageIO

struct PhotoGridSection: Identifiable {
    let id: String
    let title: String
    let photos: [PhotoItem]
}

enum SortMode: Int, CaseIterable, Identifiable {
    case alphaAsc = 0
    case alphaDesc = 1
    case fileDate = 2
    case imageDate = 3
    case descriptionAsc = 4
    case descriptionDesc = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .alphaAsc: return "Name ↑"
        case .alphaDesc: return "Name ↓"
        case .fileDate: return "File Date"
        case .imageDate: return "Image Date"
        case .descriptionAsc: return "Description ↑"
        case .descriptionDesc: return "Description ↓"
        }
    }
}

enum GalleryPhotoSorter {
    private static let noDescriptionSectionKey = "\u{0000}No Description"

    static func quickSections(from photos: [PhotoItem], sortMode: SortMode) -> [PhotoGridSection] {
        var buckets: [String: [PhotoItem]] = [:]
        var insertionOrder: [String] = []
        for photo in photos {
            let raw = MetadataCache.shared.cachedDescription(for: photo.url)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = raw.isEmpty ? noDescriptionSectionKey : raw
            if buckets[key] == nil {
                insertionOrder.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(photo)
        }
        return orderedSections(
            buckets: buckets,
            insertionOrder: insertionOrder,
            sortMode: sortMode
        )
    }

    static func sections(from photos: [PhotoItem], sortMode: SortMode) async -> [PhotoGridSection] {
        var buckets: [String: [PhotoItem]] = [:]
        var insertionOrder: [String] = []
        for photo in photos {
            let raw = await MetadataCache.shared.description(for: photo.url)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = raw.isEmpty ? noDescriptionSectionKey : raw
            if buckets[key] == nil {
                insertionOrder.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(photo)
        }
        return orderedSections(
            buckets: buckets,
            insertionOrder: insertionOrder,
            sortMode: sortMode
        )
    }

    static func quickSortedPhotos(_ photos: [PhotoItem], mode: SortMode, filter: String) -> [PhotoItem] {
        if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch mode {
            case .alphaAsc:
                return photos.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
            case .alphaDesc:
                return photos.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedDescending }
            case .fileDate, .imageDate, .descriptionAsc, .descriptionDesc:
                return photos
            }
        }

        if let regex = try? NSRegularExpression(pattern: filter, options: [.caseInsensitive]) {
            return photos.filter { photo in
                matchesRegex(regex, in: MetadataCache.shared.cachedSearchCandidate(for: photo.url))
            }
        }

        let needle = filter.lowercased()
        return photos.filter { photo in
            MetadataCache.shared.cachedSearchCandidate(for: photo.url).lowercased().contains(needle)
        }
    }

    static func computeSorted(photos: [PhotoItem], mode: SortMode, filter: String) async -> [PhotoItem] {
        let filtered: [PhotoItem]
        if filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = photos
        } else if let regex = try? NSRegularExpression(pattern: filter, options: [.caseInsensitive]) {
            var matches: [PhotoItem] = []
            for photo in photos {
                let filename = photo.url.lastPathComponent
                if matchesRegex(regex, in: filename) {
                    matches.append(photo)
                    continue
                }
                if let description = await MetadataCache.shared.description(for: photo.url),
                   !description.isEmpty,
                   matchesRegex(regex, in: description) {
                    matches.append(photo)
                    continue
                }
                let fullCandidate = await MetadataCache.shared.candidateString(for: photo.url)
                if matchesRegex(regex, in: fullCandidate) {
                    matches.append(photo)
                }
            }
            filtered = matches
        } else {
            let needle = filter.lowercased()
            var matches: [PhotoItem] = []
            for photo in photos {
                let filename = photo.url.lastPathComponent.lowercased()
                if filename.contains(needle) {
                    matches.append(photo)
                    continue
                }
                if let description = await MetadataCache.shared.description(for: photo.url),
                   description.lowercased().contains(needle) {
                    matches.append(photo)
                    continue
                }
                let full = await MetadataCache.shared.candidateString(for: photo.url)
                if full.lowercased().contains(needle) {
                    matches.append(photo)
                }
            }
            filtered = matches
        }

        return await sortPhotos(filtered, mode: mode)
    }

    private static func orderedSections(
        buckets: [String: [PhotoItem]],
        insertionOrder: [String],
        sortMode: SortMode
    ) -> [PhotoGridSection] {
        let namedKeys = insertionOrder.filter { $0 != noDescriptionSectionKey }
        let orderedKeys: [String]
        switch sortMode {
        case .descriptionAsc:
            orderedKeys = namedKeys.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        case .descriptionDesc:
            orderedKeys = namedKeys.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedDescending
            }
        default:
            orderedKeys = namedKeys
        }

        let keysWithFallback = buckets[noDescriptionSectionKey] == nil
            ? orderedKeys
            : orderedKeys + [noDescriptionSectionKey]

        return keysWithFallback.compactMap { key in
            guard let sectionPhotos = buckets[key], !sectionPhotos.isEmpty else { return nil }
            return PhotoGridSection(
                id: key,
                title: key == noDescriptionSectionKey ? "No Description" : key,
                photos: sectionPhotos
            )
        }
    }

    private static func sortPhotos(_ photos: [PhotoItem], mode: SortMode) async -> [PhotoItem] {
        switch mode {
        case .alphaAsc:
            return photos.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
        case .alphaDesc:
            return photos.sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedDescending }
        case .fileDate:
            return photos.sorted { a, b in
                let da = (try? a.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        case .imageDate:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

            func imageDate(for url: URL) -> Date? {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
                if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
                   let dateTime = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                   let date = formatter.date(from: dateTime) {
                    return date
                }
                if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                   let dateTime = tiff[kCGImagePropertyTIFFDateTime] as? String,
                   let date = formatter.date(from: dateTime) {
                    return date
                }
                return nil
            }

            return photos.sorted { a, b in
                let da = imageDate(for: a.url) ?? (try? a.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = imageDate(for: b.url) ?? (try? b.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        case .descriptionAsc, .descriptionDesc:
            var descriptions: [String: String] = [:]
            for photo in photos {
                descriptions[photo.url.path] = await MetadataCache.shared.description(for: photo.url) ?? ""
            }
            return photos.sorted { a, b in
                let da = descriptions[a.url.path] ?? ""
                let db = descriptions[b.url.path] ?? ""
                let aEmpty = da.isEmpty
                let bEmpty = db.isEmpty
                if aEmpty != bEmpty {
                    return !aEmpty && bEmpty
                }
                let cmp = da.localizedCaseInsensitiveCompare(db)
                return mode == .descriptionAsc ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }
    }

    private static func matchesRegex(_ regex: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
