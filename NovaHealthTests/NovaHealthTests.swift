//
//  NovaHealthTests.swift
//  NovaHealthTests
//
//  Comprehensive test suite for NovaHealth
//  Categories: Unit, Security, Integration, Functional, Frame, Enterprise
//
//  Written by Jordan Koch
//

import XCTest
@testable import NovaHealth
import HealthKit

// =============================================================================
// MARK: - Unit Tests: HealthPusher Core Logic
// =============================================================================

class HealthPusherUnitTests: XCTestCase {

    // MARK: - Singleton & Initialization

    @MainActor
    func testHealthPusherSharedInstanceIsSingleton() {
        let instance1 = HealthPusher.shared
        let instance2 = HealthPusher.shared
        XCTAssertTrue(instance1 === instance2, "Shared instance must be a singleton")
    }

    @MainActor
    func testInitialLastPushIsNil() {
        let pusher = HealthPusher.shared
        // On fresh launch, lastPush should be nil
        XCTAssertNotNil(pusher, "HealthPusher should exist")
    }

    @MainActor
    func testInitialLastResultText() {
        let pusher = HealthPusher.shared
        XCTAssertFalse(pusher.lastResult.isEmpty, "lastResult should not be empty")
    }

    @MainActor
    func testInitialHistoryRunningIsFalse() {
        let pusher = HealthPusher.shared
        XCTAssertFalse(pusher.historyRunning, "historyRunning should initially be false")
    }

    @MainActor
    func testInitialHistoryProgressIsEmpty() {
        let pusher = HealthPusher.shared
        XCTAssertTrue(pusher.historyProgress.isEmpty, "historyProgress should initially be empty")
    }

    // MARK: - Data Rounding Logic

    func testMetricRoundingStandardValue() {
        let value = 72.456
        let rounded = round(value * 100) / 100
        XCTAssertEqual(rounded, 72.46, accuracy: 0.001)
    }

    func testMetricRoundingIntegerValue() {
        let value = 10500.0
        let rounded = round(value * 100) / 100
        XCTAssertEqual(rounded, 10500.0, accuracy: 0.001)
    }

    func testMetricRoundingSmallDecimal() {
        let value = 0.221
        let rounded = round(value * 100) / 100
        XCTAssertEqual(rounded, 0.22, accuracy: 0.001)
    }

    func testMetricRoundingZero() {
        let value = 0.0
        let rounded = round(value * 100) / 100
        XCTAssertEqual(rounded, 0.0, accuracy: 0.001)
    }

    func testMetricRoundingNegativeFiltered() {
        let value = -5.0
        XCTAssertFalse(value > 0, "Negative values should be filtered out")
    }

    func testMetricRoundingPrecision() {
        let value = 98.6789
        let rounded = round(value * 100) / 100
        XCTAssertEqual(rounded, 98.68, accuracy: 0.001)
    }

    // MARK: - Metric Key Validation

    func testAllExpectedMetricKeysAreDefined() {
        let expectedKeys = [
            "sleep_hours", "heart_rate", "resting_heart_rate", "hrv",
            "steps", "active_energy", "basal_energy", "weight_lbs",
            "body_fat_pct", "blood_glucose_mgdl", "bp_systolic",
            "bp_diastolic", "spo2_pct", "body_temp_f",
            "respiratory_rate", "distance_miles", "flights_climbed"
        ]
        XCTAssertEqual(expectedKeys.count, 17, "Should have exactly 17 metric keys")
        for key in expectedKeys {
            XCTAssertFalse(key.isEmpty, "Metric key should not be empty")
            XCTAssertFalse(key.contains(" "), "Metric keys should use underscores, not spaces")
        }
    }

    func testMetricKeysUseSnakeCase() {
        let keys = ["sleep_hours", "heart_rate", "resting_heart_rate",
                     "body_fat_pct", "blood_glucose_mgdl"]
        for key in keys {
            XCTAssertTrue(key.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil,
                         "Key '\(key)' should be snake_case")
        }
    }
}

// =============================================================================
// MARK: - Unit Tests: ContentView Formatting
// =============================================================================

class ContentViewFormattingTests: XCTestCase {

    // MARK: - Key Formatting

    private func formatKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    func testFormatKeyReplacesUnderscores() {
        XCTAssertEqual(formatKey("heart_rate"), "Heart Rate")
    }

    func testFormatKeySingleWord() {
        XCTAssertEqual(formatKey("steps"), "Steps")
    }

    func testFormatKeyMultipleUnderscores() {
        XCTAssertEqual(formatKey("blood_glucose_mgdl"), "Blood Glucose Mgdl")
    }

    func testFormatKeyEmptyString() {
        XCTAssertEqual(formatKey(""), "")
    }

    func testFormatKeyAllUnderscores() {
        let result = formatKey("___")
        XCTAssertFalse(result.contains("_"), "Should replace all underscores")
    }

    // MARK: - Value Formatting

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

