//
//  PhotoLibrary.swift
//  PictureViewer
//

import Foundation
import UniformTypeIdentifiers
import os

struct PhotoItem: Identifiable, Hashable, Sendable {
	let id: URL
	nonisolated var url: URL { id }
	nonisolated init(url: URL) { self.id = url }
}

@MainActor
@Observable
final class PhotoLibrary {
	private static let logger = Logger(subsystem: "com.example.PictureViewer", category: "scan")
	var photos: [PhotoItem] = []
	var folderURL: URL?
	var isScanning = false
	var lastScanDate: Date?
	var scanStartDate: Date?
	var lastScanDuration: TimeInterval?

	private var currentScan: Task<Void, Never>?

	// Number of scanner worker tasks, selected at process start based on CPU.
	nonisolated static let workerCount: Int = {
		// Use the active processor count (available logical cores) but keep a
		// sensible upper bound. Scanning is IO-bound; too many threads can
		// cause diminishing returns. 32 is a practical upper limit.
		let cores = ProcessInfo.processInfo.activeProcessorCount
		return max(2, min(cores, 32))
	}()

	nonisolated static var cpuSummary: String {
		let info = ProcessInfo.processInfo
		return "\(info.activeProcessorCount) of \(info.processorCount) cores active · \(workerCount) scanner threads"
	}

	func scan(folder: URL) {
		Self.logger.log("scan:start folder=\(folder.path, privacy: .public)")
		// Ensure we have a security-scoped access to the folder while
		// scanning. Start access here and balance with a stop when the
		// scan task completes.
		let startedAccess = folder.startAccessingSecurityScopedResource()
		currentScan?.cancel()
		photos = []
		folderURL = folder
		isScanning = true
		let start = Date()
		scanStartDate = start
		lastScanDuration = nil

		Task.detached { await Telemetry.shared.startScan() }

		// Persist the folder so it can be restored on the next launch.
		WindowStateStore.shared.saveActiveFolder(folder)

		// Run the scanning driver off the main actor so the active scanning
		// work doesn't inherit the MainActor. UI updates (small publishes)
		// are still performed on the main actor.
		currentScan = Task.detached { [weak self] in
			defer {
				if startedAccess {
					folder.stopAccessingSecurityScopedResource()
				}
			}
			for await batch in PhotoLibrary.scanStream(folder: folder, batchSize: 256) {
				if Task.isCancelled { break }

				// Publish the batch to the UI on the main actor. Keep this
				// as a small, single hop to avoid prolonged main-thread work.
				await MainActor.run {
					self?.photos.append(contentsOf: batch)
				}

				// Get the published total on the main actor so we don't
				// reference main-actor-isolated state from this detached
				// context. Then log on the main actor and update telemetry
				// from the background task.
				let total = await MainActor.run { self?.photos.count ?? 0 }
				Self.logger.log("scan:batch yielded=\(batch.count, privacy: .public) total=\(total, privacy: .public)")
				await Telemetry.shared.recordFound(batch.count)
				await Telemetry.shared.recordBatchYield()

				// Kick off face processing for this batch in background.
				// Respect the user preference `enableFaceRecognition` (default
				// disabled). The FaceProcessor itself limits concurrency so we
				// can safely spawn a detached task per batch when enabled.
				let faceEnabled = UserDefaults.standard.bool(forKey: "enableFaceRecognition")
				if faceEnabled {
					Task.detached(priority: .utility) {
						Self.logger.log("scheduling face processing for batch of \(batch.count, privacy: .public) items")
						for item in batch {
							if Task.isCancelled { break }
							_ = await FaceProcessor.shared.process(file: item.url)
						}
					}
				} else {
					// Log that face processing was skipped due to user
					// preference.
					Self.logger.log("face processing skipped for batch (enableFaceRecognition=false)")
				}
			}

			// Finished scanning; update state on main actor.
			await MainActor.run {
				guard let self = self else { return }
				self.isScanning = false
				if !Task.isCancelled {
					let now = Date()
					self.lastScanDate = now
					self.lastScanDuration = now.timeIntervalSince(start)
					// Persist the discovered photo list to disk so the app can
					// restore quickly on subsequent launches without re-scanning.
					let snapshot = self.photos
					let duration = self.lastScanDuration ?? 0
					let snapshotCount = snapshot.count
					Task.detached(priority: .background) {
						PhotoLibrary.persistCachedSnapshot(snapshot, for: folder)
						Self.logger.log("scan:finished photos=\(snapshotCount, privacy: .public) duration=\(duration, privacy: .public)")
					}
					Task.detached { await Telemetry.shared.finishScan() }
				}
			}
		}
	}

