import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct NativeSourceIntegrationAuditTests {
    private func storedMetadata(apiVersion: String, manifest: String) throws -> (SourceObjectData, URL) {
        let relativePath = "NativeSourceIntegrationAudit/" + UUID().uuidString
        let directory = FileManager.default.applicationSupportDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("source.json"))
        let entity = try #require(CoreDataManager.shared.container.managedObjectModel.entitiesByName["Source"])
        // Detached metadata object: no shared context insertion or persistence writes.
        let object = SourceObject(entity: entity, insertInto: nil)
        object.id = "audit.installed"
        object.apiVersion = apiVersion
        object.path = relativePath
        return (object.toData(), directory)
    }

    @Test func databaseBrowseMetadataClassifiesInstalledNativePackageAsExternal() throws {
        let (metadata, directory) = try storedMetadata(
            apiVersion: "0.7",
            manifest: #"{"info":{"id":"audit.installed","name":"Installed","version":2,"languages":["ja"]}}"#
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = try #require(metadata.toInfo())
        #expect(info.sourceId == "audit.installed")
        #expect(info.external)
    }

    @Test func unsupportedHistoricalPackagePreservesBrowseMetadataAndIdentity() async throws {
        let (metadata, directory) = try storedMetadata(
            apiVersion: "0.6",
            manifest: #"{"info":{"id":"audit.installed","name":"Historical","version":1,"lang":"ja","nsfw":0}}"#
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await metadata.toNewSource() == nil)
        let info = try #require(metadata.toInfo())
        #expect(info.sourceId == "audit.installed")
        #expect(info.name == "Historical")
        #expect(info.languages == ["ja"])
        #expect(info.external)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.json").path))
    }
}
