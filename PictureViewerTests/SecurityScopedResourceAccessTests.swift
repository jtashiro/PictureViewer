//
//  SecurityScopedResourceAccessTests.swift
//  PictureViewerTests
//
//  Created by PictureViewer Team on 2026.
//

import XCTest
@testable import PictureViewer

final class SecurityScopedResourceAccessTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testEnsureAccess() throws {
        // Test that ensureAccess function works
        let result = SecurityScopedResourceAccess.ensureAccess(for: AppWorkingDirectory.baseURL)
        XCTAssertTrue(result) // Should succeed for default directory
    }
    
    func testProbesWritableDirectory() throws {
        // Test that probesWritableDirectory function works
        let result = SecurityScopedResourceAccess.probesWritableDirectory(AppWorkingDirectory.baseURL)
        XCTAssertTrue(result) // Should succeed for default directory
    }
}