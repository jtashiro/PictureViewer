//
//  PhotoGridCell.swift
//  PictureViewer
//

import SwiftUI
import AppKit

struct PhotoGridCell: View {
	let url: URL
	let size: CGFloat
	let refreshToken: UUID
	let metadataRefreshToken: UUID
	let forceLoad: Bool
	let isSelected: Bool
	let selectionMode: Bool
	let contextActionURLs: () -> [URL]
	let onSingleClick: () -> Void
	let onDoubleClick: () -> Void
	let onCopyFiles: ([URL]) -> Void
	let onEditKeywords: () -> Void
	let onRepairMetadata: () -> Void
	let onRecognizeWithOllama: () -> Void

	var body: some View {
		ZStack(alignment: .topTrailing) {
			VStack(spacing: 4) {
				ThumbnailView(
					url: url,
					size: size,
					refreshToken: refreshToken,
					metadataRefreshToken: metadataRefreshToken,
					forceLoad: forceLoad
				)
			}
			.overlay {
				RoundedRectangle(cornerRadius: 8)
					.stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
			}
			if selectionMode {
				Group {
					if isSelected {
						Image(systemName: "checkmark.circle.fill")
							.foregroundStyle(.white, .blue)
							.background(Circle().fill(Color.blue))
					} else {
						Image(systemName: "circle")
							.foregroundStyle(.secondary)
					}
				}
				.padding(6)
			}
		}
		.id(url)
		.background {
			GeometryReader { proxy in
				Color.clear
					.preference(key: ThumbnailFramePreferenceKey.self, value: [url: proxy.frame(in: .named("photoGridArea"))])
			}
		}
		.contentShape(Rectangle())
		.onTapGesture(perform: onSingleClick)
		.onTapGesture(count: 2, perform: onDoubleClick)
		.contextMenu {
			let contextURLs = contextActionURLs()
			Button(contextURLs.count > 1 ? "Show Selected in Finder" : "Show in Finder") {
				NSWorkspace.shared.activateFileViewerSelecting(contextURLs)
			}
			Button(contextURLs.count > 1 ? "Open Selected with Default App" : "Open with Default App") {
				for url in contextURLs { NSWorkspace.shared.open(url) }
			}
			Button(contextURLs.count > 1 ? "Copy Selected Files" : "Copy File") {
				onCopyFiles(contextURLs)
			}
			Divider()
			Button(contextURLs.count > 1 ? "Edit Keywords for Selected" : "Edit Keywords", action: onEditKeywords)
			Button("Repair metadata", action: onRepairMetadata)
			Divider()
			Button(contextURLs.count > 1 ? "Recognize Selected with Ollama" : "Recognize with Ollama", action: onRecognizeWithOllama)
		}
	}
}
