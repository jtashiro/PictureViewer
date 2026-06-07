//
//  PhotoDetailView.swift
//  PictureViewer
//

import SwiftUI
import AppKit
import CoreImage
import ImageIO
import os

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

struct FullScreenPhotoView: View {
	let url: URL
	@State private var currentURL: URL

	init(url: URL) {
		self.url = url
		_currentURL = State(initialValue: url)
	}

	@AppStorage("photoDisplayMode") private var displayMode: PhotoDisplayMode = .fullScreen

	@State private var image: NSImage?
	@State private var loadFailed = false
	@State private var rotationDegrees: Int = 0
	@State private var brightnessAdjustment: Double = 0
	@State private var contrastAdjustment: Double = 1
	@State private var isSavingEdits: Bool = false
	@State private var didConfigureWindow = false
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		ZStack {
			Color.black
				.ignoresSafeArea()

			if let image {
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
			dismiss()
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
			if displayMode == .fullScreen {
				dismiss()
			}
		}
		.task(id: currentURL) {
			await loadImage()
		}
		.toolbar {
			ToolbarItem(placement: .automatic) {
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
		.onAppear {
			WindowStateStore.shared.recordOpenPhoto(currentURL)
		}
		.onDisappear {
			// If the user rotated but didn't explicitly save, persist the
			// rotation automatically when the window closes.
			if hasPendingEdits {
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

	private func loadImage() async {
		image = nil
		loadFailed = false
		let target = currentURL
		let loaded = await Task.detached(priority: .userInitiated) {
			NSImage(contentsOf: target)
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
