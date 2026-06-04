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
		defer { Task { await limiter.release() } }

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
		defer { Task { await limiter.release() } }

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
		defer { Task { await limiter.release() } }

		// Perform the ImageIO work off the calling thread.
		let candidate = await Task.detached(priority: .utility) {
			var parts: [String] = []
			parts.append(url.lastPathComponent)

			guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return parts.joined(separator: " ") }
			guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return parts.joined(separator: " ") }

			func appendValue(_ value: Any) {
				if let s = value as? String {
					parts.append(s)
				} else if let arr = value as? [Any] {
					for v in arr { appendValue(v) }
				} else if let nsarr = value as? NSArray {
					for v in nsarr { appendValue(v) }
				} else if let dict = value as? [CFString: Any] {
					for (_, v) in dict { appendValue(v) }
				} else if let dict = value as? [String: Any] {
					for (_, v) in dict { appendValue(v) }
				} else if let num = value as? NSNumber {
					parts.append(num.stringValue)
				}
			}

			func appendDict(_ key: CFString) {
				if let dict = props[key] as? [CFString: Any] {
					for (_, value) in dict { appendValue(value) }
				} else if let dict2 = props[key] as? [String: Any] {
					for (_, value) in dict2 { appendValue(value) }
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

		// Parse fixed EXIF date format "yyyy:MM:dd HH:mm:ss" manually
		// to avoid allocating a DateFormatter on every metadata read.
		func parseExifDateString(_ s: String) -> Date? {
			// Expected length: 19
			guard s.count >= 19 else { return nil }
			// Fast manual parse by extracting numeric components
			// yyyy:MM:dd HH:mm:ss
			let chars = Array(s)
			func num(_ i: Int, _ j: Int) -> Int? {
				guard i >= 0, j < chars.count, i <= j else { return nil }
				var v = 0
				for k in i...j {
					let c = chars[k]
					guard let d = c.wholeNumberValue else { return nil }
					v = v * 10 + d
				}
				return v
			}

			guard let year = num(0,3), let month = num(5,6), let day = num(8,9),
				  let hour = num(11,12), let minute = num(14,15), let second = num(17,18)
			else { return nil }

			var comps = DateComponents()
			comps.year = year
			comps.month = month
			comps.day = day
			comps.hour = hour
			comps.minute = minute
			comps.second = second
			comps.timeZone = TimeZone.current
			return Calendar.current.date(from: comps)
		}

		if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
			if let dt = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let d = parseExifDateString(dt) { return d }
		}
		if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
			if let dt = tiff[kCGImagePropertyTIFFDateTime] as? String, let d = parseExifDateString(dt) { return d }
		}
		return nil
	}
}
