// NovaHealth — Silent HealthKit → Nova bridge for iPhone
// Written by Jordan Koch
//
// Reads HealthKit daily, POSTs to Nova's receiver on the Mac.
// Minimal UI — just a status screen. Runs via background app refresh.
// Enterprise: Real-time alerts, ML anomaly detection, workout tracking,
//             mTLS transport, offline queue with SQLite persistence.

import SwiftUI
import HealthKit
import BackgroundTasks

@main
struct NovaHealthApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    /// The running background collection task, stored so expiration handler can cancel it
    private var activeCollectionTask: Task<Void, Never>?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Register daily refresh task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "net.digitalnoise.NovaHealth.refresh", using: nil) { task in
            // FIX #1: Safe cast instead of force cast — prevents crash if wrong task type
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefresh(task: refreshTask)
        }

        // Register processing task for offline queue drain
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "net.digitalnoise.NovaHealth.queueDrain", using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleQueueDrain(task: processingTask)
        }

        scheduleAppRefresh()
        scheduleQueueDrain()

        // Start real-time health alerts observer
        Task {
            await HealthAlertEngine.shared.startObserving()
        }

        return true
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "net.digitalnoise.NovaHealth.refresh")
        request.earliestBeginDate = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 6, minute: 0), matchingPolicy: .nextTime)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[NovaHealth] Background refresh scheduled for ~6am")
        } catch {
            print("[NovaHealth] Could not schedule refresh: \(error)")
        }
    }

    func scheduleQueueDrain() {
        let request = BGProcessingTaskRequest(identifier: "net.digitalnoise.NovaHealth.queueDrain")
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[NovaHealth] Queue drain task scheduled")
        } catch {
            print("[NovaHealth] Could not schedule queue drain: \(error)")
        }
    }

    func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        let pusher = HealthPusher.shared

        // FIX #2: Expiration handler cancels the running task and reports failure
        let collectionTask = Task {
            await pusher.collectAndPush()
            task.setTaskCompleted(success: true)
        }
        activeCollectionTask = collectionTask

        task.expirationHandler = { [weak self] in
            self?.activeCollectionTask?.cancel()
            task.setTaskCompleted(success: false)
            print("[NovaHealth] Background refresh expired — task cancelled")
        }
    }

    func handleQueueDrain(task: BGProcessingTask) {
        scheduleQueueDrain()

        let drainTask = Task {
            await OfflineQueue.shared.drainQueue()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            drainTask.cancel()
            task.setTaskCompleted(success: false)
            print("[NovaHealth] Queue drain expired — task cancelled")
        }
    }
}
