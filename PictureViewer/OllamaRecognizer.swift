//
//  OllamaRecognizer.swift
//  PictureViewer
//

import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import os

/// Drives Ollama vision-model recognition for image files and logs the result
/// as a single line per image via `os.Logger`. Sequential by design — vision
/// models are GPU-bound and parallel requests on a local Ollama server tend to
/// starve resources.
actor OllamaRecognizer {
	static let shared = OllamaRecognizer()

	private static let baseURL = URL(string: "http://localhost:11434")!
	static let defaultModel = "llava"
	static let defaultPrompt = "Describe this image in one sentence."
	private static let maxEdgePixels: CGFloat = 1024
	private static let requestTimeout: TimeInterval = 120
	private static let discoveryTimeout: TimeInterval = 15

	/// Known vision-capable model name prefixes used as a fallback when
	/// `/api/show` doesn't return a `capabilities` array (older Ollama).
	private static let knownVisionPrefixes: [String] = [
		"llava", "bakllava", "moondream", "llama3.2-vision", "llama4",
		"minicpm-v", "qwen2-vl", "qwen2.5vl", "qwen2.5-vl", "pixtral",
		"granite3.2-vision", "mistral-small3.2"
	]

	private let logger = Logger(subsystem: "com.example.PictureViewer", category: "ollama")

	private struct GenerateRequest: Encodable {
		let model: String
		let prompt: String
		let images: [String]
		let stream: Bool
	}

	private struct GenerateResponse: Decodable {
		let response: String?
		let error: String?
	}

	private struct TagsResponse: Decodable {
		struct Entry: Decodable { let name: String }
		let models: [Entry]
	}

	private struct ShowRequest: Encodable {
		let name: String
	}

	private struct ShowResponse: Decodable {
		let capabilities: [String]?
	}

	/// Sends `url` to Ollama and returns the recognition text, or throws.
	/// The caller is responsible for skipping non-image files; this method
	/// will throw if the URL can't be decoded as an image.
	func recognize(imageURL url: URL, prompt: String, model: String) async throws -> String {
		try Task.checkCancellation()
		guard let base64 = Self.encodedImageData(for: url) else {
			throw RecognizerError.imageEncodingFailed
		}
		try Task.checkCancellation()

		let body = GenerateRequest(model: model, prompt: prompt, images: [base64], stream: false)
		var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/generate"))
		request.httpMethod = "POST"
		request.timeoutInterval = Self.requestTimeout
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONEncoder().encode(body)

		let (data, response) = try await URLSession.shared.data(for: request)
		try Task.checkCancellation()
		guard let http = response as? HTTPURLResponse else {
			throw RecognizerError.invalidResponse
		}
		guard (200..<300).contains(http.statusCode) else {
			let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
			throw RecognizerError.httpError(status: http.statusCode, body: String(snippet))
		}

		let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
		if let error = decoded.error, !error.isEmpty {
			throw RecognizerError.ollamaError(error)
		}
		let text = (decoded.response ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.replacingOccurrences(of: "\n", with: " ")
			.replacingOccurrences(of: "\r", with: " ")
		return text
	}

	/// Recognizes a sequence of image URLs sequentially, logging one line per
	/// image. Cancellation cooperatively stops the sequence between items.
	/// Returns the number of successfully recognized items.
	func recognizeAndLog(imageURLs urls: [URL], prompt: String, model: String) async -> Int {
		var success = 0
		let start = Date()
		let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		let effectivePrompt = trimmedPrompt.isEmpty ? Self.defaultPrompt : trimmedPrompt
		let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
		let effectiveModel = trimmedModel.isEmpty ? Self.defaultModel : trimmedModel
		logger.log("ollama:batch start count=\(urls.count, privacy: .public) model=\(effectiveModel, privacy: .public) prompt=\(effectivePrompt, privacy: .public)")
		for (index, url) in urls.enumerated() {
			if Task.isCancelled {
				logger.log("ollama:batch cancelled after=\(index, privacy: .public) of=\(urls.count, privacy: .public)")
				break
			}
			do {
				let text = try await recognize(imageURL: url, prompt: effectivePrompt, model: effectiveModel)
				logger.log("ollama:recognized \(url.lastPathComponent, privacy: .public) — \(text, privacy: .public)")
				success += 1
			} catch is CancellationError {
				logger.log("ollama:batch cancelled at=\(url.lastPathComponent, privacy: .public)")
				break
			} catch {
				logger.error("ollama:failed \(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
			}
		}
		logger.log("ollama:batch end success=\(success, privacy: .public) of=\(urls.count, privacy: .public) duration=\(Date().timeIntervalSince(start), privacy: .public)")
		return success
	}

	/// Queries Ollama for locally-installed models and returns those whose
	/// `/api/show` response advertises `"vision"` in `capabilities`. Falls back
	/// to known vision-model name prefixes when `capabilities` is absent.
	/// Returned models are sorted by name. Throws if Ollama is unreachable.
	func availableVisionModels() async throws -> [String] {
		let allModels = try await fetchAllModelNames()
		guard !allModels.isEmpty else { return [] }
		return try await withThrowingTaskGroup(of: String?.self, returning: [String].self) { group in
			for name in allModels {
				group.addTask {
					(try? await self.modelSupportsVision(name)) == true ? name : nil
				}
			}
			var visionModels: [String] = []
			for try await result in group {
				if let name = result { visionModels.append(name) }
			}
			return visionModels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
		}
	}

	private func fetchAllModelNames() async throws -> [String] {
		var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/tags"))
		request.timeoutInterval = Self.discoveryTimeout
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw RecognizerError.invalidResponse
		}
		guard (200..<300).contains(http.statusCode) else {
			let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
			throw RecognizerError.httpError(status: http.statusCode, body: String(snippet))
		}
		let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
		return decoded.models.map(\.name)
	}

	/// Returns true when Ollama's `/api/show` reports `"vision"` capability for
	/// `model`, or — when capabilities are unavailable — the model name matches
	/// a known vision-capable prefix.
	private func modelSupportsVision(_ model: String) async throws -> Bool {
		var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/show"))
		request.httpMethod = "POST"
		request.timeoutInterval = Self.discoveryTimeout
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONEncoder().encode(ShowRequest(name: model))
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
			return Self.matchesKnownVisionPrefix(model)
		}
		if let decoded = try? JSONDecoder().decode(ShowResponse.self, from: data),
		   let caps = decoded.capabilities {
			return caps.contains("vision")
		}
		return Self.matchesKnownVisionPrefix(model)
	}

	private static func matchesKnownVisionPrefix(_ model: String) -> Bool {
		let base = model.lowercased().split(separator: ":").first.map(String.init) ?? model.lowercased()
		return knownVisionPrefixes.contains { base.hasPrefix($0) }
	}

	/// Loads the image at `url`, downsizes if needed, and returns base64-encoded
	/// JPEG data suitable for Ollama's `images` field. Returns nil if the file
	/// can't be decoded as an image.
	private static func encodedImageData(for url: URL) -> String? {
		_ = url.startAccessingSecurityScopedResource()
		defer { url.stopAccessingSecurityScopedResource() }
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: maxEdgePixels,
			kCGImageSourceShouldCacheImmediately: true
		]
		guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
			return nil
		}
		let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
		guard let jpeg = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
			return nil
		}
		return jpeg.base64EncodedString()
	}

	enum RecognizerError: LocalizedError {
		case imageEncodingFailed
		case invalidResponse
		case httpError(status: Int, body: String)
		case ollamaError(String)

		var errorDescription: String? {
			switch self {
			case .imageEncodingFailed:
				return "Could not decode image for Ollama"
			case .invalidResponse:
				return "Ollama returned a non-HTTP response"
			case .httpError(let status, let body):
				return "Ollama HTTP \(status): \(body)"
			case .ollamaError(let message):
				return "Ollama error: \(message)"
			}
		}
	}
}
