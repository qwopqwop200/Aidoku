import AidokuRunner
import Foundation
import Testing
import ZIPFoundation
@testable import Aidoku

struct NativeSourceRoutingTests {
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