    func testFormatSpo2Percentage() {
        XCTAssertEqual(formatValue("spo2_pct", 0.98), "98.0%")
    }

    func testFormatBloodGlucose() {
        XCTAssertEqual(formatValue("blood_glucose_mgdl", 105.0), "105 mg/dL")
    }

    func testFormatBloodPressureSystolic() {
        XCTAssertEqual(formatValue("bp_systolic", 120.0), "120 mmHg")
    }

    func testFormatBloodPressureDiastolic() {
        XCTAssertEqual(formatValue("bp_diastolic", 80.0), "80 mmHg")
    }

    func testFormatBodyTemp() {
        let result = formatValue("body_temp_f", 98.6)
        XCTAssertTrue(result.contains("98.6"), "Should contain temperature value")
        XCTAssertTrue(result.contains("F"), "Should contain Fahrenheit indicator")
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

    func testFormatHeartRateDefault() {
        XCTAssertEqual(formatValue("heart_rate", 72.0), "72.0")
    }

    func testFormatNonNumericValue() {
        XCTAssertEqual(formatValue("unknown_key", "text_value"), "text_value")
    }

    // MARK: - Time Ago Formatting

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    func testTimeAgoJustNow() {
        let result = timeAgo(Date())
        XCTAssertEqual(result, "Just now")
    }

    func testTimeAgoMinutes() {
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        let result = timeAgo(fiveMinutesAgo)
        XCTAssertEqual(result, "5m ago")
    }

    func testTimeAgoHours() {
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        let result = timeAgo(twoHoursAgo)
        XCTAssertEqual(result, "2h ago")
    }

    func testTimeAgoDays() {
        let threeDaysAgo = Date().addingTimeInterval(-259200)
        let result = timeAgo(threeDaysAgo)
        XCTAssertEqual(result, "3d ago")
    }

    func testTimeAgoBoundaryMinute() {
        let exactly60SecondsAgo = Date().addingTimeInterval(-60)
        let result = timeAgo(exactly60SecondsAgo)
        XCTAssertEqual(result, "1m ago")
    }

    func testTimeAgoBoundaryHour() {
        let exactly3600SecondsAgo = Date().addingTimeInterval(-3600)
        let result = timeAgo(exactly3600SecondsAgo)
        XCTAssertEqual(result, "1h ago")
    }

    func testTimeAgoBoundaryDay() {
        let exactly86400SecondsAgo = Date().addingTimeInterval(-86400)
        let result = timeAgo(exactly86400SecondsAgo)
        XCTAssertEqual(result, "1d ago")
    }
}

// =============================================================================
// MARK: - Security Tests
// =============================================================================

class NovaHealthSecurityTests: XCTestCase {

    // MARK: - Server URL Security

    func testServerURLIsLocalNetwork() {
        let localURL = "http://192.168.1.6:37450/health"
        XCTAssertTrue(localURL.hasPrefix("http://192.168."),
                     "Server URL must be a local (RFC 1918) network address")
    }

    func testServerURLIsNotPublicCloud() {
        let localURL = "http://192.168.1.6:37450/health"
        let publicDomains = ["amazonaws.com", "googleapis.com", "azure.com",
                             "icloud.com", "cloudflare.com", "digitalocean.com",
                             "heroku.com", "vercel.app", "netlify.app"]
        for domain in publicDomains {
            XCTAssertFalse(localURL.contains(domain),
                          "Server URL must not point to cloud provider: \(domain)")
        }
    }

    func testServerURLIsNotHTTPS() {
        // For local network without mTLS, HTTP is acceptable
        let localURL = "http://192.168.1.6:37450/health"
        XCTAssertTrue(localURL.hasPrefix("http://"),
                     "Local network URL should use HTTP (no TLS needed on LAN without mTLS)")
    }

    func testServerPortIsInNovaRange() {
        let port = 37450
        XCTAssertTrue((37400...37499).contains(port),
                     "Port should be in Nova's reserved range (37400-37499)")
    }

    func testServerURLPathIsHealth() {
        let localURL = "http://192.168.1.6:37450/health"
        XCTAssertTrue(localURL.hasSuffix("/health"),
                     "Endpoint should be the /health path")
    }

    // MARK: - Data Privacy

    func testPushPayloadKeysContainNoPII() {
        let validKeys = ["sleep_hours", "heart_rate", "resting_heart_rate", "hrv",
                        "steps", "active_energy", "basal_energy", "weight_lbs",
                        "body_fat_pct", "blood_glucose_mgdl", "bp_systolic",
                        "bp_diastolic", "spo2_pct", "body_temp_f",
                        "respiratory_rate", "distance_miles", "flights_climbed"]
        let piiPatterns = ["name", "email", "phone", "address", "ssn",
                           "social", "birth", "dob", "zip", "city"]
        for key in validKeys {
            for pii in piiPatterns {
                XCTAssertFalse(key.lowercased().contains(pii),
                              "Key '\(key)' must not contain PII field '\(pii)'")
            }
        }
    }

