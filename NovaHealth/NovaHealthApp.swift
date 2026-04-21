// NovaHealth — Silent HealthKit → Nova bridge for iPhone
// Written by Jordan Koch
//
// Reads HealthKit daily, POSTs to Nova's receiver on the Mac.
// Minimal UI — just a status screen. Runs via background app refresh.

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
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "net.digitalnoise.NovaHealth.refresh", using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        scheduleAppRefresh()
        return true
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "net.digitalnoise.NovaHealth.refresh")
        request.earliestBeginDate = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 6, minute: 0), matchingPolicy: .nextTime)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[NovaHealth] Background refresh scheduled for ~6am")
        } catch {
            print("[NovaHealth] Could not schedule: \(error)")
        }
    }

    func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        let pusher = HealthPusher.shared
        task.expirationHandler = { }
        Task {
            await pusher.collectAndPush()
            task.setTaskCompleted(success: true)
        }
    }
}
