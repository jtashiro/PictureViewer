//
//  ContentViewSupport.swift
//  PictureViewer
//

import SwiftUI
import AppKit

/// Limits how often long-running backfill work refreshes SwiftUI focused menu
/// state. Frequent updates while AppKit is tracking a menu can crash with
/// NSRangeException inside NSContextMenuImpl.
@MainActor
final class BackfillProgressUIThrottler {
	private var lastUpdate = Date.distantPast
	private let minimumInterval: TimeInterval = 0.25

	func shouldUpdate(completed: Int, total: Int) -> Bool {
		guard total > 0 else { return false }
		if completed >= total {
			return true
		}
		let now = Date()
		guard now.timeIntervalSince(lastUpdate) >= minimumInterval else {
			return false
		}
		lastUpdate = now
		return true
	}
}

struct ThumbnailFramePreferenceKey: PreferenceKey {
	static var defaultValue: [URL: CGRect] = [:]

	static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
		value.merge(nextValue(), uniquingKeysWith: { _, new in new })
	}
}

struct PhotoGridScrollRequest: Equatable {
	let id = UUID()
	let url: URL
}

enum MarqueeSelectionMode {
	case replace
	case add
	case subtract
	case toggle
}

enum GalleryGridSelectionGeometry {
	static func columnCount(displayedPhotos: [PhotoItem], thumbnailFrames: [URL: CGRect]) -> Int {
		let sortedFrames = displayedPhotos.compactMap { photo -> (url: URL, frame: CGRect)? in
			guard let frame = thumbnailFrames[photo.url] else { return nil }
			return (photo.url, frame)
		}
		guard let first = sortedFrames.min(by: {
			if abs($0.frame.minY - $1.frame.minY) > 0.5 {
				return $0.frame.minY < $1.frame.minY
			}
			return $0.frame.minX < $1.frame.minX
		}) else {
			return 1
		}
		let rowY = first.frame.minY
		let threshold: CGFloat = 1
		let count = sortedFrames.filter { abs($0.frame.minY - rowY) < threshold }.count
		return max(1, count)
	}

	static func nextSelectionURL(
		orderedURLs: [URL],
		orderedSelection: [URL],
		direction: GridNavigationDirection,
		columnCount: Int
	) -> URL? {
		guard orderedSelection.count <= 1 else { return nil }
		guard let currentURL = orderedSelection.first else {
			return orderedURLs.first
		}
		guard let currentIndex = orderedURLs.firstIndex(of: currentURL) else { return nil }

		let nextIndex: Int?
		switch direction {
		case .left:
			nextIndex = currentIndex > 0 ? currentIndex - 1 : nil
		case .right:
			nextIndex = currentIndex + 1 < orderedURLs.count ? currentIndex + 1 : nil
		case .up:
			nextIndex = currentIndex >= columnCount ? currentIndex - columnCount : nil
		case .down:
			nextIndex = currentIndex + columnCount < orderedURLs.count ? currentIndex + columnCount : nil
		}

		guard let nextIndex, orderedURLs.indices.contains(nextIndex) else { return nil }
		return orderedURLs[nextIndex]
	}

	static func selectionRect(start: CGPoint?, current: CGPoint?) -> CGRect? {
		guard let start, let current else { return nil }
		let origin = CGPoint(x: min(start.x, current.x), y: min(start.y, current.y))
		let size = CGSize(width: abs(current.x - start.x), height: abs(current.y - start.y))
		if size.width < 2, size.height < 2 { return nil }
		return CGRect(origin: origin, size: size)
	}

	static func hitURLs(in selectionRect: CGRect, thumbnailFrames: [URL: CGRect]) -> Set<URL> {
		Set(thumbnailFrames.compactMap { url, frame in
			frame.intersects(selectionRect) ? url : nil
		})
	}

	static func dragSelection(base: Set<URL>, hits: Set<URL>, mode: MarqueeSelectionMode) -> Set<URL> {
		switch mode {
		case .replace:
			return hits
		case .add:
			return base.union(hits)
		case .subtract:
			return base.subtracting(hits)
		case .toggle:
			var next = base
			for url in hits {
				if next.contains(url) {
					next.remove(url)
				} else {
					next.insert(url)
				}
			}
			return next
		}
	}

	static func marqueeSelectionMode(for flags: NSEvent.ModifierFlags) -> MarqueeSelectionMode {
		if flags.contains(.command) { return .toggle }
		if flags.contains(.option) { return .subtract }
		if flags.contains(.shift) { return .add }
		return .replace
	}

	static func thumbnailURL(at point: CGPoint, thumbnailFrames: [URL: CGRect]) -> URL? {
		for (url, frame) in thumbnailFrames where frame.contains(point) {
			return url
		}
		return nil
	}
}

final class ThumbnailDraggingSource: NSObject, NSDraggingSource {
	func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
		.copy
	}
}

func isTextEditingFirstResponder(_ responder: NSResponder?) -> Bool {
	var current = responder
	while let candidate = current {
		if candidate is NSTextView || candidate is NSTextField || candidate is NSSearchField {
			return true
		}
		current = candidate.nextResponder
	}
	return false
}