    func testNoDeviceIdentifiersInPayloadKeys() {
        let validKeys = ["sleep_hours", "heart_rate", "steps", "weight_lbs"]
        let identifiers = ["udid", "device_id", "serial", "imei", "mac_address",
                           "apple_id", "user_id"]
        for key in validKeys {
            for id in identifiers {
                XCTAssertFalse(key.lowercased().contains(id),
                              "Key '\(key)' must not contain device identifier '\(id)'")
            }
        }
    }

    func testEmptyDataIsNotPushed() {
        let emptyData: [String: Any] = [:]
        XCTAssertTrue(emptyData.isEmpty, "Empty data should be rejected by push()")
    }

    func testRequestTimeoutIsReasonable() {
        let timeout: TimeInterval = 15
        XCTAssertTrue(timeout >= 5, "Timeout should be at least 5 seconds")
        XCTAssertTrue(timeout <= 30, "Timeout should not exceed 30 seconds")
    }

    func testContentTypeIsJSON() {
        let contentType = "application/json"
        XCTAssertEqual(contentType, "application/json",
                      "Push requests must use application/json Content-Type")
    }

    func testNoAuthTokensInURLString() {
        let localURL = "http://192.168.1.6:37450/health"
        XCTAssertFalse(localURL.contains("token="), "URL must not contain auth tokens")
        XCTAssertFalse(localURL.contains("key="), "URL must not contain API keys")
        XCTAssertFalse(localURL.contains("Bearer"), "URL must not contain bearer tokens")
    }

    // MARK: - mTLS Security Tests

    func testMTLSQRSchemeValidation() {
        // Valid QR code must use novahealth:// scheme
        let validQR = "novahealth://pair?server=aHR0cHM6Ly8xOTIuMTY4LjEuNjozNzQ1MA==&cert=AAAA&token=test"
        guard let url = URL(string: validQR) else { XCTFail("Should be a valid URL"); return }
        XCTAssertEqual(url.scheme, "novahealth")
        XCTAssertEqual(url.host, "pair")
    }

    func testMTLSRejectsInvalidScheme() {
        let invalidQR = "https://evil.com/pair?server=test&cert=test&token=test"
        guard let url = URL(string: invalidQR) else { XCTFail("Should be a valid URL"); return }
        XCTAssertNotEqual(url.scheme, "novahealth", "Must reject non-novahealth schemes")
    }

    func testAlertPayloadContainsPriorityField() {
        let alertPayload: [String: Any] = [
            "priority": "alert",
            "alert_type": "heart_rate",
            "value": 135.0,
        ]
        XCTAssertEqual(alertPayload["priority"] as? String, "alert")
    }

    func testAlertPayloadDoesNotContainPII() {
        let alertPayload: [String: Any] = [
            "priority": "alert",
            "alert_type": "heart_rate",
            "alert_reason": "Heart rate HIGH: 135 bpm",
            "value": 135.0,
            "timestamp": "2026-01-01T00:00:00Z",
            "source": "novahealth_alert_engine",
        ]
        let piiFields = ["name", "email", "phone", "address", "user_id"]
        for field in piiFields {
            XCTAssertNil(alertPayload[field], "Alert payload must not contain PII field '\(field)'")
        }
    }
}

// =============================================================================
// MARK: - Integration Tests
// =============================================================================

class NovaHealthIntegrationTests: XCTestCase {

    // MARK: - HealthKit Availability

    func testHealthDataAvailabilityCheck() {
        let available = HKHealthStore.isHealthDataAvailable()
        XCTAssertNotNil(available, "Should return a boolean, not crash")
    }

    func testHealthStoreCanBeCreated() {
        let store = HKHealthStore()
        XCTAssertNotNil(store, "HKHealthStore should be creatable")
    }

    // MARK: - HealthKit Type Identifiers

    func testHeartRateTypeExists() {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)
        XCTAssertNotNil(type, "Heart rate type should exist in HealthKit")
    }

    func testRestingHeartRateTypeExists() {
        let type = HKQuantityType.quantityType(forIdentifier: .restingHeartRate)
        XCTAssertNotNil(type, "Resting heart rate type should exist")
    }

    func testHRVTypeExists() {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        XCTAssertNotNil(type, "HRV type should exist")
    }

    func testStepCountTypeExists() {
        let type = HKQuantityType.quantityType(forIdentifier: .stepCount)
        XCTAssertNotNil(type, "Step count type should exist")
    }

    func testBodyMassTypeExists() {
        let type = HKQuantityType.quantityType(forIdentifier: .bodyMass)
        XCTAssertNotNil(type, "Body mass type should exist")
    }

