import CryptoKit
import Darwin
import Foundation

/// Core ML keys execution packages by model URL. Bundle URLs change on every
/// installation, so identical models live at a content-addressed, durable URL.
final class NativeCoreMLModelStore: @unchecked Sendable {
    static let shared = NativeCoreMLModelStore()
    private let lock = NSLock()
    private var resolved: [URL: URL] = [:]
    private var residentLeases: [URL: Int32] = [:]
    private var cleaned = false
    private let root: URL
    private let runtimeCache: URL?

    init(root: URL? = nil, runtimeCache: URL? = nil) {
        let manager = FileManager.default
        self.root = (root ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReaderCoreMLModels-v1", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
        self.runtimeCache = runtimeCache ?? Bundle.main.bundleIdentifier.map {
            manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
        }
    }

    deinit {
        for descriptor in residentLeases.values { close(descriptor) }
    }

    func modelURL(for source: URL) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = resolved[source], FileManager.default.fileExists(atPath: existing.path) { return existing }
        cleanLegacyOnce()
        let manager = FileManager.default
        let files = try regularFiles(in: source)
        guard !files.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var hash = SHA256()
        for file in files {
            let relative = String(file.path.dropFirst(source.path.count + 1))
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            hash.update(data: Data("\(relative.utf8.count):\(relative):\(size):".utf8))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty { hash.update(data: block) }
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let prefix = source.deletingPathExtension().lastPathComponent + "-"
        let destination = root.appendingPathComponent(prefix + digest + ".mlmodelc", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        // Multiple host workers and app extensions share this directory. An
        // NSLock only protects one process; publication and garbage collection
        // also need a filesystem lock, with shared leases for resident models.
        let publication = open(root.appendingPathComponent(".publication.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard publication >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(publication) }
        guard flock(publication, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let leaseDirectory = root.appendingPathComponent(".leases", isDirectory: true)
        try manager.createDirectory(at: leaseDirectory, withIntermediateDirectories: true)
        var directory = root
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)
        if !manager.fileExists(atPath: destination.path) {
            let staging = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
            defer { try? manager.removeItem(at: staging) }
            try manager.copyItem(at: source, to: staging)
            try manager.moveItem(at: staging, to: destination)
        }
        // Resolve after publication: Foundation can only fully canonicalize
        // an iOS container alias once the destination exists on disk.
        let published = destination.standardizedFileURL.resolvingSymlinksInPath()
        let lease = open(leaseDirectory.appendingPathComponent(published.lastPathComponent + ".lock").path,
                         O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lease >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(lease, LOCK_SH) == 0 else {
            close(lease)
            throw CocoaError(.fileWriteUnknown)
        }
        if let prior = residentLeases.updateValue(lease, forKey: published) { close(prior) }
        resolved[source] = published
        // Remove superseded copies of this model, never a model already loaded
        // in this process. User documents and the bundled originals are untouched.
        // /var and /private/var can name the same iOS directory. Enumeration
        // also normalizes trailing slashes; URL equality must never decide
        // whether to delete the copy just published or an in-use model.
        let residentNames = Set(resolved.values.map(\.lastPathComponent))
        for old in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        where old.lastPathComponent.hasPrefix(prefix) && old.pathExtension == "mlmodelc" && old.lastPathComponent != destination.lastPathComponent {
            if !residentNames.contains(old.lastPathComponent), try old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true {
                let oldLease = open(leaseDirectory.appendingPathComponent(old.lastPathComponent + ".lock").path,
                                    O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
                if oldLease >= 0 {
                    defer { close(oldLease) }
                    // A different process may still hold MLModel/MLModelAsset
                    // at this URL. Never unlink its weights underneath Core ML.
                    if flock(oldLease, LOCK_EX | LOCK_NB) == 0 { try? manager.removeItem(at: old) }
                }
            }
        }
        return published
    }

    /// Run on a utility task at launch. Detector model publication uses this
    /// same lock, so cleanup cannot race it.
    func reclaimLegacyExecutionCache() {
        lock.lock()
        defer { lock.unlock() }
        cleanLegacyOnce()
    }

    /// Model tiers the page pipeline no longer loads. Their content-addressed
    /// copies in the store are removed at launch (never a leased copy).
    static let retiredModelPrefixes = ["PP-OCRv6-Medium-", "PP-OCRv6-Small-", "PP-OCRv6-Tiny-"]

    static func isRetiredModelCopy(_ name: String) -> Bool {
        name.hasSuffix(".mlmodelc") && retiredModelPrefixes.contains { name.hasPrefix($0) }
    }

    private func removeRetiredModelCopies() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        let leaseDirectory = root.appendingPathComponent(".leases", isDirectory: true)
        for entry in entries where Self.isRetiredModelCopy(entry.lastPathComponent) {
            guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            let leasePath = leaseDirectory.appendingPathComponent(entry.lastPathComponent + ".lock").path
            let lease = open(leasePath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard lease >= 0 else { continue }
            defer { close(lease) }
            // Another process may still hold this model; leave it for a later launch.
            guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { continue }
            try? manager.removeItem(at: entry)
            try? manager.removeItem(atPath: leasePath)
        }
    }

    private func cleanLegacyOnce() {
        guard !cleaned else { return }
        cleaned = true
        removeRetiredModelCopies()
        guard let runtimeCache else { return }
        // Inspect only known app-owned OCR graphs. Unknown packages and all
        // current stable-path packages are retained; no private API is called.
        let manager = FileManager.default
        guard let versions = try? manager.contentsOfDirectory(at: runtimeCache, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for version in versions {
            guard (try? version.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let packages = try? manager.contentsOfDirectory(at: version, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { continue }
            for package in packages {
                guard (try? package.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                      let files = try? regularFiles(in: package) else { continue }
                let graphs = files.filter { $0.pathExtension == "mpsgraph" }
                guard !graphs.isEmpty, graphs.count <= 32 else { continue }
                let legacy = graphs.allSatisfy { graph in
                    guard let size = try? graph.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 262_144, let data = try? Data(contentsOf: graph) else { return false }
                    return Self.isLegacyOCRGraph(data)
                }
                if legacy { try? manager.removeItem(at: package) }
            }
        }
    }

    static func isLegacyOCRGraph(_ data: Data) -> Bool {
        let names = ["PP-OCRv6-Medium-RecWidths", "PP-OCRv6-Medium-DetShapes", "PP-OCRv6-Small-RecWidths",
                     "PP-OCRv6-Small-DetShapes", "PP-OCRv6-Tiny-RecWidths", "PP-OCRv6-Tiny-DetShapes"]
        let text = String(decoding: data, as: UTF8.self)
        return names.contains { name in
            let pattern = #"/Bundle/Application/[0-9A-Fa-f-]{36}/Aidoku\.app/"# + name + #"\.mlmodelc/model\.mil"#
            return text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        var enumerationError: Error?
        let rootValues = try directory.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
                  enumerationError = error
                  return false
              }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var files: [URL] = []
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            if values.isRegularFile == true { files.append(file) }
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.path < $1.path }
    }
}
