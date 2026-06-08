//
//  ThumbnailView.swift
//  PictureViewer
//

import SwiftUI
import AppKit
import QuickLookThumbnailing
import ImageIO
import os
import UniformTypeIdentifiers

private let thumbViewLogger = Logger(subsystem: "com.example.PictureViewer", category: "thumbnail-view")

struct ThumbnailView: View {
	let url: URL
	let size: CGFloat
	/// Optional namespace (tab name) used to separate thumbnail caches per tab.
	let namespace: String? = nil
	/// Bumping this value forces the thumbnail to be reloaded from source,
	/// bypassing both memory and disk caches. Used by the "Refresh
	/// Thumbnails" button.
	let refreshToken: UUID
	let metadataRefreshToken: UUID
	let forceLoad: Bool

	@State private var image: NSImage?
	@State private var loadFailed = false
	@State private var metadataState: MetadataState = .none
	@State private var embeddedKeywords: [String] = []
	private static let defaultMetadataRefreshToken = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
	// Default to false so thumbnails load by default. Setting this to true
	// defers thumbnail loading at app launch (can help avoid startup spikes).
	@AppStorage("disableThumbnailLoadingAtLaunch") private var disableThumbnailLoadingAtLaunch: Bool = false

	init(url: URL, size: CGFloat, refreshToken: UUID, metadataRefreshToken: UUID = Self.defaultMetadataRefreshToken, forceLoad: Bool = false) {
		self.url = url
		self.size = size
		self.refreshToken = refreshToken
		self.metadataRefreshToken = metadataRefreshToken
		self.forceLoad = forceLoad
		self._image = State(initialValue: ThumbnailCache.shared.memoryImage(for: url, namespace: nil))
	}

	var body: some View {
		VStack(spacing: 4) {
			ZStack {
				RoundedRectangle(cornerRadius: 6)
					.fill(Color(nsColor: .windowBackgroundColor))

				if let image {
					Image(nsImage: image)
						.resizable()
						.scaledToFit()
						.padding(2)
				} else if loadFailed {
					Image(systemName: isVideo ? "video.badge.exclamationmark" : "photo.badge.exclamationmark")
						.imageScale(.large)
						.foregroundStyle(.secondary)
				} else {
					ProgressView()
						.controlSize(.small)
				}
			}
			.frame(width: size, height: size)
			.overlay(
				RoundedRectangle(cornerRadius: 6)
					.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
			)
			.overlay(alignment: .topLeading) {
				if metadataState == .embedded {
					Image(systemName: "tag.fill")
						.font(.caption2)
						.foregroundStyle(.white)
						.padding(6)
						.background(Circle().fill(Color.green))
						.offset(x: 6, y: 6)
						.help("Embedded metadata present")
				}
			}

			// Filename and keywords shown below the thumbnail. Keywords are
			// displayed on a separate, secondary-styled line.
			Text(url.lastPathComponent)
				.font(.caption2)
				.lineLimit(1)
				.truncationMode(.middle)
				.frame(maxWidth: size)
				.foregroundStyle(.primary)

			if !embeddedKeywords.isEmpty {
				Text(embeddedKeywords.joined(separator: ", "))
					.font(.caption2)
					.lineLimit(1)
					.truncationMode(.tail)
					.frame(maxWidth: size)
					.foregroundStyle(.secondary)
			}
		}
		.help(url.lastPathComponent)
		.task(id: ThumbnailTaskID(url: url, refreshToken: refreshToken, namespace: namespace, forceLoad: forceLoad)) {
			await loadThumbnail()
		}
		.task(id: MetadataTaskID(url: url, metadataRefreshToken: metadataRefreshToken)) {
			await updateMetadataState()
		}
	}

	private struct ThumbnailTaskID: Equatable, Hashable {
		let url: URL
		let refreshToken: UUID
		let namespace: String?
		let forceLoad: Bool
	}

