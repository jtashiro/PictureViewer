//
//  EmptyFolderView.swift
//  PictureViewer
//

import SwiftUI

struct EmptyFolderView: View {
	let chooseFolder: () -> Void

	var body: some View {
		ContentUnavailableView {
			Label("No Folder Selected", systemImage: "folder.badge.questionmark")
		} description: {
			Text("Pick a folder to recursively browse photos.")
		} actions: {
			Button("Choose Folder…") { chooseFolder() }
				.buttonStyle(.borderedProminent)
		}
	}
}
