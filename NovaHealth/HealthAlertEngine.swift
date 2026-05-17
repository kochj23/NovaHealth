// NovaHealth — Real-Time Health Alert Engine (Enterprise Feature #1)
// Written by Jordan Koch
//
// Uses HKObserverQuery for continuous background delivery.
// Configurable thresholds (HR > 120, SpO2 < 92%).
// Immediate push with priority: "alert" field when threshold breached.

import Foundation
import HealthKit

@MainActor
class HealthAlertEngine: ObservableObject {
    static let shared = HealthAlertEngine()

    private let store = HKHealthStore()

    /// Configurable alert thresholds — stored in UserDefaults for user customization
    struct AlertThreshold: Codable {
        var heartRateHigh: Double = 120.0
        var heartRateLow: Double = 40.0
        var spo2Low: Double = 0.92
        var respiratoryRateHigh: Double = 30.0
        var bloodGlucoseHigh: Double = 250.0  // mg/dL
        var bloodGlucoseLow: Double = 54.0    // mg/dL
        var systolicHigh: Double = 180.0
        var diastolicHigh: Double = 120.0
    }

    @Published var thresholds = AlertThreshold()
    @Published var lastAlert: String = ""
    @Published var alertCount: Int = 0

    private static let thresholdsKey = "NovaHealth_AlertThresholds"
    private var observerQueries: [HKObserverQuery] = []

    /// Minimum seconds between alerts for the same metric to prevent spam
    private let alertCooldown: TimeInterval = 300 // 5 minutes
    private var lastAlertTimes: [String: Date] = [:]

    init() {
        loadThresholds()
    }

    // MARK: - Threshold Persistence

    private func loadThresholds() {
        guard let data = UserDefaults.standard.data(forKey: Self.thresholdsKey),
              let saved = try? JSONDecoder().decode(AlertThreshold.self, from: data) else { return }
        thresholds = saved
    }

    func saveThresholds() {
        guard let data = try? JSONEncoder().encode(thresholds) else { return }
        UserDefaults.standard.set(data, forKey: Self.thresholdsKey)
    }

    // MARK: - Observer Setup

    func startObserving() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let monitoredTypes: [(HKQuantityTypeIdentifier, String)] = [
            (.heartRate, "heart_rate"),
            (.oxygenSaturation, "spo2"),
            (.respiratoryRate, "respiratory_rate"),
            (.bloodGlucose, "blood_glucose"),
            (.bloodPressureSystolic, "bp_systolic"),
            (.bloodPressureDiastolic, "bp_diastolic"),
        ]

        for (identifier, label) in monitoredTypes {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }

            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, error in
                if let error = error {
                    print("[NovaHealth Alert] Observer error for \(label): \(error)")
                    completionHandler()
                    return
                }

                // Call completion immediately to acknowledge delivery,
                // then perform threshold check asynchronously
                completionHandler()
                Task { @MainActor [weak self] in
                    await self?.checkThreshold(for: identifier, label: label)
                }
            }

            store.execute(query)
            observerQueries.append(query)

            // Enable background delivery for this type
            do {
                try await store.enableBackgroundDelivery(for: type, frequency: .immediate)
                print("[NovaHealth Alert] Background delivery enabled for \(label)")
            } catch {
                print("[NovaHealth Alert] Background delivery failed for \(label): \(error)")
            }
        }

        print("[NovaHealth Alert] Observing \(monitoredTypes.count) health metrics for threshold breaches")
    }

    func stopObserving() {
        for query in observerQueries {
            store.stop(query)
        }
        observerQueries.removeAll()
    }

    // MARK: - Threshold Checking

    private func checkThreshold(for identifier: HKQuantityTypeIdentifier, label: String) async {
        // Cooldown check — don't spam alerts
        if let lastTime = lastAlertTimes[label],
           Date().timeIntervalSince(lastTime) < alertCooldown {
            return
        }

        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-300), // Last 5 minutes
            end: Date(),
            options: .strictStartDate
        )

        let unit = unitFor(identifier: identifier)
        let value: Double? = await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                if let sample = samples?.first as? HKQuantitySample {
                    cont.resume(returning: sample.quantity.doubleValue(for: unit))
                } else {
                    cont.resume(returning: nil)
                }
            }
            self.store.execute(query)
        }

        guard let currentValue = value else { return }

        // Check against thresholds
        var alertReason: String?

        switch identifier {
        case .heartRate:
            if currentValue > thresholds.heartRateHigh {
                alertReason = "Heart rate HIGH: \(Int(currentValue)) bpm (threshold: \(Int(thresholds.heartRateHigh)))"
            } else if currentValue < thresholds.heartRateLow {
                alertReason = "Heart rate LOW: \(Int(currentValue)) bpm (threshold: \(Int(thresholds.heartRateLow)))"
            }
        case .oxygenSaturation:
            if currentValue < thresholds.spo2Low {
                alertReason = "SpO2 LOW: \(Int(currentValue * 100))% (threshold: \(Int(thresholds.spo2Low * 100))%)"
            }
        case .respiratoryRate:
            if currentValue > thresholds.respiratoryRateHigh {
                alertReason = "Respiratory rate HIGH: \(Int(currentValue)) brpm (threshold: \(Int(thresholds.respiratoryRateHigh)))"
            }
        case .bloodGlucose:
            if currentValue > thresholds.bloodGlucoseHigh {
                alertReason = "Blood glucose HIGH: \(Int(currentValue)) mg/dL (threshold: \(Int(thresholds.bloodGlucoseHigh)))"
            } else if currentValue < thresholds.bloodGlucoseLow {
                alertReason = "Blood glucose LOW: \(Int(currentValue)) mg/dL (threshold: \(Int(thresholds.bloodGlucoseLow)))"
            }
        case .bloodPressureSystolic:
            if currentValue > thresholds.systolicHigh {
                alertReason = "Systolic BP HIGH: \(Int(currentValue)) mmHg (threshold: \(Int(thresholds.systolicHigh)))"
            }
        case .bloodPressureDiastolic:
            if currentValue > thresholds.diastolicHigh {
                alertReason = "Diastolic BP HIGH: \(Int(currentValue)) mmHg (threshold: \(Int(thresholds.diastolicHigh)))"
            }
        default:
            break
        }

        if let reason = alertReason {
            await fireAlert(label: label, reason: reason, value: currentValue)
        }
    }

    // MARK: - Alert Firing

    private func fireAlert(label: String, reason: String, value: Double) async {
        lastAlertTimes[label] = Date()
        alertCount += 1
        lastAlert = reason

        let payload: [String: Any] = [
            "priority": "alert",
            "alert_type": label,
            "alert_reason": reason,
            "value": round(value * 100) / 100,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": "novahealth_alert_engine",
        ]

        print("[NovaHealth ALERT] \(reason)")

        // Push immediately with alert priority
        let success = await HealthPusher.shared.push(payload)
        if !success {
            print("[NovaHealth ALERT] Alert push failed — queued offline")
        }
    }

    // MARK: - Helpers

    private nonisolated func unitFor(identifier: HKQuantityTypeIdentifier) -> HKUnit {
        switch identifier {
        case .heartRate: return .beatsPerMinute()
        case .oxygenSaturation: return .percent()
        case .respiratoryRate: return .count().unitDivided(by: .minute())
        case .bloodGlucose: return HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        case .bloodPressureSystolic, .bloodPressureDiastolic: return .millimeterOfMercury()
        default: return .count()
        }
    }
}
