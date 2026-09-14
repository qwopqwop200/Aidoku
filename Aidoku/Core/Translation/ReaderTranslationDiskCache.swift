import CryptoKit
import Foundation

/// Durable, byte-bounded LRU for OCR, translations and layout instructions.
/// File I/O, metadata decoding and eviction run on this actor, never on UIKit.
actor ReaderTranslationDiskCache {
    enum Kind: String, CaseIterable, Sendable { case ocr, translation, layout }
    struct Statistics: Sendable {
        let bytes: Int64
        let entries: Int
        let limit: Int64
    }
    static let maximumBytes: Int64 = 100_000_000_000
    static let defaultBytes: Int64 = 1_000_000_000
    static let limitChoices: [Int64] = [
        100_000_000, 200_000_000, 500_000_000,
        1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000, 20_000_000_000, maximumBytes
    ]
    static let shared = ReaderTranslationDiskCache(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReaderTranslationCache-v1", isDirectory: true),
        byteLimit: (UserDefaults.standard.object(forKey: ReaderTranslationSettings.keyPrefix + "cacheLimitBytes") as? NSNumber)?.int64Value
            ?? defaultBytes
    )

    private struct Entry: Equatable {
        var size: Int64
        var accessed: TimeInterval
    }
    private let directory: URL
    private var byteLimit: Int64
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var totalBytes: Int64 = 0
    private var lastAccess: TimeInterval = 0
    private var generation: UInt64 = 0
    private var compacting = false

    init(directory: URL, byteLimit: Int64 = defaultBytes) {
        self.directory = directory
        self.byteLimit = min(Self.maximumBytes, max(0, byteLimit))
    }

    func currentGeneration() -> UInt64 { generation }

    func statistics() throws -> Statistics {
        try prepare()
        return Statistics(bytes: totalBytes, entries: entries.count, limit: byteLimit)
    }

    func setByteLimit(_ value: Int64) throws {
        byteLimit = min(Self.maximumBytes, max(0, value))
        try prepare()
        try trim(to: byteLimit)
    }

    func clear() throws {
        generation &+= 1
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        entries = [:]
        totalBytes = 0
        loaded = false
    }

    func data(for key: String, kind: Kind) throws -> Data? {
        try Task.checkCancellation()
        try prepare()
        let name = fileName(key, kind: kind)
        guard entries[name] != nil else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { try remove(name); return nil }
        try touch(name)
        guard let unpacked = try? ReaderTranslationCacheCodec.unpack(data) else { try remove(name); return nil }
        return unpacked
    }

    func markUsed(_ key: String, kind: Kind) throws {
        try prepare()
        let name = fileName(key, kind: kind)
        if entries[name] != nil { try touch(name) }
    }

    func contains(_ key: String, kind: Kind) throws -> Bool {
        try prepare()
        return entries[fileName(key, kind: kind)] != nil
    }

    /// A clear operation invalidates in-flight writers, so old work cannot refill it.
    func store(_ data: Data, for key: String, kind: Kind, generation expected: UInt64) throws {
        try Task.checkCancellation()
        guard generation == expected else { return }
        try prepare()
        let data = ReaderTranslationCacheCodec.pack(data)
        let name = fileName(key, kind: kind)
        guard Int64(data.count) <= byteLimit, byteLimit > 0 else { try remove(name); return }
        try remove(name)
        try trim(to: byteLimit - Int64(data.count))
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        entries[name] = Entry(size: Int64(data.count), accessed: nextAccess())
        totalBytes += Int64(data.count)
        try touch(name)
    }

    func regions(for key: String, kind: Kind) throws -> [ReaderTranslationRegion]? {
        guard let data = try data(for: key, kind: kind) else { return nil }
        guard let stored = try? JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: data) else {
            try remove(fileName(key, kind: kind))
            return nil
        }
        return stored.map(\.region)
    }

    /// A legacy all-language translation can be narrowed without another OCR/API
    /// request. Never treat a filtered subset as a complete all-language page.
    func translatedRegions(page: String, settings: ReaderTranslationSettings) throws -> [ReaderTranslationRegion]? {
        let key = ReaderTranslationCacheIdentity.translation(page: page, settings: settings)
        if let cached = try regions(for: key, kind: .translation) { return cached }
        guard !settings.rightToLeftPanelOrder, ReaderTranslationLanguageFilter.identity(settings: settings) != nil,
              let cached = try regions(for: ReaderTranslationCacheIdentity.unfilteredTranslation(page: page, settings: settings),
                                       kind: .translation) else { return nil }
        let filtered = ReaderTranslationLanguageFilter.apply(cached, settings: settings)
        try Task.checkCancellation()
        try storeRegions(filtered, for: key, kind: .translation, generation: generation)
        return filtered
    }

    func storeRegions(_ regions: [ReaderTranslationRegion], for key: String, kind: Kind, generation: UInt64) throws {
        let data = try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
        try store(data, for: key, kind: kind, generation: generation)
    }

    func remove(_ key: String, kind: Kind) throws {
        try prepare()
        try remove(fileName(key, kind: kind))
    }

    /// Upgrade existing files in place without invalidating OCR/translation keys.
    /// Yield during each encode so opening a cached page never waits for the whole migration.
    func compact() async throws {
        guard !compacting else { return }
        compacting = true
        defer { compacting = false }
        try prepare()
        let issued = generation
        for name in Array(entries.keys) {
            try Task.checkCancellation()
            guard generation == issued else { return }
            guard let entry = entries[name] else { continue }
            let url = directory.appendingPathComponent(name)
            let task = Task.detached(priority: .background) { () -> Data? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard !ReaderTranslationCacheCodec.isPacked(data) else { return nil }
                let packed = ReaderTranslationCacheCodec.pack(data)
                return packed.count < data.count ? packed : nil
            }
            let data = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard generation == issued, !Task.isCancelled else { return }
            guard entries[name] == entry, let data else { continue }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            totalBytes += Int64(data.count) - entry.size
            entries[name]?.size = Int64(data.count)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: entry.accessed)], ofItemAtPath: url.path)
        }
    }

    private func prepare() throws {
        guard !loaded else { return }
        entries = [:]
        totalBytes = 0
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
            let name = url.lastPathComponent
            guard name.hasSuffix(".cache"),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            // Remove obsolete bitmaps before quota enforcement so their size
            // cannot evict the reusable OCR, translations or layout metadata.
            if name.hasPrefix("render-") || name.hasPrefix("renderIndex-") {
                try FileManager.default.removeItem(at: url)
                continue
            }
            guard Kind.allCases.contains(where: { name.hasPrefix($0.rawValue + "-") }),
                  let size = values.fileSize else { continue }
            let accessed = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            entries[name] = Entry(size: Int64(size), accessed: accessed)
            totalBytes += Int64(size)
            lastAccess = max(lastAccess, accessed)
        }
        loaded = true
        try trim(to: byteLimit)
    }

    private func trim(to target: Int64) throws {
        guard totalBytes > target else { return }
        for (name, _) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) {
            try remove(name)
            if totalBytes <= target { break }
        }
    }

    private func remove(_ name: String) throws {
        guard let entry = entries[name] else { return }
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        entries.removeValue(forKey: name)
        totalBytes -= entry.size
    }

    private func nextAccess() -> TimeInterval {
        lastAccess = max(Date().timeIntervalSince1970, lastAccess + 0.000_001)
        return lastAccess
    }

    private func touch(_ name: String) throws {
        let access = nextAccess()
        entries[name]?.accessed = access
        // Persist recency immediately, including if the user force-quits the app.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: access)], ofItemAtPath: directory.appendingPathComponent(name).path
        )
    }

    private func fileName(_ key: String, kind: Kind) -> String { kind.rawValue + "-" + ReaderTranslationCacheIdentity.digest(key) + ".cache" }
}

