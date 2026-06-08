//
//  PhotoDetailView.swift
//  PictureViewer
//

import SwiftUI
import AppKit
import AVKit
import CoreImage
import ImageIO
import os
import UniformTypeIdentifiers

@MainActor
final class PhotoNavigationContext {
	static let shared = PhotoNavigationContext()

	private var orderedURLs: [URL] = []

	private init() {}

	func update(urls: [URL]) {
		var seen: Set<URL> = []
		orderedURLs = urls.filter { seen.insert($0).inserted }
	}

	func adjacentURL(to url: URL, offset: Int) -> URL? {
		guard !orderedURLs.isEmpty,
			  let index = orderedURLs.firstIndex(of: url)
		else {
			return nil
		}
		let targetIndex = index + offset
		guard orderedURLs.indices.contains(targetIndex) else { return nil }
		return orderedURLs[targetIndex]
	}
}

fileprivate final class DeferredPlayerView: AVPlayerView {
	var pendingPlayer: AVPlayer? {
		didSet {
			attachPlayerIfReady()
		}
	}

	override func layout() {
		super.layout()
		attachPlayerIfReady()
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		attachPlayerIfReady()
	}

	private func attachPlayerIfReady() {
		guard bounds.width > 0, bounds.height > 0 else { return }
		if player !== pendingPlayer {
			player = pendingPlayer
		}
	}
}

private struct NativeVideoPlayerView: NSViewRepresentable {
	let player: AVPlayer

	func makeNSView(context: Context) -> DeferredPlayerView {
		let view = DeferredPlayerView()
		view.controlsStyle = .floating
		view.videoGravity = .resizeAspect
		view.updatesNowPlayingInfoCenter = false
		view.pendingPlayer = player
		return view
	}

	func updateNSView(_ nsView: DeferredPlayerView, context: Context) {
		nsView.pendingPlayer = player
	}

	static func dismantleNSView(_ nsView: DeferredPlayerView, coordinator: ()) {
		nsView.player?.pause()
		nsView.player = nil
		nsView.pendingPlayer = nil
	}
}

struct FullScreenPhotoView: View {
	let url: URL
	@State private var currentURL: URL

	init(url: URL) {
		self.url = url
		_currentURL = State(initialValue: url)
	}

	@AppStorage("photoDisplayMode") private var displayMode: PhotoDisplayMode = .fullScreen
	@AppStorage("useVLCForVideoPlayback") private var useVLCForVideoPlayback: Bool = false

