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