struct ReaderTranslationStoredRegion: Codable {
    let id: String
    let rect: CGRect
    let source: String
    let translation: String?
    let polygon: [CGPoint]
    let confidence: Double
    let orientation: String
    let singleColumn: Bool?
    let sourceImageAspectRatio: Double?
    let reuseKey: TranslationCacheKey?
    let reuseSegment: String?

    init(_ value: ReaderTranslationRegion) {
        id = value.id; rect = value.rect; source = value.source; translation = value.translation
        polygon = value.polygon; confidence = value.confidence; orientation = value.sourceOrientation.rawValue
        singleColumn = value.sourceSingleVerticalColumn
        sourceImageAspectRatio = value.sourceImageAspectRatio
        reuseKey = value.translationReuseIdentity?.cacheKey; reuseSegment = value.translationReuseIdentity?.segmentID
    }
    var region: ReaderTranslationRegion {
        var region = ReaderTranslationRegion(id: id, rect: rect, source: source, translation: translation, polygon: polygon,
                                             confidence: confidence, sourceOrientation: .init(tolerantRawValue: orientation),
                                             sourceSingleVerticalColumn: singleColumn)
        region.sourceImageAspectRatio = sourceImageAspectRatio
        if let reuseKey, let reuseSegment { region.translationReuseIdentity = .init(cacheKey: reuseKey, segmentID: reuseSegment) }
        return region
    }
}

