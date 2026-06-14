//
//  OllamaRecognizer.swift
//  PictureViewer
//

import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import os

/// Drives Ollama vision-model recognition for image and video files and logs the result
/// as a single line per media item via `os.Logger`. Sequential by design — vision
/// models are GPU-bound and parallel requests on a local Ollama server tend to
/// starve resources.
actor OllamaRecognizer {
	static let shared = OllamaRecognizer()

	private static var baseURL: URL {
		get {
			let host = UserDefaults.standard.string(forKey: "ollamaServerHost") ?? "localhost"
			return URL(string: "http://\(host):11434")!
		}
		set {
			// When setting, we store the full URL to maintain backward compatibility
			if let absoluteString = newValue.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
				UserDefaults.standard.set(absoluteString, forKey: "ollamaServerURL")
			}
			// Also store just the host for our new setting
			let components = URLComponents(url: newValue, resolvingAgainstBaseURL: false)
			if let host = components?.host {
				UserDefaults.standard.set(host, forKey: "ollamaServerHost")
			}
		}
	}
	
	/// Default context size used when the user hasn't opened Settings yet.
	/// Vision models OOM on the server-config maximum (e.g. 131070) on Macs
	/// with limited unified memory — a conservative 4096 fits a typical
	/// image+prompt+short response without thrashing.
	static let defaultNumCtx = 4096

	/// On truncation, the batch recognizer retries with num_ctx × 1.5, up to
	/// `maxTruncationRetries` extra attempts. Hard-capped at `maxRetryNumCtx`
	/// so growth can't blow past the OOM threshold the user already hit.
	private static let truncationRetryGrowthFactor: Double = 1.5
	private static let maxTruncationRetries = 3
	private static let maxRetryNumCtx = 32768

	private static var numCtx: Int {
		get {
			// `integer(forKey:)` returns 0 when the key is missing — fall back to
			// the same default the SettingsView @AppStorage uses so first-launch
			// requests don't silently send num_ctx=0 (which Ollama would treat
			// as "use server default", typically the model's full context).
			let stored = UserDefaults.standard.object(forKey: "ollamaNumCtx") as? Int
			return stored.map { $0 > 0 ? $0 : defaultNumCtx } ?? defaultNumCtx
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "ollamaNumCtx")
		}
	}
	static let defaultModel = "llava"
	static let defaultPrompt = "Describe this image or video frame in one sentence."
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

	/// Substrings in a model name that indicate the model has had its safety
	/// alignment removed or weakened ("uncensored" / "abliterated" / Dolphin
	/// fine-tune family). Used purely for tagging the model in the picker so
	/// the user knows what they're selecting.
	private static let uncensoredSubstrings: [String] = [
		"uncensored", "abliterated", "dolphin"
	]

	/// True when the model name suggests an uncensored variant. Heuristic —
	/// based on common naming conventions, not an authoritative Ollama flag.
	static func isLikelyUncensored(_ model: String) -> Bool {
		let lowered = model.lowercased()
		return uncensoredSubstrings.contains { lowered.contains($0) }
	}

	private let logger = Logger(subsystem: "com.example.PictureViewer", category: "ollama")

	private struct GenerateRequest: Encodable {
		let model: String
		let prompt: String
		let images: [String]
		let stream: Bool
		let options: Options?

		struct Options: Encodable {
			let num_ctx: Int
		}

		init(model: String, prompt: String, images: [String], stream: Bool = false, num_ctx: Int? = nil) {
			self.model = model
			self.prompt = prompt
			self.images = images
			self.stream = stream
			// Ollama requires generation parameters (num_ctx, temperature, top_p, …)
			// inside an `options` object on /api/generate. Top-level fields are
			// silently ignored and the server falls back to its config default
			// (e.g. 131070), which OOMs on machines with limited unified memory.
			self.options = num_ctx.map { Options(num_ctx: $0) }
		}
	}

	private struct GenerateResponse: Decodable {
		let response: String?
		let error: String?
		/// "stop" on a clean finish; "length" when the model hit num_predict or
		/// the context window; "load" when the server bailed before generating.
		let done_reason: String?
		/// Older Ollama versions populate this when the prompt itself was
		/// truncated to fit `num_ctx`.
		let truncated: Bool?
		let prompt_eval_count: Int?
		let eval_count: Int?
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
	/// Images are encoded directly; videos are represented by a decoded frame.
	/// The URL must point to an on-disk file — batch callers should use `recognizeAndLog`, which
	/// materializes lazy SQLite working copies on demand and removes them
	/// after the post-recognition callback completes.
	/// `numCtx` overrides the Settings-stored value (used by retry logic on
	/// truncation); pass nil to use the configured default.
	func recognize(imageURL url: URL, prompt: String, model: String, numCtx: Int? = nil) async throws -> String {
		try Task.checkCancellation()
		guard let base64 = await Self.encodedMediaData(for: url) else {
			throw RecognizerError.imageEncodingFailed
		}
		try Task.checkCancellation()

		let effectiveNumCtx = numCtx ?? Self.numCtx
		let body = GenerateRequest(model: model, prompt: prompt, images: [base64], stream: false, num_ctx: effectiveNumCtx)
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
			// Some Ollama builds surface context overflow as a plain-text error
			// (e.g. "input length exceeds context length") rather than a flag,
			// so route those into the truncated case for actionable messaging.
			if Self.isTruncationError(error) {
				throw RecognizerError.responseTruncated(partial: "", reason: error)
			}
			throw RecognizerError.ollamaError(error)
		}
		let text = (decoded.response ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.replacingOccurrences(of: "\n", with: " ")
			.replacingOccurrences(of: "\r", with: " ")
		if let reason = Self.truncationReason(from: decoded) {
			throw RecognizerError.responseTruncated(partial: text, reason: reason)
		}
		return text
	}

	/// Returns a short reason string when the response shows signs of being
	/// cut off, or nil if the generation completed cleanly.
	private static func truncationReason(from response: GenerateResponse) -> String? {
		if response.truncated == true {
			return "prompt truncated to fit num_ctx"
		}
		if let reason = response.done_reason?.lowercased(), reason == "length" {
			return "done_reason=length (context window or num_predict hit)"
		}
		return nil
	}

	private static func isTruncationError(_ message: String) -> Bool {
		let lowered = message.lowercased()
		return lowered.contains("context length")
			|| lowered.contains("context window")
			|| lowered.contains("exceeds context")
			|| lowered.contains("input length")
			|| lowered.contains("truncat")
	}

	/// Recognizes a sequence of media URLs sequentially, logging one line per
	/// item and publishing progress to `OllamaProgress.shared`. Cancellation
	/// cooperatively stops the sequence between items. `onRecognized` is
	/// invoked after each successful recognition; the caller is responsible
	/// for any post-processing (e.g. writing metadata + refreshing UI).
	/// Returns the number of successfully recognized items.
	func recognizeAndLog(
		imageURLs urls: [URL],
		prompt: String,
		model: String,
		onRecognized: (@Sendable (URL, String) async -> Void)? = nil
	) async -> Int {
		var success = 0
		let start = Date()
		let total = urls.count
		let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		let effectivePrompt = trimmedPrompt.isEmpty ? Self.defaultPrompt : trimmedPrompt
		let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
		let effectiveModel = trimmedModel.isEmpty ? Self.defaultModel : trimmedModel
		logger.log("ollama:batch start count=\(total, privacy: .public) model=\(effectiveModel, privacy: .public) prompt=\(effectivePrompt, privacy: .public)")
		for (index, url) in urls.enumerated() {
			if Task.isCancelled {
				logger.log("ollama:batch cancelled after=[\(index, privacy: .public)/\(total, privacy: .public)]")
				break
			}
			let filename = url.lastPathComponent
			let position = "[\(index + 1)/\(total)]"
			await MainActor.run {
				OllamaProgress.shared.update(completed: index, currentFilename: filename)
			}
			// Materialize lazy SQLite working copies on demand so Ollama (and any
			// `onRecognized` callback like writeKeywords) can read them from disk.
			let readableURL: URL
			if SQLiteObjectStore.needsMaterialization(url) {
				do {
					readableURL = try await SQLiteObjectStore.shared.materializeWorkingCopyIfNeeded(url)
				} catch {
					logger.error("ollama:materialize-failed \(position, privacy: .public) \(filename, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
					await MainActor.run {
						OllamaProgress.shared.update(completed: index + 1, currentFilename: filename)
					}
					continue
				}
			} else {
				readableURL = url
			}
			var cancelled = false
			// Retry-on-truncation loop. Each retry grows num_ctx by
			// `truncationRetryGrowthFactor` (capped at `maxRetryNumCtx`) so a
			// transient truncation from a too-small context doesn't kill the
			// recognition. If we still truncate after `maxTruncationRetries`
			// extra attempts, fall back to whatever partial text we have.
			var currentNumCtx = Self.numCtx
			var attempt = 0
			var producedText: String?
			truncationRetryLoop: while attempt <= Self.maxTruncationRetries {
				do {
					let text = try await recognize(
						imageURL: readableURL,
						prompt: effectivePrompt,
						model: effectiveModel,
						numCtx: currentNumCtx
					)
					if attempt > 0 {
						logger.log("ollama:retry-success \(position, privacy: .public) \(filename, privacy: .public) attempt=\(attempt, privacy: .public) numCtx=\(currentNumCtx, privacy: .public)")
					}
					producedText = text
					break truncationRetryLoop
				} catch is CancellationError {
					logger.log("ollama:batch cancelled at=\(position, privacy: .public) \(filename, privacy: .public)")
					cancelled = true
					break truncationRetryLoop
				} catch let RecognizerError.responseTruncated(partial, reason) {
					let nextNumCtx = min(
						Int((Double(currentNumCtx) * Self.truncationRetryGrowthFactor).rounded()),
						Self.maxRetryNumCtx
					)
					if attempt < Self.maxTruncationRetries, nextNumCtx > currentNumCtx {
						logger.error("ollama:truncated \(position, privacy: .public) \(filename, privacy: .public) reason=\(reason, privacy: .public) numCtx=\(currentNumCtx, privacy: .public) retryWithNumCtx=\(nextNumCtx, privacy: .public) attempt=\(attempt + 1, privacy: .public)")
						currentNumCtx = nextNumCtx
						attempt += 1
						continue truncationRetryLoop
					}
					// Out of retries or already at the cap — accept partial.
					logger.error("ollama:truncated-final \(position, privacy: .public) \(filename, privacy: .public) reason=\(reason, privacy: .public) numCtx=\(currentNumCtx, privacy: .public) attempts=\(attempt + 1, privacy: .public) partialBytes=\(partial.utf8.count, privacy: .public)")
					producedText = partial.isEmpty ? nil : partial
					break truncationRetryLoop
				} catch {
					logger.error("ollama:failed \(position, privacy: .public) \(filename, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
					break truncationRetryLoop
				}
			}
			if let producedText {
				logger.log("ollama:recognized \(position, privacy: .public) \(filename, privacy: .public) — \(producedText, privacy: .public)")
				success += 1
				if let onRecognized {
					await onRecognized(url, producedText)
				}
			}
			// Always clean up lazy SQLite working copies after recognition —
			// canonical bytes live in the .sqlite database and can be re-materialized
			// on demand, so the working dir doesn't need to accumulate them.
			if SQLiteObjectStore.isWorkingCopyURL(url),
			   FileManager.default.fileExists(atPath: readableURL.path) {
				try? FileManager.default.removeItem(at: readableURL)
			}
			if cancelled {
				break
			}
			await MainActor.run {
				OllamaProgress.shared.update(completed: index + 1, currentFilename: filename)
			}
		}
		logger.log("ollama:batch end success=\(success, privacy: .public) of=\(total, privacy: .public) duration=\(Date().timeIntervalSince(start), privacy: .public)")
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

	/// Loads an image or representative video frame and returns base64-encoded
	/// JPEG data suitable for Ollama's `images` field.
	private static func encodedMediaData(for url: URL) async -> String? {
		let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
		if PhotoLibrary.isVideoMediaFile(url, contentType: contentType) {
			return await encodedVideoFrameData(for: url)
		}
		return encodedImageData(for: url)
	}

	private static func encodedVideoFrameData(for url: URL) async -> String? {
		if let cached = await existingVideoThumbnailData(for: url) {
			return cached.base64EncodedString()
		}
		do {
			let image = try await ThumbnailGenerator.shared.generateRepresentativeVideoFrame(for: url, maxEdgePixels: maxEdgePixels)
			guard let jpeg = ThumbnailCache.jpegData(from: image, compressionFactor: 0.8) else {
				return nil
			}
			return jpeg.base64EncodedString()
		} catch {
			return nil
		}
	}

	private static func existingVideoThumbnailData(for url: URL) async -> Data? {
		if let hydrated = SQLiteObjectStore.peekHydratedThumbnailJPEGData(for: url), !hydrated.isEmpty {
			return hydrated
		}
		if let cached = ThumbnailCache.shared.existingJPEGData(for: url), !cached.isEmpty {
			return cached
		}
		if SQLiteObjectStore.isWorkingCopyURL(url),
		   let stored = await SQLiteObjectStore.shared.thumbnailJPEGData(forWorkingFile: url),
		   !stored.isEmpty {
			ThumbnailCache.shared.storeJPEGData(stored, for: url)
			return stored
		}
		return nil
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
		/// The server returned an output that was cut off (response hit
		/// num_predict / context window, or the prompt itself was truncated to
		/// fit num_ctx). `partial` carries whatever text we did receive so the
		/// caller can decide whether to use it.
		case responseTruncated(partial: String, reason: String)

		var errorDescription: String? {
			switch self {
			case .imageEncodingFailed:
				return "Could not decode media for Ollama"
			case .invalidResponse:
				return "Ollama returned a non-HTTP response"
			case .httpError(let status, let body):
				return "Ollama HTTP \(status): \(body)"
			case .ollamaError(let message):
				return "Ollama error: \(message)"
			case .responseTruncated(_, let reason):
				return "Ollama response truncated (\(reason)) — raise num_ctx or shorten the prompt"
			}
		}
	}
}
