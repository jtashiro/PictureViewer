//
//  Notifications.swift
//  PictureViewer
//

import Foundation

extension Notification.Name {
	static let embedWriteFailed = Notification.Name("com.example.PictureViewer.embedWriteFailed")
	static let galleryTabSyncImported = Notification.Name("com.example.PictureViewer.galleryTabSyncImported")
	static let sqliteObjectStoreDidChange = Notification.Name("com.example.PictureViewer.sqliteObjectStoreDidChange")
}