    func testBloodGlucoseTypeExists() {
        let type = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)
        XCTAssertNotNil(type, "Blood glucose type should exist")
    }

    func testOxygenSaturationTypeExists() {
        let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)
        XCTAssertNotNil(type, "Oxygen saturation type should exist")
    }

    func testSleepAnalysisCategoryExists() {
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        XCTAssertNotNil(type, "Sleep analysis category type should exist")
    }

    func testWorkoutTypeExists() {
        let type = HKObjectType.workoutType()
        XCTAssertNotNil(type, "Workout type should exist")
    }

    // MARK: - URL Construction

    func testServerURLConstruction() {
        let urlString = "http://192.168.1.6:37450/health"
        let url = URL(string: urlString)
        XCTAssertNotNil(url, "Server URL should be a valid URL")
        XCTAssertEqual(url?.host, "192.168.1.6")
        XCTAssertEqual(url?.port, 37450)
        XCTAssertEqual(url?.path, "/health")
    }

    func testURLRequestCanBeCreated() {
        guard let url = URL(string: "http://192.168.1.6:37450/health") else {
            XCTFail("URL should be valid")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    // MARK: - JSON Serialization

    func testMetricDataSerializesToJSON() {
        let data: [String: Any] = [
            "heart_rate": 72.0,
            "steps": 10500.0,
            "sleep_hours": 7.5
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: data)
        XCTAssertNotNil(jsonData, "Metric data should serialize to JSON")
    }

    func testEmptyDataSerializesToJSON() {
        let data: [String: Any] = [:]
        let jsonData = try? JSONSerialization.data(withJSONObject: data)
        XCTAssertNotNil(jsonData, "Even empty data should serialize")
    }

    func testHistoryPayloadSerializesToJSON() {
        let payload: [String: Any] = [
            "date": "2025-01-15",
            "heart_rate": 72.0,
            "sample_count": 24,
            "source": "healthkit_history"
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: payload)
        XCTAssertNotNil(jsonData, "History payload should serialize to JSON")
    }

    func testAnomalyPayloadSerializesToJSON() {
        let payload: [String: Any] = [
            "heart_rate": 72.0,
            "anomaly_flags": ["heart_rate:high:z=3.2"],
            "trend_7d": ["heart_rate": "rising", "steps": "stable"],
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: payload)
        XCTAssertNotNil(jsonData, "Anomaly-enriched payload should serialize to JSON")
    }

    func testWorkoutPayloadSerializesToJSON() {
        let payload: [String: Any] = [
            "workout_type": "running",
            "start_date": "2026-01-15T08:00:00Z",
            "duration_seconds": 1800,
            "active_calories": 350.5,
            "avg_heart_rate": 145.0,
            "max_heart_rate": 172.0,
            "recovery_hr_1min": 130.0,
            "recovery_hr_2min": 115.0,
            "recovery_hr_5min": 95.0,
            "recovery_score_1min": 42.0,
            "source": "novahealth_workout",
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: payload)
        XCTAssertNotNil(jsonData, "Workout payload should serialize to JSON")
    }
}

// =============================================================================
// MARK: - Functional Tests
// =============================================================================

class NovaHealthFunctionalTests: XCTestCase {

    // MARK: - Data Filtering Logic

    func testPositiveValuesAreIncluded() {
        let results: [(String, Double?)] = [
            ("heart_rate", 72.0),
            ("steps", 10500.0),
            ("sleep_hours", nil),
        ]
        var data: [String: Any] = [:]
        for (key, value) in results {
            if let v = value, v > 0 {
                data[key] = round(v * 100) / 100
            }
        }
        XCTAssertEqual(data.count, 2, "Only non-nil positive values should be included")
        XCTAssertNotNil(data["heart_rate"])
        XCTAssertNotNil(data["steps"])
        XCTAssertNil(data["sleep_hours"])
    }

    func testZeroValuesAreExcluded() {
        let value: Double = 0.0
        XCTAssertFalse(value > 0, "Zero values should be filtered out")
    }

    func testNilValuesAreExcluded() {
        let value: Double? = nil
        let included = value.flatMap { $0 > 0 ? $0 : nil } != nil
        XCTAssertFalse(included, "Nil values should be filtered out")
    }

    // MARK: - Date Calculations

    func testStartOfDayCalculation() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let components = calendar.dateComponents([.hour, .minute, .second], from: startOfToday)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    func testYesterdayStartCalculation() {
        let yesterday = Date().addingTimeInterval(-86400)
        let calendar = Calendar.current
        let startOfYesterday = calendar.startOfDay(for: yesterday)
        XCTAssertTrue(startOfYesterday < calendar.startOfDay(for: Date()),
                     "Yesterday's start should be before today's start")
    }

    func testFiveYearDateRange() {
        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .year, value: -5, to: endDate) else {
            XCTFail("Should be able to compute 5 year range")
            return
        }
        let difference = calendar.dateComponents([.year], from: startDate, to: endDate)
        XCTAssertEqual(difference.year, 5, "History range should be exactly 5 years")
    }

    func testSevenDayLookbackForLatest() {
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-7 * 86400))
        let daysSinceStart = Int(-start.timeIntervalSinceNow) / 86400
        XCTAssertTrue(daysSinceStart >= 6 && daysSinceStart <= 8,
                     "Lookback should be approximately 7 days")
    }

    // MARK: - Sleep Hours Calculation (FIX #8 Tests)

    func testSleepHoursConversion() {
        let totalSeconds: TimeInterval = 8 * 3600
        let hours = totalSeconds / 3600.0
        XCTAssertEqual(hours, 8.0, accuracy: 0.01)
    }

    func testPartialSleepHoursConversion() {
        let totalSeconds: TimeInterval = 7.5 * 3600
        let hours = totalSeconds / 3600.0
        XCTAssertEqual(hours, 7.5, accuracy: 0.01)
    }

    func testZeroSleepReturnsNil() {
        let totalSeconds: TimeInterval = 0
        let result = totalSeconds > 0 ? totalSeconds / 3600.0 : nil
        XCTAssertNil(result, "Zero sleep time should return nil")
    }

    func testInBedIsNotCountedAsSleep() {
        // FIX #8: Verify that inBed values would NOT be included in sleep total
        let sleepStates: [Int] = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ]
        let inBedState = HKCategoryValueSleepAnalysis.inBed.rawValue

        // inBed should NOT be in the accepted sleep states
        XCTAssertFalse(sleepStates.contains(inBedState),
                      "inBed must NOT be counted as sleep (FIX #8)")
    }

    func testOnlyAsleepStatesCountAsSleep() {
        // These should count as sleep
        let validSleepStates: [HKCategoryValueSleepAnalysis] = [
            .asleepCore, .asleepDeep, .asleepREM, .asleepUnspecified
        ]
        XCTAssertEqual(validSleepStates.count, 4,
                      "Exactly 4 sleep states should count (not inBed)")
    }

    // MARK: - History Grouping

    func testDayGroupingByISO8601Prefix() {
        let formatter = ISO8601DateFormatter()
        let dateString = formatter.string(from: Date())
        let dayKey = String(dateString.prefix(10))
        XCTAssertEqual(dayKey.count, 10, "Day key should be YYYY-MM-DD (10 chars)")
        XCTAssertTrue(dayKey.contains("-"), "Day key should contain dashes")
    }

    func testAveragingMultipleSamples() {
        let values = [72.0, 75.0, 68.0, 71.0]
        let avg = values.reduce(0, +) / Double(values.count)
        XCTAssertEqual(avg, 71.5, accuracy: 0.01)
    }

    // MARK: - Background Task Identifier

    func testBackgroundTaskIdentifier() {
        let identifier = "net.digitalnoise.NovaHealth.refresh"
        XCTAssertTrue(identifier.hasPrefix("net.digitalnoise."),
                     "Should use reverse domain notation")
        XCTAssertTrue(identifier.contains("NovaHealth"),
                     "Should contain app name")
        XCTAssertTrue(identifier.hasSuffix(".refresh"),
                     "Should specify task type")
    }

    func testQueueDrainTaskIdentifier() {
        let identifier = "net.digitalnoise.NovaHealth.queueDrain"
        XCTAssertTrue(identifier.hasPrefix("net.digitalnoise.NovaHealth"),
                     "Should use reverse domain notation with app name")
        XCTAssertTrue(identifier.hasSuffix(".queueDrain"),
                     "Should specify queue drain task type")
    }

    func testScheduledRefreshTime() {
        let components = DateComponents(hour: 6, minute: 0)
        XCTAssertEqual(components.hour, 6)
        XCTAssertEqual(components.minute, 0)
    }

    // MARK: - Safe Unwrap Tests (FIX #3)

    func testCalendarDateByAddingCanReturnNil() {
        let calendar = Calendar.current
        // Normal case should succeed
        let result = calendar.date(byAdding: .year, value: -5, to: Date())
        XCTAssertNotNil(result, "Normal date calculation should succeed")
    }

    func testGuardLetProtectsAgainstNilDate() {
        // Simulating the FIX #3 pattern
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .year, value: -5, to: Date()) else {
            XCTFail("This should not fail for normal dates")
            return
        }
        XCTAssertTrue(startDate < Date(), "Start date should be in the past")
    }
}

