//
//  EmbeddedVLCPlayerView.swift
//  PictureViewer
//

import SwiftUI
import AppKit
import Combine
import Darwin
import os

private final class LibVLCRuntime {
	private static let loadLogger = Logger(subsystem: "com.example.PictureViewer", category: "vlc")

	private typealias LibVLCNew = @convention(c) (Int32, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> OpaquePointer?
	private typealias LibVLCRelease = @convention(c) (OpaquePointer?) -> Void
	private typealias LibVLCMediaNewPath = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> OpaquePointer?
	private typealias LibVLCMediaRelease = @convention(c) (OpaquePointer?) -> Void
	private typealias LibVLCMediaPlayerNewFromMedia = @convention(c) (OpaquePointer?) -> OpaquePointer?
	private typealias LibVLCMediaPlayerRelease = @convention(c) (OpaquePointer?) -> Void
	private typealias LibVLCMediaPlayerSetNSObject = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
	private typealias LibVLCMediaPlayerPlay = @convention(c) (OpaquePointer?) -> Int32
	private typealias LibVLCMediaPlayerPause = @convention(c) (OpaquePointer?) -> Void
	private typealias LibVLCMediaPlayerStop = @convention(c) (OpaquePointer?) -> Void
	private typealias LibVLCMediaPlayerIsPlaying = @convention(c) (OpaquePointer?) -> Int32
	private typealias LibVLCMediaPlayerGetTime = @convention(c) (OpaquePointer?) -> Int64
	private typealias LibVLCMediaPlayerSetTime = @convention(c) (OpaquePointer?, Int64) -> Void
	private typealias LibVLCMediaPlayerGetLength = @convention(c) (OpaquePointer?) -> Int64
	private typealias LibVLCVideoGetSize = @convention(c) (OpaquePointer?, UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
	private typealias LibVLCVideoTakeSnapshot = @convention(c) (OpaquePointer?, UInt32, UnsafePointer<CChar>?, UInt32, UInt32) -> Int32

	static let shared: LibVLCRuntime? = {
		guard let runtime = loadRuntime() else { return nil }
		return LibVLCRuntime(runtime: runtime)
	}()

	private let logger = Logger(subsystem: "com.example.PictureViewer", category: "vlc")
	private let handle: UnsafeMutableRawPointer
	private let coreHandle: UnsafeMutableRawPointer?
	private let instance: OpaquePointer
	private let mediaNewPath: LibVLCMediaNewPath
	private let mediaRelease: LibVLCMediaRelease
	private let mediaPlayerNewFromMedia: LibVLCMediaPlayerNewFromMedia
	private let mediaPlayerRelease: LibVLCMediaPlayerRelease
	private let mediaPlayerSetNSObject: LibVLCMediaPlayerSetNSObject
	private let mediaPlayerPlay: LibVLCMediaPlayerPlay
	private let mediaPlayerPause: LibVLCMediaPlayerPause
	private let mediaPlayerStop: LibVLCMediaPlayerStop
	private let mediaPlayerIsPlaying: LibVLCMediaPlayerIsPlaying
	private let mediaPlayerGetTime: LibVLCMediaPlayerGetTime
	private let mediaPlayerSetTime: LibVLCMediaPlayerSetTime
	private let mediaPlayerGetLength: LibVLCMediaPlayerGetLength
	private let videoGetSize: LibVLCVideoGetSize
	private let videoTakeSnapshot: LibVLCVideoTakeSnapshot
	private let libVLCRelease: LibVLCRelease

	static var isAvailable: Bool {
		shared != nil
	}

	static func logAvailabilityResult(context: String) {
		loadLogger.log("vlc embedded: availability context=\(context, privacy: .public) available=\(isAvailable, privacy: .public)")
	}

	private init(runtime: LoadedRuntime) {
		handle = runtime.handle
		coreHandle = runtime.coreHandle
		instance = runtime.instance
		mediaNewPath = runtime.mediaNewPath
		mediaRelease = runtime.mediaRelease
		mediaPlayerNewFromMedia = runtime.mediaPlayerNewFromMedia
		mediaPlayerRelease = runtime.mediaPlayerRelease
		mediaPlayerSetNSObject = runtime.mediaPlayerSetNSObject
		mediaPlayerPlay = runtime.mediaPlayerPlay
		mediaPlayerPause = runtime.mediaPlayerPause
		mediaPlayerStop = runtime.mediaPlayerStop
		mediaPlayerIsPlaying = runtime.mediaPlayerIsPlaying
		mediaPlayerGetTime = runtime.mediaPlayerGetTime
		mediaPlayerSetTime = runtime.mediaPlayerSetTime
		mediaPlayerGetLength = runtime.mediaPlayerGetLength
		videoGetSize = runtime.videoGetSize
		videoTakeSnapshot = runtime.videoTakeSnapshot
		libVLCRelease = runtime.libVLCRelease
	}

	deinit {
		libVLCRelease(instance)
		dlclose(handle)
		if let coreHandle {
			dlclose(coreHandle)
		}
	}

	private struct LoadedRuntime {
		let handle: UnsafeMutableRawPointer
		let coreHandle: UnsafeMutableRawPointer?
		let instance: OpaquePointer
		let mediaNewPath: LibVLCMediaNewPath
		let mediaRelease: LibVLCMediaRelease
		let mediaPlayerNewFromMedia: LibVLCMediaPlayerNewFromMedia
		let mediaPlayerRelease: LibVLCMediaPlayerRelease
		let mediaPlayerSetNSObject: LibVLCMediaPlayerSetNSObject
		let mediaPlayerPlay: LibVLCMediaPlayerPlay
		let mediaPlayerPause: LibVLCMediaPlayerPause
		let mediaPlayerStop: LibVLCMediaPlayerStop
		let mediaPlayerIsPlaying: LibVLCMediaPlayerIsPlaying
		let mediaPlayerGetTime: LibVLCMediaPlayerGetTime
		let mediaPlayerSetTime: LibVLCMediaPlayerSetTime
		let mediaPlayerGetLength: LibVLCMediaPlayerGetLength
		let videoGetSize: LibVLCVideoGetSize
		let videoTakeSnapshot: LibVLCVideoTakeSnapshot
		let libVLCRelease: LibVLCRelease
	}

	private static func loadRuntime() -> LoadedRuntime? {
		loadLogger.log("vlc embedded: starting VLC runtime search")
		guard let vlcAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") else {
			loadLogger.error("vlc embedded: VLC.app not found by bundle identifier org.videolan.vlc")
			return nil
		}
		loadLogger.log("vlc embedded: found VLC.app url=\(vlcAppURL.path, privacy: .public)")

		let contentsURL = vlcAppURL.appendingPathComponent("Contents", isDirectory: true)
		let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
		let candidateLibraryURLs = [
			macOSURL.appendingPathComponent("lib", isDirectory: true).appendingPathComponent("libvlc.dylib"),
			contentsURL.appendingPathComponent("Frameworks", isDirectory: true).appendingPathComponent("libvlc.dylib"),
			macOSURL.appendingPathComponent("libvlc.dylib")
		]
		for candidateURL in candidateLibraryURLs {
			let exists = FileManager.default.fileExists(atPath: candidateURL.path)
			loadLogger.log("vlc embedded: checking libvlc candidate path=\(candidateURL.path, privacy: .public) exists=\(exists, privacy: .public)")
		}
		guard let libraryURL = candidateLibraryURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
			loadLogger.error("vlc embedded: no libvlc.dylib found inside VLC.app")
			return nil
		}
		loadLogger.log("vlc embedded: selected libvlc path=\(libraryURL.path, privacy: .public)")

		let candidateCoreURLs = [
			libraryURL.deletingLastPathComponent().appendingPathComponent("libvlccore.dylib"),
			macOSURL.appendingPathComponent("lib", isDirectory: true).appendingPathComponent("libvlccore.dylib"),
			contentsURL.appendingPathComponent("Frameworks", isDirectory: true).appendingPathComponent("libvlccore.dylib"),
			macOSURL.appendingPathComponent("libvlccore.dylib")
		]
		for candidateURL in candidateCoreURLs {
			let exists = FileManager.default.fileExists(atPath: candidateURL.path)
			loadLogger.log("vlc embedded: checking libvlccore candidate path=\(candidateURL.path, privacy: .public) exists=\(exists, privacy: .public)")
		}
		var coreHandle: UnsafeMutableRawPointer?
		if let coreURL = candidateCoreURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
			coreHandle = dlopen(coreURL.path, RTLD_NOW | RTLD_GLOBAL)
			if coreHandle == nil {
				let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
				loadLogger.error("vlc embedded: dlopen libvlccore failed path=\(coreURL.path, privacy: .public) error=\(message, privacy: .public)")
				return nil
			}
			loadLogger.log("vlc embedded: dlopen libvlccore succeeded path=\(coreURL.path, privacy: .public)")
		} else {
			loadLogger.error("vlc embedded: libvlccore.dylib not found beside VLC libvlc")
		}

