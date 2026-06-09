//
//  OllamaPromptHistory.swift
//  PictureViewer
//

import Foundation
import Combine
import SwiftUI

/// Persists the user's recent Ollama recognition prompts so they can be
/// re-selected from the Recognize Images dialog. Backed by UserDefaults via
/// a JSON-encoded `[String]`. Most recent first, capped at `maxSize`.
@MainActor
final class OllamaPromptHistory: ObservableObject {
	static let shared = OllamaPromptHistory()

	@Published private(set) var prompts: [String] = []

	private static let defaultsKey = "ollamaPromptHistory"
	private static let maxSize = 20

	private init() {
		load()
	}

	/// Records `prompt` as the most-recently-used entry. If it already exists
	/// in the history, it is moved to the front (not duplicated). Empty or
	/// whitespace-only prompts are ignored.
	func record(_ prompt: String) {
		let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		if let existing = prompts.firstIndex(of: trimmed) {
			prompts.remove(at: existing)
		}
		prompts.insert(trimmed, at: 0)
		if prompts.count > Self.maxSize {
			prompts.removeLast(prompts.count - Self.maxSize)
		}
		save()
	}

	func remove(_ prompt: String) {
		prompts.removeAll { $0 == prompt }
		save()
	}

	func clear() {
		prompts.removeAll()
		save()
	}

	private func load() {
		guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
			  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
			return
		}
		prompts = decoded
	}

	private func save() {
		if let data = try? JSONEncoder().encode(prompts) {
			UserDefaults.standard.set(data, forKey: Self.defaultsKey)
		}
	}
}
