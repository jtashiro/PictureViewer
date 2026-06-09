//
//  StatusBarView.swift
//  PictureViewer
//

import SwiftUI
import UniformTypeIdentifiers

struct StatusBarView: View {
	@ObservedObject var library: PhotoLibrary
	let isRefreshing: Bool
	let isSQLiteObjectStoreView: Bool
	let isVaultWorking: Bool
	let vaultProgressMessage: String
	let vaultProgressTotal: Int
	let vaultProgressCompleted: Int
	let sqliteLoadStartDate: Date?
	let sqliteLastLoadDuration: TimeInterval?
	let sqliteLastThumbnailLoadDuration: TimeInterval?
	let lastRefreshDate: Date?
	let lastRefreshDuration: TimeInterval?
	let onRefreshThumbnails: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			statusIcon
			statusText
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer(minLength: 8)
			Button(action: onRefreshThumbnails) {
				Label("Refresh Thumbnails", systemImage: "arrow.clockwise")
			}
			.controlSize(.small)
			.help("Clear cached thumbnails and regenerate them")
			.disabled(library.photos.isEmpty || isRefreshing)
		}
		.font(.caption)
		.padding(.horizontal, 10)
		.padding(.vertical, 4)
		.background(.bar)
	}

	@ViewBuilder
	private var statusIcon: some View {
		if library.isScanning || isRefreshing || (isSQLiteObjectStoreView && isVaultWorking) {
			ProgressView().controlSize(.mini)
		} else if library.lastScanDate != nil {
			Image(systemName: "photo.stack").foregroundStyle(.secondary)
		} else {
			Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary)
		}
	}

	@ViewBuilder
	private var statusText: some View {
		if library.isScanning {
			HStack(spacing: 6) {
				Text("Scanning \(library.folderURL?.lastPathComponent ?? "")…")
				StatusBarBullet()
				Text("\(Self.mediaStatusSummary(for: library.photos)) found")
					.foregroundStyle(.secondary)
				if let start = library.scanStartDate {
					StatusBarBullet()
					TimelineView(.periodic(from: start, by: 0.5)) { context in
						Text("elapsed \(Self.formatDuration(context.date.timeIntervalSince(start)))")
							.foregroundStyle(.secondary)
							.monospacedDigit()
					}
				}
			}
		} else if isRefreshing {
			Text("Refreshing thumbnails…").foregroundStyle(.secondary)
		} else if isSQLiteObjectStoreView {
			HStack(spacing: 6) {
				Text("\(Self.mediaStatusSummary(for: library.photos)) in SQLite store")
					.foregroundStyle(.secondary)
				if isVaultWorking {
					StatusBarBullet()
					Text(vaultProgressMessage.isEmpty ? "Opening SQLite store..." : vaultProgressMessage)
						.foregroundStyle(.secondary)
					if vaultProgressTotal > 0 {
						StatusBarBullet()
						Text("\(vaultProgressCompleted) of \(vaultProgressTotal)")
							.foregroundStyle(.secondary)
							.monospacedDigit()
					}
					if let sqliteLoadStartDate {
						StatusBarBullet()
						TimelineView(.periodic(from: sqliteLoadStartDate, by: 0.5)) { context in
							Text("elapsed \(Self.formatDuration(context.date.timeIntervalSince(sqliteLoadStartDate)))")
								.foregroundStyle(.secondary)
								.monospacedDigit()
						}
					}
				} else if let sqliteLastLoadDuration {
					StatusBarBullet()
					Text("loaded in \(Self.formatDuration(sqliteLastLoadDuration))")
						.foregroundStyle(.secondary)
						.monospacedDigit()
					if let sqliteLastThumbnailLoadDuration {
						StatusBarBullet()
						Text("thumbnails in \(Self.formatDuration(sqliteLastThumbnailLoadDuration))")
							.foregroundStyle(.secondary)
							.monospacedDigit()
					}
				}
			}
		} else if let date = library.lastScanDate {
			HStack(spacing: 6) {
				Text(Self.mediaStatusSummary(for: library.photos))
				StatusBarBullet()
				Text("scanned \(date.formatted(date: .abbreviated, time: .shortened))")
					.foregroundStyle(.secondary)
				if let dur = library.lastScanDuration {
					Text("in \(Self.formatDuration(dur))")
						.foregroundStyle(.secondary)
						.monospacedDigit()
				}
				if let rDate = lastRefreshDate, let rDur = lastRefreshDuration {
					StatusBarBullet()
					Text("thumbnails refreshed \(rDate.formatted(date: .omitted, time: .shortened)) in \(Self.formatDuration(rDur))")
						.foregroundStyle(.secondary)
						.monospacedDigit()
				}
			}
		} else {
			Text("No folder scanned yet").foregroundStyle(.secondary)
		}
	}

	static func mediaStatusSummary(for items: [PhotoItem]) -> String {
		let videoCount = items.reduce(into: 0) { count, item in
			let contentType = try? item.url.resourceValues(forKeys: [.contentTypeKey]).contentType
			if PhotoLibrary.isVideoMediaFile(item.url, contentType: contentType) {
				count += 1
			}
		}
		let totalCount = items.count
		let photoCount = max(0, totalCount - videoCount)
		let totalLabel = totalCount.formatted()
		let photoLabel = "\(photoCount.formatted()) photo\(photoCount == 1 ? "" : "s")"
		let videoLabel = "\(videoCount.formatted()) video\(videoCount == 1 ? "" : "s")"
		return "\(totalLabel) (\(photoLabel), \(videoLabel))"
	}

	static func formatDuration(_ duration: TimeInterval) -> String {
		if duration < 1 {
			return String(format: "%.0f ms", duration * 1000)
		} else if duration < 60 {
			return String(format: "%.1f s", duration)
		} else {
			let total = Int(duration)
			return "\(total / 60)m \(total % 60)s"
		}
	}
}

private struct StatusBarBullet: View {
	var body: some View {
		Text("·").foregroundStyle(.tertiary)
	}
}