		let pluginURLs = [
			macOSURL.appendingPathComponent("plugins", isDirectory: true),
			contentsURL.appendingPathComponent("plugins", isDirectory: true)
		]
		for pluginURL in pluginURLs {
			let exists = FileManager.default.fileExists(atPath: pluginURL.path)
			loadLogger.log("vlc embedded: checking plugin candidate path=\(pluginURL.path, privacy: .public) exists=\(exists, privacy: .public)")
		}
		if let pluginURL = pluginURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
			setenv("VLC_PLUGIN_PATH", pluginURL.path, 1)
			loadLogger.log("vlc embedded: set VLC_PLUGIN_PATH=\(pluginURL.path, privacy: .public)")
		} else {
			loadLogger.error("vlc embedded: VLC plugin directory not found; libVLC may fail to initialize")
		}

		guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
			let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
			loadLogger.error("vlc embedded: dlopen failed path=\(libraryURL.path, privacy: .public) error=\(message, privacy: .public)")
			if let coreHandle {
				dlclose(coreHandle)
			}
			return nil
		}
		loadLogger.log("vlc embedded: dlopen succeeded path=\(libraryURL.path, privacy: .public)")

		func symbol<T>(_ name: String, as type: T.Type) -> T? {
			guard let pointer = dlsym(handle, name) else { return nil }
			return unsafeBitCast(pointer, to: type)
		}

		let requiredSymbolNames = [
			"libvlc_new",
			"libvlc_release",
			"libvlc_media_new_path",
			"libvlc_media_release",
			"libvlc_media_player_new_from_media",
			"libvlc_media_player_release",
			"libvlc_media_player_set_nsobject",
			"libvlc_media_player_play",
			"libvlc_media_player_pause",
			"libvlc_media_player_stop",
			"libvlc_media_player_is_playing",
			"libvlc_media_player_get_time",
			"libvlc_media_player_set_time",
			"libvlc_media_player_get_length",
			"libvlc_video_get_size",
			"libvlc_video_take_snapshot"
		]
		for symbolName in requiredSymbolNames {
			let found = dlsym(handle, symbolName) != nil
			loadLogger.log("vlc embedded: checking symbol name=\(symbolName, privacy: .public) found=\(found, privacy: .public)")
		}

		guard let libVLCNew = symbol("libvlc_new", as: LibVLCNew.self),
			  let libVLCRelease = symbol("libvlc_release", as: LibVLCRelease.self),
			  let mediaNewPath = symbol("libvlc_media_new_path", as: LibVLCMediaNewPath.self),
			  let mediaRelease = symbol("libvlc_media_release", as: LibVLCMediaRelease.self),
			  let mediaPlayerNewFromMedia = symbol("libvlc_media_player_new_from_media", as: LibVLCMediaPlayerNewFromMedia.self),
			  let mediaPlayerRelease = symbol("libvlc_media_player_release", as: LibVLCMediaPlayerRelease.self),
			  let mediaPlayerSetNSObject = symbol("libvlc_media_player_set_nsobject", as: LibVLCMediaPlayerSetNSObject.self),
			  let mediaPlayerPlay = symbol("libvlc_media_player_play", as: LibVLCMediaPlayerPlay.self),
			  let mediaPlayerPause = symbol("libvlc_media_player_pause", as: LibVLCMediaPlayerPause.self),
			  let mediaPlayerStop = symbol("libvlc_media_player_stop", as: LibVLCMediaPlayerStop.self),
			  let mediaPlayerIsPlaying = symbol("libvlc_media_player_is_playing", as: LibVLCMediaPlayerIsPlaying.self),
			  let mediaPlayerGetTime = symbol("libvlc_media_player_get_time", as: LibVLCMediaPlayerGetTime.self),
			  let mediaPlayerSetTime = symbol("libvlc_media_player_set_time", as: LibVLCMediaPlayerSetTime.self),
			  let mediaPlayerGetLength = symbol("libvlc_media_player_get_length", as: LibVLCMediaPlayerGetLength.self),
			  let videoGetSize = symbol("libvlc_video_get_size", as: LibVLCVideoGetSize.self),
			  let videoTakeSnapshot = symbol("libvlc_video_take_snapshot", as: LibVLCVideoTakeSnapshot.self)
		else {
			loadLogger.error("vlc embedded: required libVLC symbols missing")
			dlclose(handle)
			if let coreHandle {
				dlclose(coreHandle)
			}
			return nil
		}

		let args = ["--no-video-title-show", "--quiet"]
		let cStrings = args.map { strdup($0) }
		defer {
			for cString in cStrings {
				free(cString)
			}
		}
		var argv = cStrings.map { UnsafePointer<CChar>($0) }
		let argc = Int32(argv.count)
		guard let instance = argv.withUnsafeMutableBufferPointer({
			libVLCNew(argc, $0.baseAddress)
		}) else {
			loadLogger.error("vlc embedded: libvlc_new failed")
			dlclose(handle)
			if let coreHandle {
				dlclose(coreHandle)
			}
			return nil
		}
		loadLogger.log("vlc embedded: libvlc_new succeeded; embedded VLC runtime is available")

		return LoadedRuntime(
			handle: handle,
			coreHandle: coreHandle,
			instance: instance,
			mediaNewPath: mediaNewPath,
			mediaRelease: mediaRelease,
			mediaPlayerNewFromMedia: mediaPlayerNewFromMedia,
			mediaPlayerRelease: mediaPlayerRelease,
			mediaPlayerSetNSObject: mediaPlayerSetNSObject,
			mediaPlayerPlay: mediaPlayerPlay,
			mediaPlayerPause: mediaPlayerPause,
			mediaPlayerStop: mediaPlayerStop,
			mediaPlayerIsPlaying: mediaPlayerIsPlaying,
			mediaPlayerGetTime: mediaPlayerGetTime,
			mediaPlayerSetTime: mediaPlayerSetTime,
			mediaPlayerGetLength: mediaPlayerGetLength,
			videoGetSize: videoGetSize,
			videoTakeSnapshot: videoTakeSnapshot,
			libVLCRelease: libVLCRelease
		)
	}

	func makePlayer(for url: URL, in view: NSView? = nil) -> LibVLCPlayer? {
		let startedAccess = SecurityScopedResourceAccess.ensureAccess(for: url)
		guard let media = url.path.withCString({ mediaNewPath(instance, $0) }) else {
			if startedAccess {
				url.stopAccessingSecurityScopedResource()
			}
			logger.error("vlc embedded: failed to create media path=\(url.path, privacy: .public)")
			return nil
		}
		guard let player = mediaPlayerNewFromMedia(media) else {
			mediaRelease(media)
			if startedAccess {
				url.stopAccessingSecurityScopedResource()
			}
			logger.error("vlc embedded: failed to create player path=\(url.path, privacy: .public)")
			return nil
		}
		if let view {
			mediaPlayerSetNSObject(player, Unmanaged.passUnretained(view).toOpaque())
		}
		_ = mediaPlayerPlay(player)
		return LibVLCPlayer(
			url: url,
			startedAccess: startedAccess,
			media: media,
			player: player,
			mediaPlayerPlay: mediaPlayerPlay,
			mediaPlayerPause: mediaPlayerPause,
			mediaPlayerStop: mediaPlayerStop,
			mediaPlayerIsPlaying: mediaPlayerIsPlaying,
			mediaPlayerGetTime: mediaPlayerGetTime,
			mediaPlayerSetTime: mediaPlayerSetTime,
			mediaPlayerGetLength: mediaPlayerGetLength,
			videoGetSize: videoGetSize,
			videoTakeSnapshot: videoTakeSnapshot,
			mediaRelease: mediaRelease,
			mediaPlayerRelease: mediaPlayerRelease
		)
	}

	@MainActor
	func generateSnapshotThumbnail(for url: URL) async throws -> NSImage {
		let snapshotSize = Int(ThumbnailCache.canonicalSize)
		let view = EmbeddedVLCNSView(frame: NSRect(x: 0, y: 0, width: snapshotSize, height: snapshotSize))
		let window = NSWindow(
			contentRect: NSRect(x: -10_000, y: -10_000, width: snapshotSize, height: snapshotSize),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.contentView = view
		window.backgroundColor = .black
		window.isOpaque = true
		window.ignoresMouseEvents = true
		window.alphaValue = 0.02
		window.orderFrontRegardless()
		defer {
			window.orderOut(nil)
			window.contentView = nil
		}

		guard let player = makePlayer(for: url, in: view) else {
			throw EmbeddedVLCThumbnailError.playerCreationFailed
		}
		defer {
			player.stop()
		}

		try await Task.sleep(nanoseconds: 1_500_000_000)
		let duration = player.duration
		let targetSeconds = duration > 31 ? 30 : max(0.1, duration * 0.5)
		logger.log("vlc embedded: thumbnail snapshot preparing url=\(url.path, privacy: .public) duration=\(duration, privacy: .public) targetSeconds=\(targetSeconds, privacy: .public)")
		player.seek(to: targetSeconds)
		try await Task.sleep(nanoseconds: 2_000_000_000)

		let scratchURL = AppWorkingDirectory.scratchURL()
		try AppWorkingDirectory.ensureDirectory(scratchURL)
		let snapshotURL = scratchURL
			.appendingPathComponent("PictureViewer-VLCThumbnail-\(UUID().uuidString)")
			.appendingPathExtension("png")
		try? FileManager.default.removeItem(at: snapshotURL)
		defer {
			try? FileManager.default.removeItem(at: snapshotURL)
		}

		let snapshotPixelSize = player.snapshotPixelSize(maxDimension: UInt32(snapshotSize))
		logger.log("vlc embedded: thumbnail snapshot dimensions url=\(url.path, privacy: .public) width=\(snapshotPixelSize.width, privacy: .public) height=\(snapshotPixelSize.height, privacy: .public)")
		try player.takeSnapshot(to: snapshotURL, width: snapshotPixelSize.width, height: snapshotPixelSize.height)
		guard let image = NSImage(contentsOf: snapshotURL) else {
			throw EmbeddedVLCThumbnailError.snapshotReadFailed
		}
		logger.log("vlc embedded: thumbnail snapshot succeeded url=\(url.path, privacy: .public)")
		return image
	}
}

