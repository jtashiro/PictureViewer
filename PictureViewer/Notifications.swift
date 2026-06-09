//
//  Notifications.swift
//  PictureViewer
//

import Foundation

extension Notification.Name {
	nonisolated static let embedWriteFailed = Notification.Name("com.example.PictureViewer.embedWriteFailed")
	nonisolated static let galleryTabSyncImported = Notification.Name("com.example.PictureViewer.galleryTabSyncImported")
	nonisolated static let sqliteObjectStoreDidChange = Notification.Name("com.example.PictureViewer.sqliteObjectStoreDidChange")
	nonisolated static let fileNavigationMenuShouldReload = Notification.Name("com.example.PictureViewer.fileNavigationMenuShouldReload")
}
