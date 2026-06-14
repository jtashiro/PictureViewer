//
//  Notifications.swift
//  PictureViewer
//

import Foundation

extension Notification.Name {
	nonisolated static let embedWriteFailed = Notification.Name("com.example.PictureViewer.embedWriteFailed")
	nonisolated static let galleryTabSyncImported = Notification.Name("com.example.PictureViewer.galleryTabSyncImported")
	nonisolated static let sqliteObjectStoreDidChange = Notification.Name("com.example.PictureViewer.sqliteObjectStoreDidChange")
	nonisolated static let sqliteSyncWillBegin = Notification.Name("com.example.PictureViewer.sqliteSyncWillBegin")
	nonisolated static let fileNavigationMenuShouldReload = Notification.Name("com.example.PictureViewer.fileNavigationMenuShouldReload")
}

struct EmbedWriteFailure: Sendable {
	let url: URL
	let operation: String
	let message: String

	private enum Key {
		nonisolated static let url = "url"
		nonisolated static let operation = "op"
		nonisolated static let message = "message"
	}

	nonisolated init(url: URL, operation: String, message: String) {
		self.url = url
		self.operation = operation
		self.message = message
	}

	nonisolated init?(notification: Notification) {
		if let failure = notification.object as? EmbedWriteFailure {
			self = failure
			return
		}
		guard let userInfo = notification.userInfo,
			  let path = userInfo[Key.url] as? String,
			  let operation = userInfo[Key.operation] as? String,
			  let message = userInfo[Key.message] as? String else {
			return nil
		}
		self.init(url: URL(fileURLWithPath: path), operation: operation, message: message)
	}

	nonisolated func post(using center: NotificationCenter = .default) {
		center.post(
			name: .embedWriteFailed,
			object: self,
			userInfo: [
				Key.url: url.path,
				Key.operation: operation,
				Key.message: message
			]
		)
	}
}
