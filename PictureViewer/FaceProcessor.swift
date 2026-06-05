//
//  FaceProcessor.swift
//  PictureViewer
//

import Foundation
import Vision
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import os

private let faceLogger = Logger(subsystem: "com.example.PictureViewer", category: "face")

/// FaceProcessor: detects faces in scanned image files, writes cropped
/// face thumbnails to Application Support, stores a small JSON index, and
/// provides clustering and person-management APIs.
final class FaceProcessor {
	static let shared = FaceProcessor()

	// Face processing work is performed on detached tasks; database
	// access is managed by an actor to avoid data races.
	private let fm = FileManager.default
	private let limiter: AsyncLimiter
	private let baseURL: URL?
	private let dbActor: FaceDatabaseActor

	private init() {
		let cap = max(1, PhotoLibrary.workerCount)
		self.limiter = AsyncLimiter(capacity: cap)

		// Prepare base directory
		if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
			let base = appSupport.appendingPathComponent("PictureViewer", isDirectory: true)
			let faces = base.appendingPathComponent("faces", isDirectory: true)
			try? fm.createDirectory(at: faces, withIntermediateDirectories: true)
			self.baseURL = base
		} else {
			self.baseURL = nil
		}

		self.dbActor = FaceDatabaseActor(baseURL: baseURL)
	}

	// MARK: - Public API

	/// Process a file for faces. Returns face IDs (existing or newly created).
	func process(file url: URL) async -> [UUID] {
		await limiter.acquire()
		defer { Task { await limiter.release() } }

		// Skip detection only when we already have real (non-synthetic) faces
		// for this file. Synthetic entries (manual assignments) do not count.
		if await dbActor.hasDetectedFaces(forPath: url.path) {
			return await dbActor.faceIDs(forPath: url.path)
		}

		// Perform CPU/IO heavy work off the main actor in a detached task.
		let created = await Task.detached(priority: .utility) { [weak self] () -> [FaceEntry] in
			guard let self = self, let base = self.baseURL else { return [] }
			guard let cg = self.loadCGImage(url: url) else { return [] }

			let handler = VNImageRequestHandler(cgImage: cg, options: [:])
			let detect = VNDetectFaceRectanglesRequest()
			do { try handler.perform([detect]) } catch { return [] }
			guard let faces = detect.results as? [VNFaceObservation], !faces.isEmpty else { return [] }

			var localCreated: [FaceEntry] = []
			for face in faces {
				let id = UUID()
				if let crop = self.cropFace(cgImage: cg, boundingBox: face.boundingBox) {
					let thumbURL = base.appendingPathComponent("faces").appendingPathComponent("\(id.uuidString).jpg")
					if self.writeJPEG(cgImage: crop, to: thumbURL, quality: 0.7) {
						let entry = FaceEntry(id: id, sourcePath: url.path, bbox: Rect(normalized: face.boundingBox), thumbPath: thumbURL.path)
						localCreated.append(entry)
					}
				}
			}
			return localCreated
		}.value

		if created.isEmpty { return [] }
		await dbActor.addRecords(path: url.path, entries: created)
		return created.map { $0.id }
	}

	func faceIDs(forFile url: URL) async -> [UUID] {
		return await dbActor.faceIDs(forPath: url.path)
	}
	func allFaces() async -> [PublicFace] {
		return await dbActor.allFaces()
	}

	// (processSync removed — processing now runs in `process(file:)` using the actor)

	// MARK: - Image helpers

	private func loadCGImage(url: URL) -> CGImage? {
		guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
		return CGImageSourceCreateImageAtIndex(src, 0, nil)
	}

	private func cropFace(cgImage: CGImage, boundingBox: CGRect) -> CGImage? {
		let w = CGFloat(cgImage.width)
		let h = CGFloat(cgImage.height)
		let x = boundingBox.origin.x * w
		let y = (1 - boundingBox.origin.y - boundingBox.size.height) * h
		let rect = CGRect(x: x, y: y, width: boundingBox.size.width * w, height: boundingBox.size.height * h).integral
		guard rect.width > 0 && rect.height > 0 else { return nil }
		return cgImage.cropping(to: rect)
	}

	private func writeJPEG(cgImage: CGImage, to url: URL, quality: CGFloat) -> Bool {
		guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
		let props = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
		CGImageDestinationAddImage(dest, cgImage, props)
		return CGImageDestinationFinalize(dest)
	}

	// MARK: - Clustering

	func clusterFaces(
		eps: Float = 0.6,
		minPoints: Int = 1,
		preservedAssignments: [String: String] = [:],
		progress: (@Sendable (_ completed: Int, _ total: Int, _ status: String) -> Void)? = nil
	) async -> Bool {
		guard baseURL != nil else { return false }

		// Capture manual (synthetic) assignments that still live in db.persons
		// so they can be re-applied after replacePersons rebuilds clusters.
		// Callers that have already wiped persons (e.g. via removeRecords) pass
		// a pre-captured `preservedAssignments` instead.
		let internalAssignments = await dbActor.snapshotSyntheticAssignments()
		let combinedAssignments = preservedAssignments.merging(internalAssignments) { keep, _ in keep }

		// Exclude synthetic (manual-assignment) entries from clustering — their
		// thumbnails are full source images and would not yield meaningful
		// face-feature prints. They are re-attached to their named person at
		// the end of this call.
		let faceEntries = await dbActor.snapshotFaceEntries().filter { !$0.isSynthetic }
		if faceEntries.isEmpty {
			await dbActor.reattachSyntheticAssignments(combinedAssignments)
			return true
		}
		let started = Date()
		faceLogger.log("clusterFaces:start entries=\(faceEntries.count, privacy: .public)")
		let totalSteps = max(1, faceEntries.count * 2)
		progress?(0, totalSteps, "Preparing feature extraction")

		var features: [VNFeaturePrintObservation?] = Array(repeating: nil, count: faceEntries.count)
		for (i, entry) in faceEntries.enumerated() {
			if Task.isCancelled {
				faceLogger.log("clusterFaces:cancelled during feature extraction")
				progress?(i, totalSteps, "Cancelled")
				return false
			}
			if i % 25 == 0 {
				let sourceName = URL(fileURLWithPath: entry.sourcePath).lastPathComponent
				faceLogger.log("clusterFaces:extracting feature \(i + 1, privacy: .public)/\(faceEntries.count, privacy: .public) file=\(sourceName, privacy: .public)")
			}
			if i % 16 == 0 { await Task.yield() }
			progress?(i + 1, totalSteps, "Extracting features \(i + 1)/\(faceEntries.count)")
			if let cg = loadCGImage(url: URL(fileURLWithPath: entry.thumbPath)) {
				let handler = VNImageRequestHandler(cgImage: cg, options: [:])
				let req = VNGenerateImageFeaturePrintRequest()
				do { try handler.perform([req]); features[i] = req.results?.first as? VNFeaturePrintObservation } catch { features[i] = nil }
			}
		}

		func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
			var d: Float = 0
			try? a.computeDistance(&d, to: b)
			return d
		}

		let n = faceEntries.count
		var visited = Array(repeating: false, count: n)
		var assigned = Array(repeating: -1, count: n)
		var clusters: [[Int]] = []

		for i in 0..<n {
			if Task.isCancelled {
				faceLogger.log("clusterFaces:cancelled during clustering")
				progress?(faceEntries.count + i, totalSteps, "Cancelled")
				return false
			}
			if i % 16 == 0 { await Task.yield() }
			progress?(faceEntries.count + i + 1, totalSteps, "Clustering \(i + 1)/\(n)")
			if visited[i] { continue }
			visited[i] = true
			var neighborIdxs: [Int] = []
			if let fi = features[i] {
				for j in 0..<n where i != j { if let fj = features[j], distance(fi, fj) <= eps { neighborIdxs.append(j) } }
			}
			if neighborIdxs.count + 1 < minPoints {
				if minPoints <= 1 { clusters.append([i]); assigned[i] = clusters.count - 1 }
				continue
			}
			var cluster: [Int] = [i]
			assigned[i] = clusters.count
			var queue = neighborIdxs
			var queued = Set(neighborIdxs)
			var queueIndex = 0
			while queueIndex < queue.count {
				let j = queue[queueIndex]
				queueIndex += 1
				if !visited[j] {
					visited[j] = true
					if let fj = features[j] {
						var jNeighbors: [Int] = []
						for k in 0..<n where k != j { if let fk = features[k], distance(fj, fk) <= eps { jNeighbors.append(k) } }
						if jNeighbors.count + 1 >= minPoints {
							for neighbor in jNeighbors where queued.insert(neighbor).inserted {
								queue.append(neighbor)
							}
						}
					}
				}
				if assigned[j] == -1 { assigned[j] = clusters.count; cluster.append(j) }
			}
			clusters.append(cluster)
		}

		var persons: [String: [String]] = [:]
		for cluster in clusters { let pid = UUID().uuidString; persons[pid] = cluster.map { faceEntries[$0].id.uuidString } }
		await dbActor.replacePersons(persons)
		await dbActor.reattachSyntheticAssignments(combinedAssignments)
		faceLogger.log("clusterFaces:done clusters=\(clusters.count, privacy: .public) elapsed_ms=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)")
		progress?(totalSteps, totalSteps, "Completed")
		return true
	}

	func allPeople() async -> [Person] {
		return await dbActor.personsList()
	}

	// MARK: - Person management

	func personsList() async -> [Person] {
		return await dbActor.personsList()
	}

	func facesForPerson(personID: UUID) async -> [PublicFace] {
		return await dbActor.facesForPerson(personID: personID)
	}

	func sourcePathsForPerson(personID: UUID) async -> [String] {
		return await dbActor.sourcePathsForPerson(personID: personID)
	}

	func renamePerson(personID: UUID, to newName: String) async {
		await dbActor.renamePerson(personID: personID, to: newName)
	}

	func mergePerson(source: UUID, into target: UUID) async {
		await dbActor.mergePerson(source: source, into: target)
	}

	func splitPerson(personID: UUID, faceIDsToMove: [UUID]) async -> UUID? {
		return await dbActor.splitPerson(personID: personID, faceIDsToMove: faceIDsToMove)
	}

  func assignPerson(named name: String, toFiles urls: [URL]) async -> PersonAssignmentResult {
	let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
	guard !normalizedName.isEmpty else { return PersonAssignmentResult(facesAssigned: 0, photosWithFaces: 0) }

	var filePaths: [String] = []
	for url in urls {
	  if Task.isCancelled { break }
	  _ = await process(file: url)
	  filePaths.append(url.path)
	}
	return await dbActor.assignFaces(filePaths: filePaths, toPersonNamed: normalizedName)
  }

  func rescanFaceRecognition(
	forFiles urls: [URL],
	progress: (@Sendable (_ phase: String, _ completed: Int, _ total: Int) -> Void)? = nil
  ) async -> Int {
	let uniquePaths = Array(Set(urls.map(\.path)))
	guard !uniquePaths.isEmpty else { return 0 }

	// Snapshot manual assignments before tearing down clusters so they can
	// be restored after re-clustering completes.
	let syntheticAssignments = await dbActor.snapshotSyntheticAssignments()

	await dbActor.removeRecords(forPaths: uniquePaths)
	let total = uniquePaths.count
	progress?("Detecting faces", 0, total)
	for (i, path) in uniquePaths.enumerated() {
	  if Task.isCancelled { break }
	  _ = await process(file: URL(fileURLWithPath: path))
	  progress?("Detecting faces \(i + 1)/\(total)", i + 1, total)
	}
	if Task.isCancelled { return 0 }
	let _ = await clusterFaces(preservedAssignments: syntheticAssignments) { completed, total, status in
	  progress?("Grouping faces — \(status)", completed, total)
	}
	return uniquePaths.count
  }
}

