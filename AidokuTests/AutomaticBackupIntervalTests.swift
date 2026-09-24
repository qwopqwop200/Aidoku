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

    @Test func invalidPersistedIntervalLeavesBackupTimestampUnchanged() async {
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
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        settings.enabled.set(true)
        settings.interval.set("corrupted-backup-interval")
        settings.lastBackup.set(timestamp)
        await BackupManager.shared.scheduleAutoBackup()
        #expect(settings.lastBackup.get() == timestamp)
        #expect(settings.interval.get() == "corrupted-backup-interval")
    }
}
