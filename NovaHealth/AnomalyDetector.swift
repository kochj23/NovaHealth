// NovaHealth — On-Device ML Anomaly Detection (Enterprise Feature #2)
// Written by Jordan Koch
//
// Uses statistical analysis on a 30-day rolling window to detect anomalies.
// Adds anomaly_flags and trend_7d to push payload.
// Core ML model integration point provided for future trained model.

import Foundation
import HealthKit

@MainActor
class AnomalyDetector: ObservableObject {
    static let shared = AnomalyDetector()

    private let store = HKHealthStore()

    /// Anomaly detection uses a Z-score threshold — values beyond this many
    /// standard deviations from the 30-day mean are flagged as anomalous.
    private let zScoreThreshold: Double = 2.5

    /// Metrics to analyze for anomalies
    private let analyzedMetrics: [(HKQuantityTypeIdentifier, HKUnit, String)] = [
        (.heartRate, HKUnit.count().unitDivided(by: .minute()), "heart_rate"),
        (.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), "resting_heart_rate"),
        (.heartRateVariabilitySDNN, .secondUnit(with: .milli), "hrv"),
        (.stepCount, .count(), "steps"),
        (.oxygenSaturation, .percent(), "spo2_pct"),
        (.bodyMass, .pound(), "weight_lbs"),
    ]

    // MARK: - Public API

    /// Analyzes current metrics against 30-day rolling window.
    /// Returns dictionary with anomaly_flags (array of flagged metrics) and
    /// trend_7d (dictionary of 7-day directional trends per metric).
    func analyzeCurrentMetrics(_ currentData: [String: Any]) async -> [String: Any] {
        var anomalyFlags: [String] = []
        var trends: [String: String] = [:]

        for (identifier, unit, key) in analyzedMetrics {
            guard let currentValue = currentData[key] as? Double else { continue }

            // Fetch 30-day history for this metric
            let history = await fetch30DayHistory(identifier: identifier, unit: unit)
            guard history.count >= 7 else { continue } // Need at least a week of data

            // Z-score anomaly detection
            let mean = history.reduce(0, +) / Double(history.count)
            let variance = history.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(history.count)
            let stdDev = sqrt(variance)

            if stdDev > 0 {
                let zScore = abs(currentValue - mean) / stdDev
                if zScore > zScoreThreshold {
                    let direction = currentValue > mean ? "high" : "low"
                    anomalyFlags.append("\(key):\(direction):z=\(String(format: "%.1f", zScore))")
                }
            }

            // 7-day trend calculation
            let recent7 = Array(history.suffix(7))
            if recent7.count >= 2 {
                let trend = calculateTrend(recent7)
                trends[key] = trend
            }
        }

        var result: [String: Any] = [:]
        if !anomalyFlags.isEmpty {
            result["anomaly_flags"] = anomalyFlags
        }
        if !trends.isEmpty {
            result["trend_7d"] = trends
        }
        return result
    }

    // MARK: - 30-Day History Fetch

    private func fetch30DayHistory(identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> [Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }

        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -30, to: endDate) else { return [] }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        // Use statistics collection for daily aggregation
        var interval = DateComponents()
        interval.day = 1
        let anchorDate = calendar.startOfDay(for: startDate)

        return await withCheckedContinuation { cont in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .cumulativeSum],
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                guard let results = results else {
                    cont.resume(returning: [])
                    return
                }

                var dailyValues: [Double] = []
                results.enumerateStatistics(from: startDate, to: endDate) { stats, _ in
                    // Use average for discrete types (HR, weight, etc.)
                    // Use sum for cumulative types (steps, energy)
                    if let avg = stats.averageQuantity() {
                        dailyValues.append(avg.doubleValue(for: unit))
                    } else if let sum = stats.sumQuantity() {
                        dailyValues.append(sum.doubleValue(for: unit))
                    }
                }
                cont.resume(returning: dailyValues)
            }

            self.store.execute(query)
        }
    }

    // MARK: - Trend Analysis

    /// Calculates directional trend from an array of daily values.
    /// Returns "rising", "falling", "stable", or "volatile"
    private func calculateTrend(_ values: [Double]) -> String {
        guard values.count >= 2 else { return "insufficient_data" }

        // Simple linear regression slope
        let n = Double(values.count)
        let indices = Array(0..<values.count).map { Double($0) }
        let sumX = indices.reduce(0, +)
        let sumY = values.reduce(0, +)
        let sumXY = zip(indices, values).map { $0 * $1 }.reduce(0, +)
        let sumX2 = indices.map { $0 * $0 }.reduce(0, +)

        let denominator = n * sumX2 - sumX * sumX
        guard denominator != 0 else { return "stable" }

        let slope = (n * sumXY - sumX * sumY) / denominator
        let meanY = sumY / n

        // Normalize slope relative to mean
        guard meanY != 0 else { return "stable" }
        let normalizedSlope = slope / meanY

        // Also check volatility (coefficient of variation)
        let variance = values.map { ($0 - meanY) * ($0 - meanY) }.reduce(0, +) / n
        let cv = sqrt(variance) / abs(meanY)

        if cv > 0.3 {
            return "volatile"
        } else if normalizedSlope > 0.02 {
            return "rising"
        } else if normalizedSlope < -0.02 {
            return "falling"
        } else {
            return "stable"
        }
    }
}
