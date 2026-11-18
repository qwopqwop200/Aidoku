import AidokuRunner
import Foundation
import Testing
import ZIPFoundation
@testable import Aidoku

struct NativeSourceRoutingTests {
    private actor ImportedRunners {
        private(set) var directories: [URL] = []
        private(set) weak var latest: TestableSourceRunner?

        func make(at url: URL) -> TestableSourceRunner {
            directories.append(url.standardizedFileURL)
            let runner = TestableSourceRunner()
            latest = runner
            return runner
        }
    }

    @Test @MainActor func delayedSnapshotCannotResurrectDisabledOrRemovedSource() {
        let store = SourceStore()
        let source = AidokuRunner.Source.test(runner: TestableSourceRunner())
        store.update(revision: 1, sourcesByKey: [source.key: source], disabledSourceKeys: [])
        store.update(revision: 3, sourcesByKey: [:], disabledSourceKeys: [source.key])
        store.update(revision: 2, sourcesByKey: [source.key: source], disabledSourceKeys: [])
        #expect(store.source(for: source.key) == nil)
        #expect(store.isDisabled(sourceKey: source.key))
        store.update(revision: 5, sourcesByKey: [:], disabledSourceKeys: [])
        store.update(revision: 4, sourcesByKey: [source.key: source], disabledSourceKeys: [])
        #expect(!store.isInstalled(sourceKey: source.key))
        #expect(!store.isDisabled(sourceKey: source.key))
    }

    @Test func customSourceMetadataMatchesItsRunnerIncludingLocalizedAndRenamedSources() {
        let config = CustomSourceConfig.KeyNameServer(key: "test.catalog", name: "Renamed Server", server: "https://example.invalid")
        let sources: [CustomSourceConfig] = [.local, .demo, .komga(config), .kavita(config), .suwayomi(config)]
        for source in sources {
            #expect(source.toInfo() == source.toSource().toInfo())
        }
    }

    @Test func archiveInitializesOnlyInstalledRunnersAndReleasesReplacedInstances() async throws {
        let manager = SourceManager.shared
        await manager.waitForSourcesLoad()
        let key = "test.import-" + UUID().uuidString.lowercased()
        let probe = ImportedRunners()
        try NativeSourceRunnerRegistry.shared.register(sourceKey: key, supportedVersions: [1, 2]) { [weak probe] context in
            guard let probe else { throw CancellationError() }
            return await probe.make(at: context.directoryURL)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payload = directory.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func install(version: Int) async throws {
            let info: [String: Any] = ["id": key, "name": "Import fixture", "version": version, "languages": ["en"]]
            let data = try JSONSerialization.data(withJSONObject: ["info": info])
            try data.write(to: payload.appendingPathComponent("source.json"))
            let archive = directory.appendingPathComponent("\(version).aix")
            try FileManager.default.zipItem(at: payload, to: archive)
            let source = try #require(try await manager.importSourceValidated(from: archive))
            #expect(source.version == version)
            #expect(await manager.source(for: key) === source)
        }

        do {
            try await install(version: 1)
            weak var previous = await probe.latest
            #expect(previous != nil)
            try await install(version: 2)
            #expect(previous == nil)
            let installed = SourceManager.directory.appendingPathComponent(key).standardizedFileURL.path
            #expect(await probe.directories.map(\.path) == [installed, installed])
            weak var current = await probe.latest
            await manager.remove(sourceKey: key)
            #expect(current == nil)
            #expect(await manager.source(for: key) == nil)
        } catch {
            await manager.remove(sourceKey: key)
            throw error
        }
    }

    @Test
    func installedNativePackageRetainsExternalClassification() {
        let source = AidokuRunner.Source(
            url: URL(fileURLWithPath: "/Sources/test.native"),
            key: "test.native",
            name: "Test Native",
            version: 2,
            contentRating: .safe,
            runner: TestableSourceRunner()
        )
        #expect(source.isExternal)
        #expect(source.toInfo().external)
    }

    @Test
    func customNativeSourceRetainsBuiltInClassification() {
        let source = AidokuRunner.Source.test(runner: TestableSourceRunner())
        #expect(!source.isExternal)
        #expect(!source.toInfo().external)
    }

    @Test
    func installedPackageKeyMismatchIsRejectedBeforeExecutableLoading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(#"{"info":{"id":"test.native","name":"Test Native","version":2,"languages":["en"]}}"#.utf8)
        try data.write(to: directory.appendingPathComponent("source.json"))
        await #expect(throws: NativeSourceRegistration.PackageError.keyMismatch) {
            _ = try await NativeSourceRegistration.loadPackage(at: directory, expectedKey: "another.source")
        }
    }

    @Test
    func legacyPackageIsRejectedWithoutWasmRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(#"{"info":{"id":"test.legacy","name":"Legacy","version":1,"lang":"en"}}"#.utf8)
        try data.write(to: directory.appendingPathComponent("source.json"))
        await #expect(throws: AidokuRunner.Source.InitError.unsupportedNativeSource(sourceKey: "test.legacy", version: 1)) {
            _ = try await NativeSourceRegistration.loadPackage(at: directory)
        }
    }
    @Test
    func recoveredHitomiVersionLoadsWithoutExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(#"{"info":{"id":"multi.hitomi","name":"Hitomi","version":2,"languages":["en"],"url":"https://hitomi.la"}}"#.utf8)
        try data.write(to: directory.appendingPathComponent("source.json"))
        let source = try await NativeSourceRegistration.loadPackage(at: directory, expectedKey: "multi.hitomi")
        #expect(source.runner is HitomiSourceRunner)
        #expect(source.key == "multi.hitomi")
        #expect(source.version == 2)
        #expect(source.isExternal)
    }

    @Test
    func unknownPackageIsRejectedEvenWithExecutablePresent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(#"{"info":{"id":"test.unsupported","name":"Unknown","version":99,"languages":["en"]}}"#.utf8)
        try data.write(to: directory.appendingPathComponent("source.json"))
        try Data([0, 97, 115, 109]).write(to: directory.appendingPathComponent("main.wasm"))
        await #expect(throws: AidokuRunner.Source.InitError.unsupportedNativeSource(sourceKey: "test.unsupported", version: 99)) {
            _ = try await NativeSourceRegistration.loadPackage(at: directory)
        }
    }

    @Test
    func directArchiveImportRetainsTypedUnsupportedSourceIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payload = directory.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(#"{"info":{"id":"test.unsupported","name":"Unknown","version":99,"languages":["en"]}}"#.utf8)
        try data.write(to: payload.appendingPathComponent("source.json"))
        let archive = directory.appendingPathComponent("unsupported.aix")
        try FileManager.default.zipItem(at: payload, to: archive)
        await #expect(throws: AidokuRunner.Source.InitError.unsupportedNativeSource(sourceKey: "test.unsupported", version: 99)) {
            _ = try await SourceManager.shared.importSourceValidated(from: archive)
        }
    }

    @Test
    func unsupportedVersionDescriptionIncludesSourceAndVersion() {
        let description = AidokuRunner.Source.InitError.unsupportedNativeSource(sourceKey: "test.unsupported", version: 99).aidokuDescription()
        #expect(description.contains("test.unsupported"))
        #expect(description.contains("99"))
        #expect(!description.contains("NATIVE_SOURCE_UNSUPPORTED_VERSION"))
    }

}