private final class LibVLCPlayer {
	let url: URL
	private let startedAccess: Bool
	private let media: OpaquePointer
	private let player: OpaquePointer
	private let mediaPlayerPlay: (OpaquePointer?) -> Int32
	private let mediaPlayerPause: (OpaquePointer?) -> Void
	private let mediaPlayerStop: (OpaquePointer?) -> Void
	private let mediaPlayerIsPlaying: (OpaquePointer?) -> Int32
	private let mediaPlayerGetTime: (OpaquePointer?) -> Int64
	private let mediaPlayerSetTime: (OpaquePointer?, Int64) -> Void
	private let mediaPlayerGetLength: (OpaquePointer?) -> Int64
	private let videoGetSize: (OpaquePointer?, UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
	private let videoTakeSnapshot: (OpaquePointer?, UInt32, UnsafePointer<CChar>?, UInt32, UInt32) -> Int32
	private let mediaRelease: (OpaquePointer?) -> Void
	private let mediaPlayerRelease: (OpaquePointer?) -> Void
	private var didStop = false

	init(
		url: URL,
		startedAccess: Bool,
		media: OpaquePointer,
		player: OpaquePointer,
		mediaPlayerPlay: @escaping (OpaquePointer?) -> Int32,
		mediaPlayerPause: @escaping (OpaquePointer?) -> Void,
		mediaPlayerStop: @escaping (OpaquePointer?) -> Void,
		mediaPlayerIsPlaying: @escaping (OpaquePointer?) -> Int32,
		mediaPlayerGetTime: @escaping (OpaquePointer?) -> Int64,
		mediaPlayerSetTime: @escaping (OpaquePointer?, Int64) -> Void,
		mediaPlayerGetLength: @escaping (OpaquePointer?) -> Int64,
		videoGetSize: @escaping (OpaquePointer?, UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32,
		videoTakeSnapshot: @escaping (OpaquePointer?, UInt32, UnsafePointer<CChar>?, UInt32, UInt32) -> Int32,
		mediaRelease: @escaping (OpaquePointer?) -> Void,
		mediaPlayerRelease: @escaping (OpaquePointer?) -> Void
	) {
		self.url = url
		self.startedAccess = startedAccess
		self.media = media
		self.player = player
		self.mediaPlayerPlay = mediaPlayerPlay
		self.mediaPlayerPause = mediaPlayerPause
		self.mediaPlayerStop = mediaPlayerStop
		self.mediaPlayerIsPlaying = mediaPlayerIsPlaying
		self.mediaPlayerGetTime = mediaPlayerGetTime
		self.mediaPlayerSetTime = mediaPlayerSetTime
		self.mediaPlayerGetLength = mediaPlayerGetLength
		self.videoGetSize = videoGetSize
		self.videoTakeSnapshot = videoTakeSnapshot
		self.mediaRelease = mediaRelease
		self.mediaPlayerRelease = mediaPlayerRelease
	}

	var isPlaying: Bool {
		mediaPlayerIsPlaying(player) != 0
	}

	var time: TimeInterval {
		let milliseconds = mediaPlayerGetTime(player)
		guard milliseconds > 0 else { return 0 }
		return TimeInterval(milliseconds) / 1000
	}

	var duration: TimeInterval {
		let milliseconds = mediaPlayerGetLength(player)
		guard milliseconds > 0 else { return 0 }
		return TimeInterval(milliseconds) / 1000
	}

	func play() {
		_ = mediaPlayerPlay(player)
	}

	func pause() {
		mediaPlayerPause(player)
	}

	func stop() {
		guard !didStop else { return }
		didStop = true
		mediaPlayerStop(player)
	}

	func seek(to seconds: TimeInterval) {
		let milliseconds = max(0, Int64(seconds * 1000))
		mediaPlayerSetTime(player, milliseconds)
	}

	func skip(by seconds: TimeInterval) {
		let target = max(0, min(duration, time + seconds))
		seek(to: target)
	}

	func snapshotPixelSize(maxDimension: UInt32) -> (width: UInt32, height: UInt32) {
		var width: UInt32 = 0
		var height: UInt32 = 0
		guard videoGetSize(player, 0, &width, &height) == 0,
			  width > 0,
			  height > 0
		else {
			return (maxDimension, 0)
		}
		if width >= height {
			let scaledHeight = max(1, UInt32((Double(height) / Double(width) * Double(maxDimension)).rounded()))
			return (maxDimension, scaledHeight)
		}
		let scaledWidth = max(1, UInt32((Double(width) / Double(height) * Double(maxDimension)).rounded()))
		return (scaledWidth, maxDimension)
	}

	func takeSnapshot(to url: URL, width: UInt32, height: UInt32) throws {
		let result = url.path.withCString {
			videoTakeSnapshot(player, 0, $0, width, height)
		}
		guard result == 0 else {
			throw EmbeddedVLCThumbnailError.snapshotFailed
		}
	}

	deinit {
		stop()
		mediaPlayerRelease(player)
		mediaRelease(media)
		if startedAccess {
			url.stopAccessingSecurityScopedResource()
		}
	}
}

enum EmbeddedVLCThumbnailError: LocalizedError {
	case runtimeUnavailable
	case playerCreationFailed
	case snapshotFailed
	case snapshotReadFailed

	var errorDescription: String? {
		switch self {
		case .runtimeUnavailable:
			"Embedded VLC runtime is unavailable."
		case .playerCreationFailed:
			"Embedded VLC could not create a media player for the video."
		case .snapshotFailed:
			"Embedded VLC failed to write a video snapshot."
		case .snapshotReadFailed:
			"Embedded VLC wrote no readable snapshot image."
		}
	}
}

@MainActor
final class EmbeddedVLCPlaybackController: ObservableObject {
	@Published private(set) var isPlaying = false
	@Published private(set) var currentTime: TimeInterval = 0
	@Published private(set) var duration: TimeInterval = 0

	private weak var player: LibVLCPlayer?
	private var updateTask: Task<Void, Never>?

	fileprivate func attach(player: LibVLCPlayer?) {
		self.player = player
		refreshState()
		startUpdating()
	}

	fileprivate func detach(player: LibVLCPlayer?) {
		guard self.player === player || player == nil else { return }
		updateTask?.cancel()
		updateTask = nil
		self.player = nil
		isPlaying = false
		currentTime = 0
		duration = 0
	}

	func togglePlayPause() {
		guard let player else { return }
		if player.isPlaying {
			player.pause()
		} else {
			player.play()
		}
		refreshState()
	}

	func stop() {
		player?.stop()
		refreshState()
	}

	func skip(by seconds: TimeInterval) {
		player?.skip(by: seconds)
		refreshState()
	}

	func seek(to seconds: TimeInterval) {
		player?.seek(to: seconds)
		refreshState()
	}

	private func startUpdating() {
		updateTask?.cancel()
		updateTask = Task { [weak self] in
			while !Task.isCancelled {
				self?.refreshState()
				try? await Task.sleep(nanoseconds: 300_000_000)
			}
		}
	}

	private func refreshState() {
		guard let player else {
			isPlaying = false
			currentTime = 0
			duration = 0
			return
		}
		isPlaying = player.isPlaying
		currentTime = player.time
		duration = player.duration
	}

	deinit {
		updateTask?.cancel()
	}
}

final class EmbeddedVLCNSView: NSView {
	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.backgroundColor = NSColor.black.cgColor
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		wantsLayer = true
		layer?.backgroundColor = NSColor.black.cgColor
	}
}

struct EmbeddedVLCPlayerView: NSViewRepresentable {
	let url: URL
	@ObservedObject var controller: EmbeddedVLCPlaybackController

