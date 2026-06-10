//
//  GalleryWindowCloseDelegate.swift
//  PictureViewer
//

import SwiftUI
import AppKit
import ObjectiveC

private var galleryWindowCloseDelegateKey: UInt8 = 0

@MainActor
final class GalleryTabCloseCoordinator {
	static let shared = GalleryTabCloseCoordinator()
	var isPerformingConfirmedClose = false
}

@MainActor
final class SQLiteThumbnailRefreshCoordinator {
	static let shared = SQLiteThumbnailRefreshCoordinator()
	private var handlers: [String: () -> Void] = [:]

	func setHandler(for storeName: String, _ handler: @escaping () -> Void) {
		handlers[storeName] = handler
	}

	func removeHandler(for storeName: String) {
		handlers.removeValue(forKey: storeName)
	}

	func thumbnailsDecoded(for storeName: String) {
		handlers[storeName]?()
	}
}

private final class SQLiteThumbnailRefreshThrottle: @unchecked Sendable {
	private let lock = NSLock()
	nonisolated(unsafe) private var lastNotifiedCount = 0
	private let batchInterval = 64

	nonisolated func shouldNotify(decoded: Int, total: Int) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard decoded > 0, total > 0 else { return false }
		if decoded >= total {
			lastNotifiedCount = decoded
			return true
		}
		return false
	}
}

enum SQLiteThumbnailRefreshSupport {
	static func progressHandler(for storeName: String) -> @Sendable (Int, Int) async -> Void {
		let throttle = SQLiteThumbnailRefreshThrottle()
		return { decoded, total in
			guard throttle.shouldNotify(decoded: decoded, total: total) else { return }
			await SQLiteThumbnailRefreshCoordinator.shared.thumbnailsDecoded(for: storeName)
		}
	}
}

@MainActor
final class SQLiteStoreOpenRequestCoordinator {
	struct PendingOpen: Equatable {
		let storeName: String
		let requestID: UUID
		let fileURL: URL?
	}

	static let shared = SQLiteStoreOpenRequestCoordinator()
	private(set) var pending: PendingOpen?

	@discardableResult
	func requestOpen(storeName: String, fileURL: URL? = nil) -> UUID {
		let trimmed = SQLiteObjectStore.normalizedStoreName(storeName)
		let requestID = UUID()
		guard !trimmed.isEmpty else { return requestID }
		pending = PendingOpen(storeName: trimmed, requestID: requestID, fileURL: fileURL)
		return requestID
	}

	func hasPending(requestID: UUID) -> Bool {
		pending?.requestID == requestID
	}

	func matchesOpenToken(_ token: String) -> Bool {
		guard let pending,
		      let requestID = SQLiteObjectStore.requestID(fromOpenToken: token) else {
			return false
		}
		return pending.requestID == requestID
	}

	@discardableResult
	func consumePending(for storeName: String, requestID: UUID? = nil) -> PendingOpen? {
		guard let pending, SQLiteObjectStore.storeNamesMatch(pending.storeName, storeName) else { return nil }
		if let requestID, pending.requestID != requestID { return nil }
		self.pending = nil
		return pending
	}

	@discardableResult
	func consumePending(matchingRequestID requestID: UUID) -> PendingOpen? {
		guard let pending, pending.requestID == requestID else { return nil }
		self.pending = nil
		return pending
	}
}

@MainActor
final class GalleryWindowCloseDelegate: NSObject, NSWindowDelegate {
	var closeHandler: (() -> Void)?

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		if GalleryTabCloseCoordinator.shared.isPerformingConfirmedClose {
			GalleryTabCloseCoordinator.shared.isPerformingConfirmedClose = false
			return true
		}
		closeHandler?()
		return false
	}
}

@MainActor
enum GalleryWindowCloseSupport {
	static func install(on window: NSWindow, closeHandler: @escaping () -> Void) {
		let delegate: GalleryWindowCloseDelegate
		if let existing = objc_getAssociatedObject(window, &galleryWindowCloseDelegateKey) as? GalleryWindowCloseDelegate {
			delegate = existing
		} else {
			delegate = GalleryWindowCloseDelegate()
			objc_setAssociatedObject(
				window,
				&galleryWindowCloseDelegateKey,
				delegate,
				.OBJC_ASSOCIATION_RETAIN_NONATOMIC
			)
			window.delegate = delegate
		}
		delegate.closeHandler = closeHandler
	}
}

struct GalleryWindowCloseInstaller: NSViewRepresentable {
	let onCloseRequest: () -> Void

	func makeNSView(context: Context) -> NSView {
		let view = NSView(frame: .zero)
		DispatchQueue.main.async {
			guard let window = view.window else { return }
			GalleryWindowCloseSupport.install(on: window, closeHandler: onCloseRequest)
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		DispatchQueue.main.async {
			guard let window = nsView.window else { return }
			GalleryWindowCloseSupport.install(on: window, closeHandler: onCloseRequest)
		}
	}
}