	private struct MetadataTaskID: Equatable, Hashable {
		let url: URL
		let metadataRefreshToken: UUID
	}

	private var isVideo: Bool {
		let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
		if let contentType {
			return contentType.conforms(to: .movie)
				|| contentType.conforms(to: .video)
				|| contentType.conforms(to: .audiovisualContent)
		}
		guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
		return type.conforms(to: .movie)
			|| type.conforms(to: .video)
			|| type.conforms(to: .audiovisualContent)
	}

	private func loadThumbnail() async {
		loadFailed = false

		if let cached = ThumbnailCache.shared.memoryImage(for: url, namespace: namespace) {
			image = cached
			return
		}

		image = nil

		if disableThumbnailLoadingAtLaunch && !forceLoad {
			thumbViewLogger.log("ThumbnailView: skipping thumbnail load for \(url.lastPathComponent, privacy: .public) because disableThumbnailLoadingAtLaunch=true")
			return
		}

		let target = url

		// 1) Try the persistent cache off the main thread.
		let ns = namespace
		let cacheLookup = Task.detached(priority: .userInitiated) {
			await ThumbnailCache.shared.image(for: target, namespace: ns)
		}
		if let cached = await cacheLookup.value {
			if Task.isCancelled { return }
			image = cached
			return
		}

		// 2) Start a small, fast low-resolution preview generation so the
		// user sees something immediately while the high-quality QuickLook
		// thumbnail is generated. Both tasks are child tasks of the view's
		// `.task` so they are cancelled when the view is recycled.
		if !isVideo {
			Task.detached(priority: .utility) {
				// Fast low-res thumbnail via ImageIO. This path is image-only;
				// videos use QuickLook/AVFoundation because ImageIO logs errors.
				if !Task.isCancelled {
					if let src = CGImageSourceCreateWithURL(target as CFURL, nil) {
						let opts: [CFString: Any] = [
							kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
							kCGImageSourceCreateThumbnailWithTransform: true,
							kCGImageSourceThumbnailMaxPixelSize: 128
						]
						if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
							let low = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
							await MainActor.run {
								if !Task.isCancelled && image == nil {
									image = low
								}
							}
						}
					}
				}
			}
		}

		// 3) Generate the high-quality thumbnail (QuickLook) in a child
		// task so the UI remains responsive; when complete it replaces the
		// low-res preview.
		Task.detached(priority: .utility) {
			do {
				let nsImage = try await ThumbnailGenerator.shared.generateThumbnail(for: target)
				// Store to cache (mem+disk) off the main actor.
				await ThumbnailCache.shared.store(nsImage, for: target, namespace: namespace)
				// Publish to UI on the main actor if still relevant.
				await MainActor.run {
					if !Task.isCancelled {
						image = nsImage
					}
				}
			} catch {
				await MainActor.run {
					if !Task.isCancelled {
						loadFailed = true
					}
				}
			}
		}
	}

	private enum MetadataState {
		case none
		case embedded
	}

	private func updateMetadataState() async {
		var foundEmbedded = false
		var kws: [String] = []
		if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
			// IPTC keywords
			if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
				if let arr = iptc[kCGImagePropertyIPTCKeywords] as? [Any] {
					for v in arr {
						if let s = v as? String, !s.isEmpty { kws.append(s) }
					}
				}
			}

			// EXIF user comment (treat as a keyword-like freeform string)
			if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any], let user = exif[kCGImagePropertyExifUserComment] as? String, !user.isEmpty {
				foundEmbedded = true
				kws.append(user)
			}

			// TIFF image description
			if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any], let desc = tiff[kCGImagePropertyTIFFImageDescription] as? String, !desc.isEmpty {
				foundEmbedded = true
				kws.append(desc)
			}

			if !kws.isEmpty { foundEmbedded = true }
		}

		await MainActor.run {
			metadataState = foundEmbedded ? .embedded : .none
			embeddedKeywords = kws
		}
	}
}