	static var isAvailable: Bool {
		LibVLCRuntime.isAvailable
	}

	static func logAvailabilityResult(context: String) {
		LibVLCRuntime.logAvailabilityResult(context: context)
	}

	static func generateThumbnail(for url: URL) async throws -> NSImage {
		guard let runtime = LibVLCRuntime.shared else {
			throw EmbeddedVLCThumbnailError.runtimeUnavailable
		}
		return try await runtime.generateSnapshotThumbnail(for: url)
	}

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> EmbeddedVLCNSView {
		let view = EmbeddedVLCNSView()
		context.coordinator.controller = controller
		context.coordinator.update(url: url, in: view)
		return view
	}

	func updateNSView(_ nsView: EmbeddedVLCNSView, context: Context) {
		context.coordinator.controller = controller
		context.coordinator.update(url: url, in: nsView)
	}

	static func dismantleNSView(_ nsView: EmbeddedVLCNSView, coordinator: Coordinator) {
		coordinator.stop()
	}

	final class Coordinator {
		private var currentPlayer: LibVLCPlayer?
		private var currentURL: URL?

		func update(url: URL, in view: NSView) {
			guard currentURL != url else { return }
			controller?.detach(player: currentPlayer)
			currentPlayer = nil
			currentURL = url
			guard let runtime = LibVLCRuntime.shared else { return }
			currentPlayer = runtime.makePlayer(for: url, in: view)
			controller?.attach(player: currentPlayer)
		}

		func stop() {
			currentPlayer?.stop()
			controller?.detach(player: currentPlayer)
			currentPlayer = nil
			currentURL = nil
		}

		weak var controller: EmbeddedVLCPlaybackController?
	}
}
