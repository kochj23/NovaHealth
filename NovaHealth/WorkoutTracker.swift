// NovaHealth — Workout Session Tracking (Enterprise Feature #3)
// Written by Jordan Koch
//
// Queries HKWorkout + associated heart rate series.
// Calculates recovery HR at +1/+2/+5 min post-workout.
// Pushes as /health/workout payload.

import Foundation
import HealthKit

@MainActor
class WorkoutTracker: ObservableObject {
    static let shared = WorkoutTracker()

    private let store = HKHealthStore()

    @Published var lastWorkout: WorkoutSummary?
    @Published var workoutCount: Int = 0

    struct WorkoutSummary: Identifiable {
        let id = UUID()
        let type: String
        let startDate: Date
        let duration: TimeInterval
        let activeCalories: Double
        let avgHeartRate: Double
        let maxHeartRate: Double
        let recoveryHR1min: Double?
        let recoveryHR2min: Double?
        let recoveryHR5min: Double?
    }

    // MARK: - Workout Query

    /// Fetches the most recent workout and its associated heart rate data.
    /// Calculates recovery HR at +1, +2, and +5 minutes post-workout.
    func fetchAndPushLatestWorkout() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        // Fetch most recent workout from last 24 hours
        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-86400),
            end: Date(),
            options: .strictStartDate
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let workout: HKWorkout? = await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                cont.resume(returning: samples?.first as? HKWorkout)
            }
            self.store.execute(query)
        }

        guard let workout = workout else {
            print("[NovaHealth Workout] No recent workouts found")
            return
        }

        // Fetch HR during workout
        let workoutHR = await fetchHeartRateDuring(workout: workout)
        let avgHR = workoutHR.isEmpty ? 0 : workoutHR.reduce(0, +) / Double(workoutHR.count)
        let maxHR = workoutHR.max() ?? 0

        // Fetch recovery HR at +1, +2, +5 minutes after workout end
        let recovery1 = await fetchRecoveryHR(after: workout.endDate, offsetMinutes: 1)
        let recovery2 = await fetchRecoveryHR(after: workout.endDate, offsetMinutes: 2)
        let recovery5 = await fetchRecoveryHR(after: workout.endDate, offsetMinutes: 5)

        let activeCalories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0

        let summary = WorkoutSummary(
            type: workoutTypeName(workout.workoutActivityType),
            startDate: workout.startDate,
            duration: workout.duration,
            activeCalories: activeCalories,
            avgHeartRate: avgHR,
            maxHeartRate: maxHR,
            recoveryHR1min: recovery1,
            recoveryHR2min: recovery2,
            recoveryHR5min: recovery5
        )

        lastWorkout = summary
        workoutCount += 1

        // Build and push payload
        await pushWorkoutPayload(summary)
    }

    // MARK: - Heart Rate During Workout

    private func fetchHeartRateDuring(workout: HKWorkout) async -> [Double] {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }

        let predicate = HKQuery.predicateForSamples(
            withStart: workout.startDate,
            end: workout.endDate,
            options: .strictStartDate
        )
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let values = (samples as? [HKQuantitySample])?.map {
                    $0.quantity.doubleValue(for: .beatsPerMinute())
                } ?? []
                cont.resume(returning: values)
            }
            self.store.execute(query)
        }
    }

    // MARK: - Recovery Heart Rate

    /// Fetches heart rate sample closest to the specified offset after workout end.
    /// Uses a 60-second window around the target time.
    private func fetchRecoveryHR(after endDate: Date, offsetMinutes: Int) async -> Double? {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return nil }

        let targetTime = endDate.addingTimeInterval(Double(offsetMinutes) * 60)
        let windowStart = targetTime.addingTimeInterval(-30)
        let windowEnd = targetTime.addingTimeInterval(30)

        // Don't try to fetch recovery data from the future
        guard windowEnd <= Date() else { return nil }

        let predicate = HKQuery.predicateForSamples(
            withStart: windowStart,
            end: windowEnd,
            options: .strictStartDate
        )

        // Get sample closest to target time
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                guard let hrSamples = samples as? [HKQuantitySample], !hrSamples.isEmpty else {
                    cont.resume(returning: nil)
                    return
                }
                // Find the sample closest to target time
                let closest = hrSamples.min(by: {
                    abs($0.startDate.timeIntervalSince(targetTime)) < abs($1.startDate.timeIntervalSince(targetTime))
                })
                cont.resume(returning: closest?.quantity.doubleValue(for: .beatsPerMinute()))
            }
            self.store.execute(query)
        }
    }

    // MARK: - Push Workout

    private func pushWorkoutPayload(_ summary: WorkoutSummary) async {
        var payload: [String: Any] = [
            "workout_type": summary.type,
            "start_date": ISO8601DateFormatter().string(from: summary.startDate),
            "duration_seconds": Int(summary.duration),
            "active_calories": round(summary.activeCalories * 10) / 10,
            "avg_heart_rate": round(summary.avgHeartRate),
            "max_heart_rate": round(summary.maxHeartRate),
            "source": "novahealth_workout",
        ]

        if let r1 = summary.recoveryHR1min {
            payload["recovery_hr_1min"] = round(r1)
        }
        if let r2 = summary.recoveryHR2min {
            payload["recovery_hr_2min"] = round(r2)
        }
        if let r5 = summary.recoveryHR5min {
            payload["recovery_hr_5min"] = round(r5)
        }

        // Calculate recovery score (higher drop = better fitness)
        if let r1 = summary.recoveryHR1min, summary.maxHeartRate > 0 {
            let recoveryDrop = summary.maxHeartRate - r1
            payload["recovery_score_1min"] = round(recoveryDrop)
        }

        let _ = await HealthPusher.shared.push(payload)
    }

    // MARK: - Helpers

    private func workoutTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .walking: return "walking"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .functionalStrengthTraining: return "strength"
        case .highIntensityIntervalTraining: return "hiit"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .stairClimbing: return "stairs"
        case .coreTraining: return "core"
        case .flexibility: return "flexibility"
        case .dance: return "dance"
        case .cooldown: return "cooldown"
        case .mixedCardio: return "mixed_cardio"
        default: return "other"
        }
    }
}
