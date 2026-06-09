//
//  VaultCommands.swift
//  PictureViewer
//

import SwiftUI

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
	let openSQLiteStore: () -> Void
	let copy: () -> Void
	let paste: () -> Void
	let selectAll: () -> Void
	let recognizeDisplayed: () -> Void
	let canCloseVault: Bool
	let canRenameVault: Bool
	let canImportSelected: Bool
	let canExport: Bool
	let canSyncToTab: Bool
	let canSyncToSQLiteStore: Bool
	let canSyncSelectedToSQLiteStore: Bool
	let canOpenSQLiteStore: Bool
	let canCopy: Bool
	let canPaste: Bool
	let canSelectAll: Bool
	let canRecognize: Bool
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
