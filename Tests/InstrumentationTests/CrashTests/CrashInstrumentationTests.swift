/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import XCTest
import OpenTelemetrySdk
import OpenTelemetryApi
@testable import Crashes

final class CrashInstrumentationTests: XCTestCase {

    // MARK: - extractCrashMessage

    func testExtractCrashMessageWithExceptionType() {
        let stackTrace = """
        Exception Type:  EXC_BREAKPOINT (SIGTRAP)
        Thread 0 Crashed:
        0   libswiftCore.dylib            0x000000019ed5c8c4 $ss17_assertionFailure + 172
        """

        let result = CrashInstrumentation.extractCrashMessage(from: stackTrace)
        XCTAssertEqual(result, "EXC_BREAKPOINT (SIGTRAP) detected on thread 0 at libswiftCore.dylib + 172")
    }

    func testExtractCrashMessageWithBadAccess() {
        let stackTrace = """
        Exception Type:  EXC_BAD_ACCESS (SIGSEGV)
        Thread 2 Crashed:
        0   MyApp                         0x0000000104abc123 main + 456
        """

        let result = CrashInstrumentation.extractCrashMessage(from: stackTrace)
        XCTAssertEqual(result, "EXC_BAD_ACCESS (SIGSEGV) detected on thread 2 at MyApp + 456")
    }

    func testExtractCrashMessageWithoutExceptionType() {
        let stackTrace = """
        Thread 0 Crashed:
        0   libswiftCore.dylib            0x000000019ed5c8c4 $ss17_assertionFailure + 172
        """

        let result = CrashInstrumentation.extractCrashMessage(from: stackTrace)
        XCTAssertEqual(result, "Unknown exception detected on thread 0 at libswiftCore.dylib + 172")
    }

    func testExtractCrashMessageWithDifferentThread() {
        let stackTrace = """
        Exception Type:  EXC_CRASH (SIGABRT)
        Thread 5 Crashed:
        0   SomeFramework                 0x00000001f14e1a90 someFunction + 8
        """

        let result = CrashInstrumentation.extractCrashMessage(from: stackTrace)
        XCTAssertEqual(result, "EXC_CRASH (SIGABRT) detected on thread 5 at SomeFramework + 8")
    }

    func testExtractCrashMessageEmptyString() {
        XCTAssertEqual(
            CrashInstrumentation.extractCrashMessage(from: ""),
            "Unknown exception detected at unknown location"
        )
    }

    func testExtractCrashMessageNoThreadCrashed() {
        let stackTrace = "Some other content\nThread 1:\n0   libsystem_kernel.dylib"
        XCTAssertEqual(
            CrashInstrumentation.extractCrashMessage(from: stackTrace),
            "Unknown exception detected at unknown location"
        )
    }

    func testExtractCrashMessageMalformedCrashedLine() {
        let stackTrace = "Thread Crashed:\n0   SomeFramework"
        XCTAssertEqual(
            CrashInstrumentation.extractCrashMessage(from: stackTrace),
            "Unknown exception detected at unknown location"
        )
    }

    func testExtractCrashMessageExceptionTypeOnly() {
        let stackTrace = """
        Exception Type:  EXC_CRASH (SIGABRT)
        """

        let result = CrashInstrumentation.extractCrashMessage(from: stackTrace)
        XCTAssertEqual(result, "EXC_CRASH (SIGABRT) detected at unknown location")
    }

    func testExtractCrashMessageWithWhitespaceHandling() {
        let stackTrace = """
        Exception Type:  EXC_BAD_ACCESS (SIGSEGV)
        Thread 2 Crashed:
        0     MyFramework     \t\t\t    0x123456789    myFunction    +    123
        """

        let result = CrashInstrumentation.extractCrashMessage(from: stackTrace)
        XCTAssertEqual(result, "EXC_BAD_ACCESS (SIGSEGV) detected on thread 2 at MyFramework + 123")
    }

    // MARK: - CrashReportParser

    func testParseNSException() {
        let json: [String: Any] = [
            "crash": [
                "error": [
                    "nsexception": [
                        "name": "NSRangeException",
                        "reason": "index 10 beyond bounds [0 .. 2]"
                    ]
                ],
                "threads": [
                    [
                        "index": 0,
                        "crashed": true,
                        "dispatch_queue": "com.apple.main-thread",
                        "backtrace": ["contents": []]
                    ]
                ]
            ]
        ]

        let parsed = CrashReportParser.parse(dictionary: json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.exceptionType, "NSRangeException")
        XCTAssertEqual(parsed?.exceptionMessage, "index 10 beyond bounds [0 .. 2]")
        XCTAssertEqual(parsed?.threadId, "0")
        XCTAssertEqual(parsed?.threadName, "com.apple.main-thread")
    }