enum ReaderTranslationCacheIdentity {
    static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    static func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return digest((try? encoder.encode(value)) ?? Data())
    }
    static func ocr(page: String, settings: ReaderTranslationSettings) -> String {
        // OCR entries contain merged regions. A merger change must also
        // invalidate derived translations/layouts instead of replaying old boxes.
        encoded(["reader-ocr-v23-single-native-pass", page, encoded(settings.ocrConfiguration)])
    }
    static func translation(page: String, settings: ReaderTranslationSettings) -> String {
        let previous = unfilteredTranslation(page: page, settings: settings)
        let base = settings.rightToLeftPanelOrder ? encoded([previous, "rtl-panel-order-v3-framed-narrow-gutters"]) : previous
        guard let filter = ReaderTranslationLanguageFilter.identity(settings: settings) else { return base }
        return encoded([base] + filter)
    }
    static func unfilteredTranslation(page: String, settings: ReaderTranslationSettings) -> String {
        let config = settings.configuration
        return encoded([
            "reader-translation-v1", ocr(page: page, settings: settings), config.provider.rawValue, config.apiProtocol.rawValue,
            config.baseURL, config.model, config.credentialAccount, String(config.credentialGeneration), config.reasoningEffort.rawValue,
            config.instructions, settings.sourceLanguage, settings.targetLanguage
        ])
    }
    // Every geometry/appearance input must be included to reject stale pixels after a reader change.
    // swiftlint:disable:next function_parameter_count
    static func render(page: String, settings: ReaderTranslationSettings, imageSize: CGSize, viewport: CGSize,
                       scale: CGFloat, aspectFit: Bool, crop: CGRect, dark: Bool) -> String {
        // Auto Layout rounds view edges to display pixels. Mathematical prefetch
        // sizes differ by tiny fractions (568.016 pt vs 568 pt); those are one raster.
        let pixelScale = max(1, scale)
        let viewport = CGSize(width: (viewport.width * pixelScale).rounded() / pixelScale,
                              height: (viewport.height * pixelScale).rounded() / pixelScale)
        return encoded([
            "reader-render-v12-stable-placement", translation(page: page, settings: settings), encoded(settings.overlay),
            encoded(imageSize), encoded(viewport), String(Double(scale)), String(aspectFit), encoded(crop), String(dark),
            ProcessInfo.processInfo.operatingSystemVersionString
        ])
    }
}
