//
//  PhotoGridCell.swift
//  PictureViewer
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
				.disabled(!contextURLs.contains(where: Self.isOllamaRecognitionEligible))
		}
	}

	private nonisolated static func isOllamaRecognitionEligible(_ url: URL) -> Bool {
		let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
		if PhotoLibrary.isVideoMediaFile(url, contentType: contentType) {
			return SQLiteObjectStore.isWorkingCopyURL(url)
		}
		return true
	}
}

struct PhotoGridSectionHeader: View {
	let section: PhotoGridSection
	let isCollapsed: Bool
	let onToggle: () -> Void

	var body: some View {
		Button {
			withAnimation(.easeInOut(duration: 0.2)) {
				onToggle()
			}
		} label: {
			HStack(spacing: 8) {
				Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
					.frame(width: 12)
				Text(section.title)
					.font(.headline)
					.foregroundStyle(.primary)
				Text("\(section.photos.count)")
					.font(.caption)
					.foregroundStyle(.secondary)
					.monospacedDigit()
				Spacer()
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(isCollapsed ? "Expand section" : "Collapse section")
	}
}

struct PhotoGridCellsView: View {
	let photos: [PhotoItem]
	let thumbnailSize: CGFloat
	let refreshToken: UUID
	let metadataRefreshTokens: [URL: UUID]
	let forceThumbnailLoading: Bool
	let selectionMode: Bool
	let isPhotoSelected: (URL) -> Bool
	let contextActionURLs: (URL) -> [URL]
	let onSingleClick: (URL) -> Void
	let onDoubleClick: (URL) -> Void
	let onCopyFiles: ([URL]) -> Void
	let onEditKeywords: (URL) -> Void
	let onRepairMetadata: (URL) -> Void
	let onRecognizeWithOllama: (URL) -> Void

	var body: some View {
		LazyVGrid(
			columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize * 1.4), spacing: 10)],
			spacing: 10
		) {
			ForEach(photos) { photo in
				PhotoGridCell(
					url: photo.url,
					size: thumbnailSize,
					refreshToken: refreshToken,
					metadataRefreshToken: metadataRefreshTokens[photo.url] ?? refreshToken,
					forceLoad: forceThumbnailLoading,
					isSelected: isPhotoSelected(photo.url),
					selectionMode: selectionMode,
					contextActionURLs: { contextActionURLs(photo.url) },
					onSingleClick: { onSingleClick(photo.url) },
					onDoubleClick: { onDoubleClick(photo.url) },
					onCopyFiles: onCopyFiles,
					onEditKeywords: { onEditKeywords(photo.url) },
					onRepairMetadata: { onRepairMetadata(photo.url) },
					onRecognizeWithOllama: { onRecognizeWithOllama(photo.url) }
				)
			}
		}
	}
}