	// MARK: - Persistent snapshot support

	/// Writes a lightweight snapshot (array of file paths and a timestamp)
	/// to the app's Application Support directory keyed by the folder path so
	/// the app can restore the photo list quickly at next launch without
	/// rescanning the file system.
	nonisolated static func persistCachedSnapshot(_ photos: [PhotoItem], for folder: URL) {
		let fm = FileManager.default
		guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
		let base = appSupport.appendingPathComponent("PictureViewer", isDirectory: true)
		do { try fm.createDirectory(at: base, withIntermediateDirectories: true) } catch { return }

		let key = Self.safeFilename(for: folder.path)
		let fileURL = base.appendingPathComponent(key).appendingPathExtension("json")

		let paths = photos.map { $0.url.path }
		let payload: [String: Any] = [
			"version": 1,
			"timestamp": ISO8601DateFormatter().string(from: Date()),
			"paths": paths
		]
		do {
			let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
			try data.write(to: fileURL, options: .atomic)
		} catch {
			// Best-effort persistence; failures are non-fatal.
		}
	}

	/// Persist a combined snapshot for multiple folders. This writes a
	/// single JSON file containing the list of paths and the list of source
	/// folder paths so the UI can restore a combined view quickly.
	nonisolated static func persistCombinedSnapshot(_ photos: [PhotoItem], for folders: [URL]) {
		let fm = FileManager.default
		guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
		let base = appSupport.appendingPathComponent("PictureViewer", isDirectory: true)
		do { try fm.createDirectory(at: base, withIntermediateDirectories: true) } catch { return }

		let fileURL = base.appendingPathComponent("combined_snapshot").appendingPathExtension("json")
		let paths = photos.map { $0.url.path }
		let foldersPaths = folders.map { $0.path }
		let payload: [String: Any] = [
			"version": 1,
			"timestamp": ISO8601DateFormatter().string(from: Date()),
			"folders": foldersPaths,
			"paths": paths
		]
		do {
			let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
			try data.write(to: fileURL, options: .atomic)
		} catch {
			// best-effort
		}
	}

	nonisolated static func loadCombinedSnapshot() -> ([URL], [URL])? {
		let fm = FileManager.default
		guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
		let base = appSupport.appendingPathComponent("PictureViewer", isDirectory: true)
		let fileURL = base.appendingPathComponent("combined_snapshot").appendingPathExtension("json")
		guard let data = try? Data(contentsOf: fileURL) else { return nil }
		guard let obj = try? JSONSerialization.jsonObject(with: data, options: []), let dict = obj as? [String: Any] else { return nil }
		let folderPaths = (dict["folders"] as? [String]) ?? []
		let paths = (dict["paths"] as? [String]) ?? []
		let folders = folderPaths.map { URL(fileURLWithPath: $0) }
		let urls = paths.map { URL(fileURLWithPath: $0) }
		return (urls, folders)
	}

	/// Append the results of scanning `folder` to the existing library.photos
	/// without replacing the current folder. This is intended for
	/// multi-folder scans where results from several folders are combined.
	nonisolated func appendScan(folder: URL) {
		let startedAccess = folder.startAccessingSecurityScopedResource()
		Task.detached { [weak self] in
			defer {
				if startedAccess { folder.stopAccessingSecurityScopedResource() }
			}
			for await batch in PhotoLibrary.scanStream(folder: folder, batchSize: 256) {
				if Task.isCancelled { break }
				await MainActor.run {
					self?.photos.append(contentsOf: batch)
				}
				let total = await MainActor.run { self?.photos.count ?? 0 }
				Self.logger.log("appendScan:batch yielded=\(batch.count, privacy: .public) total=\(total, privacy: .public)")
				await Telemetry.shared.recordFound(batch.count)
			}
		}
	}

	/// Attempts to load a previously saved snapshot for `folder`. Returns an
	/// array of URLs (may include files that no longer exist) or nil if there
	/// is no snapshot available.
	nonisolated static func loadCachedSnapshot(for folder: URL) -> [URL]? {
		let fm = FileManager.default
		guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
		let base = appSupport.appendingPathComponent("PictureViewer", isDirectory: true)
		let key = Self.safeFilename(for: folder.path)
		let fileURL = base.appendingPathComponent(key).appendingPathExtension("json")
		guard let data = try? Data(contentsOf: fileURL) else { return nil }
		guard let obj = try? JSONSerialization.jsonObject(with: data, options: []), let dict = obj as? [String: Any], let paths = dict["paths"] as? [String] else { return nil }
		return paths.map { URL(fileURLWithPath: $0) }
	}

