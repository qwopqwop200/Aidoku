import Foundation

/// Optional lifecycle for native runners that hold source-specific caches or connections.
public protocol NativeSourceRunnerLifecycle: Runner {
    func restart() async throws
    func clearCache() async
}

/// Explicit, version-scoped native implementations for installed source manifests.
/// Register only manifest versions whose behavior the native implementation supports.
public final class NativeSourceRunnerRegistry: @unchecked Sendable {
    public static let shared = NativeSourceRunnerRegistry()

    public struct Context: Sendable {
        public let directoryURL: URL
        public let manifest: SourceInfo
        public var sourceKey: String { manifest.info.id }
        public var version: Int { manifest.info.version }

        public init(directoryURL: URL, manifest: SourceInfo) {
            self.directoryURL = directoryURL
            self.manifest = manifest
        }
    }

    public typealias Factory = @Sendable (Context) async throws -> Runner

    public enum RegistrationError: Error, Equatable {
        case invalidRegistration
        case duplicateRegistration(sourceKey: String, version: Int)
    }

    private let lock = NSLock()
    // Every read and write is protected by lock. Factories execute outside it.
    private var factories: [String: [Int: Factory]] = [:]

    public init() {}

    /// Registration is atomic; overlapping registrations fail without changing any version.
    public func register(sourceKey: String, supportedVersions: Set<Int>, factory: @escaping Factory) throws {
        guard !sourceKey.isEmpty, !supportedVersions.isEmpty else {
            throw RegistrationError.invalidRegistration
        }
        lock.lock()
        defer { lock.unlock() }
        for version in supportedVersions.sorted() where factories[sourceKey]?[version] != nil {
            throw RegistrationError.duplicateRegistration(sourceKey: sourceKey, version: version)
        }
        for version in supportedVersions {
            factories[sourceKey, default: [:]][version] = factory
        }
    }

    /// Nil means there is no supported replacement. A selected factory's error is propagated,
    /// so a broken native source cannot hide its initialization error.
    public func makeRunner(context: Context) async throws -> Runner? {
        try Task.checkCancellation()
        guard let factory = lookup(sourceKey: context.sourceKey, version: context.version) else { return nil }
        let runner = try await factory(context)
        try Task.checkCancellation()
        return runner
    }

    private func lookup(sourceKey: String, version: Int) -> Factory? {
        lock.lock()
        defer { lock.unlock() }
        return factories[sourceKey]?[version]
    }
}
