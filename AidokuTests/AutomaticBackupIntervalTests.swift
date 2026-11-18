import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct AutomaticBackupIntervalTests {
    @Test func corruptedBackupIntervalsCannotScheduleImmediateRecurringWork() {
        for value in ["", "0", "daily ", "never", "unknown", "-1"] {
            #expect(BackupManager.autoBackupInterval(for: value) == nil)
        }
    }

    @Test func supportedIntervalsRetainTheirExistingDurations() {
        let expected: [(String, TimeInterval)] = [
            ("6hours", 21_600), ("12hours", 43_200), ("daily", 86_400),
            ("2days", 172_800), ("weekly", 604_800)
        ]
        for (value, duration) in expected {
            #expect(BackupManager.autoBackupInterval(for: value) == duration)
        }
    }

    @Test func staleBackgroundDeliverySkipsTheSnapshotAfterAForegroundBackup() async {
        await withRestoredBackupScheduleDefaults { settings in
            let timestamp = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
            settings.enabled.set(true)
            settings.interval.set("weekly")
            settings.lastBackup.set(timestamp)
            let manager = BackupManager()
            let handled = await manager.performAutoBackupIfDue {
                Issue.record("A fresh automatic backup must skip the database snapshot and retention scan")
                return false
            }
            #expect(handled)
            #expect(settings.lastBackup.get() == timestamp)
        }
    }

    @Test func invalidPersistedIntervalLeavesBackupTimestampUnchanged() async {
        await withRestoredBackupScheduleDefaults { settings in
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            settings.enabled.set(true)
            settings.interval.set("corrupted-backup-interval")
            settings.lastBackup.set(timestamp)
            await BackupManager.shared.scheduleAutoBackup()
            #expect(settings.lastBackup.get() == timestamp)
            #expect(settings.interval.get() == "corrupted-backup-interval")
        }
    }

    private func withRestoredBackupScheduleDefaults(_ operation: (BackupsSettings.AutoBackupsSettings) async -> Void) async {
        let settings = AppSettings.backups.autoBackups
        let keys = [settings.enabled.key, settings.interval.key, settings.lastBackup.key]
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let original = keys.map { domain[$0] }
        defer {
            for (key, value) in zip(keys, original) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        await operation(settings)
    }
}
