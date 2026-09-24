import CryptoKit
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Aidoku

/// Root-controlled isolated simulator only. Exercises the actual SwiftUI change observer
/// and production scheduler; no injected callback that merely repeats the implementation.
@Suite(.serialized) @MainActor
struct Round2AutomaticBackupIntervalUITests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("Round2Data/enabled").path)))
    func changingIntervalWhileEnabledReevaluatesDueBackup() async throws {
#if targetEnvironment(simulator)
        let marker = URL.documentsDirectory.appendingPathComponent("Round2Data/enabled")
        try #require(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            == "dedicated-audit-simulator")
        let existing = Set(BackupManager.backupUrls)
        // Production retention keeps four automatic backups. Refuse a fixture that
        // would make this action evict one; preserve all existing files byte-for-byte.
        let automaticCount = existing.filter { BackupInfo.load(from: $0)?.automatic == true }.count
        try #require(automaticCount < 4, "Creating a backup must not invoke retention on existing data")
        let originalHashes = try Dictionary(uniqueKeysWithValues: existing.map { ($0, try fileHash($0)) })
        let defaults = UserDefaults.standard
        let bundle = try #require(Bundle.main.bundleIdentifier)
        let saved = defaults.persistentDomain(forName: bundle) ?? [:]
        let settings = AppSettings.backups.autoBackups
        let timestamp = Date().addingTimeInterval(-7 * 3600)
        settings.enabled.set(true)
        settings.interval.set("weekly")
        settings.lastBackup.set(timestamp)
        let persistedTimestamp = settings.lastBackup.get()
        for key in [settings.libraryEntries.key, settings.history.key, settings.chapters.key,
                    settings.tracking.key, settings.readingSessions.key, settings.vocabulary.key,
                    settings.updates.key, settings.categories.key, settings.settings.key,
                    settings.sourceLists.key, settings.sensitiveSettings.key] {
            defaults.set(false, forKey: key)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: AutomaticBackupsView())
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            defaults.setPersistentDomain(saved, forName: bundle)
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(settings.lastBackup.get() == persistedTimestamp)
        // Changing the persisted selection is the exact binding the production
        // SettingView writes. Enabled remains true throughout; no toggle rescue.
        settings.interval.set("6hours")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        let deadline = Date().addingTimeInterval(5)
        while settings.lastBackup.get() == persistedTimestamp, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let created = BackupManager.backupUrls.filter { !existing.contains($0) }
        defer { for file in created { try? FileManager.default.removeItem(at: file) } }
        #expect(settings.enabled.get())
        #expect(settings.interval.get() == "6hours")
        #expect(settings.lastBackup.get() > persistedTimestamp, "Enabled interval selection must reschedule the newly due backup")
        #expect(created.count == 1)
        #expect(existing.isSubset(of: Set(BackupManager.backupUrls)))
        for (file, expected) in originalHashes { #expect(try fileHash(file) == expected) }
        if let file = created.first {
            let backup = try #require(Backup.load(from: file))
            #expect(backup.automatic == true)
            #expect(backup.library == nil && backup.chapters == nil && backup.history == nil)
            #expect(backup.settings == nil && backup.sourceLists == nil)
        }
#else
        Issue.record("Dedicated simulator required")
#endif
    }

    private func fileHash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
