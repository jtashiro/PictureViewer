import Foundation
import ImageIO
import os

/// Caches image metadata (e.g., EXIF date) and performs metadata reads
/// concurrently. The previous actor-based implementation serialized all
/// metadata requests which became a bottleneck when scanning many files.
final class MetadataCache {
	static let shared = MetadataCache()

	// Concurrent caches protected by a concurrent dispatch queue. Readers
	// can access the dictionaries concurrently; writers use a barrier.
	private var imageDateCache: [String: Date?] = [:]
	private var fileDateCache: [String: Date?] = [:]
	private var candidateCache: [String: String] = [:]
	private let cacheQueue = DispatchQueue(label: "MetadataCache.cacheQueue", attributes: .concurrent)

	private let limiter: AsyncLimiter

	init() {
		// Allow up to the scanner worker count concurrent metadata reads so
		// the system can utilize available CPU while scanning. This moves
		// toward "max CPU" behavior; if this overloads a slow device you
		// can clamp it down again.
		let cap = max(1, PhotoLibrary.workerCount)
		self.limiter = AsyncLimiter(capacity: cap)
	}

	/// Returns the cached image date if available, otherwise parses the
	/// image metadata off the actor and caches the result. This function
	/// performs expensive IO/decoding off the calling thread via
	/// `Task.detached` so callers aren't blocked.
	func imageDate(for url: URL) async -> Date? {
		let key = url.path
		// Fast concurrent read from the cache.
		if let v = cacheQueue.sync(execute: { imageDateCache[key] }) { return v }

		await limiter.acquire()
		defer { limiter.release() }

		// Telemetry: note we're doing a metadata read
		Task { await Telemetry.shared.recordMetadataRead() }

		// Do the heavy work off any actor/executor so it can run in
		// parallel on other threads.
		let d = await Task.detached(priority: .userInitiated) {
			return Self.readImageDate(url: url)
		}.value

		// Store the result with a barrier write.
		cacheQueue.async(flags: .barrier) { [weak self] in
			self?.imageDateCache[key] = d
		}
		return d
	}

	func fileModificationDate(for url: URL) async -> Date? {
		let key = url.path
		if let v = cacheQueue.sync(execute: { fileDateCache[key] }) { return v }

		await limiter.acquire()
		defer { limiter.release() }

		// Telemetry: note we're doing a metadata read
		Task { await Telemetry.shared.recordMetadataRead() }

		let d = await Task.detached(priority: .userInitiated) {
			return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
		}.value

		cacheQueue.async(flags: .barrier) { [weak self] in
			self?.fileDateCache[key] = d
		}
		return d
	}

	/// Returns a concatenated candidate string (filename + common embedded
	/// metadata fields) suitable for substring/regex matching. Results are
	/// cached in-memory to avoid repeated ImageIO property reads.
	func candidateString(for url: URL) async -> String {
		let key = url.path
		if let v = cacheQueue.sync(execute: { candidateCache[key] }) { return v }

		await limiter.acquire()
		defer { limiter.release() }

		// Perform the ImageIO work off the calling thread.
		let candidate = await Task.detached(priority: .utility) {
			var parts: [String] = []
			parts.append(url.lastPathComponent)

			guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return parts.joined(separator: " ") }
			guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return parts.joined(separator: " ") }

			func appendDict(_ key: CFString) {
				if let dict = props[key] as? [CFString: Any] {
					for (_, value) in dict {
						if let s = value as? String { parts.append(s) }
						else if let arr = value as? [String] { parts.append(contentsOf: arr) }
					}
				}
			}

			appendDict(kCGImagePropertyExifDictionary)
			appendDict(kCGImagePropertyTIFFDictionary)
			appendDict(kCGImagePropertyIPTCDictionary)
			if let t = props[kCGImagePropertyPNGDictionary] as? [CFString: Any], let text = t[kCGImagePropertyPNGTitle] as? String {
				parts.append(text)
			}

			return parts.joined(separator: " ")
		}.value

		cacheQueue.async(flags: .barrier) { [weak self] in
			self?.candidateCache[key] = candidate
		}
		return candidate
	}

	private static func readImageDate(url: URL) -> Date? {
		guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
		guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }

		// Create a local DateFormatter per call. Creating a formatter is
		// somewhat expensive, but it's safer than sharing a single
		// DateFormatter across threads. In practice the metadata read and
		// image decoding dominate the cost.
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = .current
		formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

		if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
			if let dt = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let d = formatter.date(from: dt) { return d }
		}
		if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
			if let dt = tiff[kCGImagePropertyTIFFDateTime] as? String, let d = formatter.date(from: dt) { return d }
		}
		return nil
	}
}