	nonisolated static func safeFilename(for key: String) -> String {
		// Base64 the path then make it URL-safe so it can be used as a file name.
		let b64 = Data(key.utf8).base64EncodedString()
		let safe = b64.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
		return safe
	}

	// Simple actor that tracks seen file names (basename) and tells callers
	// whether a given name is unique. We dedupe by lowercased lastPathComponent
	// so the UI doesn't show multiple files with the same filename.
	actor FileNameDeduper {
		private var seen: Set<String> = []
		func isUnique(_ name: String) -> Bool {
			let key = name.lowercased()
			if seen.contains(key) { return false }
			seen.insert(key)
			return true
		}
	}

	nonisolated static func scanStream(folder: URL, batchSize: Int) -> AsyncStream<[PhotoItem]> {
		AsyncStream { continuation in
			let parent = Task.detached(priority: .userInitiated) {
				let workers = workerCount
				let coordinator = ScanCoordinator(workerCount: workers, root: folder)
				let deduper = FileNameDeduper()
				await withTaskGroup(of: Void.self) { group in
					for _ in 0..<workers {
						group.addTask {
							await runWorker(
								coordinator: coordinator,
								batchSize: batchSize,
								continuation: continuation,
								deduper: deduper
							)
						}
					}
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in
				parent.cancel()
			}
		}
	}

	nonisolated private static func runWorker(
		coordinator: ScanCoordinator,
		batchSize: Int,
		continuation: AsyncStream<[PhotoItem]>.Continuation,
		deduper: FileNameDeduper
	) async {
		let fm = FileManager.default
		let keys: [URLResourceKey] = [
			.isDirectoryKey,
			.isRegularFileKey,
			.contentTypeKey,
			.isSymbolicLinkKey,
		]
		let keySet = Set(keys)

		var batch: [PhotoItem] = []

		while !Task.isCancelled {
			guard let dir = await coordinator.dequeue() else { break }

			let contents: [URL]
			do {
				contents = try fm.contentsOfDirectory(
					at: dir,
					includingPropertiesForKeys: keys,
					options: [.skipsHiddenFiles, .skipsPackageDescendants]
				)
			} catch {
				continue
			}

			var subdirs: [URL] = []
			subdirs.reserveCapacity(8)

			for url in contents {
				if Task.isCancelled { break }
				guard let values = try? url.resourceValues(forKeys: keySet) else { continue }

				if values.isDirectory == true {
					// Don't follow directory symlinks — avoids cycles on large trees.
					if values.isSymbolicLink != true {
						subdirs.append(url)
					}
				} else if values.isRegularFile == true,
						  let type = values.contentType,
						  type.conforms(to: .image) {
					// Dedupe by filename (basename) so we don't show multiple
					// files with the same name in the UI. Keep the first
					// occurrence encountered by the scanner.
					let name = url.lastPathComponent
					if await deduper.isUnique(name) {
						batch.append(PhotoItem(url: url))
					} else {
						// Skip duplicates silently.
					}
					if batch.count >= batchSize {
						continuation.yield(batch)
						batch.removeAll(keepingCapacity: true)
					}
				}
			}

			if !subdirs.isEmpty {
				await coordinator.enqueue(subdirs)
			}
		}

		if !batch.isEmpty {
			continuation.yield(batch)
		}
	}
}

/// Shared work queue of directories for the parallel scanner.
/// Workers `dequeue` directories to process and `enqueue` any subdirectories
/// they discover. The coordinator detects termination when every worker is
/// idle and the queue is empty.
actor ScanCoordinator {
	private var queue: [URL] = []
	private var waiters: [CheckedContinuation<URL?, Never>] = []
	private var idleCount = 0
	private var finished = false
	private let workerCount: Int

	init(workerCount: Int, root: URL) {
		self.workerCount = workerCount
		self.queue = [root]
	}

	func enqueue(_ dirs: [URL]) {
		guard !finished else { return }
		queue.append(contentsOf: dirs)
		while !waiters.isEmpty, let url = queue.popLast() {
			let waiter = waiters.removeFirst()
			idleCount -= 1
			waiter.resume(returning: url)
		}
	}

	func dequeue() async -> URL? {
		if finished { return nil }
		if let url = queue.popLast() {
			return url
		}
		idleCount += 1
		if idleCount == workerCount {
			// Queue empty and every worker is idle → no more work.
			finished = true
			let toWake = waiters
			waiters.removeAll()
			for waiter in toWake {
				waiter.resume(returning: nil)
			}
			return nil
		}
		return await withCheckedContinuation { continuation in
			waiters.append(continuation)
		}
	}
}
