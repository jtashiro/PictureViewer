//
//  ContentViewSupport.swift
//  PictureViewer
//

import SwiftUI
import AppKit

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
