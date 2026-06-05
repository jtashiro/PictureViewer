import SwiftUI
import AppKit

private struct RepresentativeImageView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var isLoading = false
    
    init(url: URL) {
        self.url = url
    }
    
    var body: some View {
        Group {
            if let image, !isLoading {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
                    .frame(width: 120, height: 120)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
            }
        }
        .frame(width: 120, height: 120)
        .clipped()
        .cornerRadius(8)
        .task(id: url) {
            guard !Task.isCancelled else { return }
            
            isLoading = true
            
            // Load image off the main thread
            let loaded = await Task.detached(priority: .background) {
                NSImage(contentsOf: url)
            }.value

            if Task.isCancelled { return }

            // Handle loading errors gracefully
            guard let loaded, loaded.isValid else {
                isLoading = false
                return
            }

            image = loaded
            isLoading = false
        }
    }
}

// Optional: Simple cache for loaded images (can be moved to a global scope)
private var imageCache = [URL: NSImage]()
