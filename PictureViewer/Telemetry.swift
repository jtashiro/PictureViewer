import Foundation
import os

/// Simple telemetry collector to measure scan/thumbnail/metadata rates.
actor Telemetry {
    static let shared = Telemetry()

    private let logger = Logger(subsystem: "com.example.PictureViewer", category: "telemetry")

    private var filesFound: Int = 0
    private var batchesYielded: Int = 0
    private var thumbnailsGenerated: Int = 0
    private var metadataReads: Int = 0

    private var scanStart: Date?

    func startScan() {
        filesFound = 0
        batchesYielded = 0
        thumbnailsGenerated = 0
        metadataReads = 0
        scanStart = Date()
        logger.log("scan:start")
    }

    func finishScan() {
        guard let start = scanStart else {
            logger.log("scan:finish (no start)")
            return
        }
        let duration = Date().timeIntervalSince(start)
        let filesPerSec = duration > 0 ? Double(filesFound) / duration : 0
        logger.log("scan:finish duration: \(duration) files: \(self.filesFound) files/sec: \(filesPerSec) batches: \(self.batchesYielded) thumbnails: \(self.thumbnailsGenerated) metadataReads: \(self.metadataReads)")
        scanStart = nil
    }

    func recordFound(_ count: Int) {
        filesFound += count
    }

    func recordBatchYield() {
        batchesYielded += 1
    }

    func recordThumbnail() {
        thumbnailsGenerated += 1
    }

    func recordMetadataRead() {
        metadataReads += 1
    }

    func snapshot() -> String {
        return "files=\(filesFound) batches=\(batchesYielded) thumbs=\(thumbnailsGenerated) meta=\(metadataReads)"
    }
}
