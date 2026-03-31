/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

#if os(iOS) || os(tvOS)
import XCTest
import UIKit
import OpenTelemetryApi
@testable import OpenTelemetrySdk
@testable import PulseKit

final class UIKitTapInstrumentationTests: XCTestCase {

    var logExporter: InMemoryLogRecordExporter!
    var loggerProvider: LoggerProviderSdk!
    var logger: OpenTelemetryApi.Logger!

    override func setUp() {
        super.setUp()
        logExporter = InMemoryLogRecordExporter()
        loggerProvider = LoggerProviderBuilder()
            .with(processors: [SimpleLogRecordProcessor(logRecordExporter: logExporter)])
            .build()
        logger = loggerProvider.get(instrumentationScopeName: "test.uikit.tap")
    }

    // MARK: - Click target detection

    func testUIControlIsClickTarget() {
        XCTAssertTrue(UIWindowSwizzler.isClickTarget(UIButton()))
        XCTAssertTrue(UIWindowSwizzler.isClickTarget(UISwitch()))
        XCTAssertTrue(UIWindowSwizzler.isClickTarget(UISegmentedControl()))
        XCTAssertTrue(UIWindowSwizzler.isClickTarget(UIStepper()))
    }

    func testTableViewCellIsClickTarget() {
        XCTAssertTrue(UIWindowSwizzler.isClickTarget(UITableViewCell()))
    }

    func testCollectionViewCellIsClickTarget() {
        let layout = UICollectionViewFlowLayout()
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        let cell = UICollectionViewCell()
        XCTAssertTrue(UIWindowSwizzler.isClickTarget(cell))
    }

    func testViewWithTapGestureRecognizerIsClickTarget() {
        let view = UIView()
        view.addGestureRecognizer(UITapGestureRecognizer())
        XCTAssertTrue(UIWindowSwizzler.isClickTarget(view))
    }

    func testPlainViewIsNotClickTarget() {
        XCTAssertFalse(UIWindowSwizzler.isClickTarget(UIView()))
    }

    func testUIScrollViewIsNotClickTargetEvenWithTapGesture() {
        let scroll = UIScrollView()
        scroll.addGestureRecognizer(UITapGestureRecognizer())
        XCTAssertFalse(UIWindowSwizzler.isClickTarget(scroll))
    }

    func testUITableViewIsNotClickTarget() {
        let table = UITableView()
        XCTAssertFalse(UIWindowSwizzler.isClickTarget(table))
    }

    func testUILabelIsNotClickTarget() {
        XCTAssertFalse(UIWindowSwizzler.isClickTarget(UILabel()))
    }

    func testViewWithPanGestureOnlyIsNotClickTarget() {
        let view = UIView()
        view.addGestureRecognizer(UIPanGestureRecognizer())
        XCTAssertFalse(UIWindowSwizzler.isClickTarget(view))
    }

    func testViewWithLongPressGestureRecognizerIsClickTarget() {
        let view = UIView()
        view.addGestureRecognizer(UILongPressGestureRecognizer())
        XCTAssertTrue(UIWindowSwizzler.isClickTarget(view))
    }

    func testViewWithSwipeGestureRecognizerIsClickTarget() {
        let view = UIView()
        view.addGestureRecognizer(UISwipeGestureRecognizer())
        XCTAssertTrue(UIWindowSwizzler.isClickTarget(view))
    }

    func testViewWithAccessibilityButtonTraitIsClickTarget() {
        let view = UIView()
        view.accessibilityTraits.insert(.button)
        XCTAssertTrue(UIWindowSwizzler.isClickTarget(view))
    }

    func testViewWithAccessibilityLinkTraitIsClickTarget() {
        let view = UIView()
        view.accessibilityTraits.insert(.link)
        XCTAssertTrue(UIWindowSwizzler.isClickTarget(view))
    }

    // MARK: - Label extraction: UILabel

    func testExtractLabelFromUILabel() {
        let label = UILabel()
        label.text = "Hello World"
        XCTAssertEqual(UIWindowSwizzler.extractLabel(from: label), "Hello World")
    }

    func testExtractLabelFromUILabelReturnsNilWhenEmpty() {
        let label = UILabel()
        label.text = ""
        XCTAssertNil(UIWindowSwizzler.extractLabel(from: label))
    }

    // MARK: - Label extraction: UIButton (direct UILabel child)