	@State private var image: NSImage?
	@State private var player: AVPlayer?
	@State private var loadFailed = false
	@State private var materializedURL: URL?
	@State private var rotationDegrees: Int = 0
	@State private var brightnessAdjustment: Double = 0
	@State private var contrastAdjustment: Double = 1
	@State private var isSavingEdits: Bool = false
	@State private var didConfigureWindow = false
	@State private var embeddedVLCControlBarOffset: CGSize = .zero
	@State private var embeddedVLCControlBarDragStart: CGSize = .zero
	@StateObject private var embeddedVLCController = EmbeddedVLCPlaybackController()
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		ZStack {
			Color.black
				.ignoresSafeArea()

			if isCurrentVideo {
				if usesEmbeddedVLC {
					if let materializedURL {
						ZStack(alignment: .bottom) {
							EmbeddedVLCPlayerView(url: materializedURL, controller: embeddedVLCController)
								.frame(minWidth: 1, minHeight: 1)
								.ignoresSafeArea()
							embeddedVLCControlBar
								.padding(.horizontal, 24)
								.padding(.bottom, 20)
								.offset(embeddedVLCControlBarOffset)
								.gesture(embeddedVLCControlBarDragGesture)
						}
					} else if loadFailed {
						VStack(spacing: 12) {
							Image(systemName: "video")
								.font(.system(size: 56))
								.foregroundStyle(.secondary)
							Text("Cannot Display Video")
								.font(.title3)
								.foregroundStyle(.secondary)
						}
					} else {
						ProgressView()
							.controlSize(.large)
							.tint(.white)
					}
				} else if let player {
					NativeVideoPlayerView(player: player)
						.frame(minWidth: 1, minHeight: 1)
						.ignoresSafeArea()
				} else if loadFailed {
					VStack(spacing: 12) {
						Image(systemName: "video")
							.font(.system(size: 56))
							.foregroundStyle(.secondary)
						Text("Cannot Display Video")
							.font(.title3)
							.foregroundStyle(.secondary)
					}
				} else {
					ProgressView()
						.controlSize(.large)
						.tint(.white)
				}
			} else if let image {
				Image(nsImage: image)
					.resizable()
					.scaledToFit()
					.rotationEffect(.degrees(Double(rotationDegrees)))
					.brightness(brightnessAdjustment)
					.contrast(contrastAdjustment)
					.ignoresSafeArea()
			} else if loadFailed {
				VStack(spacing: 12) {
					Image(systemName: "photo.badge.exclamationmark")
						.font(.system(size: 56))
						.foregroundStyle(.secondary)
					Text("Cannot Display Image")
						.font(.title3)
						.foregroundStyle(.secondary)
				}
			} else {
				ProgressView()
					.controlSize(.large)
					.tint(.white)
			}
		}
		.background(WindowAccessor { window in
			configure(window: window)
		})
		.focusable()
		.focusEffectDisabled()
		.onKeyPress(.escape) {
			stopPlayback()
			dismiss()
			return .handled
		}
		.onKeyPress(.space) {
			guard usesEmbeddedVLC else { return .ignored }
			embeddedVLCController.togglePlayPause()
			return .handled
		}
		.onKeyPress(.leftArrow) {
			navigateToAdjacentPhoto(offset: -1)
			return .handled
		}
		.onKeyPress(.rightArrow) {
			navigateToAdjacentPhoto(offset: 1)
			return .handled
		}
		.onTapGesture {
			if !isCurrentVideo && displayMode == .fullScreen {
				dismiss()
			}
		}
		.task(id: currentURL) {
			await loadMedia()
		}
		.toolbar {
			ToolbarItem(placement: .automatic) {
				if !isCurrentVideo {
					HStack(spacing: 8) {
						Button(action: { rotateLeft() }) {
							Image(systemName: "rotate.left")
						}
						.help("Rotate left 90°")
						Button(action: { rotateRight() }) {
							Image(systemName: "rotate.right")
						}
						.help("Rotate right 90°")
						Image(systemName: "sun.max")
							.foregroundStyle(.secondary)
						Slider(value: $brightnessAdjustment, in: -1...1, step: 0.05)
							.frame(width: 120)
							.help("Brightness")
						Image(systemName: "circle.lefthalf.filled")
							.foregroundStyle(.secondary)
						Slider(value: $contrastAdjustment, in: 0.2...2.0, step: 0.05)
							.frame(width: 120)
							.help("Contrast")
						Button(action: { resetAdjustments() }) {
							Image(systemName: "arrow.uturn.backward")
						}
						.help("Reset brightness/contrast")
						.disabled(abs(brightnessAdjustment) < 0.001 && abs(contrastAdjustment - 1) < 0.001)
						Button(action: { Task { await saveEdits() } }) {
							if isSavingEdits {
								ProgressView().controlSize(.small)
							} else {
								Image(systemName: "square.and.arrow.down")
							}
						}
						.help("Save edits to file")
						.disabled(isSavingEdits || !hasPendingEdits || image == nil)
					}
				}
			}
		}
		.onAppear {
			WindowStateStore.shared.recordOpenPhoto(currentURL)
		}
		.onDisappear {
			// If the user rotated but didn't explicitly save, persist the
			// rotation automatically when the window closes.
			stopPlayback()
			if !isCurrentVideo && hasPendingEdits {
				Task.detached(priority: .utility) {
					await saveEdits()
				}
			}
			WindowStateStore.shared.recordClosedPhoto(currentURL)
		}
	}

	private var hasPendingEdits: Bool {
		rotationDegrees % 360 != 0 || abs(brightnessAdjustment) >= 0.001 || abs(contrastAdjustment - 1) >= 0.001
	}

	private var embeddedVLCControlBar: some View {
		HStack(spacing: 12) {
			Button {
				embeddedVLCController.skip(by: -10)
			} label: {
				Image(systemName: "gobackward.10")
			}
			.help("Back 10 seconds")

			Button {
				embeddedVLCController.togglePlayPause()
			} label: {
				Image(systemName: embeddedVLCController.isPlaying ? "pause.fill" : "play.fill")
			}
			.help(embeddedVLCController.isPlaying ? "Pause" : "Play")

			Button {
				embeddedVLCController.stop()
			} label: {
				Image(systemName: "stop.fill")
			}
			.help("Stop")

			Button {
				embeddedVLCController.skip(by: 10)
			} label: {
				Image(systemName: "goforward.10")
			}
			.help("Forward 10 seconds")

			Text(formatPlaybackTime(embeddedVLCController.currentTime))
				.monospacedDigit()
				.foregroundStyle(.white)
				.frame(width: 54, alignment: .trailing)

			Slider(
				value: Binding(
					get: { embeddedVLCController.currentTime },
					set: { embeddedVLCController.seek(to: $0) }
				),
				in: 0...max(embeddedVLCController.duration, 1)
			)
			.frame(minWidth: 180)

			Text(formatPlaybackTime(embeddedVLCController.duration))
				.monospacedDigit()
				.foregroundStyle(.white)
				.frame(width: 54, alignment: .leading)
		}
		.buttonStyle(.bordered)
		.controlSize(.large)
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.frame(maxWidth: 760)
		.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
		.overlay {
			RoundedRectangle(cornerRadius: 8)
				.stroke(.white.opacity(0.18), lineWidth: 1)
		}
		.shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
	}

	private var embeddedVLCControlBarDragGesture: some Gesture {
		DragGesture()
			.onChanged { value in
				embeddedVLCControlBarOffset = CGSize(
					width: embeddedVLCControlBarDragStart.width + value.translation.width,
					height: embeddedVLCControlBarDragStart.height + value.translation.height
				)
			}
			.onEnded { _ in
				embeddedVLCControlBarDragStart = embeddedVLCControlBarOffset
			}
	}

	private var isCurrentVideo: Bool {
		let contentType = try? currentURL.resourceValues(forKeys: [.contentTypeKey]).contentType
		return PhotoLibrary.isVideoMediaFile(currentURL, contentType: contentType)
	}

	private var usesEmbeddedVLC: Bool {
		isCurrentVideo && useVLCForVideoPlayback && EmbeddedVLCPlayerView.isAvailable
	}

	private func configure(window: NSWindow?) {
		guard let window, !didConfigureWindow else { return }
		didConfigureWindow = true
		window.title = currentURL.lastPathComponent
		// Record the represented URL on the NSWindow so global window
		// snapshotting can discover open photo windows even when their
		// SwiftUI views aren't currently 'appeared' (for example when a
		// photo is open in a background tab). This makes session
		// persistence more robust.
		window.representedURL = currentURL
		// Prefer tabbed windows so multiple photo windows group as tabs.
		window.tabbingMode = .preferred

		switch displayMode {
		case .fullScreen:
			// Size the window to the screen before going full-screen so the
			// transition doesn't leave artifacts (e.g. a stale focus ring
			// from the small initial frame) in the corner of the display.
			if let screen = window.screen ?? NSScreen.main {
				window.setFrame(screen.frame, display: false, animate: false)
			}
			if !window.styleMask.contains(.fullScreen) {
				window.toggleFullScreen(nil)
			}
		case .windowMaximized:
			if let screen = window.screen ?? NSScreen.main {
				window.setFrame(screen.visibleFrame, display: true, animate: false)
			}
		case .windowed:
			if let screen = window.screen ?? NSScreen.main {
				let visible = screen.visibleFrame
				let w = visible.width * 0.7
				let h = visible.height * 0.8
				let frame = NSRect(
					x: visible.midX - w / 2,
					y: visible.midY - h / 2,
					width: w,
					height: h
				)
				window.setFrame(frame, display: true, animate: false)
			}
		}
	}

	private func loadMedia() async {
		image = nil
		player?.pause()
		player = nil
		materializedURL = nil
		loadFailed = false
		let target = currentURL
		_ = SecurityScopedResourceAccess.ensureAccess(for: target)
		let readableURL: URL
		do {
			readableURL = try await SQLiteObjectStore.shared.materializeWorkingCopyIfNeeded(target)
		} catch {
			loadFailed = true
			return
		}
		if Task.isCancelled { return }
		materializedURL = readableURL
		if isCurrentVideo {
			if usesEmbeddedVLC {
				return
			}
			if PhotoLibrary.requiresExternalVideoPlayer(readableURL) {
				loadFailed = true
				return
			}
			let nextPlayer = AVPlayer(url: readableURL)
			player = nextPlayer
			nextPlayer.play()
			return
		}
		let loaded = await Task.detached(priority: .userInitiated) {
			NSImage(contentsOf: readableURL)
		}.value
		if Task.isCancelled { return }
		if let loaded {
			image = loaded
		} else {
			loadFailed = true
		}
	}

	private func rotateLeft() {
		rotationDegrees = (rotationDegrees - 90) % 360
		if rotationDegrees < 0 { rotationDegrees += 360 }
	}

	private func rotateRight() {
		rotationDegrees = (rotationDegrees + 90) % 360
	}

	private func resetAdjustments() {
		brightnessAdjustment = 0
		contrastAdjustment = 1
	}

	private func navigateToAdjacentPhoto(offset: Int) {
		guard let targetURL = PhotoNavigationContext.shared.adjacentURL(to: currentURL, offset: offset),
			  targetURL != currentURL
		else {
			return
		}
		if hasPendingEdits {
			Task {
				await saveEdits()
				navigate(to: targetURL)
			}
		} else {
			navigate(to: targetURL)
		}
	}

	private func navigate(to targetURL: URL) {
		let previousURL = currentURL
		stopPlayback()
		WindowStateStore.shared.recordClosedPhoto(previousURL)
		currentURL = targetURL
		resetAdjustments()
		rotationDegrees = 0
		WindowStateStore.shared.recordOpenPhoto(targetURL)
		updateWindowMetadata(previousURL: previousURL, newURL: targetURL)
	}

	private func nextEditedURL(for sourceURL: URL) -> URL {
		let directoryURL = sourceURL.deletingLastPathComponent()
		let fileExt = sourceURL.pathExtension
		let baseName = sourceURL.deletingPathExtension().lastPathComponent
		let rootName = baseName.replacingOccurrences(of: #"-edit-\d+$"#, with: "", options: .regularExpression)

		let escapedRoot = NSRegularExpression.escapedPattern(for: rootName)
		let versionRegex = try? NSRegularExpression(pattern: "^\(escapedRoot)-edit-(\\d+)$")

		var maxVersion = 0
		if let files = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
			for file in files {
				if !fileExt.isEmpty && file.pathExtension.lowercased() != fileExt.lowercased() { continue }
				let stem = file.deletingPathExtension().lastPathComponent
				guard let regex = versionRegex else { continue }
				let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
				guard let match = regex.firstMatch(in: stem, options: [], range: range), match.numberOfRanges == 2,
					  let verRange = Range(match.range(at: 1), in: stem),
					  let version = Int(stem[verRange]) else { continue }
				maxVersion = max(maxVersion, version)
			}
		}

		return directoryURL
			.appendingPathComponent("\(rootName)-edit-\(maxVersion + 1)")
			.appendingPathExtension(fileExt)
	}

	private func updateWindowMetadata(previousURL: URL, newURL: URL) {
		let candidate = NSApp.windows.first { $0.representedURL == previousURL }
		let window = candidate ?? NSApp.keyWindow
		window?.title = newURL.lastPathComponent
		window?.representedURL = newURL
	}

	private func stopPlayback() {
		player?.pause()
		embeddedVLCController.stop()
	}

	private func formatPlaybackTime(_ seconds: TimeInterval) -> String {
		guard seconds.isFinite, seconds > 0 else { return "0:00" }
		let totalSeconds = Int(seconds.rounded(.down))
		let hours = totalSeconds / 3600
		let minutes = (totalSeconds / 60) % 60
		let remainingSeconds = totalSeconds % 60
		if hours > 0 {
			return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
		}
		return String(format: "%d:%02d", minutes, remainingSeconds)
	}

	/// Save rotation/brightness/contrast by writing a versioned "-edit-#" file
	/// next to the source image.
	private func saveEdits() async {
		guard hasPendingEdits else { return }
		guard let nsImg = image else { return }
		let sourceURL = currentURL
		let shouldPersistToSQLite = SQLiteObjectStore.isWorkingCopyURL(sourceURL)
		isSavingEdits = true
		defer { isSavingEdits = false }

		let degrees = rotationDegrees
		let brightness = brightnessAdjustment
		let contrast = contrastAdjustment
		let savedURL = await Task.detached(priority: .utility) { () -> URL? in
			// Obtain a CGImage from the NSImage
			var loadCG: CGImage? = nil
			if let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
				loadCG = cg
			} else {
				// Try to create from TIFFRepresentation
				if let tiff = nsImg.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage {
					loadCG = cg
				}
			}
			guard let cgImage = loadCG else { return nil }
			var workingImage = cgImage

			let absDeg = (degrees % 360 + 360) % 360
			if absDeg != 0 {
				let radians = Double(degrees) * Double.pi / 180.0
				var destWidth = cgImage.width
				var destHeight = cgImage.height
				if absDeg == 90 || absDeg == 270 {
					destWidth = cgImage.height
					destHeight = cgImage.width
				}

				guard let colorSpace = cgImage.colorSpace else { return nil }
				guard let ctx = CGContext(data: nil, width: destWidth, height: destHeight, bitsPerComponent: cgImage.bitsPerComponent, bytesPerRow: 0, space: colorSpace, bitmapInfo: cgImage.bitmapInfo.rawValue) else { return nil }

				// Apply transform: translate to center, rotate, draw
				ctx.translateBy(x: CGFloat(destWidth)/2.0, y: CGFloat(destHeight)/2.0)
				ctx.rotate(by: CGFloat(radians))
				ctx.translateBy(x: -CGFloat(cgImage.width)/2.0, y: -CGFloat(cgImage.height)/2.0)
				ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))

				guard let rotated = ctx.makeImage() else { return nil }
				workingImage = rotated
			}

			if abs(brightness) >= 0.001 || abs(contrast - 1) >= 0.001 {
				var ciOut = CIImage(cgImage: workingImage)
				if abs(brightness) >= 0.001 {
					guard let brightnessFilter = CIFilter(name: "CIColorControls") else { return nil }
					brightnessFilter.setValue(ciOut, forKey: kCIInputImageKey)
					brightnessFilter.setValue(Float(brightness), forKey: kCIInputBrightnessKey)
					brightnessFilter.setValue(1.0, forKey: kCIInputContrastKey)
					guard let out = brightnessFilter.outputImage else { return nil }
					ciOut = out
				}
				if abs(contrast - 1) >= 0.001 {
					guard let contrastFilter = CIFilter(name: "CIColorControls") else { return nil }
					contrastFilter.setValue(ciOut, forKey: kCIInputImageKey)
					contrastFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
					contrastFilter.setValue(Float(contrast), forKey: kCIInputContrastKey)
					guard let out = contrastFilter.outputImage else { return nil }
					ciOut = out
				}
				let renderColorSpace = workingImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
				let ciContext = CIContext(options: [
					.workingColorSpace: renderColorSpace as Any,
					.outputColorSpace: renderColorSpace as Any
				])
				guard let adjusted = ciContext.createCGImage(ciOut, from: ciOut.extent) else { return nil }
				workingImage = adjusted
			}

			// Preserve metadata if possible
			guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil), let type = CGImageSourceGetType(src) else { return nil }
			let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]

			// Ensure we have security-scoped access for the folder containing the file
			_ = await ContentView.ensureSecurityScopedAccess(for: sourceURL)

			let destinationURL = nextEditedURL(for: sourceURL)
			guard let dest = CGImageDestinationCreateWithURL(destinationURL as CFURL, type, 1, nil) else {
				let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
				logger.error("photo-detail: cannot create CGImageDestination for destinationURL=\(destinationURL.path, privacy: .public) type=\(String(describing: type), privacy: .public)")
				NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": sourceURL.path, "op": "photoDetailSave", "message": "CGImageDestinationCreateWithURL failed when attempting to save edited image."])
				// Per policy, do not write sidecars; report failure.
				return nil
			}
			if let metadata = props as CFDictionary? {
				CGImageDestinationAddImage(dest, workingImage, metadata)
			} else {
				CGImageDestinationAddImage(dest, workingImage, nil)
			}
			if !CGImageDestinationFinalize(dest) {
				let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
				logger.error("photo-detail: CGImageDestinationFinalize failed for destinationURL=\(destinationURL.path, privacy: .public)")
				NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": sourceURL.path, "op": "photoDetailSave", "message": "CGImageDestinationFinalize failed when attempting to save edited image."])
				// Do not write sidecar; surface failure.
				return nil
			}

			if shouldPersistToSQLite {
				do {
					try await SQLiteObjectStore.shared.storeObjectFile(at: destinationURL)
					await MainActor.run {
						NotificationCenter.default.post(
							name: .sqliteObjectStoreDidChange,
							object: nil,
							userInfo: ["filename": destinationURL.lastPathComponent]
						)
					}
				} catch {
					let logger = Logger(subsystem: "com.example.PictureViewer", category: "sqlite-object-store")
					logger.error("photo-detail: failed to persist sqlite edit path=\(destinationURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
				}
			}

			return destinationURL
		}.value

		if let destinationURL = savedURL {
			let previousURL = currentURL
			await PhotoVault.shared.reencryptWorkingCopyIfNeeded(destinationURL, sourceWorkingURL: previousURL)
			currentURL = destinationURL
			WindowStateStore.shared.recordClosedPhoto(previousURL)
			WindowStateStore.shared.recordOpenPhoto(destinationURL)
			updateWindowMetadata(previousURL: previousURL, newURL: destinationURL)
			if let loadedEdited = NSImage(contentsOf: destinationURL) {
				image = loadedEdited
				loadFailed = false
			}
			let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
			logger.log("photo-detail: saved edited image to \(destinationURL.path, privacy: .public)")
			// Reset edits (already baked into file)
			rotationDegrees = 0
			brightnessAdjustment = 0
			contrastAdjustment = 1
		} else {
			// Pixel rewrite failed (e.g. due to permissions). Per policy, do
			// not write a sidecar — log and surface failure.
			let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
			logger.error("photo-detail: saveEdits failed for \(sourceURL.path, privacy: .public)")
			NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": sourceURL.path, "op": "photoDetailSave", "message": "Failed to save edited image (pixel rewrite failed or permission error). "])
		}
	}
}
