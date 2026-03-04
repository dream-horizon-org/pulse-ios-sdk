/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Unit tests for project ID prefix extraction.
 */

import XCTest
@testable import PulseKit

final class ProjectIdParsingTests: XCTestCase {

    func testWhenProjectIdContainsHyphenShouldReturnPrefixBeforeHyphen() {
        let projectId = "tenant123-7876796bhbghb"
        let result = PulseKit.extractProjectID(from: projectId)
        XCTAssertEqual(result, "tenant123")
    }

    func testWhenProjectIdHasNoHyphenShouldReturnOriginalId() {
        let projectId = "simpleid"
        let result = PulseKit.extractProjectID(from: projectId)
        XCTAssertEqual(result, "simpleid")
    }

    func testWhenProjectIdContainsMultipleHyphensShouldReturnPrefixBeforeFirstHyphen() {
        let projectId = "tenant123-7876796bhbghb-extra-suffix"
        let result = PulseKit.extractProjectID(from: projectId)
        XCTAssertEqual(result, "tenant123")
    }

    func testWhenHyphenIsAtStartOfProjectIdShouldReturnOriginalId() {
        let projectId = "-tenant123"
        let result = PulseKit.extractProjectID(from: projectId)
        XCTAssertEqual(result, "-tenant123")
    }

    func testWhenProjectIdIsEmptyStringShouldReturnEmptyString() {
        let projectId = ""
        let result = PulseKit.extractProjectID(from: projectId)
        XCTAssertEqual(result, "")
    }

    func testWhenProjectIdHasSingleCharacterBeforeHyphenShouldReturnThatCharacter() {
        let projectId = "a-123456"
        let result = PulseKit.extractProjectID(from: projectId)
        XCTAssertEqual(result, "a")
    }

    func testWhenProjectIdIsOnlyHyphenShouldReturnHyphen() {
        let projectId = "-"
        let result = PulseKit.extractProjectID(from: projectId)
        XCTAssertEqual(result, "-")
    }

    func testWhenProjectIdContainsNumbersAndLettersShouldReturnPrefixCorrectly() {
        let projectId = "project123-abc456def"
        let result = PulseKit.extractProjectID(from: projectId)
        XCTAssertEqual(result, "project123")
    }

    func testWhenProjectIdPrefixContainsUnderscoresShouldReturnPrefixWithUnderscores() {
        let projectId = "tenant_123-7876796bhbghb"
        let result = PulseKit.extractProjectID(from: projectId)
        XCTAssertEqual(result, "tenant_123")
    }
}
