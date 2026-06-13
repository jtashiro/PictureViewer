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

private nonisolated let thumbViewLogger = Logger(subsystem: "com.example.PictureViewer", category: "thumbnail-view")

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
	@State private var embeddedDescription: String?
	@State private var embeddedKeywords: [String] = []
	private static let defaultMetadataRefreshToken = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
	// Default to false so thumbnails load by default. Setting this to true
	// defers thumbnail loading at app launch (can help avoid startup spikes).
	@AppStorage("disableThumbnailLoadingAtLaunch") private var disableThumbnailLoadingAtLaunch: Bool = false
	@AppStorage("displayDescriptionInGrid") private var displayDescriptionInGrid: Bool = false
	@AppStorage("displayKeywordsInGrid") private var displayKeywordsInGrid: Bool = false

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
					Image(systemName: isVideo ? "video" : "photo.badge.exclamationmark")
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

			if displayDescriptionInGrid, let embeddedDescription, !embeddedDescription.isEmpty {
				Text(embeddedDescription)
					.font(.caption2)
					.lineLimit(2)
					.truncationMode(.tail)
					.frame(maxWidth: size)
					.foregroundStyle(.secondary)
			}

			if displayKeywordsInGrid, !embeddedKeywords.isEmpty {
				Text(embeddedKeywords.joined(separator: ", "))
					.font(.caption2)
					.lineLimit(1)
					.truncationMode(.tail)
					.frame(maxWidth: size)
					.foregroundStyle(.tertiary)
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
		return PhotoLibrary.isVideoMediaFile(url, contentType: contentType)
	}

	private func loadThumbnail() async {
		loadFailed = false

		if let cached = ThumbnailCache.shared.memoryImage(for: url, namespace: namespace) {
			image = cached
			return
		}

		image = nil

		let target = url
		_ = SecurityScopedResourceAccess.ensureAccess(for: target)

		// 1) Try the persistent cache off the main thread. Cache reads always run,
		// even when launch-time generation is deferred.
		let ns = namespace
		let cacheLookup = Task.detached(priority: .userInitiated) {
			ThumbnailCache.shared.image(for: target, namespace: ns)
		}
		if let cached = await cacheLookup.value {
			if Task.isCancelled { return }
			thumbViewLogger.log("ThumbnailView: source=thumbnail-cache filename=\(target.lastPathComponent, privacy: .public)")
			image = cached
			return
		}

		if disableThumbnailLoadingAtLaunch && !forceLoad {
			if await hydrateCachedVideoThumbnailIfAvailable(for: target, namespace: ns, requireFresh: false) {
				return
			}
			thumbViewLogger.log("ThumbnailView: skipping thumbnail load for \(url.lastPathComponent, privacy: .public) because disableThumbnailLoadingAtLaunch=true")
			return
		}

		// SQLite lazy working copies may not exist on disk yet. Prefer the
		// thumbnail BLOB stored in the object database over on-the-fly generation.
		if SQLiteObjectStore.isWorkingCopyURL(target),
		   !FileManager.default.fileExists(atPath: target.path) {
			if let storedData = SQLiteObjectStore.peekHydratedThumbnailJPEGData(for: target, namespace: namespace),
			   let storedImage = ThumbnailCache.image(fromJPEGData: storedData) {
				if Task.isCancelled { return }
				thumbViewLogger.log("ThumbnailView: source=hydrated-registry filename=\(target.lastPathComponent, privacy: .public) bytes=\(storedData.count, privacy: .public)")
				ThumbnailCache.shared.storeJPEGData(storedData, for: target, namespace: namespace)
				image = storedImage
				return
			}
			if await SQLiteObjectStore.shared.shouldDeferIndividualThumbnailLookup(for: target) {
				return
			}
			guard let storedData = await SQLiteObjectStore.shared.thumbnailJPEGData(forWorkingFile: target),
			      let storedImage = ThumbnailCache.image(fromJPEGData: storedData) else {
				return
			}
			if Task.isCancelled { return }
			thumbViewLogger.log("ThumbnailView: source=database-blob filename=\(target.lastPathComponent, privacy: .public) bytes=\(storedData.count, privacy: .public)")
			ThumbnailCache.shared.storeJPEGData(storedData, for: target, namespace: namespace)
			image = storedImage
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

		// 3) Generate the high-quality thumbnail in a child task so the UI
		// remains responsive; when complete it replaces the low-res preview.
		Task.detached(priority: .utility) {
			do {
				let thumbnailSource: URL
				if SQLiteObjectStore.isWorkingCopyURL(target),
				   !FileManager.default.fileExists(atPath: target.path) {
					_ = AppWorkingDirectory.ensureAccess()
					guard forceLoad else {
						return
					}
					thumbnailSource = try await SQLiteObjectStore.shared.materializeWorkingCopyIfNeeded(target)
				} else {
					thumbnailSource = target
				}
				let nsImage = try await ThumbnailGenerator.shared.generateThumbnail(for: thumbnailSource)
				thumbViewLogger.log("ThumbnailView: source=generated filename=\(target.lastPathComponent, privacy: .public) materialized=\(thumbnailSource != target, privacy: .public)")
				// Store to cache (mem+disk) off the main actor.
				ThumbnailCache.shared.store(nsImage, for: target, namespace: namespace)
				if SQLiteObjectStore.isWorkingCopyURL(target),
				   let thumbnailData = await MainActor.run(body: { ThumbnailCache.jpegData(from: nsImage) }) {
					try? await SQLiteObjectStore.shared.storeThumbnailData(thumbnailData, forWorkingFile: target)
				}
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

	private func hydrateCachedVideoThumbnailIfAvailable(
		for target: URL,
		namespace: String?,
		requireFresh: Bool
	) async -> Bool {
		guard isVideo else { return false }
		let hydrated = await Task.detached(priority: .userInitiated) {
			ThumbnailCache.shared.hydrateFromDiskIfAvailable(for: target, namespace: namespace, requireFresh: requireFresh)
		}.value
		guard let hydrated else { return false }
		if Task.isCancelled { return false }
		thumbViewLogger.log("ThumbnailView: source=thumbnail-cache-stale filename=\(target.lastPathComponent, privacy: .public) requireFresh=\(requireFresh, privacy: .public)")
		image = hydrated
		return true
	}

	private enum MetadataState {
		case none
		case embedded
	}

	private func updateMetadataState() async {
		if SQLiteObjectStore.isWorkingCopyURL(url),
		   !FileManager.default.fileExists(atPath: url.path),
		   let stored = await SQLiteObjectStore.shared.metadataForWorkingFile(url) {
			await MainActor.run {
				embeddedDescription = stored.description
				embeddedKeywords = stored.keywords
				metadataState = stored.description != nil || !stored.keywords.isEmpty ? .embedded : .none
			}
			return
		}

		ensureMetadataAccess(for: url)
		let target = url
		let metadata = await Task.detached(priority: .utility) {
			ImageEmbeddedMetadataReader.read(from: target)
		}.value

		await MainActor.run {
			embeddedDescription = metadata.description
			embeddedKeywords = metadata.keywords
			metadataState = metadata.hasEmbeddedMetadata ? .embedded : .none
		}
	}

	private func ensureMetadataAccess(for url: URL) {
		_ = SecurityScopedResourceAccess.ensureAccess(for: url)
		let workingBase = AppWorkingDirectory.baseURL.standardizedFileURL.path
		let candidatePath = url.standardizedFileURL.path
		if candidatePath == workingBase || candidatePath.hasPrefix(workingBase + "/") {
			_ = AppWorkingDirectory.ensureAccess()
		}
	}
}
