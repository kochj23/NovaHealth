// NovaHealth — Multi-Day Offline Queue (Enterprise Feature #5)
// Written by Jordan Koch
//
// SQLite-backed queue (via SwiftData) stores all pushes when Mac is unreachable.
// Drains on reconnect with dedup (409 Conflict = success).
// BGProcessingTask triggers large drains when device is idle.

import Foundation
import SwiftData

// MARK: - Queue Entry Model

@Model
final class QueuedPush {
    @Attribute(.unique) var id: String
    var payload: Data
    var createdAt: Date
    var retryCount: Int
    var endpoint: String

    init(payload: Data, endpoint: String) {
        self.id = UUID().uuidString
        self.payload = payload
        self.createdAt = Date()
        self.retryCount = 0
        self.endpoint = endpoint
    }
}

// MARK: - Offline Queue Manager

@MainActor
class OfflineQueue: ObservableObject {
    static let shared = OfflineQueue()

    @Published var queuedCount: Int = 0
    @Published var isDraining: Bool = false
    @Published var lastDrainResult: String = ""

    private var container: ModelContainer?
    private var context: ModelContext?

    /// Maximum retries before discarding a queued push
    private let maxRetries = 10

    /// Maximum age for queued items (7 days)
    private let maxAge: TimeInterval = 7 * 86400

    /// Delay between drain pushes to avoid overwhelming the server
    private let drainDelay: UInt64 = 50_000_000 // 50ms

    init() {
        setupStorage()
    }

    // MARK: - Storage Setup

    private func setupStorage() {
        do {
            let schema = Schema([QueuedPush.self])
            let config = ModelConfiguration(
                "NovaHealthQueue",
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )
            container = try ModelContainer(for: schema, configurations: [config])
            if let container = container {
                context = ModelContext(container)
                updateCount()
            }
        } catch {
            print("[NovaHealth Queue] Failed to initialize SwiftData: \(error)")
            // Fallback: use in-memory container
            do {
                let schema = Schema([QueuedPush.self])
                let config = ModelConfiguration(
                    "NovaHealthQueueFallback",
                    schema: schema,
                    isStoredInMemoryOnly: true,
                    allowsSave: true
                )
                container = try ModelContainer(for: schema, configurations: [config])
                if let container = container {
                    context = ModelContext(container)
                }
            } catch {
                print("[NovaHealth Queue] CRITICAL: Cannot create even in-memory store: \(error)")
            }
        }
    }

    // MARK: - Enqueue

    /// Adds a failed push payload to the offline queue for later delivery.
    func enqueue(_ data: [String: Any], endpoint: String = "health") {
        guard let context = context else {
            print("[NovaHealth Queue] No storage context — payload lost")
            return
        }

        guard let payloadData = try? JSONSerialization.data(withJSONObject: data) else {
            print("[NovaHealth Queue] Failed to serialize payload for queue")
            return
        }

        let entry = QueuedPush(payload: payloadData, endpoint: endpoint)
        context.insert(entry)

        do {
            try context.save()
            queuedCount += 1
            print("[NovaHealth Queue] Enqueued payload (\(queuedCount) in queue)")
        } catch {
            print("[NovaHealth Queue] Failed to save queued push: \(error)")
        }
    }

    // MARK: - Drain Queue

    /// Attempts to deliver all queued payloads. Called on reconnect or by BGProcessingTask.
    /// Treats 409 Conflict as success (server already has the data).
    func drainQueue() async {
        guard let context = context else { return }
        guard !isDraining else {
            print("[NovaHealth Queue] Drain already in progress")
            return
        }

        isDraining = true
        print("[NovaHealth Queue] Starting queue drain...")

        // Fetch all queued items, oldest first
        let descriptor = FetchDescriptor<QueuedPush>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )

        do {
            let items = try context.fetch(descriptor)
            guard !items.isEmpty else {
                isDraining = false
                lastDrainResult = "Queue empty"
                return
            }

            var delivered = 0
            var failed = 0
            var expired = 0

            for item in items {
                // Check if task is cancelled (BGProcessingTask expiration)
                if Task.isCancelled { break }

                // Remove expired items
                if Date().timeIntervalSince(item.createdAt) > maxAge {
                    context.delete(item)
                    expired += 1
                    continue
                }

                // Remove items that exceeded max retries
                if item.retryCount >= maxRetries {
                    context.delete(item)
                    expired += 1
                    continue
                }

                // Attempt delivery
                let success = await deliverQueuedItem(item)
                if success {
                    context.delete(item)
                    delivered += 1
                } else {
                    item.retryCount += 1
                    failed += 1
                }

                // Rate limit between deliveries
                try? await Task.sleep(nanoseconds: drainDelay)
            }

            try? context.save()
            updateCount()

            let result = "Drain complete: \(delivered) delivered, \(failed) failed, \(expired) expired"
            lastDrainResult = result
            print("[NovaHealth Queue] \(result)")

        } catch {
            print("[NovaHealth Queue] Fetch failed during drain: \(error)")
            lastDrainResult = "Drain error: \(error.localizedDescription)"
        }

        isDraining = false
    }

    // MARK: - Individual Delivery

    private func deliverQueuedItem(_ item: QueuedPush) async -> Bool {
        let baseURL = MTLSManager.shared.serverURL ?? "http://192.168.1.6:37450"
        let endpoint = "\(baseURL)/\(item.endpoint)"
        guard let url = URL(string: endpoint) else { return false }

        let session = MTLSManager.shared.isConfigured
            ? MTLSManager.shared.secureSession
            : URLSession.shared

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("offline-queue", forHTTPHeaderField: "X-NovaHealth-Source")
        request.setValue(item.id, forHTTPHeaderField: "X-NovaHealth-Idempotency-Key")
        request.timeoutInterval = 10
        request.httpBody = item.payload

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                // 200-299 = success, 409 = duplicate (also success for us)
                if (200...299).contains(http.statusCode) || http.statusCode == 409 {
                    return true
                }
            }
        } catch {
            // Network error — item stays in queue
        }

        return false
    }

    // MARK: - Maintenance

    /// Removes all items older than maxAge
    func pruneExpired() {
        guard let context = context else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let descriptor = FetchDescriptor<QueuedPush>(
            predicate: #Predicate { $0.createdAt < cutoff }
        )

        do {
            let expired = try context.fetch(descriptor)
            for item in expired {
                context.delete(item)
            }
            try context.save()
            updateCount()
            print("[NovaHealth Queue] Pruned \(expired.count) expired items")
        } catch {
            print("[NovaHealth Queue] Prune failed: \(error)")
        }
    }

    /// Clears the entire queue (for testing or manual reset)
    func clearAll() {
        guard let context = context else { return }
        let descriptor = FetchDescriptor<QueuedPush>()

        do {
            let all = try context.fetch(descriptor)
            for item in all {
                context.delete(item)
            }
            try context.save()
            queuedCount = 0
            print("[NovaHealth Queue] Queue cleared")
        } catch {
            print("[NovaHealth Queue] Clear failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func updateCount() {
        guard let context = context else { return }
        let descriptor = FetchDescriptor<QueuedPush>()
        queuedCount = (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Attempts a connectivity check and triggers drain if server is reachable
    func checkConnectivityAndDrain() async {
        let baseURL = MTLSManager.shared.serverURL ?? "http://192.168.1.6:37450"
        guard let url = URL(string: "\(baseURL)/health") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                // Server is reachable — drain queue
                if queuedCount > 0 {
                    await drainQueue()
                }
            }
        } catch {
            // Server unreachable — nothing to do
        }
    }
}
