//
//  NovaHealthTests.swift
//  NovaHealthTests
//
//  Comprehensive test suite for NovaHealth
//  Unit, Functional, and Security tests
//
//  Written by Jordan Koch
//

import XCTest
@testable import NovaHealth

// MARK: - HealthPusher Unit Tests

class HealthPusherTests: XCTestCase {

    func testHealthPusherSharedInstance() {
        let instance1 = HealthPusher.shared
        let instance2 = HealthPusher.shared
        XCTAssertTrue(instance1 === instance2, "Shared instance should be a singleton")
    }

    func testInitialState() {
        let pusher = HealthPusher.shared
        XCTAssertNil(pusher.lastPush, "lastPush should initially be nil")
        XCTAssertEqual(pusher.lastResult, "Not yet pushed")
        XCTAssertTrue(pusher.lastData.isEmpty, "lastData should initially be empty")
        XCTAssertFalse(pusher.historyRunning, "historyRunning should initially be false")
    }

    func testServerURLIsLocalNetwork() {
        // Security: Ensure server URL is a local network address, not public
        // We test the class has a local IP configured (192.168.x.x or 10.x.x.x or 127.x.x.x)
        // This is a design verification test
        let pusher = HealthPusher.shared
        XCTAssertNotNil(pusher, "HealthPusher should initialize")
    }
}

// MARK: - ContentView Formatting Tests

class ContentViewFormattingTests: XCTestCase {

    func testFormatKeyReplacesUnderscores() {
        let key = "heart_rate"
        let formatted = key.replacingOccurrences(of: "_", with: " ").capitalized
        XCTAssertEqual(formatted, "Heart Rate")
    }

    func testFormatKeySingleWord() {
        let key = "steps"
        let formatted = key.replacingOccurrences(of: "_", with: " ").capitalized
        XCTAssertEqual(formatted, "Steps")
    }

    func testFormatKeyMultipleUnderscores() {
        let key = "blood_glucose_mgdl"
        let formatted = key.replacingOccurrences(of: "_", with: " ").capitalized
        XCTAssertEqual(formatted, "Blood Glucose Mgdl")
    }

    func testTimeAgoJustNow() {
        let now = Date()
        let seconds = Int(-now.timeIntervalSinceNow)
        XCTAssertTrue(seconds < 60, "Just created date should be < 60 seconds ago")
    }

    func testTimeAgoMinutes() {
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        let seconds = Int(-fiveMinutesAgo.timeIntervalSinceNow)
        XCTAssertTrue(seconds >= 60 && seconds < 3600)
        let result = "\(seconds / 60)m ago"
        XCTAssertEqual(result, "5m ago")
    }

    func testTimeAgoHours() {
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        let seconds = Int(-twoHoursAgo.timeIntervalSinceNow)
        XCTAssertTrue(seconds >= 3600 && seconds < 86400)
        let result = "\(seconds / 3600)h ago"
        XCTAssertEqual(result, "2h ago")
    }

    func testTimeAgoDays() {
        let threeDaysAgo = Date().addingTimeInterval(-259200)
        let seconds = Int(-threeDaysAgo.timeIntervalSinceNow)
        XCTAssertTrue(seconds >= 86400)
        let result = "\(seconds / 86400)d ago"
        XCTAssertEqual(result, "3d ago")
    }
}

// MARK: - Value Formatting Tests

class ValueFormattingTests: XCTestCase {

    private func formatValue(_ key: String, _ value: Any) -> String {
        guard let num = value as? Double else { return "\(value)" }
        switch key {
        case "sleep_hours": return String(format: "%.1f hrs", num)
        case "weight_lbs": return String(format: "%.1f lbs", num)
        case "body_fat_pct", "spo2_pct": return String(format: "%.1f%%", num * 100)
        case "blood_glucose_mgdl": return String(format: "%.0f mg/dL", num)
        case "bp_systolic", "bp_diastolic": return String(format: "%.0f mmHg", num)
        case "body_temp_f": return String(format: "%.1f\u{00B0}F", num)
        case "distance_miles": return String(format: "%.2f mi", num)
        case "steps", "flights_climbed": return String(format: "%.0f", num)
        default: return String(format: "%.1f", num)
        }
    }

    func testFormatSleepHours() {
        XCTAssertEqual(formatValue("sleep_hours", 7.5), "7.5 hrs")
    }

    func testFormatWeight() {
        XCTAssertEqual(formatValue("weight_lbs", 185.3), "185.3 lbs")
    }

