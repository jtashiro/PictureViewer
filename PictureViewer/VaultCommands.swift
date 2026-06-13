//
//  VaultCommands.swift
//  PictureViewer
//

import SwiftUI

struct FileNavigationCommandActions {
	let openFolder: (URL) -> Void
	let openSQLiteStore: (String) -> Void
	let openPhoto: (URL) -> Void
	let restoreSavedGallerySession: () -> Void
	let showBookmarkManager: () -> Void
}

private struct FileNavigationCommandActionsKey: FocusedValueKey {
	typealias Value = FileNavigationCommandActions
}

extension FocusedValues {
	var fileNavigationActions: FileNavigationCommandActions? {
		get { self[FileNavigationCommandActionsKey.self] }
		set { self[FileNavigationCommandActionsKey.self] = newValue }
	}
}

struct VaultCommandActions {
	let newItem: () -> Void
	let openItem: () -> Void
	let newVault: () -> Void
	let importFolders: () -> Void
	let importSelected: () -> Void
	let chooseAndOpenVault: () -> Void
	let openVault: () -> Void
	let closeVault: () -> Void
	let renameVault: () -> Void
	let manageVaults: () -> Void
	let exportPhotos: () -> Void
	let syncToTab: () -> Void
	let syncToSQLiteStore: () -> Void
	let syncSelectedToSQLiteStore: () -> Void
	let backfillSQLiteThumbnails: () -> Void
	let openSQLiteStore: () -> Void
	let copy: () -> Void
	let paste: () -> Void
	let selectAll: () -> Void
	let recognizeDisplayed: () -> Void
	let recognizeSelected: () -> Void
	let canCloseVault: Bool
	let canRenameVault: Bool
	let canImportSelected: Bool
	let canExport: Bool
	let canSyncToTab: Bool
	let canSyncToSQLiteStore: Bool
	let canSyncSelectedToSQLiteStore: Bool
	let canBackfillSQLiteThumbnails: Bool
	let canOpenSQLiteStore: Bool
	let canCopy: Bool
	let canPaste: Bool
	let canSelectAll: Bool
	let canRecognize: Bool
	let canRecognizeSelected: Bool
}

private struct VaultCommandActionsKey: FocusedValueKey {
	typealias Value = VaultCommandActions
}

extension FocusedValues {
	var vaultCommandActions: VaultCommandActions? {
		get { self[VaultCommandActionsKey.self] }
		set { self[VaultCommandActionsKey.self] = newValue }
	}
}
