import Foundation
import AppKit
import AVFoundation
import QuickLookThumbnailing
import os
import UniformTypeIdentifiers

private nonisolated let qlLogger = Logger(subsystem: "com.example.PictureViewer", category: "thumbnail-generator")

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
		if AppLogLevel.current.allows(.debug) {
			qlLogger.debug("generateThumbnail:start url=\(url.path, privacy: .public) main=\(Thread.isMainThread, privacy: .public)")
		}
		_ = SecurityScopedResourceAccess.ensureAccess(for: url)
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

		do {
			let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
			if AppLogLevel.current.allows(.debug) {
				qlLogger.debug("generateThumbnail:finished url=\(url.path, privacy: .public)")
			}
			// Telemetry: count generated thumbnails
			Task { await Telemetry.shared.recordThumbnail() }
			return rep.nsImage
		} catch {
			guard Self.isVideo(url) else { throw error }
			do {
				let fallback = try await Self.generateVideoFrameThumbnail(for: url)
				Task { await Telemetry.shared.recordThumbnail() }
				return fallback
			} catch {
				qlLogger.error("generateThumbnail: video frame fallback failed url=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
				do {
					let vlcThumbnail = try await EmbeddedVLCPlayerView.generateThumbnail(for: url)
					qlLogger.log("generateThumbnail: generated VLC snapshot thumbnail url=\(url.path, privacy: .public)")
					Task { await Telemetry.shared.recordThumbnail() }
					return vlcThumbnail
				} catch {
					qlLogger.error("generateThumbnail: VLC snapshot fallback failed url=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
				}
				let fallback = Self.genericVideoThumbnail(for: url)
				Task { await Telemetry.shared.recordThumbnail() }
				return fallback
			}
		}
	}

	private static func isVideo(_ url: URL) -> Bool {
		let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
		return PhotoLibrary.isVideoMediaFile(url, contentType: contentType)
	}

	private static func generateVideoFrameThumbnail(for url: URL) async throws -> NSImage {
		let asset = AVURLAsset(url: url)
		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		generator.maximumSize = CGSize(width: ThumbnailCache.canonicalSize, height: ThumbnailCache.canonicalSize)
		let duration = try await asset.load(.duration)
		let durationSeconds = duration.seconds.isFinite ? duration.seconds : 0
		let requestedSeconds = durationSeconds > 31 ? 30 : max(0.1, durationSeconds * 0.5)
		let time = CMTime(seconds: requestedSeconds, preferredTimescale: 600)
		let cgImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
			generator.generateCGImageAsynchronously(for: time) { image, _, error in
				if let image {
					continuation.resume(returning: image)
				} else {
					continuation.resume(throwing: error ?? NSError(domain: "ThumbnailGenerator", code: 1))
				}
			}
		}
		if AppLogLevel.current.allows(.debug) {
			qlLogger.debug("generateThumbnail: generated video frame thumbnail url=\(url.path, privacy: .public) requestedSeconds=\(requestedSeconds, privacy: .public)")
		}
		return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
	}

	private static func genericVideoThumbnail(for url: URL) -> NSImage {
		let icon = NSWorkspace.shared.icon(forFile: url.path)
		icon.size = NSSize(width: ThumbnailCache.canonicalSize, height: ThumbnailCache.canonicalSize)
		return icon
	}
}