// Public lightweight face description used by the UI.
struct PublicFace: Identifiable {
	let id: UUID
	let thumbURL: URL
	let sourceURL: URL
}

struct Person: Identifiable {
	let id: UUID
	let representative: URL
	let count: Int
	let sampleSource: URL?
	let name: String?
}

struct PersonAssignmentResult: Sendable {
	let facesAssigned: Int
	let photosWithFaces: Int
}

// MARK: - Persistence types

struct FaceDatabase: Codable {
	var records: [String: [FaceEntry]] = [:]
	var persons: [String: [String]] = [:]
	var personNames: [String: String] = [:]

	static func load(from base: URL?) -> FaceDatabase {
		guard let base = base else { return FaceDatabase() }
		let file = base.appendingPathComponent("face-db.json")
		guard let data = try? Data(contentsOf: file) else { return FaceDatabase() }
		return (try? JSONDecoder().decode(FaceDatabase.self, from: data)) ?? FaceDatabase()
	}

	func save(to base: URL?) {
		guard let base = base else { return }
		let file = base.appendingPathComponent("face-db.json")
		if let data = try? JSONEncoder().encode(self) { try? data.write(to: file, options: .atomic) }
	}
}

struct FaceEntry: Codable {
	let id: UUID
	let sourcePath: String
	let bbox: Rect
	let thumbPath: String

	/// True when this entry was created by a manual assignment rather than
	/// face detection (zero-area bounding box). Synthetic entries exist so
	/// photos the user explicitly tagged are preserved even when Vision
	/// cannot detect a face in them.
	var isSynthetic: Bool { bbox.w == 0 && bbox.h == 0 }
}

struct Rect: Codable {
	var x: CGFloat
	var y: CGFloat
	var w: CGFloat
	var h: CGFloat
	init(normalized: CGRect) { self.x = normalized.origin.x; self.y = normalized.origin.y; self.w = normalized.size.width; self.h = normalized.size.height }
}
