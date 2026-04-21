// NovaHealth — Content View
// Written by Jordan Koch

import SwiftUI

struct ContentView: View {
    @StateObject private var pusher = HealthPusher.shared

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "heart.text.clipboard")
                .font(.system(size: 48))
                .foregroundStyle(.pink)

            Text("Nova Health")
                .font(.title)
                .fontWeight(.bold)

            VStack(spacing: 8) {
                statusRow("HealthKit", value: pusher.isAuthorized ? "Authorized" : "Pending",
                          color: pusher.isAuthorized ? .green : .orange)
                statusRow("Last Push", value: pusher.lastPush.map { timeAgo($0) } ?? "Never",
                          color: pusher.lastPush != nil ? .green : .secondary)
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(12)

            Text(pusher.lastResult)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

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
            .padding(.horizontal)

            Text("Auto-pushes daily at ~6am via background refresh.\nData goes to your Mac only — never cloud.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .task {
            _ = await pusher.requestAuth()
        }
    }

    private func statusRow(_ label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(color)
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
