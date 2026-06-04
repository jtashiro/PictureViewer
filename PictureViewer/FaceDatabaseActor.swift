import Foundation
import os

private let faceDBLogger = Logger(subsystem: "com.example.PictureViewer", category: "face-db")

actor FaceDatabaseActor {
	private var db: FaceDatabase
	private let baseURL: URL?

	init(baseURL: URL?) {
		self.baseURL = baseURL
		// Initialize with an empty database synchronously to satisfy
		// the actor's invariant, then asynchronously load the on-disk
		// copy. Loading may be main-actor-isolated; perform that work
		// off this initializer and assign back to the actor when done.
		self.db = FaceDatabase()

		Task.detached { [weak self] in
			// If FaceDatabase.load is main-actor-isolated, run it on the
			// MainActor. Otherwise this simply executes the load.
			let loaded = await MainActor.run { FaceDatabase.load(from: baseURL) }
			// Assign back to the actor instance on its own isolation.
			await self?.replaceDB(loaded)
		}
	}

	private func replaceDB(_ newDB: FaceDatabase) {
		self.db = newDB
	}

	func faceIDs(forPath path: String) -> [UUID] {
		return db.records[path]?.map { $0.id } ?? []
	}

	func addRecords(path: String, entries: [FaceEntry]) async {
		db.records[path] = entries
		db.save(to: baseURL)
		faceDBLogger.log("addRecords: added \(entries.count, privacy: .public) faces for path=\(path, privacy: .public)")
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
			db.personNames[pid] = "Person"
		}
		db.save(to: baseURL)
		faceDBLogger.log("replacePersons: wrote \(persons.count, privacy: .public) person clusters")
	}

	func personsList() -> [Person] {
		var out: [Person] = []
		for (pid, faceIDs) in db.persons {
			if let first = faceIDs.first, let uuid = UUID(uuidString: first) {
				var repThumb: URL? = nil
				var source: URL? = nil
				outer: for (_, entries) in db.records {
					for e in entries { if e.id == uuid { repThumb = URL(fileURLWithPath: e.thumbPath); source = URL(fileURLWithPath: e.sourcePath); break outer } }
				}
				if let rep = repThumb { out.append(Person(id: UUID(uuidString: pid) ?? UUID(), representative: rep, count: faceIDs.count, sampleSource: source, name: db.personNames[pid])) }
			}
		}
		return out
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
		guard let sFaces = db.persons[s] else { return }
		var tFaces = db.persons[t] ?? []
		tFaces.append(contentsOf: sFaces)
		db.persons[t] = tFaces
		db.persons.removeValue(forKey: s)
		db.personNames.removeValue(forKey: s)
		db.save(to: baseURL)
	}

	func splitPerson(personID: UUID, faceIDsToMove: [UUID]) -> UUID? {
		let pid = personID.uuidString
		guard var faces = db.persons[pid] else { return nil }
		let moveStrings = faceIDsToMove.map { $0.uuidString }
		faces.removeAll { moveStrings.contains($0) }
		db.persons[pid] = faces
		let newPID = UUID()
		db.persons[newPID.uuidString] = moveStrings
		db.personNames[newPID.uuidString] = "Person"
		db.save(to: baseURL)
		return newPID
	}
}
