//
//  PhotoDetailView.swift
//  PictureViewer
//

import SwiftUI
import AppKit
import os

struct FullScreenPhotoView: View {
    let url: URL

    @AppStorage("photoDisplayMode") private var displayMode: PhotoDisplayMode = .fullScreen

    @State private var image: NSImage?
    @State private var loadFailed = false
    @State private var rotationDegrees: Int = 0
    @State private var isSavingRotation: Bool = false
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
        .onTapGesture {
            if displayMode == .fullScreen {
                dismiss()
            }
        }
        .task(id: url) {
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
                    Button(action: { Task { await saveRotation() } }) {
                        if isSavingRotation {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .help("Save rotation to file")
                    .disabled(isSavingRotation || rotationDegrees % 360 == 0 || image == nil)
                }
            }
        }
        .onAppear {
            WindowStateStore.shared.recordOpenPhoto(url)
        }
        .onDisappear {
            // If the user rotated but didn't explicitly save, persist the
            // rotation automatically when the window closes.
            if rotationDegrees % 360 != 0 {
                Task.detached(priority: .utility) {
                    _ = await saveRotation()
                }
            }
            WindowStateStore.shared.recordClosedPhoto(url)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window, !didConfigureWindow else { return }
        didConfigureWindow = true
        window.title = url.lastPathComponent
        // Record the represented URL on the NSWindow so global window
        // snapshotting can discover open photo windows even when their
        // SwiftUI views aren't currently 'appeared' (for example when a
        // photo is open in a background tab). This makes session
        // persistence more robust.
        window.representedURL = url
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
        let target = url
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

    /// Save the current rotation by rewriting the image pixels to a new file
    /// with the rotation applied. This is a best-effort operation and will
    /// replace the original file (with a temporary backup) on success.
    private func saveRotation() async {
        guard rotationDegrees % 360 != 0 else { return }
        guard let nsImg = image else { return }
        isSavingRotation = true
        defer { isSavingRotation = false }

        let degrees = rotationDegrees
        let success = await Task.detached(priority: .utility) {
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
            guard let cgImage = loadCG else { return false }

            let radians = Double(degrees) * Double.pi / 180.0
            let absDeg = (degrees % 360 + 360) % 360
            var destWidth = cgImage.width
            var destHeight = cgImage.height
            if absDeg == 90 || absDeg == 270 {
                destWidth = cgImage.height
                destHeight = cgImage.width
            }

            guard let colorSpace = cgImage.colorSpace else { return false }
            guard let ctx = CGContext(data: nil, width: destWidth, height: destHeight, bitsPerComponent: cgImage.bitsPerComponent, bytesPerRow: 0, space: colorSpace, bitmapInfo: cgImage.bitmapInfo.rawValue) else { return false }

            // Apply transform: translate to center, rotate, draw
            ctx.translateBy(x: CGFloat(destWidth)/2.0, y: CGFloat(destHeight)/2.0)
            ctx.rotate(by: CGFloat(radians))
            ctx.translateBy(x: -CGFloat(cgImage.width)/2.0, y: -CGFloat(cgImage.height)/2.0)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))

            guard let rotated = ctx.makeImage() else { return false }

            // Preserve metadata if possible
            let fm = FileManager.default
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else { return false }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]

            // Ensure we have security-scoped access for the folder containing the file
            _ = await ContentView.ensureSecurityScopedAccess(for: url)

            // Write to temp file next to original to avoid cross-volume rename issues
            let tempURL = url.deletingLastPathComponent().appendingPathComponent(".pvtmp-\(UUID().uuidString)").appendingPathExtension(url.pathExtension)
            guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, type, 1, nil) else {
                let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
                logger.error("photo-detail: cannot create CGImageDestination for tempURL=\(tempURL.path, privacy: .public) type=\(String(describing: type), privacy: .public)")
                NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "photoDetailSave", "message": "CGImageDestinationCreateWithURL failed when attempting to save rotated image."])
                // Per policy, do not write sidecars; report failure.
                return false
            }
            if let metadata = props as CFDictionary? {
                CGImageDestinationAddImage(dest, rotated, metadata)
            } else {
                CGImageDestinationAddImage(dest, rotated, nil)
            }
            if !CGImageDestinationFinalize(dest) {
                try? fm.removeItem(at: tempURL)
                let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
                logger.error("photo-detail: CGImageDestinationFinalize failed for tempURL=\(tempURL.path, privacy: .public)")
                NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "photoDetailSave", "message": "CGImageDestinationFinalize failed when attempting to save rotated image."])
                // Do not write sidecar; surface failure.
                return false
            }

            do {
                let backupURL = url.appendingPathExtension("backup")
                if fm.fileExists(atPath: backupURL.path) { try? fm.removeItem(at: backupURL) }
                try fm.moveItem(at: url, to: backupURL)
                try fm.moveItem(at: tempURL, to: url)
                try? fm.removeItem(at: backupURL)
                return true
            } catch {
                try? fm.removeItem(at: tempURL)
                return false
            }
        }.value

        if success {
            // Reload image from disk to reflect any format changes
            await loadImage()
            // Reset rotation (already baked into file)
            rotationDegrees = 0
        } else {
            // Pixel rewrite failed (e.g. due to permissions). Per policy, do
            // not write a sidecar — log and surface failure.
            let logger = Logger(subsystem: "com.example.PictureViewer", category: "metadata")
            logger.error("photo-detail: saveRotation failed for \(url.path, privacy: .public)")
            NotificationCenter.default.post(name: .embedWriteFailed, object: nil, userInfo: ["url": url.path, "op": "photoDetailSave", "message": "Failed to save rotated image (pixel rewrite failed or permission error). "])
        }
    }
}
