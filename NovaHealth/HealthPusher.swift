// NovaHealth — HealthKit data collector and pusher
// Written by Jordan Koch
//
// Sources: Withings, Dexcom G6/G7, RingCon, 23andMe, Brightside
//
// FIX #7: Plain HTTP is intentional — this app ONLY communicates with a receiver
// on the local RFC 1918 network (192.168.x.x). The isLocalNetwork() guard enforces
// this at runtime. When mTLS is configured via QR pairing, HTTPS is used instead.

import Foundation
import HealthKit

// FIX #4: Mark @MainActor to ensure Sendable safety for @Published properties
// and prevent data races across concurrency boundaries.
@MainActor
class HealthPusher: ObservableObject {
    static let shared = HealthPusher()

    private let store = HKHealthStore()

    /// Base server URL — plain HTTP for LAN-only operation (see FIX #7 comment at top).
    /// When mTLS is configured, this is overridden with the HTTPS URL from Keychain.
    private var serverURL: String {
        if let mtlsURL = MTLSManager.shared.serverURL {
            return mtlsURL
        }
        return "http://192.168.1.6:37450/health"
    }

    /// Validates that a URL points to a local RFC 1918 network address.
    /// Returns true for 10.x.x.x, 172.16-31.x.x, 192.168.x.x, and 127.x.x.x (loopback).
    /// Logs a warning and returns false if the destination is not on a local network.
    private nonisolated func isLocalNetwork(url: URL) -> Bool {
        guard let host = url.host else {
            print("[NovaHealth] WARNING: No host in URL — refusing to send health data")
            return false
        }

        let components = host.split(separator: ".").compactMap { Int($0) }
        guard components.count == 4 else {
            print("[NovaHealth] WARNING: Non-IP host '\(host)' — refusing to send health data to non-local destination")
            return false
        }

        let isLocal: Bool
        switch components[0] {
        case 10:
            isLocal = true
        case 172:
            isLocal = components[1] >= 16 && components[1] <= 31
        case 192:
            isLocal = components[1] == 168
        case 127:
            isLocal = true  // loopback
        default:
            isLocal = false
        }

        if !isLocal {
            print("[NovaHealth] WARNING: Server URL '\(host)' is NOT on a local RFC 1918 network. Health data will NOT be sent.")
        }
        return isLocal
    }

    @Published var lastPush: Date?
    @Published var lastResult: String = "Not yet pushed"
    @Published var lastData: [String: Any] = [:]
    @Published var isAuthorized: Bool = false

    private let readTypes: Set<HKObjectType> = {
        var types = Set<HKObjectType>()
        let quantityTypes: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .stepCount,
            .activeEnergyBurned,
            .basalEnergyBurned,
            .bodyMass,
            .bodyFatPercentage,
            .bloodGlucose,
            .bloodPressureSystolic,
            .bloodPressureDiastolic,
            .oxygenSaturation,
            .bodyTemperature,
            .respiratoryRate,
            .distanceWalkingRunning,
            .flightsClimbed,
        ]
        for id in quantityTypes {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        // Enterprise: workout type for workout tracking
        types.insert(HKObjectType.workoutType())
        return types
    }()

