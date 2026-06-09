//
//  OllamaProgress.swift
//  PictureViewer
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class OllamaProgress: ObservableObject {
	static let shared = OllamaProgress()

	@Published var isActive: Bool = false
	@Published var model: String = ""
	@Published var completed: Int = 0
	@Published var total: Int = 0
	@Published var currentFilename: String = ""
	@Published var isCancelling: Bool = false
	/// URL of the most recently recognized image whose metadata has been
	/// updated. Observers (e.g. ContentView) react to changes here to refresh
	/// the grid cell for that URL.
	@Published var lastCompletedURL: URL? = nil

	private var cancelHook: (@Sendable () -> Void)?

	private init() {}

	func begin(total: Int, model: String, cancel: @escaping @Sendable () -> Void) {
		self.model = model
		self.total = max(0, total)
		self.completed = 0
		self.currentFilename = ""
		self.lastCompletedURL = nil
		self.isCancelling = false
		self.cancelHook = cancel
		self.isActive = true
	}

	func update(completed: Int, currentFilename: String) {
		self.completed = max(0, completed)
		self.currentFilename = currentFilename
	}

	func markMetadataUpdated(for url: URL) {
		// Always assign a fresh value (even if same URL) so .onChange fires
		// when the same image is reprocessed in a future run.
		lastCompletedURL = url
	}

	func cancel() {
		guard isActive, !isCancelling else { return }
		isCancelling = true
		cancelHook?()
	}

	func end() {
		isActive = false
		isCancelling = false
		cancelHook = nil
		completed = 0
		total = 0
		currentFilename = ""
		model = ""
		lastCompletedURL = nil
	}

	var fraction: Double {
		guard total > 0 else { return 0 }
		return min(1, max(0, Double(completed) / Double(total)))
	}
}