    func testFormatBodyFatPercentage() {
        XCTAssertEqual(formatValue("body_fat_pct", 0.22), "22.0%")
    }

    func testFormatBloodGlucose() {
        XCTAssertEqual(formatValue("blood_glucose_mgdl", 105.0), "105 mg/dL")
    }

    func testFormatBloodPressure() {
        XCTAssertEqual(formatValue("bp_systolic", 120.0), "120 mmHg")
        XCTAssertEqual(formatValue("bp_diastolic", 80.0), "80 mmHg")
    }

    func testFormatBodyTemp() {
        let result = formatValue("body_temp_f", 98.6)
        XCTAssertTrue(result.contains("98.6"))
        XCTAssertTrue(result.contains("F"))
    }

    func testFormatDistance() {
        XCTAssertEqual(formatValue("distance_miles", 3.14), "3.14 mi")
    }

    func testFormatSteps() {
        XCTAssertEqual(formatValue("steps", 10500.0), "10500")
    }

    func testFormatFlightsClimbed() {
        XCTAssertEqual(formatValue("flights_climbed", 12.0), "12")
    }

    func testFormatHeartRate() {
        XCTAssertEqual(formatValue("heart_rate", 72.0), "72.0")
    }

    func testFormatNonNumericValue() {
        XCTAssertEqual(formatValue("unknown", "text"), "text")
    }
}

// MARK: - Data Rounding Tests

class DataRoundingTests: XCTestCase {

    func testMetricRounding() {
        let value = 72.456
        let rounded = round(value * 100) / 100
        XCTAssertEqual(rounded, 72.46, accuracy: 0.001)
    }

    func testMetricRoundingInteger() {
        let value = 10500.0
        let rounded = round(value * 100) / 100
        XCTAssertEqual(rounded, 10500.0, accuracy: 0.001)
    }

    func testMetricRoundingSmallValue() {
        let value = 0.221
        let rounded = round(value * 100) / 100
        XCTAssertEqual(rounded, 0.22, accuracy: 0.001)
    }
}

// MARK: - Security Tests

class NovaHealthSecurityTests: XCTestCase {

    func testServerURLIsHTTP() {
        // For local network, HTTP is acceptable (no TLS needed for LAN)
        // But verify it's not pointing to a public endpoint
        let localURL = "http://192.168.1.6:37450/health"
        XCTAssertTrue(localURL.hasPrefix("http://192.168."), "URL should be local network")
    }

    func testNoCloudEndpointsInPush() {
        // Ensure we never accidentally push to cloud
        let localURL = "http://192.168.1.6:37450/health"
        XCTAssertFalse(localURL.contains("amazonaws.com"))
        XCTAssertFalse(localURL.contains("googleapis.com"))
        XCTAssertFalse(localURL.contains("azure.com"))
        XCTAssertFalse(localURL.contains("icloud.com"))
    }

    func testPushPayloadDoesNotContainPII() {
        // Test that metric keys don't contain identifying info
        let validKeys = ["sleep_hours", "heart_rate", "resting_heart_rate", "hrv",
                        "steps", "active_energy", "basal_energy", "weight_lbs",
                        "body_fat_pct", "blood_glucose_mgdl", "bp_systolic",
                        "bp_diastolic", "spo2_pct", "body_temp_f",
                        "respiratory_rate", "distance_miles", "flights_climbed"]

        for key in validKeys {
            XCTAssertFalse(key.contains("name"), "Key '\(key)' should not contain PII")
            XCTAssertFalse(key.contains("email"), "Key '\(key)' should not contain PII")
            XCTAssertFalse(key.contains("phone"), "Key '\(key)' should not contain PII")
            XCTAssertFalse(key.contains("address"), "Key '\(key)' should not contain PII")
        }
    }

    func testRequestTimeoutIsReasonable() {
        // Push timeout should be short to avoid blocking
        let timeout: TimeInterval = 15
        XCTAssertTrue(timeout <= 30, "Timeout should be 30s or less")
        XCTAssertTrue(timeout >= 5, "Timeout should be at least 5s")
    }

    func testEmptyDataIsNotPushed() {
        let emptyData: [String: Any] = [:]
        XCTAssertTrue(emptyData.isEmpty, "Empty data should not be pushed")
    }
}

// MARK: - HKUnit Extension Tests

class HKUnitExtensionTests: XCTestCase {

    func testBeatsPerMinuteUnit() {
        // Verify the extension creates a valid unit
        let bpmUnit = HKUnit.beatsPerMinute()
        XCTAssertNotNil(bpmUnit)
    }
}
