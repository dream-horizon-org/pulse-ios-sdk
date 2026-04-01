/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi

/// Handles all click event emission for UIKit tap instrumentation:
/// buffers taps, detects rage clusters, and emits good / dead / rage events.
internal class ClickEventEmitter {
    private let logger: OpenTelemetryApi.Logger
    
    init(logger: OpenTelemetryApi.Logger) {
        self.logger = logger
    }
    
    func emitGoodClick(_ click: PendingClick) {
        var attrs: [String: AttributeValue] = [
            PulseAttributes.clickType: .string(PulseAttributes.ClickTypeValues.good),
            "app.widget.name": .string(click.widgetName ?? ""),
            "app.widget.id": .string(click.widgetId ?? ""),
            "app.screen.coordinate.x": .int(Int(click.x)),
            "app.screen.coordinate.y": .int(Int(click.y)),
        ]
        
        if let context = click.clickContext {
            attrs["app.click.context"] = .string(context)
        }
        
        applyViewportAttrs(&attrs, click.viewportWidthPt, click.viewportHeightPt, click.x, click.y)
        
        // Log good click for debugging
        let normX = Double(click.x) / Double(click.viewportWidthPt)
        let normY = Double(click.y) / Double(click.viewportHeightPt)
        let contextStr = click.clickContext ?? "none"
        PulseLogger.log("[GOOD_CLICK] type=good | widget=\(click.widgetName ?? "unknown") | coords=(\(Int(click.x)),\(Int(click.y))) | norm=(\(String(format: "%.3f", normX)),\(String(format: "%.3f", normY))) | context=\(contextStr)")
        
        let timestamp = Date(timeIntervalSince1970: TimeInterval(click.tapEpochMs) / 1000.0)
        let record = logger.logRecordBuilder()
            .setEventName("app.widget.click")
            .setTimestamp(timestamp)
            .setAttributes(attrs)
        record.emit()
    }
    
    func emitDeadClick(_ click: PendingClick) {
        var attrs: [String: AttributeValue] = [
            PulseAttributes.clickType: .string(PulseAttributes.ClickTypeValues.dead),
            "app.screen.coordinate.x": .int(Int(click.x)),
            "app.screen.coordinate.y": .int(Int(click.y)),
        ]
        
        applyViewportAttrs(&attrs, click.viewportWidthPt, click.viewportHeightPt, click.x, click.y)
        
        // Log dead click for debugging
        let normX = Double(click.x) / Double(click.viewportWidthPt)
        let normY = Double(click.y) / Double(click.viewportHeightPt)
        PulseLogger.log("[DEAD_CLICK] type=dead | coords=(\(Int(click.x)),\(Int(click.y))) | norm=(\(String(format: "%.3f", normX)),\(String(format: "%.3f", normY))) | viewport=\(click.viewportWidthPt)x\(click.viewportHeightPt)")
        
        let timestamp = Date(timeIntervalSince1970: TimeInterval(click.tapEpochMs) / 1000.0)
        let record = logger.logRecordBuilder()
            .setEventName("app.widget.click")
            .setTimestamp(timestamp)
            .setAttributes(attrs)
        record.emit()
    }
    
    func emitRageClick(_ rage: RageEvent) {
        let clickType = rage.hasTarget ? PulseAttributes.ClickTypeValues.good : PulseAttributes.ClickTypeValues.dead
        var attrs: [String: AttributeValue] = [
            PulseAttributes.clickType: .string(clickType),
            PulseAttributes.clickIsRage: .bool(true),
            PulseAttributes.clickRageCount: .int(rage.count),
            "app.screen.coordinate.x": .int(Int(rage.x)),
            "app.screen.coordinate.y": .int(Int(rage.y)),
        ]
        
        if let name = rage.widgetName {
            attrs["app.widget.name"] = .string(name)
        }
        if let id = rage.widgetId {
            attrs["app.widget.id"] = .string(id)
        }
        if let context = rage.clickContext {
            attrs["app.click.context"] = .string(context)
        }
        
        applyViewportAttrs(&attrs, rage.viewportWidthPt, rage.viewportHeightPt, rage.x, rage.y)
        
        // Log rage click for debugging
        let normX = Double(rage.x) / Double(rage.viewportWidthPt)
        let normY = Double(rage.y) / Double(rage.viewportHeightPt)
        let rageTypeStr = rage.hasTarget ? "good" : "dead"
        PulseLogger.log("[RAGE_CLICK] type=\(rageTypeStr) | rage_count=\(rage.count) | widget=\(rage.widgetName ?? "unknown") | coords=(\(Int(rage.x)),\(Int(rage.y))) | norm=(\(String(format: "%.3f", normX)),\(String(format: "%.3f", normY)))")
        
        let timestamp = Date(timeIntervalSince1970: TimeInterval(rage.tapEpochMs) / 1000.0)
        let record = logger.logRecordBuilder()
            .setEventName("app.widget.click")
            .setTimestamp(timestamp)
            .setAttributes(attrs)
        record.emit()
    }
    
    private func applyViewportAttrs(_ attrs: inout [String: AttributeValue], _ widthPt: Int, _ heightPt: Int, _ x: Float, _ y: Float) {
        if widthPt > 0 && heightPt > 0 {
            attrs[PulseAttributes.deviceScreenWidth] = .int(widthPt)
            attrs[PulseAttributes.deviceScreenHeight] = .int(heightPt)
            attrs[PulseAttributes.appScreenCoordinateNx] = .double(Double(x) / Double(widthPt))
            attrs[PulseAttributes.appScreenCoordinateNy] = .double(Double(y) / Double(heightPt))
        } 
    }
}
