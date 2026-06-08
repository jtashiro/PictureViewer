//
//  GalleryTabRegistry.swift
//  PictureViewer
//

import Foundation

struct GalleryTabSnapshot: Identifiable, Hashable {
	let id: UUID
	let title: String
	let folderURL: URL?
	let sqliteStoreName: String?
	let isVault: Bool
	let photoURLs: [URL]
}

struct VaultImportOptions {
	let ignoreDuplicates: Bool
	let keywords: [String]
}

@MainActor
final class GalleryTabRegistry {
	static let shared = GalleryTabRegistry()

	private var snapshots: [UUID: GalleryTabSnapshot] = [:]

	func update(_ snapshot: GalleryTabSnapshot) {
		snapshots[snapshot.id] = snapshot
	}

	func remove(id: UUID) {
		snapshots.removeValue(forKey: id)
	}

	func targets(excluding id: UUID) -> [GalleryTabSnapshot] {
		snapshots.values
			.filter { $0.id != id && $0.folderURL != nil }
			.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
	}

	func sqliteTargets(excluding id: UUID) -> [GalleryTabSnapshot] {
		snapshots.values
			.filter { $0.id != id && $0.sqliteStoreName != nil }
			.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
	}

	func containsBookmarkName(_ name: String, excluding id: UUID? = nil) -> Bool {
		let key = Self.normalizedBookmarkName(name)
		guard !key.isEmpty else { return false }
		return snapshots.values.contains { snapshot in
			if let id, snapshot.id == id { return false }
			let snapshotName = snapshot.folderURL?.lastPathComponent ?? snapshot.title
			return Self.normalizedBookmarkName(snapshotName) == key
		}
	}

	private static func normalizedBookmarkName(_ name: String) -> String {
		name
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
	}
}
