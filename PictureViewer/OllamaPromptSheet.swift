//
//  OllamaPromptSheet.swift
//  PictureViewer
//

import SwiftUI

struct OllamaPromptSheet: View {
	let imageCount: Int
	let modelName: String
	@Binding var prompt: String
	let onCancel: () -> Void
	let onRun: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("Recognize Images with Ollama")
				.font(.headline)

			Text("This prompt will be sent to \(modelName) together with each of the \(imageCount) displayed image\(imageCount == 1 ? "" : "s"). Use it to provide context (e.g. \"These are wedding photos from 2023. Describe each image and name visible people if you can.\"). Change the model in Settings → Ollama.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			TextEditor(text: $prompt)
				.font(.body)
				.frame(minHeight: 120)
				.overlay {
					RoundedRectangle(cornerRadius: 6)
						.stroke(Color.secondary.opacity(0.3), lineWidth: 1)
				}

			HStack {
				Button("Reset to Default") {
					prompt = OllamaRecognizer.defaultPrompt
				}
				Spacer()
				Button("Cancel", action: onCancel)
					.keyboardShortcut(.cancelAction)
				Button("Recognize", action: onRun)
					.keyboardShortcut(.defaultAction)
					.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			}
		}
		.padding()
		.frame(width: 480)
	}
}