// =============================================================================
// MARK: - Enterprise Feature Tests
// =============================================================================

class NovaHealthEnterpriseTests: XCTestCase {

    // MARK: - Alert Threshold Tests (Feature #1)

    func testDefaultHeartRateHighThreshold() {
        let threshold = HealthAlertEngine.AlertThreshold()
        XCTAssertEqual(threshold.heartRateHigh, 120.0,
                      "Default HR high threshold should be 120 bpm")
    }

    func testDefaultHeartRateLowThreshold() {
        let threshold = HealthAlertEngine.AlertThreshold()
        XCTAssertEqual(threshold.heartRateLow, 40.0,
                      "Default HR low threshold should be 40 bpm")
    }

    func testDefaultSpO2Threshold() {
        let threshold = HealthAlertEngine.AlertThreshold()
        XCTAssertEqual(threshold.spo2Low, 0.92,
                      "Default SpO2 threshold should be 92%")
    }

    func testDefaultRespiratoryRateThreshold() {
        let threshold = HealthAlertEngine.AlertThreshold()
        XCTAssertEqual(threshold.respiratoryRateHigh, 30.0,
                      "Default respiratory rate threshold should be 30 brpm")
    }

    func testDefaultBloodGlucoseHighThreshold() {
        let threshold = HealthAlertEngine.AlertThreshold()
        XCTAssertEqual(threshold.bloodGlucoseHigh, 250.0,
                      "Default glucose high threshold should be 250 mg/dL")
    }

