import Foundation
import Testing
@testable import Aidoku

/// Root-only utility for restoring the exact preference domain around native UI tests.
/// Private backup never leaves the dedicated audit simulator or enters test attachments.
@Suite(.serialized) @MainActor
struct Round2PreferencesAuditTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("Round2PreferencesAudit/enabled").path)))
    func backupOrRestoreExactPreferenceDomain() throws {
#if targetEnvironment(simulator)
        let root = URL.documentsDirectory.appendingPathComponent("Round2PreferencesAudit")
        try #require(try String(contentsOf: root.appendingPathComponent("enabled"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "dedicated-audit-simulator")
        let action = try String(contentsOf: root.appendingPathComponent("action"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        let domain = try #require(Bundle.main.bundleIdentifier)
        let backup = root.appendingPathComponent("private-domain.plist")
        if action == "backup" {
            try #require(!FileManager.default.fileExists(atPath: backup.path), "Do not overwrite an outstanding preference backup")
            let value: [String: Any] = ["exists": defaults.persistentDomain(forName: domain) != nil,
                "domain": defaults.persistentDomain(forName: domain) ?? [:]]
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
                .write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        } else {
            try #require(action == "restore")
            let value = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: backup), options: 0, format: nil) as? [String: Any])
            let original = try #require(value["domain"] as? [String: Any])
            if value["exists"] as? Bool == true { defaults.setPersistentDomain(original, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
            try #require(defaults.synchronize())
            let exact = NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:]).isEqual(to: original)
            try #require(exact, "Preference restoration must preserve every key and absent default")
            try FileManager.default.removeItem(at: backup)
        }
        try JSONSerialization.data(withJSONObject: ["action": action, "verified": true], options: .sortedKeys)
            .write(to: root.appendingPathComponent(action + "-result.json"), options: .atomic)
#endif
    }
}
