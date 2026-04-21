// NovaHealth — HealthKit data collector and pusher
// Written by Jordan Koch
//
// Sources: Withings, Dexcom G6/G7, RingCon, 23andMe, Brightside

import Foundation
import HealthKit

class HealthPusher: ObservableObject {
    static let shared = HealthPusher()

    private let store = HKHealthStore()
    private let serverURL = "http://192.168.1.6:37450/health"

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
        return types
    }()

    func requestAuth() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            await MainActor.run { isAuthorized = true }
            return true
        } catch {
            print("HealthKit auth failed: \(error)")
            return false
        }
    }

    func collectAndPush() async {
        guard await requestAuth() else {
            await MainActor.run { lastResult = "HealthKit not authorized" }
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

        let success = await push(data)

        await MainActor.run {
            lastPush = Date()
            lastData = data
            lastResult = success
                ? "\(populated) metrics collected"
                : "Push failed — Mac reachable?"
        }
    }

    // MARK: - HealthKit Queries

    private func fetchSleepHours() async -> Double? {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86400))
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: 0, sortDescriptors: nil) { _, samples, _ in
                var total: TimeInterval = 0
                if let categorySamples = samples as? [HKCategorySample] {
                    for s in categorySamples {
                        let val = HKCategoryValueSleepAnalysis(rawValue: s.value)
                        if val == .asleepCore || val == .asleepDeep || val == .asleepREM
                            || val == .asleepUnspecified || val == .inBed {
                            total += s.endDate.timeIntervalSince(s.startDate)
                        }
                    }
                }
                cont.resume(returning: total > 0 ? total / 3600.0 : nil)
            }
            store.execute(query)
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
            store.execute(query)
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
            store.execute(query)
        }
    }

    // MARK: - Historical Bulk Export

    @Published var historyProgress: String = ""
    @Published var historyRunning: Bool = false

    func exportHistory() async {
        guard await requestAuth() else { return }
        await MainActor.run { historyRunning = true; historyProgress = "Starting..." }

        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .year, value: -5, to: endDate)!

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

        var totalPushed = 0
        for (identifier, unit, key) in metrics {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            await MainActor.run { historyProgress = "Exporting \(key)..." }

            let samples = await fetchAllSamples(type: type, unit: unit, start: startDate, end: endDate)
            if samples.isEmpty { continue }

            // Group by day
            var byDay: [String: [Double]] = [:]
            for (date, value) in samples {
                let dayKey = ISO8601DateFormatter().string(from: calendar.startOfDay(for: date)).prefix(10)
                byDay[String(dayKey), default: []].append(value)
            }

            // Push each day as a batch
            for (day, values) in byDay.sorted(by: { $0.key < $1.key }) {
                let avg = values.reduce(0, +) / Double(values.count)
                let payload: [String: Any] = [
                    "date": day,
                    key: round(avg * 100) / 100,
                    "sample_count": values.count,
                    "source": "healthkit_history",
                ]
                _ = await push(payload)
                totalPushed += 1
            }
            await MainActor.run { historyProgress = "\(key): \(byDay.count) days exported (\(totalPushed) total)" }
        }

        // Sleep history
        await MainActor.run { historyProgress = "Exporting sleep..." }
        let sleepDays = await fetchAllSleep(start: startDate, end: endDate)
        for (day, hours) in sleepDays.sorted(by: { $0.key < $1.key }) {
            let payload: [String: Any] = [
                "date": day,
                "sleep_hours": round(hours * 100) / 100,
                "source": "healthkit_history",
            ]
            _ = await push(payload)
            totalPushed += 1
        }

        await MainActor.run {
            historyProgress = "Done: \(totalPushed) daily records exported"
            historyRunning = false
            lastResult = "History export: \(totalPushed) records"
        }
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
            store.execute(query)
        }
    }

    private func fetchAllSleep(start: Date, end: Date) async -> [String: Double] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                var byDay: [String: TimeInterval] = [:]
                let cal = Calendar.current
                if let categorySamples = samples as? [HKCategorySample] {
                    for s in categorySamples {
                        let val = HKCategoryValueSleepAnalysis(rawValue: s.value)
                        if val == .asleepCore || val == .asleepDeep || val == .asleepREM
                            || val == .asleepUnspecified || val == .inBed {
                            let dayKey = ISO8601DateFormatter().string(from: cal.startOfDay(for: s.startDate)).prefix(10)
                            byDay[String(dayKey), default: 0] += s.endDate.timeIntervalSince(s.startDate)
                        }
                    }
                }
                cont.resume(returning: byDay.mapValues { $0 / 3600.0 })
            }
            store.execute(query)
        }
    }

    // MARK: - Push to Nova

    private func push(_ data: [String: Any]) async -> Bool {
        guard !data.isEmpty else { return false }
        guard let url = URL(string: serverURL) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        guard let body = try? JSONSerialization.data(withJSONObject: data) else { return false }
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                print("[NovaHealth] Push: HTTP \(http.statusCode) — \(data.count) metrics")
                return (200...299).contains(http.statusCode)
            }
            return false
        } catch {
            print("[NovaHealth] Push failed: \(error)")
            return false
        }
    }
}

extension HKUnit {
    static func beatsPerMinute() -> HKUnit {
        return HKUnit.count().unitDivided(by: .minute())
    }
}
