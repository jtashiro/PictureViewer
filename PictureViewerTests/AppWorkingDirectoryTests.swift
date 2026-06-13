//
//  AppWorkingDirectoryTests.swift
//  PictureViewerTests
//
//  Created by PictureViewer Team on 2026.
//

import XCTest
@testable import PictureViewer

final class AppWorkingDirectoryTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        // Reset to default state before each test
        AppWorkingDirectory.resetToDefault()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        AppWorkingDirectory.resetToDefault()
    }

    func testDefaultBaseURL() throws {
        // Test that default base URL is properly constructed
        let defaultURL = AppWorkingDirectory.defaultBaseURL
        XCTAssertNotNil(defaultURL)
        
        // Should contain PictureViewer in the path
        XCTAssertTrue(defaultURL.path.contains("PictureViewer"))
        
        // Should be under application support directory or home directory
        XCTAssertTrue(
            defaultURL.path.contains("/Library/Application Support/") ||
            defaultURL.path.contains("/Users/")
        )
    }

    func testIsLegacyTemporaryDefault() throws {
        // Test legacy temporary default detection
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("PictureViewer", isDirectory: true)
        XCTAssertTrue(AppWorkingDirectory.isLegacyTemporaryDefault(tempURL))
        
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("PictureViewer", isDirectory: true)
        XCTAssertFalse(AppWorkingDirectory.isLegacyTemporaryDefault(appSupportURL))
    }

    func testBaseURLWithNoSet() throws {
        // Test baseURL when no bookmark or path has been set
        let baseURL = AppWorkingDirectory.baseURL
        XCTAssertNotNil(baseURL)
        
        // Should default to the standard defaultBaseURL 
        XCTAssertEqual(baseURL, AppWorkingDirectory.defaultBaseURL)
    }

    func testSetAndGetBaseURL() throws {
        // Test setting and getting a custom base URL
        let testURL = FileManager.default.temporaryDirectory.appendingPathComponent("TestWorkingDirectory", isDirectory: true)
        
        // Ensure directory exists or can be created
        try? FileManager.default.createDirectory(at: testURL, withIntermediateDirectories: true)
        
        AppWorkingDirectory.setBaseURL(testURL, userChosen: true)
        
        let retrievedURL = AppWorkingDirectory.baseURL
        XCTAssertEqual(retrievedURL, testURL)
        
        // Check if it's marked as user chosen
        XCTAssertTrue(AppWorkingDirectory.isUserChosen)
    }

    func testResetToDefault() throws {
        // Test resetting to default after setting a custom URL
        let testURL = FileManager.default.temporaryDirectory.appendingPathComponent("TestReset", isDirectory: true)
        try? FileManager.default.createDirectory(at: testURL, withIntermediateDirectories: true)
        
        AppWorkingDirectory.setBaseURL(testURL, userChosen: true)
        AppWorkingDirectory.resetToDefault()
        
        // After reset, should return to default
        XCTAssertEqual(AppWorkingDirectory.baseURL, AppWorkingDirectory.defaultBaseURL)
        XCTAssertFalse(AppWorkingDirectory.isUserChosen)
    }

    func testEnsureAccess() throws {
        // Test access ensuring functionality
        let result = AppWorkingDirectory.ensureAccess()
        XCTAssertTrue(result)
    }
    
    func testAppDataDirectories() throws {
        // Test app data directory functions
        let appDataURL = AppWorkingDirectory.appDataURL()
        XCTAssertNotNil(appDataURL)
        
        let thumbnailsURL = AppWorkingDirectory.thumbnailsCacheURL()
        XCTAssertNotNil(thumbnailsURL)
        
        let sidecarsURL = AppWorkingDirectory.metadataSidecarsURL()
        XCTAssertNotNil(sidecarsURL)
        
        let facesURL = AppWorkingDirectory.facesDataURL()
        XCTAssertNotNil(facesURL)
        
        let sqliteManifestsURL = AppWorkingDirectory.sqliteManifestsURL()
        XCTAssertNotNil(sqliteManifestsURL)
    }
}