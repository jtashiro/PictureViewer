//
//  PersonRecognitionStore.swift
//  PictureViewer
//

import Foundation
import os

struct PersonRecognitionProfile: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var examples: [PersonRecognitionExample]
    var updatedAt: Date
}

struct PersonRecognitionExample: Codable, Identifiable, Sendable {
    let id: UUID
    let imagePath: String
    let description: String
    let addedAt: Date
}

struct PersonRecognitionTrainingResult: Sendable {
    let examplesAdded: Int
    let failed: Int
}

struct PersonRecognitionBatchResult: Sendable {
    let photosProcessed: Int
    let photosWithMatches: Int
    let namesAssigned: Int
    let failed: Int
}

actor PersonRecognitionStore {
    static let shared = PersonRecognitionStore()

    private static let logger = Logger(subsystem: "com.example.PictureViewer", category: "person-recognition")

    private var profiles: [PersonRecognitionProfile]
    private let storeURL: URL?

    private init() {
        let directory = AppWorkingDirectory.baseURL
            .appendingPathComponent("PersonRecognition", isDirectory: true)
        _ = AppWorkingDirectory.baseURL.startAccessingSecurityScopedResource()
        try? AppWorkingDirectory.ensureDirectory(directory)
        self.storeURL = directory.appendingPathComponent("person-recognition.json")
        self.profiles = Self.loadProfiles(from: storeURL)
    }

    func profileCount() -> Int {
        profiles.count
    }

    func knownNames() -> [String] {
        profiles.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func train(
        name: String,
        imageURLs: [URL],
        model: String,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ status: String) -> Void)? = nil
    ) async -> PersonRecognitionTrainingResult {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, !imageURLs.isEmpty else {
            return PersonRecognitionTrainingResult(examplesAdded: 0, failed: imageURLs.count)
        }

        var examples: [PersonRecognitionExample] = []
        var failed = 0
        let total = imageURLs.count
        for (index, url) in imageURLs.enumerated() {
            if Task.isCancelled { break }
            progress?(index, total, "Teaching \(normalizedName) from \(url.lastPathComponent)")
            do {
                let description = try await OllamaRecognizer.shared.recognize(
                    imageURL: url,
                    prompt: Self.trainingPrompt(for: normalizedName),
                    model: model
                )
                let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    failed += 1
                    continue
                }
                examples.append(PersonRecognitionExample(
                    id: UUID(),
                    imagePath: url.path,
                    description: trimmed,
                    addedAt: Date()
                ))
            } catch {
                failed += 1
                Self.logger.error("person recognition training failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
            progress?(index + 1, total, "Teaching \(normalizedName) \(index + 1)/\(total)")
        }

        if !examples.isEmpty {
            upsertExamples(examples, forName: normalizedName)
            save()
        }
        progress?(total, total, "Training complete")
        return PersonRecognitionTrainingResult(examplesAdded: examples.count, failed: failed)
    }

    func recognize(
        imageURLs: [URL],
        model: String,
        progress: (@Sendable (_ completed: Int, _ total: Int, _ status: String) -> Void)? = nil,
        onRecognized: (@Sendable (_ url: URL, _ names: [String]) async -> Void)? = nil
    ) async -> PersonRecognitionBatchResult {
        let activeProfiles = profiles.filter { !$0.examples.isEmpty }
        guard !activeProfiles.isEmpty, !imageURLs.isEmpty else {
            return PersonRecognitionBatchResult(photosProcessed: 0, photosWithMatches: 0, namesAssigned: 0, failed: imageURLs.count)
        }

        var processed = 0
        var matchedPhotos = 0
        var namesAssigned = 0
        var failed = 0
        let total = imageURLs.count
        let prompt = Self.recognitionPrompt(for: activeProfiles)
        for (index, url) in imageURLs.enumerated() {
            if Task.isCancelled { break }
            progress?(index, total, "Recognizing people in \(url.lastPathComponent)")
            do {
                let response = try await OllamaRecognizer.shared.recognize(imageURL: url, prompt: prompt, model: model)
                let names = Self.extractRecognizedNames(from: response, knownNames: activeProfiles.map(\.name))
                processed += 1
                if !names.isEmpty {
                    matchedPhotos += 1
                    namesAssigned += names.count
                    await onRecognized?(url, names)
                }
                Self.logger.log("person recognition file=\(url.lastPathComponent, privacy: .public) matches=\(names.joined(separator: ","), privacy: .public)")
            } catch {
                failed += 1
                Self.logger.error("person recognition failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
            progress?(index + 1, total, "Recognized \(index + 1)/\(total)")
        }

        return PersonRecognitionBatchResult(
            photosProcessed: processed,
            photosWithMatches: matchedPhotos,
            namesAssigned: namesAssigned,
            failed: failed
        )
    }

    private func upsertExamples(_ examples: [PersonRecognitionExample], forName name: String) {
        if let index = profiles.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            var profile = profiles[index]
            var existingPaths = Set(profile.examples.map(\.imagePath))
            profile.examples.append(contentsOf: examples.filter { existingPaths.insert($0.imagePath).inserted })
            profile.updatedAt = Date()
            profiles[index] = profile
        } else {
            profiles.append(PersonRecognitionProfile(id: UUID(), name: name, examples: examples, updatedAt: Date()))
        }
    }

    private func save() {
        guard let storeURL else { return }
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            Self.logger.error("person recognition store save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadProfiles(from storeURL: URL?) -> [PersonRecognitionProfile] {
        guard let storeURL,
              let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([PersonRecognitionProfile].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private static func trainingPrompt(for name: String) -> String {
        """
        You are helping build a private local person-recognition reference for a photo library.
        The image contains \(name). Describe only stable visual identity cues useful for recognizing this same person later: face shape, hair, complexion, eyewear, facial hair, approximate age range, expression, and any distinctive features.
        Do not identify any other people. Do not mention clothing unless it is clearly recurring or identity-relevant.
        Return a concise rich description in one paragraph.
        """
    }

    private static func recognitionPrompt(for profiles: [PersonRecognitionProfile]) -> String {
        let profileText = profiles.map { profile in
            let examples = profile.examples
                .suffix(4)
                .enumerated()
                .map { index, example in
                    "Example \(index + 1): \(example.description)"
                }
                .joined(separator: "\n")
            return "Known person: \(profile.name)\n\(examples)"
        }.joined(separator: "\n\n")

        return """
        You are recognizing known people in a private local photo library.
        Compare the current image against these taught people using face and visual identity cues. Only name a person when there is a strong visual match. If unsure, omit the name.

        \(profileText)

        Return only JSON in this exact shape:
        {"people":["Name"]}
        Use an empty array when no taught person is visible.
        """
    }

    private static func extractRecognizedNames(from response: String, knownNames: [String]) -> [String] {
        let lowerResponse = response.lowercased()
        var found: [String] = []
        var seen: Set<String> = []

        if let data = response.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let people = object["people"] as? [String] {
            for name in people {
                if let known = knownNames.first(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }),
                   seen.insert(known.lowercased()).inserted {
                    found.append(known)
                }
            }
        }

        if found.isEmpty {
            for known in knownNames where lowerResponse.contains(known.lowercased()) {
                if seen.insert(known.lowercased()).inserted {
                    found.append(known)
                }
            }
        }

        return found
    }
}
