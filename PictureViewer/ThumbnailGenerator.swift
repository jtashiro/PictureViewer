import Foundation
import AppKit
import QuickLookThumbnailing
import os

private let qlLogger = Logger(subsystem: "com.example.PictureViewer", category: "thumbnail-generator")

/// Async limiter that allows up to `capacity` concurrent holders.
actor AsyncLimiter {
	private var available: Int
	private var waiters: [CheckedContinuation<Void, Never>] = []

	init(capacity: Int) {
		self.available = max(1, capacity)
	}

	func acquire() async {
		if available > 0 {
			available -= 1
			return
		}
		await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
			waiters.append(cont)
		}
	}

	func release() {
		if !waiters.isEmpty {
			let cont = waiters.removeFirst()
			cont.resume()
		} else {
			available += 1
		}
	}
}

final class ThumbnailGenerator: @unchecked Sendable {
	static let shared = ThumbnailGenerator()

	private let limiter: AsyncLimiter
	private let screenScale: CGFloat

	private init() {
		// Allow up to the scanner worker count concurrent thumbnail
		// generations. On machines with many cores this helps utilize CPU
		// while decoding thumbnails. If this overwhelms a slow disk/USB
		// device you can clamp it back down.
		let cap = max(1, PhotoLibrary.workerCount)
		self.limiter = AsyncLimiter(capacity: cap)
		// Cache the main screen backing scale once at init to avoid
		// hopping to the MainActor on every thumbnail generation call.
		// Fall back to 2.0 if unavailable.
		self.screenScale = NSScreen.main?.backingScaleFactor ?? 2
	}

	/// Generates a thumbnail via QuickLook. Concurrency is limited by the
	/// internal limiter so we don't overwhelm the system with thumbnail
	/// generation tasks.
	/// Generate a thumbnail. If `scale` is nil the function will retrieve
	/// the current screen scale on the main actor. The heavy QuickLook
	/// generation is limited by the internal limiter. This function is
	/// safe to call from background threads.
	func generateThumbnail(for url: URL, scale: CGFloat? = nil) async throws -> NSImage {
		qlLogger.log("generateThumbnail:start url=\(url.path, privacy: .public) main=\(Thread.isMainThread, privacy: .public)")
		// Determine scale on main actor if needed.
		let actualScale: CGFloat
		if let s = scale {
			actualScale = s
		} else {
			actualScale = self.screenScale
		}

		await limiter.acquire()
		defer { Task { await limiter.release() } }

		let pixelSize = CGSize(width: ThumbnailCache.canonicalSize, height: ThumbnailCache.canonicalSize)
		let request = QLThumbnailGenerator.Request(fileAt: url, size: pixelSize, scale: actualScale, representationTypes: .thumbnail)

		let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
		qlLogger.log("generateThumbnail:finished url=\(url.path, privacy: .public)")
		// Telemetry: count generated thumbnails
		Task { await Telemetry.shared.recordThumbnail() }
		return rep.nsImage
	}
}
