// NovaHealth — Content View
// Written by Jordan Koch

import SwiftUI

struct ContentView: View {
    @StateObject private var pusher = HealthPusher.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "heart.text.clipboard")
                    .font(.system(size: 44))
                    .foregroundStyle(.pink)

                Text("Nova Health")
                    .font(.title)
                    .fontWeight(.bold)

                VStack(spacing: 6) {
                    statusRow("HealthKit", value: pusher.isAuthorized ? "Authorized" : "Pending",
                              color: pusher.isAuthorized ? .green : .orange)
                    statusRow("Last Push", value: pusher.lastPush.map { timeAgo($0) } ?? "Never",
                              color: pusher.lastPush != nil ? .green : .secondary)
                    statusRow("Metrics", value: pusher.lastData.isEmpty ? "—" : "\(pusher.lastData.count) collected",
                              color: pusher.lastData.isEmpty ? .secondary : .blue)
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)

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

                Button {
                    Task { await pusher.exportHistory() }
                } label: {
                    Label("Export History (5 years)", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(pusher.historyRunning)

                if !pusher.historyProgress.isEmpty {
                    Text(pusher.historyProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Auto-pushes daily at ~6am\nData stays on your local network")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .task {
            _ = await pusher.requestAuth()
        }
    }

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
        guard let num = value as? Double else { return "\(value)" }
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
