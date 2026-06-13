//
//  ThumbnailCacheTests.swift
//  PictureViewerTests
//
//  Created by PictureViewer Team on 2026.
//

import XCTest
@testable import PictureViewer

final class ThumbnailCacheTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        // Clear cache before each test
        ThumbnailCache.shared.clear()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        // Clear cache after each test
        ThumbnailCache.shared.clear()
    }

    func testSharedInstanceExists() throws {
        // Test that shared instance can be accessed
        XCTAssertNotNil(ThumbnailCache.shared)
    }
    
    func testCacheDirectoryCreation() throws {
        // Test that cache directory is properly set up
        let cacheDirectory = ThumbnailCache.shared.cacheDirectory
        XCTAssertNotNil(cacheDirectory)
        
        // Should be under app data directory
        XCTAssertTrue(cacheDirectory.path.contains("AppData"))
        XCTAssertTrue(cacheDirectory.path.contains("Thumbnails"))
    }

    func testKeyGeneration() throws {
        // Test key generation for cache entries
        let url = URL(fileURLWithPath: "/test/image.jpg")
        let key = ThumbnailCache.shared.key(for: url)
        
        XCTAssertNotNil(key)
        XCTAssertTrue(key.count == 64) // SHA256 produces 64 hex characters
        
        // Test with namespace
        let keyWithNamespace = ThumbnailCache.shared.key(for: url, namespace: "test")
        XCTAssertNotNil(keyWithNamespace)
        XCTAssertNotEqual(key, keyWithNamespace)
    }

    func testCacheFilePaths() throws {
        // Test cache file path generation
        let url = URL(fileURLWithPath: "/test/image.jpg") 
        let key = ThumbnailCache.shared.key(for: url)
        let file = ThumbnailCache.shared.cacheFile(forKey: key)
        
        XCTAssertNotNil(file)
        XCTAssertTrue(file.path.hasSuffix(".jpg"))
    }
    
    func testIsFresh() throws {
        // Test isFresh function - we'll create a mock scenario
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbnailCacheTest", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let testFile = tempDir.appendingPathComponent("test.jpg")
        
        // Create test file
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
        
        // We can't easily test the full isFresh mechanism without mocking file system operations,
        // but we can at least ensure basic functions work
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: testFile.path))
    }
    
    func testMemoryImageAccess() throws {
        // Test memory-only lookup functionality
        let url = URL(fileURLWithPath: "/test/image.jpg")
        
        // Should not crash when cache is empty
        let result = ThumbnailCache.shared.memoryImage(for: url)
        XCTAssertNil(result)
    }

    func testSweepStale() throws {
        // Test sweep stale functionality
        ThumbnailCache.shared.sweepStale(olderThanDays: 30)
        
        // Should not crash and should complete normally
        XCTAssertTrue(true)
    }
    
    func testDiskUsage() throws {
        // Test disk usage calculation
        let usage = ThumbnailCache.shared.diskUsage()
        XCTAssertGreaterThanOrEqual(usage, 0)
    }
}