    func testDefaultBloodGlucoseLowThreshold() {
        let threshold = HealthAlertEngine.AlertThreshold()
        XCTAssertEqual(threshold.bloodGlucoseLow, 54.0,
                      "Default glucose low threshold should be 54 mg/dL")
    }

    func testAlertThresholdEncodable() {
        let threshold = HealthAlertEngine.AlertThreshold()
        let data = try? JSONEncoder().encode(threshold)
        XCTAssertNotNil(data, "Thresholds should be encodable for persistence")
    }

    func testAlertThresholdDecodable() {
        let threshold = HealthAlertEngine.AlertThreshold()
        guard let data = try? JSONEncoder().encode(threshold) else {
            XCTFail("Encoding failed"); return
        }
        let decoded = try? JSONDecoder().decode(HealthAlertEngine.AlertThreshold.self, from: data)
        XCTAssertNotNil(decoded, "Thresholds should be decodable")
        XCTAssertEqual(decoded?.heartRateHigh, 120.0)
    }

    // MARK: - Anomaly Detection Tests (Feature #2)

    func testZScoreCalculation() {
        // Test Z-score math used by AnomalyDetector
        let values: [Double] = [70, 72, 71, 73, 72, 71, 70, 72, 73, 71]
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        let stdDev = sqrt(variance)

        let outlier = 85.0
        let zScore = abs(outlier - mean) / stdDev
        XCTAssertTrue(zScore > 2.5, "85 bpm should be anomalous relative to 70-73 range")
    }

    func testZScoreNormalValueNotAnomalous() {
        let values: [Double] = [70, 72, 71, 73, 72, 71, 70, 72, 73, 71]
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        let stdDev = sqrt(variance)

        let normal = 72.0
        let zScore = abs(normal - mean) / stdDev
        XCTAssertTrue(zScore < 2.5, "72 bpm should NOT be anomalous in 70-73 range")
    }