    func testExtractLabelFromUIButton() {
        let button = UIButton(type: .system)
        button.setTitle("Add to Cart", for: .normal)
        // Force layout so titleLabel.text is set
        button.layoutIfNeeded()
        let result = UIWindowSwizzler.extractLabel(from: button)
        XCTAssertEqual(result, "Add to Cart")
    }

    // MARK: - Label extraction: UISegmentedControl

    func testExtractLabelFromSegmentedControlReturnsSelectedSegment() {
        let seg = UISegmentedControl(items: ["Monthly", "Daily", "Weekly"])
        seg.selectedSegmentIndex = 0
        XCTAssertEqual(UIWindowSwizzler.extractLabel(from: seg), "Monthly")

        seg.selectedSegmentIndex = 2
        XCTAssertEqual(UIWindowSwizzler.extractLabel(from: seg), "Weekly")
    }

    func testExtractLabelFromSegmentedControlNotAllSegments() {
        let seg = UISegmentedControl(items: ["Monthly", "Daily", "Weekly"])
        seg.selectedSegmentIndex = 1
        let result = UIWindowSwizzler.extractLabel(from: seg)
        // Must be exactly "Daily", NOT "Monthly | Daily | Weekly"
        XCTAssertEqual(result, "Daily")
        XCTAssertFalse(result?.contains("|") ?? false)
    }

    // MARK: - Label extraction: accessibilityLabel fallback

    func testExtractLabelFallsBackToAccessibilityLabel() {
        let view = UIView()
        view.accessibilityLabel = "Settings Button"
        XCTAssertEqual(UIWindowSwizzler.extractLabel(from: view), "Settings Button")
    }

    func testExtractLabelPrefersUILabelOverAccessibilityLabel() {
        let container = UIView()
        let label = UILabel()
        label.text = "Direct Label"
        container.addSubview(label)
        container.accessibilityLabel = "Should Not Use This"
        // Direct UILabel child takes priority over accessibilityLabel
        XCTAssertEqual(UIWindowSwizzler.extractLabel(from: container), "Direct Label")
    }

    // MARK: - Label extraction: recursive scan

    func testExtractLabelRecursivelyCollectsTextFromDescendants() {
        let card = UIView()
        let title = UILabel(); title.text = "Galaxy S24 Ultra"
        let subtitle = UILabel(); subtitle.text = "Samsung"
        card.addSubview(title)
        card.addSubview(subtitle)

        let result = UIWindowSwizzler.extractLabel(from: card)
        XCTAssertEqual(result, "Galaxy S24 Ultra | Samsung")
    }

    func testExtractLabelCapsAtFiveSegments() {
        let container = UIView()
        for i in 1...7 {
            let label = UILabel(); label.text = "Segment \(i)"
            container.addSubview(label)
        }
        let result = UIWindowSwizzler.extractLabel(from: container) ?? ""
        let segments = result.components(separatedBy: " | ")
        XCTAssertLessThanOrEqual(segments.count, 5)
    }

    func testExtractLabelTruncatesResultOver200Chars() {
        let container = UIView()
        // Each segment is 50 chars; 5 segments + delimiters = well over 200
        for _ in 1...5 {
            let label = UILabel()
            label.text = String(repeating: "A", count: 50)
            container.addSubview(label)
        }
        let result = UIWindowSwizzler.extractLabel(from: container) ?? ""
        XCTAssertLessThanOrEqual(result.count, 200)
    }

    func testExtractLabelReturnsNilWhenNoLabelsFound() {
        let view = UIView()
        view.addSubview(UIView()) // no UILabel subviews
        XCTAssertNil(UIWindowSwizzler.extractLabel(from: view))
    }

    // MARK: - PII safety

    func testUITextFieldDoesNotCaptureTypedText() {
        let field = UITextField()
        field.text = "secret_password"
        field.accessibilityLabel = nil
        // Typed text must never be captured
        XCTAssertNil(UIWindowSwizzler.extractLabel(from: field))
    }

    func testUITextFieldCapturesAccessibilityLabelOnly() {
        let field = UITextField()
        field.text = "secret_password"
        field.accessibilityLabel = "Email Address"
        // Only developer-set label, not the typed text
        XCTAssertEqual(UIWindowSwizzler.extractLabel(from: field), "Email Address")
    }

    func testUITextViewDoesNotCaptureTypedText() {
        let textView = UITextView()
        textView.text = "user typed content"
        textView.accessibilityLabel = nil
        XCTAssertNil(UIWindowSwizzler.extractLabel(from: textView))
    }

