import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Schedules and runs unattended Drive backups via `BGProcessingTaskRequest`.
///
/// It needs only the signed-in account (the refresh token is in the Keychain,
/// `AfterFirstUnlockThisDeviceOnly`, so it's readable after the first unlock even
/// while the app is backgrounded) and network — no stored passphrase, because the
/// managed key comes from Drive.
///
/// The hidden vault's key is biometry-gated and cannot be read in the background,
/// so `autoBackupIfSafe()` declines when hidden content exists rather than
/// uploading a partial that would clobber a fuller manual backup. See
/// BACKUP_SYNC.md for that trade-off.
enum BackgroundBackup {

    /// Must also be listed in Info.plist under `BGTaskSchedulerPermittedIdentifiers`.
    static let taskIdentifier = "com.filewall.autobackup"

#if os(iOS)
    /// Call once, before the app finishes launching (e.g. in the App initializer /
    /// `application(_:didFinishLaunchingWithOptions:)`).
    static func registerHandler() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handle(task)
        }
    }

    /// Ask the system to run a backup later. Call after a successful sign-in and
    /// after each run.
    static func schedule(after interval: TimeInterval = 6 * 60 * 60) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date().addingTimeInterval(interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Cancel any pending scheduled backup (the "Back up daily" toggle turning off).
    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    private static func handle(_ task: BGProcessingTask) {
        schedule() // always queue the next one first

        let work = Task {
            do {
                _ = try await DriveBackupService.shared.autoBackupIfSafe()
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
#else
    // macOS has no BGTaskScheduler. Scheduled background backup is iOS-only for
    // now; on macOS the user runs backups manually (a future macOS build could
    // use NSBackgroundActivityScheduler). No-ops keep call sites cross-platform.
    static func registerHandler() {}
    static func schedule(after interval: TimeInterval = 6 * 60 * 60) {}
    static func cancel() {}
#endif
}
