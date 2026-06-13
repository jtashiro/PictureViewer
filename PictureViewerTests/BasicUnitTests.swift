//
//  BasicUnitTests.swift
//  PictureViewerTests
//
//  Created by PictureViewer Team on 2026.
//

import XCTest
@testable import PictureViewer

final class BasicUnitTests: XCTestCase {

    // MARK: - AppWorkingDirectory Tests
    
    func testAppWorkingDirectoryConstantsExist() {
        // Test that the constants defined in AppWorkingDirectory are accessible
        XCTAssertTrue(AppWorkingDirectory.directoryPathKey == "appWorkingDirectoryPath")
        XCTAssertTrue(AppWorkingDirectory.directoryBookmarkKey == "appWorkingDirectoryBookmark")
        XCTAssertTrue(AppWorkingDirectory.userChosenKey == "appWorkingDirectoryUserChosen")
    }
    
    func testThumbnailCacheCanonicalSize() {
        // Test that canonical size constant is correct
        XCTAssertEqual(ThumbnailCache.canonicalSize, 512)
    }
    
    // MARK: - Utility Function Tests
    
    func testStringExtensions() {
        // Test basic string utility functions if any exist
        XCTAssertTrue(true) // Placeholder for actual functionality tests when available
    }
    
    func testURLConstruction() throws {
        // Basic URL construction tests
        let baseURL = AppWorkingDirectory.defaultBaseURL
        XCTAssertNotNil(baseURL)
        
        // Test that we can construct URLs from base
        let appDataURL = AppWorkingDirectory.appDataURL()
        XCTAssertNotNil(appDataURL)
        XCTAssertTrue(appDataURL.path.contains("AppData"))
    }
    
    func testThumbnailCacheInitialization() {
        // Test that thumbnail cache initializes correctly
        XCTAssertNotNil(ThumbnailCache.shared)
        
        // Verify shared instance is the same
        let cache1 = ThumbnailCache.shared
        let cache2 = ThumbnailCache.shared
        XCTAssertTrue(cache1 === cache2)
    }
}