    func testParseSignalCrash() {
        let json: [String: Any] = [
            "crash": [
                "error": [
                    "signal": [
                        "name": "SIGABRT",
                        "code": 0
                    ]
                ],
                "diagnosis": "Abort trap triggered",
                "threads": [
                    [
                        "index": 3,
                        "crashed": true,
                        "name": "com.dispatch.worker.7",
                        "backtrace": ["contents": []]
                    ]
                ]
            ]
        ]

        let parsed = CrashReportParser.parse(dictionary: json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.exceptionType, "SIGABRT")
        XCTAssertEqual(parsed?.exceptionMessage, "Abort trap triggered")
        XCTAssertEqual(parsed?.threadId, "3")
        XCTAssertEqual(parsed?.threadName, "com.dispatch.worker.7")
    }

    func testParseMachException() {
        let json: [String: Any] = [
            "crash": [
                "error": [
                    "mach": [
                        "exception_name": "EXC_BAD_ACCESS",
                        "exception": 1
                    ]
                ],
                "diagnosis": "Attempted to dereference null pointer",
                "threads": [
                    ["index": 0, "crashed": false, "dispatch_queue": "com.apple.main-thread"],
                    ["index": 1, "crashed": true, "name": "WorkerThread"]
                ]
            ]
        ]

        let parsed = CrashReportParser.parse(dictionary: json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(parsed?.exceptionMessage, "Attempted to dereference null pointer")
        XCTAssertEqual(parsed?.threadId, "1")
        XCTAssertEqual(parsed?.threadName, "WorkerThread")
    }

    func testParseSignalWithNoDiagnosis() {
        let json: [String: Any] = [
            "crash": [
                "error": [
                    "signal": [
                        "name": "SIGSEGV",
                        "code": 11
                    ]
                ],
                "threads": [
                    ["index": 0, "crashed": true, "dispatch_queue": "com.apple.main-thread"]
                ]
            ]
        ]

        let parsed = CrashReportParser.parse(dictionary: json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.exceptionType, "SIGSEGV")
        XCTAssertEqual(parsed?.exceptionMessage, "SIGSEGV (code: 11)")
        XCTAssertEqual(parsed?.threadId, "0")
    }

    func testParseMissingCrashSection() {
        let json: [String: Any] = ["report": ["timestamp": "2025-01-01"]]
        XCTAssertNil(CrashReportParser.parse(dictionary: json))
    }

    func testParseEmptyDictionary() {
        XCTAssertNil(CrashReportParser.parse(dictionary: [:]))
    }

    func testParseNoThreads() {
        let json: [String: Any] = [
            "crash": [
                "error": [
                    "nsexception": [
                        "name": "TestException",
                        "reason": "test"
                    ]
                ]
            ]
        ]

        let parsed = CrashReportParser.parse(dictionary: json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.exceptionType, "TestException")
        XCTAssertEqual(parsed?.threadId, "0")
        XCTAssertEqual(parsed?.threadName, "unknown")
    }

    func testParseNoCrashedThread() {
        let json: [String: Any] = [
            "crash": [
                "error": ["signal": ["name": "SIGABRT", "code": 0]],
                "threads": [
                    ["index": 0, "crashed": false, "dispatch_queue": "com.apple.main-thread"],
                    ["index": 1, "crashed": false, "name": "worker"]
                ]
            ]
        ]

        let parsed = CrashReportParser.parse(dictionary: json)
        XCTAssertNotNil(parsed)
        // Falls back to first thread when none marked crashed
        XCTAssertEqual(parsed?.threadId, "0")
        XCTAssertEqual(parsed?.threadName, "com.apple.main-thread")
    }

    func testParseFromJsonString() {
        let jsonString = """
        {
            "crash": {
                "error": {
                    "nsexception": {
                        "name": "TestCrashException",
                        "reason": "Test reason"
                    }
                },
                "threads": [
                    {
                        "index": 0,
                        "crashed": true,
                        "dispatch_queue": "com.apple.main-thread"
                    }
                ]
            }
        }
        """

        let parsed = CrashReportParser.parse(jsonString: jsonString)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.exceptionType, "TestCrashException")
        XCTAssertEqual(parsed?.exceptionMessage, "Test reason")
    }

    // MARK: - CrashAttributes

    func testCrashAttributeKeys() {
        XCTAssertEqual(CrashAttributes.exceptionMessage, "exception.message")
        XCTAssertEqual(CrashAttributes.exceptionType, "exception.type")
        XCTAssertEqual(CrashAttributes.exceptionStacktrace, "exception.stacktrace")
        XCTAssertEqual(CrashAttributes.threadId, "thread.id")
        XCTAssertEqual(CrashAttributes.threadName, "thread.name")
    }
}
