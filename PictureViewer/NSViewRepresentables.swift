//
//  NSViewRepresentables.swift
//  PictureViewer
//

import SwiftUI
import AppKit

struct ScrollViewAccessor: NSViewRepresentable {
	let callback: (NSScrollView?) -> Void

	func makeNSView(context: Context) -> NSView {
		let view = NSView(frame: .zero)
		DispatchQueue.main.async { [weak view] in
			callback(view?.enclosingScrollView)
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		DispatchQueue.main.async {
			callback(nsView.enclosingScrollView)
		}
	}
}

struct SelectAllKeyboardShortcutView: NSViewRepresentable {
	let isEnabled: Bool
	let action: () -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> NSView {
		let view = SelectAllResponderView(frame: .zero)
		context.coordinator.view = view
		context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
			coordinator?.handle(event) ?? event
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		context.coordinator.view = nsView
		context.coordinator.isEnabled = isEnabled
		context.coordinator.action = action
		if let responderView = nsView as? SelectAllResponderView {
			responderView.isSelectAllEnabled = isEnabled
			responderView.selectAllAction = action
			responderView.ensureMenuResponderIfAppropriate()
		}
	}

	final class SelectAllResponderView: NSView, NSUserInterfaceValidations {
		var isSelectAllEnabled = false
		var selectAllAction: (() -> Void)?

		override var acceptsFirstResponder: Bool { true }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			ensureMenuResponderIfAppropriate()
		}

		func ensureMenuResponderIfAppropriate() {
			guard isSelectAllEnabled,
				  let window,
				  window.firstResponder == nil || !isTextEditingFirstResponder(window.firstResponder)
			else { return }
			window.makeFirstResponder(self)
		}

		override func selectAll(_ sender: Any?) {
			guard isSelectAllEnabled,
				  let window,
				  !isTextEditingFirstResponder(window.firstResponder)
			else { return }
			selectAllAction?()
		}

		func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
			if item.action == #selector(selectAll(_:)) {
				return isSelectAllEnabled
			}
			return false
		}

	}

	final class Coordinator: @unchecked Sendable {
		weak var view: NSView?
		var isEnabled = false
		var action: (() -> Void)?
		nonisolated(unsafe) var monitor: Any?

		nonisolated deinit {
			if let monitor {
				NSEvent.removeMonitor(monitor)
			}
		}

		func handle(_ event: NSEvent) -> NSEvent? {
			guard isEnabled,
				let window = view?.window,
				window.isKeyWindow,
				event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
				event.charactersIgnoringModifiers?.lowercased() == "a",
				!isTextEditingFirstResponder(window.firstResponder)
			else {
				return event
			}

			action?()
			return nil
		}
	}
}

struct GridArrowKeyboardShortcutView: NSViewRepresentable {
	let isEnabled: Bool
	let action: (GridNavigationDirection) -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> NSView {
		let view = GridArrowResponderView(frame: .zero)
		context.coordinator.view = view
		context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
			coordinator?.handle(event) ?? event
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		context.coordinator.view = nsView
		context.coordinator.isEnabled = isEnabled
		context.coordinator.action = action
		if let responderView = nsView as? GridArrowResponderView {
			responderView.isGridNavigationEnabled = isEnabled
			responderView.navigationAction = action
			responderView.ensureMenuResponderIfAppropriate()
		}
	}

	final class GridArrowResponderView: NSView {
		var isGridNavigationEnabled = false
		var navigationAction: ((GridNavigationDirection) -> Void)?

		override var acceptsFirstResponder: Bool { true }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			ensureMenuResponderIfAppropriate()
		}

		func ensureMenuResponderIfAppropriate() {
			guard isGridNavigationEnabled, let window else { return }
			if window.firstResponder == nil || isTextEditingFirstResponder(window.firstResponder) {
				return
			}
			if window.firstResponder !== self {
				window.makeFirstResponder(self)
			}
		}

		override func keyDown(with event: NSEvent) {
			guard isGridNavigationEnabled,
				  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
				  let direction = GridNavigationDirection(event: event)
			else {
				super.keyDown(with: event)
				return
			}
			navigationAction?(direction)
		}
	}

	final class Coordinator: @unchecked Sendable {
		weak var view: NSView?
		var isEnabled = false
		var action: ((GridNavigationDirection) -> Void)?
		nonisolated(unsafe) var monitor: Any?

		nonisolated deinit {
			if let monitor {
				NSEvent.removeMonitor(monitor)
			}
		}

		func handle(_ event: NSEvent) -> NSEvent? {
			guard isEnabled,
				  let window = view?.window,
				  window.isKeyWindow,
				  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
				  let direction = GridNavigationDirection(event: event),
				  !isTextEditingFirstResponder(window.firstResponder)
			else {
				return event
			}

			action?(direction)
			return nil
		}
	}
}

enum GridNavigationDirection {
	case left
	case right
	case up
	case down

	init?(event: NSEvent) {
		switch event.keyCode {
		case 123: self = .left
		case 124: self = .right
		case 126: self = .up
		case 125: self = .down
		default: return nil
		}
	}
}
