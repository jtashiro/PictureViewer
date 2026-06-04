//
//  FaceProcessor.swift
//  PictureViewer
//

import Foundation
import Vision
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

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

        // Check whether we already have records for this file.
        let existing = await dbActor.faceIDs(forPath: url.path)
        if !existing.isEmpty { return existing }

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

    func clusterFaces(eps: Float = 0.6, minPoints: Int = 1) async {
        guard baseURL != nil else { return }
        let faceEntries = await dbActor.snapshotFaceEntries()
        if faceEntries.isEmpty { return }

        var features: [VNFeaturePrintObservation?] = Array(repeating: nil, count: faceEntries.count)
        for (i, entry) in faceEntries.enumerated() {
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
            while !queue.isEmpty {
                let j = queue.removeFirst()
                if !visited[j] {
                    visited[j] = true
                    if let fj = features[j] {
                        var jNeighbors: [Int] = []
                        for k in 0..<n where k != j { if let fk = features[k], distance(fj, fk) <= eps { jNeighbors.append(k) } }
                        if jNeighbors.count + 1 >= minPoints { queue.append(contentsOf: jNeighbors.filter { !queue.contains($0) }) }
                    }
                }
                if assigned[j] == -1 { assigned[j] = clusters.count; cluster.append(j) }
            }
            clusters.append(cluster)
        }

        var persons: [String: [String]] = [:]
        for cluster in clusters { let pid = UUID().uuidString; persons[pid] = cluster.map { faceEntries[$0].id.uuidString } }
        await dbActor.replacePersons(persons)
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

    func renamePerson(personID: UUID, to newName: String) async {
        await dbActor.renamePerson(personID: personID, to: newName)
    }

    func mergePerson(source: UUID, into target: UUID) async {
        await dbActor.mergePerson(source: source, into: target)
    }

    func splitPerson(personID: UUID, faceIDsToMove: [UUID]) async -> UUID? {
        return await dbActor.splitPerson(personID: personID, faceIDsToMove: faceIDsToMove)
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
}

struct Rect: Codable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat
    init(normalized: CGRect) { self.x = normalized.origin.x; self.y = normalized.origin.y; self.w = normalized.size.width; self.h = normalized.size.height }
}
