// NovaHealth — Content View
// Written by Jordan Koch

import SwiftUI

struct ContentView: View {
    @StateObject private var pusher = HealthPusher.shared
    @StateObject private var alertEngine = HealthAlertEngine.shared
    @StateObject private var workoutTracker = WorkoutTracker.shared
    @StateObject private var offlineQueue = OfflineQueue.shared
    @StateObject private var mtlsManager = MTLSManager.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    statusSection
                    alertsSection
                    metricsSection
                    actionsSection
                    queueSection
                    securitySection
                    infoSection
                }
                .padding()
            }
            .navigationTitle("Nova Health")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            _ = await pusher.requestAuth()
            // Try to drain offline queue on launch
            await offlineQueue.checkConnectivityAndDrain()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.text.clipboard")
                .font(.system(size: 44))
                .foregroundStyle(.pink)

            if alertEngine.alertCount > 0 {
                Label("\(alertEngine.alertCount) alerts fired", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(spacing: 6) {
            statusRow("HealthKit", value: pusher.isAuthorized ? "Authorized" : "Pending",
                      color: pusher.isAuthorized ? .green : .orange)
            statusRow("Last Push", value: pusher.lastPush.map { timeAgo($0) } ?? "Never",
                      color: pusher.lastPush != nil ? .green : .secondary)
            statusRow("Metrics", value: pusher.lastData.isEmpty ? "—" : "\(pusher.lastData.count) collected",
                      color: pusher.lastData.isEmpty ? .secondary : .blue)
            statusRow("Transport", value: mtlsManager.isPaired ? "mTLS" : "HTTP (LAN)",
                      color: mtlsManager.isPaired ? .green : .secondary)
            if offlineQueue.queuedCount > 0 {
                statusRow("Offline Queue", value: "\(offlineQueue.queuedCount) pending",
                          color: .orange)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }

    // MARK: - Alerts Section

    @ViewBuilder
    private var alertsSection: some View {
        if !alertEngine.lastAlert.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Latest Alert", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(alertEngine.lastAlert)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)
        }
    }

    // MARK: - Metrics

    @ViewBuilder
    private var metricsSection: some View {
        if !pusher.lastData.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Latest Data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                ForEach(pusher.lastData.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack {
                        Text(formatKey(key))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatValue(key, value))
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(12)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 12) {
            Text(pusher.lastResult)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await pusher.collectAndPush() }
            } label: {
                Label("Push Now", systemImage: "arrow.up.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .controlSize(.large)

            HStack(spacing: 12) {
                Button {
                    Task { await workoutTracker.fetchAndPushLatestWorkout() }
                } label: {
                    Label("Workout", systemImage: "figure.run")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task { await pusher.exportHistory() }
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(pusher.historyRunning)
            }

            if !pusher.historyProgress.isEmpty {
                Text(pusher.historyProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let workout = workoutTracker.lastWorkout {
                workoutSummaryView(workout)
            }
        }
    }

    // MARK: - Offline Queue Section

    @ViewBuilder
    private var queueSection: some View {
        if offlineQueue.queuedCount > 0 || !offlineQueue.lastDrainResult.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Offline Queue", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if offlineQueue.queuedCount > 0 {
                    Text("\(offlineQueue.queuedCount) items queued for delivery")
                        .font(.caption2)

                    Button {
                        Task { await offlineQueue.drainQueue() }
                    } label: {
                        Label("Drain Now", systemImage: "arrow.up.forward")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(offlineQueue.isDraining)
                }

                if !offlineQueue.lastDrainResult.isEmpty {
                    Text(offlineQueue.lastDrainResult)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(12)
        }
    }

    // MARK: - Security Section

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Security", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(mtlsManager.pairingStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !mtlsManager.isPaired {
                Text("Scan QR code from Mac server to enable mTLS")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    mtlsManager.unpair()
                } label: {
                    Label("Unpair", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }

    // MARK: - Info

    private var infoSection: some View {
        Text("Auto-pushes daily at ~6am\nReal-time alerts for threshold breaches\nData stays on your local network")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
    }

    // MARK: - Workout Summary

    private func workoutSummaryView(_ workout: WorkoutTracker.WorkoutSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Last Workout: \(workout.type.capitalized)", systemImage: "figure.run")
                .font(.caption)
                .foregroundStyle(.green)

            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("\(Int(workout.duration / 60)) min")
                        .font(.caption2).fontWeight(.medium)
                    Text("Duration").font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("\(Int(workout.avgHeartRate)) bpm")
                        .font(.caption2).fontWeight(.medium)
                    Text("Avg HR").font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("\(Int(workout.activeCalories)) kcal")
                        .font(.caption2).fontWeight(.medium)
                    Text("Calories").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let r1 = workout.recoveryHR1min {
                Text("Recovery: \(Int(r1)) bpm @ 1min (drop: \(Int(workout.maxHeartRate - r1)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private func statusRow(_ label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).foregroundStyle(color)
        }
    }

    private func formatKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func formatValue(_ key: String, _ value: Any) -> String {
        guard let num = value as? Double else {
            // Handle arrays and other types
            if let arr = value as? [String] {
                return arr.joined(separator: ", ")
            }
            return "\(value)"
        }
        switch key {
        case "sleep_hours": return String(format: "%.1f hrs", num)
        case "weight_lbs": return String(format: "%.1f lbs", num)
        case "body_fat_pct", "spo2_pct": return String(format: "%.1f%%", num * 100)
        case "blood_glucose_mgdl": return String(format: "%.0f mg/dL", num)
        case "bp_systolic", "bp_diastolic": return String(format: "%.0f mmHg", num)
        case "body_temp_f": return String(format: "%.1f°F", num)
        case "distance_miles": return String(format: "%.2f mi", num)
        case "steps", "flights_climbed": return String(format: "%.0f", num)
        default: return String(format: "%.1f", num)
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}
