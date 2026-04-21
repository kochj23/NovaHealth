// NovaHealth — HealthKit data collector and pusher
// Written by Jordan Koch

import Foundation
import HealthKit

class HealthPusher: ObservableObject {
    static let shared = HealthPusher()

    private let store = HKHealthStore()
    private let serverURL = "http://192.168.1.6:37450/health"

    @Published var lastPush: Date?
    @Published var lastResult: String = "Not yet pushed"
    @Published var isAuthorized: Bool = false

    private let readTypes: Set<HKObjectType> = {
        var types = Set<HKObjectType>()
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if let rhr = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) { types.insert(rhr) }
        if let hrv = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(hrv) }
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) { types.insert(steps) }
        if let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(energy) }
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
        async let rhr = fetchRestingHR()
        async let hrv = fetchHRV()
        async let steps = fetchSteps()
        async let energy = fetchActiveEnergy()

        let s = await sleep, r = await rhr, h = await hrv, st = await steps, e = await energy

        let data: [String: Any] = [
            "sleep_hours": s ?? 0,
            "resting_heart_rate": r ?? 0,
            "hrv": h ?? 0,
            "steps": st ?? 0,
            "active_energy": e ?? 0,
        ]

        let success = await push(data)
        let summary = String(format: "Sleep %.1fh | HR %.0f | HRV %.0f | Steps %.0f | Energy %.0f",
                             s ?? 0, r ?? 0, h ?? 0, st ?? 0, e ?? 0)

        await MainActor.run {
            lastPush = Date()
            lastResult = success ? summary : "Push failed — Mac reachable?"
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
                        if val == .asleepCore || val == .asleepDeep || val == .asleepREM || val == .asleepUnspecified {
                            total += s.endDate.timeIntervalSince(s.startDate)
                        }
                    }
                }
                cont.resume(returning: total > 0 ? total / 3600.0 : nil)
            }
            store.execute(query)
        }
    }

    private func fetchRestingHR() async -> Double? {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else { return nil }
        return await fetchLatestQuantity(type: hrType, unit: HKUnit.count().unitDivided(by: .minute()))
    }

    private func fetchHRV() async -> Double? {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return nil }
        return await fetchLatestQuantity(type: hrvType, unit: .secondUnit(with: .milli))
    }

    private func fetchSteps() async -> Double? {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return nil }
        return await fetchTodaySum(type: stepType, unit: .count())
    }

    private func fetchActiveEnergy() async -> Double? {
        guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return nil }
        return await fetchTodaySum(type: energyType, unit: .kilocalorie())
    }

    private func fetchLatestQuantity(type: HKQuantityType, unit: HKUnit) async -> Double? {
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86400))
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

    private func fetchTodaySum(type: HKQuantityType, unit: HKUnit) async -> Double? {
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        return await withCheckedContinuation { cont in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    // MARK: - Push to Nova

    private func push(_ data: [String: Any]) async -> Bool {
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
                print("[NovaHealth] Push: HTTP \(http.statusCode)")
                return (200...299).contains(http.statusCode)
            }
            return false
        } catch {
            print("[NovaHealth] Push failed: \(error)")
            return false
        }
    }
}
