import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeSourceBackupCoverageTests {
    private final class BundleMarker: NSObject {}

    private struct Backup: Decodable {
        let manifest: AidokuRunner.SourceInfo
        let filters: [AidokuRunner.Filter]
        let settings: [AidokuRunner.Setting]
        let provenance: Provenance
    }
    private struct Provenance: Decodable {
        let backupPath: String
        let manifestSHA256: String
        let wasmSHA256: String
    }

    private func fixtures() throws -> [Backup] {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "NativeSourceBackupMetadata", withExtension: "json")
            ?? bundle.url(forResource: "NativeSourceBackupMetadata", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([Backup].self, from: Data(contentsOf: url))
    }

    private func payload(_ backup: Backup, version: Int? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let encoder = JSONEncoder()
            var manifest = try JSONSerialization.jsonObject(with: encoder.encode(backup.manifest)) as! [String: Any]
            if let version {
                var info = manifest["info"] as! [String: Any]
                info["version"] = version
                manifest["info"] = info
            }
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("source.json"))
            try encoder.encode(backup.filters).write(to: folder.appendingPathComponent("filters.json"))
            try encoder.encode(backup.settings).write(to: folder.appendingPathComponent("settings.json"))
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    @Test func everyRecoveredInstalledSourceLoadsWithoutExecutableAndPreservesMetadata() async throws {
        let backups = try fixtures()
        let expectedVersions = [
            "ja.mangarawbest": 2, "ja.mangarawjp": 2, "ja.rawdevart": 3, "ja.rawkuma": 6,
            "ja.rawotaku": 2, "ja.senmanga": 2, "ja.soraraw": 5, "ja.spoilerplus": 1,
            "ko.yomii": 7, "multi.ehentai": 2, "multi.hitomi": 2, "multi.nhentai": 17
        ]
        #expect(backups.count == 12)
        #expect(Set(backups.map { $0.manifest.info.id }) == Set(expectedVersions.keys))
        for backup in backups {
            let info = backup.manifest.info
            #expect(expectedVersions[info.id] == info.version)
            #expect(backup.provenance.manifestSHA256.count == 64)
            #expect(backup.provenance.wasmSHA256.count == 64)
            let directory = try payload(backup)
            defer { try? FileManager.default.removeItem(at: directory) }
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("main.wasm").path))
            let source = try await NativeSourceRegistration.loadPackage(at: directory, expectedKey: info.id)
            #expect(source.key == info.id)
            #expect(source.version == info.version)
            #expect(source.name == info.name)
            #expect(source.languages == info.languages)
            #expect(source.contentRating == (info.contentRating ?? .safe))
            let listings = source.staticListings
            #expect(listings == (backup.manifest.listings ?? []).map(\.listing))
            let filters = source.staticFilters
            #expect(Array(filters.prefix(backup.filters.count)) == backup.filters)
            #expect(Array(source.staticSettings.suffix(backup.settings.count)) == backup.settings)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("main.wasm").path))
        }
    }

    @Test func allRecoveredIdentitiesRejectUnknownVersionsWithoutExecutableFallback() async throws {
        for backup in try fixtures() {
            let rejectedVersion = backup.manifest.info.version + 10_000
            let directory = try payload(backup, version: rejectedVersion)
            defer { try? FileManager.default.removeItem(at: directory) }
            await #expect(throws: AidokuRunner.Source.InitError.unsupportedNativeSource(
                sourceKey: backup.manifest.info.id, version: rejectedVersion
            )) {
                _ = try await NativeSourceRegistration.loadPackage(at: directory)
            }
        }
    }
}
