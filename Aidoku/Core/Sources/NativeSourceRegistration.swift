import AidokuRunner
import Foundation

/// App-owned registrations for recoverable, version-scoped source ports.
/// Unsupported packages are rejected without executing bundled WASM.
enum NativeSourceRegistration {
    private static let registration: Result<Void, Error> = Result {
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "ja.mangarawbest", supportedVersions: [2]) { context in
            MangarawBestSourceRunner(sourceKey: context.sourceKey)
        }
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "ja.mangarawjp", supportedVersions: [2]) { context in
            MangarawJPSourceRunner(sourceKey: context.sourceKey)
        }
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "ja.rawdevart", supportedVersions: [3]) { context in
            RawdevartSourceRunner(sourceKey: context.sourceKey)
        }
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "ja.rawkuma", supportedVersions: [6]) { context in
            RawkumaSourceRunner(sourceKey: context.sourceKey)
        }
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "ja.rawotaku", supportedVersions: [2]) { context in
            RawOtakuSourceRunner(sourceKey: context.sourceKey)
        }
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "ja.senmanga", supportedVersions: [2]) { context in
            SenMangaSourceRunner(sourceKey: context.sourceKey)
        }
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "ja.soraraw", supportedVersions: [5]) { context in
            SoraRawSourceRunner(sourceKey: context.sourceKey)
        }
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "ja.spoilerplus", supportedVersions: [1]) { context in
            SpoilerPlusSourceRunner(sourceKey: context.sourceKey)
        }
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "ko.yomii", supportedVersions: [7]) { context in
            YomiiSourceRunner(sourceKey: context.sourceKey)
        }
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "multi.ehentai", supportedVersions: [2]) { context in
            EHentaiSourceRunner(sourceKey: context.sourceKey)
        }
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "multi.hitomi", supportedVersions: [2]) { context in
            HitomiSourceRunner(sourceKey: context.sourceKey)
        }
        try NativeSourceRunnerRegistry.shared.register(sourceKey: "multi.nhentai", supportedVersions: [17]) { context in
            NHentaiSourceRunner(sourceKey: context.sourceKey)
        }
    }

    static func ensureRegistered() throws {
        try registration.get()
    }

    /// Read modern package metadata and initialize only its registered native port.
    /// No archive executable is read or executed.
    static func loadPackage(at url: URL, expectedKey: String? = nil) async throws -> AidokuRunner.Source {
        try ensureRegistered()
        let data = try Data(contentsOf: url.appendingPathComponent("source.json"))
        let manifest: AidokuRunner.SourceInfo
        do {
            manifest = try JSONDecoder().decode(AidokuRunner.SourceInfo.self, from: data)
        } catch {
            if let historical = try? JSONDecoder().decode(LegacySourceManifest.self, from: data) {
                throw AidokuRunner.Source.InitError.unsupportedNativeSource(sourceKey: historical.info.id, version: historical.info.version)
            }
            throw error
        }
        guard expectedKey == nil || expectedKey == manifest.info.id else { throw PackageError.keyMismatch }
        return try await AidokuRunner.Source(key: manifest.info.id, url: url)
    }

    enum PackageError: Error, Equatable {
        case keyMismatch
    }
}