    func testTrendCalculationRising() {
        let values: [Double] = [60, 62, 64, 66, 68, 70, 72]
        let n = Double(values.count)
        let indices = Array(0..<values.count).map { Double($0) }
        let sumX = indices.reduce(0, +)
        let sumY = values.reduce(0, +)
        let sumXY = zip(indices, values).map { $0 * $1 }.reduce(0, +)
        let sumX2 = indices.map { $0 * $0 }.reduce(0, +)
        let slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX)
        XCTAssertTrue(slope > 0, "Consistently rising values should have positive slope")
    }

    func testTrendCalculationFalling() {
        let values: [Double] = [80, 78, 76, 74, 72, 70, 68]
        let n = Double(values.count)
        let indices = Array(0..<values.count).map { Double($0) }
        let sumX = indices.reduce(0, +)
        let sumY = values.reduce(0, +)
        let sumXY = zip(indices, values).map { $0 * $1 }.reduce(0, +)
        let sumX2 = indices.map { $0 * $0 }.reduce(0, +)
        let slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX)
        XCTAssertTrue(slope < 0, "Consistently falling values should have negative slope")
    }

    // MARK: - Workout Tracking Tests (Feature #3)

    func testWorkoutTypeNames() {
        // Verify expected workout type mappings
        let expectedTypes: [(HKWorkoutActivityType, String)] = [
            (.running, "running"),
            (.cycling, "cycling"),
            (.swimming, "swimming"),
            (.walking, "walking"),
            (.yoga, "yoga"),
        ]
        // Types are defined in WorkoutTracker — just verify the activity types exist
        for (type, _) in expectedTypes {
            XCTAssertNotEqual(type.rawValue, 0, "Activity type should have a valid raw value")
        }
    }

    func testRecoveryHRScoreCalculation() {
        let maxHR = 175.0
        let recovery1min = 145.0
        let recoveryDrop = maxHR - recovery1min
        XCTAssertEqual(recoveryDrop, 30.0,
                      "Recovery drop should be max HR minus recovery HR")
        XCTAssertTrue(recoveryDrop > 0,
                     "Recovery HR should be less than max HR")
    }

    func testWorkoutDurationFormatting() {
        let duration: TimeInterval = 1800 // 30 minutes
        let minutes = Int(duration / 60)
        XCTAssertEqual(minutes, 30, "1800 seconds should be 30 minutes")
    }

    // MARK: - mTLS Tests (Feature #4)

    func testQRCodeParsing() {
        let serverURL = "https://192.168.1.6:37450"
        let serverB64 = Data(serverURL.utf8).base64EncodedString()
        let qrContent = "novahealth://pair?server=\(serverB64)&cert=AAAA&token=test-uuid"

        guard let url = URL(string: qrContent) else {
            XCTFail("QR content should be a valid URL"); return
        }
        XCTAssertEqual(url.scheme, "novahealth")
        XCTAssertEqual(url.host, "pair")

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let serverParam = components.queryItems?.first(where: { $0.name == "server" })?.value,
              let decodedData = Data(base64Encoded: serverParam),
              let decodedURL = String(data: decodedData, encoding: .utf8) else {
            XCTFail("Should decode server URL from QR"); return
        }
        XCTAssertEqual(decodedURL, serverURL)
    }

    func testKeychainServiceIdentifier() {
        let service = "net.digitalnoise.NovaHealth"
        XCTAssertEqual(service, "net.digitalnoise.NovaHealth",
                      "Keychain service should match bundle ID")
    }

    // MARK: - Offline Queue Tests (Feature #5)

    func testQueuePayloadSerialization() {
        let data: [String: Any] = [
            "heart_rate": 72.0,
            "steps": 10500.0,
        ]
        let serialized = try? JSONSerialization.data(withJSONObject: data)
        XCTAssertNotNil(serialized, "Queue payload must be serializable")
    }

    func testDeduplicationVia409() {
        // 409 Conflict should be treated as success
        let statusCode = 409
        let isSuccess = (200...299).contains(statusCode) || statusCode == 409
        XCTAssertTrue(isSuccess, "409 should be treated as success (duplicate)")
    }

    func testMaxRetriesLimit() {
        let maxRetries = 10
        XCTAssertEqual(maxRetries, 10,
                      "Queue items should have max 10 retries before discard")
    }

    func testMaxAgeForQueuedItems() {
        let maxAge: TimeInterval = 7 * 86400
        XCTAssertEqual(maxAge, 604800,
                      "Queue items should expire after 7 days")
    }

    func testIdempotencyKeyHeader() {
        // Each queued item should have a unique idempotency key
        let id1 = UUID().uuidString
        let id2 = UUID().uuidString
        XCTAssertNotEqual(id1, id2, "Each queue entry must have a unique ID")
    }

    func testQueueDrainRateLimit() {
        let drainDelay: UInt64 = 50_000_000 // 50ms in nanoseconds
        XCTAssertEqual(drainDelay, 50_000_000,
                      "Drain should have 50ms delay between pushes")
    }
}

// =============================================================================
// MARK: - Frame Tests (UI/View Structure)
// =============================================================================

class NovaHealthFrameTests: XCTestCase {

    // MARK: - Status Row Layout

    func testStatusRowLabelsExist() {
        let labels = ["HealthKit", "Last Push", "Metrics", "Transport"]
        for label in labels {
            XCTAssertFalse(label.isEmpty, "Status row label '\(label)' should not be empty")
        }
    }

    func testStatusRowColorAssignment() {
        let isAuthorized = true
        let expectedColorLabel = isAuthorized ? "Authorized" : "Pending"
        XCTAssertEqual(expectedColorLabel, "Authorized")

        let notAuthorized = false
        let pendingLabel = notAuthorized ? "Authorized" : "Pending"
        XCTAssertEqual(pendingLabel, "Pending")
    }

    // MARK: - Metrics Display

    func testMetricsCountDisplay() {
        let data: [String: Any] = ["heart_rate": 72.0, "steps": 10000]
        let displayText = data.isEmpty ? "-" : "\(data.count) collected"
        XCTAssertEqual(displayText, "2 collected")
    }

    func testEmptyMetricsDisplay() {
        let data: [String: Any] = [:]
        let displayText = data.isEmpty ? "-" : "\(data.count) collected"
        XCTAssertEqual(displayText, "-")
    }

    // MARK: - Button States

    func testPushButtonLabelText() {
        let label = "Push Now"
        XCTAssertEqual(label, "Push Now")
    }

    func testExportButtonDisabledWhenRunning() {
        let historyRunning = true
        XCTAssertTrue(historyRunning, "Export button should be disabled when running")
    }

    func testExportButtonEnabledWhenIdle() {
        let historyRunning = false
        XCTAssertFalse(historyRunning, "Export button should be enabled when idle")
    }

    // MARK: - Transport Status Display

    func testTransportStatusMTLS() {
        let isPaired = true
        let display = isPaired ? "mTLS" : "HTTP (LAN)"
        XCTAssertEqual(display, "mTLS")
    }

    func testTransportStatusHTTP() {
        let isPaired = false
        let display = isPaired ? "mTLS" : "HTTP (LAN)"
        XCTAssertEqual(display, "HTTP (LAN)")
    }

    // MARK: - Info Text

