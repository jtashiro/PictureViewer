//
//  OllamaPromptSheet.swift
//  PictureViewer
//

import SwiftUI

struct OllamaPromptSheet: View {
	let imageCount: Int
	let modelName: String
	@Binding var prompt: String
	@Binding var updateMetadata: Bool
	let onCancel: () -> Void
	let onRun: () -> Void

	@ObservedObject private var history = OllamaPromptHistory.shared

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("Recognize Images with Ollama")
				.font(.headline)

			Text("This prompt will be sent to \(modelName) together with each of the \(imageCount) displayed image\(imageCount == 1 ? "" : "s"). Use it to provide context (e.g. \"These are wedding photos from 2023. Describe each image and name visible people if you can.\"). Change the model in Settings → Ollama.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			HStack {
				Spacer()
				Menu {
					if history.prompts.isEmpty {
						Text("No prior prompts")
					} else {
						ForEach(history.prompts, id: \.self) { item in
							Menu(menuLabel(for: item)) {
								Button("Use this prompt") { prompt = item }
								Button("Delete", role: .destructive) { history.remove(item) }
							}
						}
						Divider()
						Button("Clear History", role: .destructive) { history.clear() }
					}
				} label: {
					Label("Recent…", systemImage: "clock.arrow.circlepath")
				}
				.menuStyle(.borderlessButton)
				.fixedSize()
				.disabled(history.prompts.isEmpty)
			}

			TextEditor(text: $prompt)
				.font(.body)
				.frame(minHeight: 126)
				.overlay {
					RoundedRectangle(cornerRadius: 6)
						.stroke(Color.secondary.opacity(0.3), lineWidth: 1)
				}

			Toggle("Update image metadata (keywords) with recognition result", isOn: $updateMetadata)
				.help("When enabled, each recognition result is appended to the image's IPTC Keywords. Existing entries are preserved and duplicates are skipped.")

			HStack {
				Button("Reset to Default") {
					prompt = OllamaRecognizer.defaultPrompt
				}
				Spacer()
				Button("Cancel", action: onCancel)
					.keyboardShortcut(.cancelAction)
				Button("Recognize") {
					history.record(prompt)
					onRun()
				}
				.keyboardShortcut(.defaultAction)
				.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			}
		}
		.padding()
		.frame(width: 480)
	}

	private func menuLabel(for prompt: String) -> String {
		let collapsed = prompt
			.replacingOccurrences(of: "\n", with: " ")
			.replacingOccurrences(of: "\r", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		if collapsed.count <= 70 { return collapsed }
		return String(collapsed.prefix(70)) + "…"
	}
}