    func requestAuth() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
            return true
        } catch {
            print("HealthKit auth failed: \(error)")
            return false
        }
    }

    func collectAndPush() async {
        guard await requestAuth() else {
            lastResult = "HealthKit not authorized"
            return
        }

        async let sleep = fetchSleepHours()
        async let hr = fetchLatest(.heartRate, unit: .beatsPerMinute())
        async let rhr = fetchLatest(.restingHeartRate, unit: .beatsPerMinute())
        async let hrv = fetchLatest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli))
        async let steps = fetchTodaySum(.stepCount, unit: .count())
        async let activeEnergy = fetchTodaySum(.activeEnergyBurned, unit: .kilocalorie())
        async let basalEnergy = fetchTodaySum(.basalEnergyBurned, unit: .kilocalorie())
        async let weight = fetchLatest(.bodyMass, unit: .pound())
        async let bodyFat = fetchLatest(.bodyFatPercentage, unit: .percent())
        async let glucose = fetchLatest(.bloodGlucose, unit: HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)))
        async let systolic = fetchLatest(.bloodPressureSystolic, unit: .millimeterOfMercury())
        async let diastolic = fetchLatest(.bloodPressureDiastolic, unit: .millimeterOfMercury())
        async let spo2 = fetchLatest(.oxygenSaturation, unit: .percent())
        async let bodyTemp = fetchLatest(.bodyTemperature, unit: .degreeFahrenheit())
        async let respRate = fetchLatest(.respiratoryRate, unit: .count().unitDivided(by: .minute()))
        async let distance = fetchTodaySum(.distanceWalkingRunning, unit: .mile())
        async let flights = fetchTodaySum(.flightsClimbed, unit: .count())

        var data: [String: Any] = [:]

        let results: [(String, Double?)] = await [
            ("sleep_hours", sleep),
            ("heart_rate", hr),
            ("resting_heart_rate", rhr),
            ("hrv", hrv),
            ("steps", steps),
            ("active_energy", activeEnergy),
            ("basal_energy", basalEnergy),
            ("weight_lbs", weight),
            ("body_fat_pct", bodyFat),
            ("blood_glucose_mgdl", glucose),
            ("bp_systolic", systolic),
            ("bp_diastolic", diastolic),
            ("spo2_pct", spo2),
            ("body_temp_f", bodyTemp),
            ("respiratory_rate", respRate),
            ("distance_miles", distance),
            ("flights_climbed", flights),
        ]

        var populated = 0
        for (key, value) in results {
            if let v = value, v > 0 {
                data[key] = round(v * 100) / 100
                populated += 1
            }
        }

        // Enterprise Feature #2: Add anomaly flags and 7-day trend
        let anomalyData = await AnomalyDetector.shared.analyzeCurrentMetrics(data)
        if !anomalyData.isEmpty {
            data["anomaly_flags"] = anomalyData["anomaly_flags"]
            data["trend_7d"] = anomalyData["trend_7d"]
        }

        let success = await push(data)

        lastPush = Date()
        lastData = data
        lastResult = success
            ? "\(populated) metrics collected"
            : "Push failed — queued offline"
    }

    // MARK: - HealthKit Queries

    // FIX #8: Separate inBed from actual sleep states.
    // Only asleepCore, asleepDeep, asleepREM, and asleepUnspecified count as sleep.
    // inBed is tracked separately and NOT included in sleep_hours.
    private func fetchSleepHours() async -> Double? {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86400))
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: 0, sortDescriptors: nil) { _, samples, _ in
                var totalAsleep: TimeInterval = 0
                if let categorySamples = samples as? [HKCategorySample] {
                    for s in categorySamples {
                        let val = HKCategoryValueSleepAnalysis(rawValue: s.value)
                        // FIX #8: Only count actual sleep states, NOT inBed
                        if val == .asleepCore || val == .asleepDeep || val == .asleepREM
                            || val == .asleepUnspecified {
                            totalAsleep += s.endDate.timeIntervalSince(s.startDate)
                        }
                    }
                }
                cont.resume(returning: totalAsleep > 0 ? totalAsleep / 3600.0 : nil)
            }
            self.store.execute(query)
        }
    }

    private func fetchLatest(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-7 * 86400))
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                if let sample = samples?.first as? HKQuantitySample {
                    cont.resume(returning: sample.quantity.doubleValue(for: unit))
                } else {
                    cont.resume(returning: nil)
                }
            }
            self.store.execute(query)
        }
    }

    private func fetchTodaySum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        return await withCheckedContinuation { cont in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            self.store.execute(query)
        }
    }

    // MARK: - Historical Bulk Export

    @Published var historyProgress: String = ""
    @Published var historyRunning: Bool = false

    /// Key used to persist the last successfully exported date for checkpoint/resume
    private nonisolated static let lastExportCheckpointKey = "NovaHealth_LastExportDate"

    /// Saves the last successfully pushed date for export checkpointing
    private nonisolated func saveExportCheckpoint(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastExportCheckpointKey)
    }

    /// Loads the last export checkpoint date, or nil if no checkpoint exists
    private nonisolated func loadExportCheckpoint() -> Date? {
        let interval = UserDefaults.standard.double(forKey: Self.lastExportCheckpointKey)
        guard interval > 0 else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    func exportHistory() async {
        guard await requestAuth() else { return }
        historyRunning = true
        historyProgress = "Starting..."

        let calendar = Calendar.current
        let endDate = Date()

        // FIX #3: Safe unwrap instead of force unwrap on calendar.date(byAdding:)
        guard let defaultStart = calendar.date(byAdding: .year, value: -5, to: endDate) else {
            historyProgress = "Error: Could not compute start date"
            historyRunning = false
            return
        }

        let startDate = loadExportCheckpoint() ?? defaultStart
        if loadExportCheckpoint() != nil {
            historyProgress = "Resuming from checkpoint..."
        }

        let metrics: [(HKQuantityTypeIdentifier, HKUnit, String)] = [
            (.heartRate, .beatsPerMinute(), "heart_rate"),
            (.restingHeartRate, .beatsPerMinute(), "resting_heart_rate"),
            (.heartRateVariabilitySDNN, .secondUnit(with: .milli), "hrv"),
            (.stepCount, .count(), "steps"),
            (.activeEnergyBurned, .kilocalorie(), "active_energy"),
            (.bodyMass, .pound(), "weight_lbs"),
            (.bodyFatPercentage, .percent(), "body_fat_pct"),
            (.bloodGlucose, HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)), "blood_glucose_mgdl"),
            (.bloodPressureSystolic, .millimeterOfMercury(), "bp_systolic"),
            (.bloodPressureDiastolic, .millimeterOfMercury(), "bp_diastolic"),
            (.oxygenSaturation, .percent(), "spo2_pct"),
            (.distanceWalkingRunning, .mile(), "distance_miles"),
        ]

        // FIX #5: Create ISO8601DateFormatter once outside the loop, reuse throughout
        let isoFormatter = ISO8601DateFormatter()

        var totalPushed = 0
        for (identifier, unit, key) in metrics {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            historyProgress = "Exporting \(key)..."

            let samples = await fetchAllSamples(type: type, unit: unit, start: startDate, end: endDate)
            if samples.isEmpty { continue }

            // Group by day — FIX #5: reuse isoFormatter instead of creating in loop
            var byDay: [String: [Double]] = [:]
            for (date, value) in samples {
                let dayKey = String(isoFormatter.string(from: calendar.startOfDay(for: date)).prefix(10))
                byDay[dayKey, default: []].append(value)
            }

            // Push each day as a batch — FIX #6: Rate limiting with 100ms delay between POSTs
            for (day, values) in byDay.sorted(by: { $0.key < $1.key }) {
                let avg = values.reduce(0, +) / Double(values.count)
                let payload: [String: Any] = [
                    "date": day,
                    key: round(avg * 100) / 100,
                    "sample_count": values.count,
                    "source": "healthkit_history",
                ]
                let success = await push(payload)
                totalPushed += 1
                // Save checkpoint on successful push so export can resume here on restart
                if success, let dayDate = isoFormatter.date(from: day + "T00:00:00Z") {
                    saveExportCheckpoint(dayDate)
                }
                // FIX #6: Rate limit — 100ms delay between POSTs to avoid overwhelming receiver
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            historyProgress = "\(key): \(byDay.count) days exported (\(totalPushed) total)"
        }

        // Sleep history — FIX #5 & #8: reuse formatter, separate inBed from asleep
        historyProgress = "Exporting sleep..."
        let sleepDays = await fetchAllSleep(start: startDate, end: endDate)
        for (day, hours) in sleepDays.sorted(by: { $0.key < $1.key }) {
            let payload: [String: Any] = [
                "date": day,
                "sleep_hours": round(hours * 100) / 100,
                "source": "healthkit_history",
            ]
            let success = await push(payload)
            totalPushed += 1
            if success, let dayDate = isoFormatter.date(from: day + "T00:00:00Z") {
                saveExportCheckpoint(dayDate)
            }
            // FIX #6: Rate limit between sleep day POSTs
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Mark export as complete by saving current date as checkpoint
        saveExportCheckpoint(endDate)

        historyProgress = "Done: \(totalPushed) daily records exported"
        historyRunning = false
        lastResult = "History export: \(totalPushed) records"
    }

    private func fetchAllSamples(type: HKQuantityType, unit: HKUnit, start: Date, end: Date) async -> [(Date, Double)] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                var results: [(Date, Double)] = []
                if let quantitySamples = samples as? [HKQuantitySample] {
                    for s in quantitySamples {
                        results.append((s.startDate, s.quantity.doubleValue(for: unit)))
                    }
                }
                cont.resume(returning: results)
            }
            self.store.execute(query)
        }
    }

    // FIX #8: fetchAllSleep now excludes inBed from sleep calculation
    private func fetchAllSleep(start: Date, end: Date) async -> [String: Double] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                // FIX #5: Create formatter once for this closure scope (avoids Sendable issue)
                let isoFormatter = ISO8601DateFormatter()
                var byDay: [String: TimeInterval] = [:]
                let cal = Calendar.current
                if let categorySamples = samples as? [HKCategorySample] {
                    for s in categorySamples {
                        let val = HKCategoryValueSleepAnalysis(rawValue: s.value)
                        // FIX #8: Only count actual sleep, NOT inBed
                        if val == .asleepCore || val == .asleepDeep || val == .asleepREM
                            || val == .asleepUnspecified {
                            let dayKey = String(isoFormatter.string(from: cal.startOfDay(for: s.startDate)).prefix(10))
                            byDay[dayKey, default: 0] += s.endDate.timeIntervalSince(s.startDate)
                        }
                    }
                }
                cont.resume(returning: byDay.mapValues { $0 / 3600.0 })
            }
            self.store.execute(query)
        }
    }

    // MARK: - Push to Nova

    /// Pushes data to the server with retry logic: 3 attempts with exponential backoff (1s, 2s, 4s).
    /// Validates that the destination is on a local RFC 1918 network before sending.
    /// On failure after all retries, queues payload offline for later delivery.
    func push(_ data: [String: Any]) async -> Bool {
        guard !data.isEmpty else { return false }
        guard let url = URL(string: serverURL) else { return false }

        // Security: only send health data to local network destinations
        guard isLocalNetwork(url: url) else { return false }

        guard let body = try? JSONSerialization.data(withJSONObject: data) else { return false }

        let maxAttempts = 3
        let baseDelay: UInt64 = 1_000_000_000 // 1 second in nanoseconds

        // Choose URLSession based on mTLS configuration
        let session = MTLSManager.shared.isConfigured
            ? MTLSManager.shared.secureSession
            : URLSession.shared

        for attempt in 1...maxAttempts {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            request.httpBody = body

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    print("[NovaHealth] Push attempt \(attempt): HTTP \(http.statusCode) — \(data.count) metrics")
                    if (200...299).contains(http.statusCode) {
                        return true
                    }
                    // 409 Conflict = server already has this record (dedup success)
                    if http.statusCode == 409 {
                        print("[NovaHealth] Server returned 409 (duplicate) — treating as success")
                        return true
                    }
                }
            } catch {
                print("[NovaHealth] Push attempt \(attempt)/\(maxAttempts) failed: \(error)")
            }

            // Exponential backoff: 1s, 2s, 4s
            if attempt < maxAttempts {
                let delay = baseDelay * UInt64(1 << (attempt - 1))
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        print("[NovaHealth] Push failed after \(maxAttempts) attempts — queuing offline")
        // Enterprise Feature #5: Queue for offline delivery
        OfflineQueue.shared.enqueue(data)
        return false
    }
}

extension HKUnit {
    static func beatsPerMinute() -> HKUnit {
        return HKUnit.count().unitDivided(by: .minute())
    }
}
