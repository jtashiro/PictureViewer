import Foundation
import CoreGraphics
import os

actor FaceDatabaseActor {
	nonisolated private static let logger = Logger(subsystem: "com.example.PictureViewer", category: "face-db")

	private var db: FaceDatabase
	private let baseURL: URL?

	init(baseURL: URL?) {
		self.baseURL = baseURL
		// Load the current state from disk upon initialization/startup.
		self.db = FaceDatabase.load(from: baseURL)
	}

	func faceIDs(forPath path: String) -> [UUID] {
		return db.records[path]?.map { $0.id } ?? []
	}

	/// Returns true when the path has any non-synthetic (detected) face entry.
	func hasDetectedFaces(forPath path: String) -> Bool {
		guard let entries = db.records[path] else { return false }
		return entries.contains { !$0.isSynthetic }
	}

	func addRecords(path: String, entries: [FaceEntry]) async {
		// Preserve any synthetic (manual-assignment) entries already on file
		let existing = db.records[path] ?? []
		let syntheticSurvivors = existing.filter { $0.isSynthetic }

        // Only append new entries that do not already exist by ID to prevent duplication.
		let existingIDs = Set(existing.map { $0.id })
        let uniqueNewEntries = entries.filter { !existingIDs.contains($0.id) }
        
		db.records[path] = syntheticSurvivors + uniqueNewEntries
		db.save(to: baseURL)
		Self.logger.log("addRecords: added \(entries.count, privacy: .public) faces for path=\(path, privacy: .public)")
	}

	func allFaces() -> [PublicFace] {
		var out: [PublicFace] = []
		for (source, entries) in db.records {
			for e in entries {
				out.append(PublicFace(id: e.id, thumbURL: URL(fileURLWithPath: e.thumbPath), sourceURL: URL(fileURLWithPath: source)))
			}
		}
		return out
	}

	func snapshotFaceEntries() -> [FaceEntry] {
		var out: [FaceEntry] = []
		for (_, entries) in db.records { out.append(contentsOf: entries) }
		return out
	}

	func replacePersons(_ persons: [String: [String]]) async {
		db.persons = persons
		for pid in persons.keys where db.personNames[pid] == nil {
			db.personNames[pid] = "Person" // Assign default name if cluster ID is new
		}
		db.save(to: baseURL)
		Self.logger.log("replacePersons: wrote \(persons.count, privacy: .public) person clusters")
	}

	func personsList() -> [Person] {
		// Build a fast lookup from face UUID string to entry for quick retrieval during build.
		var entryByID: [String: FaceEntry] = [:]
		for (_, entries) in db.records {
			for e in entries { entryByID[e.id.uuidString] = e }
		}
        
		var out: [Person] = []
		for (pid, faceIDs) in db.persons {
			// The key `pid` is the string representation of the person's cluster ID.
            let pidStr = pid // Stable String representation of the group

			// Find a preferred face entry for this cluster/person group.
			let preferredFaceID = faceIDs.first { 
                // Prefer non-synthetic entries (biometric match) unless the group only contains synthetics.
                if let entry = entryByID[$0], !entry.isSynthetic { return true }
                return false 
            } ?? faceIDs.first // Fallback to first entry if none is preferred

			guard let chosenID = preferredFaceID, let entry = entryByID[chosenID] else { continue }

			// Use the cluster ID (pidStr) as the stable `id` for the Person object.
			let rep = URL(fileURLWithPath: entry.thumbPath)
			let source = URL(fileURLWithPath: entry.sourcePath)
            
			// Note: Using pidStr as the stable ID allows linking across usage sessions.
			out.append(Person(id: UUID(uuidString: pidStr) ?? UUID(), representative: rep, count: faceIDs.count, sampleSource: source, name: db.personNames[pidStr]))
		}
		return out
	}

	/// Unique source-image paths for every face assigned to the given person.
	func sourcePathsForPerson(personID: UUID) -> [String] {
		let pid = personID.uuidString
		guard let faceIDs = db.persons[pid] else { return [] }
		let idSet = Set(faceIDs)
		var paths: Set<String> = []
		for (path, entries) in db.records {
			for e in entries where idSet.contains(e.id.uuidString) {
				paths.insert(path)
				break // Found one matching entry for this path, move to next path.
			}
		}
		return Array(paths)
	}

	func facesForPerson(personID: UUID) -> [PublicFace] {
		var out: [PublicFace] = []
		let pid = personID.uuidString
		guard let faceIDs = db.persons[pid] else { return out }
		for fid in faceIDs {
			if let uuid = UUID(uuidString: fid) {
				for (_, entries) in db.records {
					for e in entries where e.id == uuid {
						out.append(PublicFace(id: e.id, thumbURL: URL(fileURLWithPath: e.thumbPath), sourceURL: URL(fileURLWithPath: e.sourcePath)))
					}
				}
			}
		}
		return out
	}

	func renamePerson(personID: UUID, to newName: String) {
		let pid = personID.uuidString
		db.personNames[pid] = newName
		db.save(to: baseURL)
	}

	func mergePerson(source: UUID, into target: UUID) {
		let s = source.uuidString
		let t = target.uuidString
        
        // Ensure the target exists before merging into it.
        guard db.persons[t] != nil else { return } 
        
		guard let sFaces = db.persons[s] else { return } // Source must have faces
		var tFaces = db.persons[t] ?? []
        
        // Prevent adding the same face ID twice if merging multiple times.
        let newFaces = sFaces.filter { !tFaces.contains($0) }
		tFaces.append(contentsOf: newFaces)
		db.persons[t] = tFaces
		db.persons.removeValue(forKey: s)
		db.personNames.removeValue(forKey: s) // Remove old name entry
		db.save(to: baseURL)
	}

	func splitPerson(personID: UUID, faceIDsToMove: [UUID]) -> UUID? {
		let pid = personID.uuidString
		guard var faces = db.persons[pid] else { return nil } // Ensure person exists
		let moveStrings = faceIDsToMove.map { $0.uuidString }

        // Filter out faces being moved from the current group
		faces.removeAll { moveStrings.contains($0) } 
        
		db.persons[pid] = faces // Update remaining group
		let newPID = UUID() // New person gets a brand new stable ID/Cluster ID
        // IMPORTANT: Use the cluster ID UUID string for mapping, not a temporary local variable.
		db.persons[newPID.uuidString] = moveStrings 
		db.personNames[newPID.uuidString] = "Person" // Assign default name
		db.save(to: baseURL)
		return newPID
	}

    func assignFaces(filePaths: [String], toPersonNamed name: String) -> PersonAssignmentResult {
		let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalizedName.isEmpty else { return PersonAssignmentResult(facesAssigned: 0, photosWithFaces: 0) }

		let targetPID = ensurePerson(named: normalizedName)
		var movedFaceIDs: Set<String> = []
		var photosWithFaces = 0
		for path in filePaths {
			var entries = db.records[path] ?? []
			if entries.isEmpty {
				// No detectable face — create a synthetic entry so the manual
				// assignment is preserved and the photo appears under the person.
				let synthetic = FaceEntry(
					id: UUID(),
					sourcePath: path,
					bbox: Rect(normalized: .zero), // Zero bbox indicates manual assignment/no detection
					thumbPath: path
				)
				entries = [synthetic]
				db.records[path] = entries
			}
			photosWithFaces += 1
            // Ensure we only track the entry IDs for moved faces.
			for entry in entries {
				movedFaceIDs.insert(entry.id.uuidString)
			}
		}
        
		guard !movedFaceIDs.isEmpty else { return PersonAssignmentResult(facesAssigned: 0, photosWithFaces: 0) }

		// Add all matched face IDs to the target person group
		var currentTargetIDs = db.persons[targetPID] ?? []
        let newFaces = movedFaceIDs.filter { !currentTargetIDs.contains($0) }
		currentTargetIDs.append(contentsOf: newFaces)
		db.persons[targetPID] = currentTargetIDs

		db.save(to: baseURL)
		return PersonAssignmentResult(facesAssigned: movedFaceIDs.count, photosWithFaces: photosWithFaces)
	}

    func removeRecords(forPaths paths: [String]) {
		for path in paths {
			guard let entries = db.records[path] else { continue }
			let syntheticSurvivors = entries.filter { $0.isSynthetic }
			if syntheticSurvivors.isEmpty {
				db.records.removeValue(forKey: path)
			} else {
				// Keep synthetic (manual-assignment) entries so a rescan does
				db.records[path] = syntheticSurvivors
			}
		}
		// Person clusters must be rebuilt after source records are removed.
		db.persons = [:]
		db.personNames = [:]
		db.save(to: baseURL)
	}

    func snapshotSyntheticAssignments() -> [String: String] {
		var syntheticIDs: Set<String> = []
		for (_, entries) in db.records {
			for e in entries where e.isSynthetic {
				syntheticIDs.insert(e.id.uuidString)
			}
		}
		guard !syntheticIDs.isEmpty else { return [:] }
		var mapping: [String: String] = [:]
		for (pid, faceIDs) in db.persons {
			guard let name = db.personNames[pid] else { continue }
			for fid in faceIDs where syntheticIDs.contains(fid) {
				mapping[fid] = name // Map Face ID to Person Name (stable label)
			}
		}
		return mapping
	}

    func reattachSyntheticAssignments(_ mapping: [String: String]) {
		guard !mapping.isEmpty else { return }
		var byName: [String: [String]] = [:]
		for (faceID, name) in mapping {
			byName[name, default: []].append(faceID)
		}
		for (name, faceIDs) in byName {
			let pid = ensurePerson(named: name)
			var current = Set(db.persons[pid] ?? [])
            // Add the recovered face IDs to the existing group members.
			current.formUnion(faceIDs) 
			db.persons[pid] = Array(current)
		}
		db.save(to: baseURL)
		Self.logger.log("reattachSyntheticAssignments: restored \(mapping.count, privacy: .public) manual face assignments")
	}

    private func ensurePerson(named name: String) -> String {
		if let existing = db.personNames.first(where: { $0.value.localizedCaseInsensitiveCompare(name) == .orderedSame })?.key {
			if db.persons[existing] == nil { db.persons[existing] = [] }
			return existing
		}
		let pid = UUID().uuidString
		db.personNames[pid] = name
		db.persons[pid] = []
		return pid
	}
}