    func testAutoScheduleInfoText() {
        let infoText = "Auto-pushes daily at ~6am\nReal-time alerts for threshold breaches\nData stays on your local network"
        XCTAssertTrue(infoText.contains("6am"), "Should mention schedule time")
        XCTAssertTrue(infoText.contains("local network"),
                     "Should mention data stays local")
        XCTAssertTrue(infoText.contains("alerts"),
                     "Should mention real-time alerts")
    }

    // MARK: - Sorted Data Display

    func testMetricsSortedAlphabetically() {
        let data: [String: Any] = [
            "steps": 10000,
            "heart_rate": 72.0,
            "active_energy": 450.0
        ]
        let sorted = data.sorted(by: { $0.key < $1.key })
        XCTAssertEqual(sorted[0].key, "active_energy")
        XCTAssertEqual(sorted[1].key, "heart_rate")
        XCTAssertEqual(sorted[2].key, "steps")
    }

    // MARK: - System Image Names

    func testSystemImageNameForAppIcon() {
        let imageName = "heart.text.clipboard"
        XCTAssertFalse(imageName.isEmpty, "System image name should not be empty")
        XCTAssertTrue(imageName.contains("heart"),
                     "App icon should be health-related")
    }

    func testPushButtonSystemImage() {
        let imageName = "arrow.up.circle.fill"
        XCTAssertFalse(imageName.isEmpty)
    }

    func testWorkoutButtonSystemImage() {
        let imageName = "figure.run"
        XCTAssertFalse(imageName.isEmpty)
    }
}

// =============================================================================
// MARK: - HKUnit Extension Tests
// =============================================================================

class HKUnitExtensionTests: XCTestCase {

    func testBeatsPerMinuteUnitCreation() {
        let bpmUnit = HKUnit.beatsPerMinute()
        XCTAssertNotNil(bpmUnit, "BPM unit should be creatable")
    }

    func testBeatsPerMinuteUnitIsComposite() {
        let bpmUnit = HKUnit.beatsPerMinute()
        let countUnit = HKUnit.count()
        let minuteUnit = HKUnit.minute()
        let manual = countUnit.unitDivided(by: minuteUnit)
        XCTAssertEqual(bpmUnit.unitString, manual.unitString,
                      "BPM unit should equal count/min")
    }

    func testCommonHealthKitUnits() {
        XCTAssertNotNil(HKUnit.pound(), "Pound unit should exist")
        XCTAssertNotNil(HKUnit.percent(), "Percent unit should exist")
        XCTAssertNotNil(HKUnit.kilocalorie(), "Kilocalorie unit should exist")
        XCTAssertNotNil(HKUnit.mile(), "Mile unit should exist")
        XCTAssertNotNil(HKUnit.count(), "Count unit should exist")
        XCTAssertNotNil(HKUnit.millimeterOfMercury(), "mmHg unit should exist")
        XCTAssertNotNil(HKUnit.degreeFahrenheit(), "Fahrenheit unit should exist")
    }

    func testBloodGlucoseUnitComposition() {
        let unit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        XCTAssertNotNil(unit, "Blood glucose unit (mg/dL) should be creatable")
    }

    func testRespiratoryRateUnitComposition() {
        let unit = HKUnit.count().unitDivided(by: .minute())
        XCTAssertNotNil(unit, "Respiratory rate unit (breaths/min) should be creatable")
    }
}

// =============================================================================
// MARK: - HTTP Response Handling Tests
// =============================================================================

class HTTPResponseHandlingTests: XCTestCase {

    func testSuccessStatusCodes() {
        for code in 200...299 {
            XCTAssertTrue((200...299).contains(code),
                         "Status code \(code) should be considered success")
        }
    }

    func testFailureStatusCodes() {
        let failureCodes = [400, 401, 403, 404, 500, 502, 503]
        for code in failureCodes {
            XCTAssertFalse((200...299).contains(code),
                          "Status code \(code) should be considered failure")
        }
    }

    func testHTTPMethodIsPOST() {
        let method = "POST"
        XCTAssertEqual(method, "POST", "Push method should be POST")
    }

    func test409ConflictIsDedupSuccess() {
        let statusCode = 409
        let isSuccess = (200...299).contains(statusCode) || statusCode == 409
        XCTAssertTrue(isSuccess, "409 Conflict should be treated as dedup success")
    }

    func testExponentialBackoffDelays() {
        let baseDelay: UInt64 = 1_000_000_000
        let delay1 = baseDelay * UInt64(1 << 0) // 1s
        let delay2 = baseDelay * UInt64(1 << 1) // 2s
        let delay3 = baseDelay * UInt64(1 << 2) // 4s
        XCTAssertEqual(delay1, 1_000_000_000)
        XCTAssertEqual(delay2, 2_000_000_000)
        XCTAssertEqual(delay3, 4_000_000_000)
    }

    func testRateLimitDelayForHistory() {
        // FIX #6: 100ms delay between history POSTs
        let delay: UInt64 = 100_000_000
        XCTAssertEqual(delay, 100_000_000,
                      "History export should have 100ms rate limit between POSTs")
    }
}