    func testRecursiveScanSkipsTextInputSubviews() {
        let container = UIView()
        let safeLabel = UILabel(); safeLabel.text = "Safe"
        let field = UITextField(); field.text = "PII data"
        container.addSubview(safeLabel)
        container.addSubview(field)

        let result = UIWindowSwizzler.extractLabel(from: container)
        XCTAssertEqual(result, "Safe")
        XCTAssertFalse(result?.contains("PII data") ?? false)
    }

    // MARK: - Event emission

    func testEmitClickEventEmitsCorrectEventName() {
        let button = UIButton()
        UIWindowSwizzler.emitClickEvent(for: button, at: CGPoint(x: 10, y: 20), logger: logger, captureContext: false)

        let records = logExporter.getFinishedLogRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].eventName, "app.widget.click")
    }

    func testEmitClickEventSetsWidgetNameToClassName() {
        let button = UIButton()
        UIWindowSwizzler.emitClickEvent(for: button, at: .zero, logger: logger, captureContext: false)

        let record = logExporter.getFinishedLogRecords()[0]
        XCTAssertEqual(record.attributes["app.widget.name"], .string("UIButton"))
    }

    func testEmitClickEventSetsCoordinates() {
        let view = UIButton()
        UIWindowSwizzler.emitClickEvent(for: view, at: CGPoint(x: 142, y: 380), logger: logger, captureContext: false)

        let record = logExporter.getFinishedLogRecords()[0]
        XCTAssertEqual(record.attributes["app.screen.coordinate.x"], .int(142))
        XCTAssertEqual(record.attributes["app.screen.coordinate.y"], .int(380))
    }

    func testEmitClickEventIncludesLabelInContextWhenCaptureContextTrue() {
        let button = UIButton(type: .system)
        button.setTitle("Checkout", for: .normal)
        button.layoutIfNeeded()

        UIWindowSwizzler.emitClickEvent(for: button, at: .zero, logger: logger, captureContext: true)

        let record = logExporter.getFinishedLogRecords()[0]
        XCTAssertEqual(record.attributes["app.click.context"], .string("label=Checkout"))
    }

    func testEmitClickEventOmitsContextWhenCaptureContextFalse() {
        let button = UIButton(type: .system)
        button.setTitle("Checkout", for: .normal)
        button.layoutIfNeeded()

        UIWindowSwizzler.emitClickEvent(for: button, at: .zero, logger: logger, captureContext: false)

        let record = logExporter.getFinishedLogRecords()[0]
        XCTAssertNil(record.attributes["app.click.context"])
    }

    func testEmitClickEventOmitsContextWhenNoLabelFound() {
        let view = UIButton() // no title set
        UIWindowSwizzler.emitClickEvent(for: view, at: .zero, logger: logger, captureContext: true)

        let record = logExporter.getFinishedLogRecords()[0]
        XCTAssertNil(record.attributes["app.click.context"])
    }

    func testEmitClickEventSegmentedControlUsesSelectedSegmentLabel() {
        let seg = UISegmentedControl(items: ["Monthly", "Daily", "Weekly"])
        seg.selectedSegmentIndex = 2

        UIWindowSwizzler.emitClickEvent(for: seg, at: .zero, logger: logger, captureContext: true)

        let record = logExporter.getFinishedLogRecords()[0]
        XCTAssertEqual(record.attributes["app.click.context"], .string("label=Weekly"))
    }

    func testEmitClickEventDoesNotEmitAppWidgetId() {
        let button = UIButton()
        button.accessibilityIdentifier = "some_id"
        UIWindowSwizzler.emitClickEvent(for: button, at: .zero, logger: logger, captureContext: false)

        let record = logExporter.getFinishedLogRecords()[0]
        XCTAssertNil(record.attributes["app.widget.id"])
    }

    // MARK: - Config

    func testConfigDefaultsToEnabled() {
        let config = UIKitTapInstrumentationConfig()
        XCTAssertTrue(config.enabled)
        XCTAssertTrue(config.captureContext)
    }

    func testConfigCanBeDisabled() {
        var config = UIKitTapInstrumentationConfig()
        config.enabled(false)
        XCTAssertFalse(config.enabled)
    }

    func testConfigCaptureContextCanBeDisabled() {
        var config = UIKitTapInstrumentationConfig()
        config.captureContext(false)
        XCTAssertFalse(config.captureContext)
    }
}
#endif
