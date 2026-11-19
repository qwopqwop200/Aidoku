import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct NativeSourceRoutingTests {
    /// Every built-in native port, routed by exact source id and recovered package version.
    private static var builtIns: [(id: String, version: Int, matches: (Any) -> Bool)] { [
        ("ja.mangarawbest", 2, { $0 is MangarawBestSourceRunner }),
        ("ja.mangarawjp", 2, { $0 is MangarawJPSourceRunner }),
        ("ja.rawdevart", 3, { $0 is RawdevartSourceRunner }),
        ("ja.rawkuma", 6, { $0 is RawkumaSourceRunner }),
        ("ja.rawotaku", 2, { $0 is RawOtakuSourceRunner }),
        ("ja.senmanga", 2, { $0 is SenMangaSourceRunner }),
        ("ja.soraraw", 5, { $0 is SoraRawSourceRunner }),
        ("ja.spoilerplus", 1, { $0 is SpoilerPlusSourceRunner }),
        ("ko.yomii", 7, { $0 is YomiiSourceRunner }),
        ("multi.ehentai", 2, { $0 is EHentaiSourceRunner }),
        ("multi.hitomi", 2, { $0 is HitomiSourceRunner }),
        ("multi.nhentai", 17, { $0 is NHentaiSourceRunner })
    ] }

    private func package(_ manifest: String, executable: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("source.json"))
        if executable { try Data([0, 97, 115, 109]).write(to: directory.appendingPathComponent("main.wasm")) }
        return directory
    }

    private func manifest(_ id: String, version: Int) -> String {
        #"{"info":{"id":"\#(id)","name":"Native","version":\#(version),"languages":["ja"]}}"#
    }

    @Test func builtInPackagesLoadTheirNativeRunnerWithoutExecutable() async throws {
        for source in Self.builtIns {
            let directory = try package(manifest(source.id, version: source.version))
            defer { try? FileManager.default.removeItem(at: directory) }
            let loaded = try await NativeSourceRegistration.loadPackage(at: directory, expectedKey: source.id)
            #expect(loaded.key == source.id)
            #expect(loaded.version == source.version)
            #expect(source.matches(loaded.runner), "\(source.id) routed to the wrong runner")
            #expect(loaded.isExternal)
        }
    }

    @Test func builtInIdentitiesRejectOtherVersions() async throws {
        for source in Self.builtIns {
            let version = source.version + 10_000
            let directory = try package(manifest(source.id, version: version))
            defer { try? FileManager.default.removeItem(at: directory) }
            await #expect(throws: AidokuRunner.Source.InitError.unsupportedNativeSource(sourceKey: source.id, version: version)) {
                _ = try await NativeSourceRegistration.loadPackage(at: directory)
            }
        }
    }

    @Test func unknownPackageIsRejectedEvenWithExecutablePresent() async throws {
        let directory = try package(manifest("test.unsupported", version: 99), executable: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: AidokuRunner.Source.InitError.unsupportedNativeSource(sourceKey: "test.unsupported", version: 99)) {
            _ = try await NativeSourceRegistration.loadPackage(at: directory)
        }
    }

    @Test func legacyPackageIsRejectedWithoutWasmRuntime() async throws {
        let directory = try package(#"{"info":{"id":"test.legacy","name":"Legacy","version":1,"lang":"en"}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: AidokuRunner.Source.InitError.unsupportedNativeSource(sourceKey: "test.legacy", version: 1)) {
            _ = try await NativeSourceRegistration.loadPackage(at: directory)
        }
    }

    @Test func installedPackageKeyMismatchIsRejectedBeforeLoading() async throws {
        let directory = try package(manifest("multi.hitomi", version: 2))
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: NativeSourceRegistration.PackageError.keyMismatch) {
            _ = try await NativeSourceRegistration.loadPackage(at: directory, expectedKey: "another.source")
        }
    }
}
