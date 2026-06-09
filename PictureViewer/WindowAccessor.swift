import SwiftUI
import AppKit
import ObjectiveC

private var WindowAccessorObserverKey: UInt8 = 0

/// Small helper to obtain the underlying `NSWindow` for a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            let win = view.window
            callback(win)
            // Install a termination/close observer for this window so we
            // can snapshot open tabs when the window (or a tab group)
            // closes. Store the observer token on the view so it lives as
            // long as the view.
            if let win {
                // Avoid installing multiple observers for the same view.
                if objc_getAssociatedObject(view, &WindowAccessorObserverKey) == nil {
                    let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { _ in
                        MainActor.assumeIsolated {
                            WindowStateStore.shared.snapshotTabs(of: win)
                        }
                    }
                    objc_setAssociatedObject(view, &WindowAccessorObserverKey, token, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
