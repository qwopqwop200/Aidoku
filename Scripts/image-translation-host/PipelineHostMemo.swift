import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// `AIDOKU_PIPELINE_MEMO=DIR`: the on-disk `PipelineMemo` store. Each kind lives under `DIR/KIND-TAG`, TAG being a
/// content digest of the model package that produced it, so a replaced model never reads another's outputs.
/// Entries are LZ4 files written by rename (two host runs may share the store).
final class PipelineHostMemo: PipelineMemo.Store, @unchecked Sendable {
    private let directories: [PipelineMemo.Kind: URL]
    private let lock = NSLock()
    private var hits: [PipelineMemo.Kind: Int] = [:]
    private var misses: [PipelineMemo.Kind: Int] = [:]

    /// `packages`: the model package each model kind ran (decode has none).
    init(root: URL, packages: [PipelineMemo.Kind: URL]) throws {
        var directories: [PipelineMemo.Kind: URL] = [:]
        for kind in PipelineMemo.Kind.allCases {
            let tag = try packages[kind].map(Self.digest) ?? "v1"
            directories[kind] = root.appendingPathComponent("\(kind.rawValue)-\(tag.prefix(16))")
        }
        self.directories = directories
    }

    private static func digest(_ package: URL) throws -> String {
        var hasher = SHA256()
        let files = (FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw PipelineHostError("model package not found: \(package.path)") }
        for file in files {
            hasher.update(data: Data(file.path.replacingOccurrences(of: package.path, with: "").utf8))
            hasher.update(data: try Data(contentsOf: file, options: .mappedIfSafe))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func url(_ kind: PipelineMemo.Kind, _ key: String) -> URL {
        directories[kind]!.appendingPathComponent(String(key.prefix(2))).appendingPathComponent(key)
    }

    func get(_ kind: PipelineMemo.Kind, _ key: String) -> Data? {
        let value = (try? Data(contentsOf: url(kind, key))).flatMap { try? ($0 as NSData).decompressed(using: .lz4) as Data }
        lock.withLock { value == nil ? (misses[kind, default: 0] += 1) : (hits[kind, default: 0] += 1) }
        return value
    }

    func put(_ kind: PipelineMemo.Kind, _ key: String, _ value: Data) {
        let target = url(kind, key)
        guard let packed = try? (value as NSData).compressed(using: .lz4) as Data else { return }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(key).\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try packed.write(to: temporary)
            if rename(temporary.path, target.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
        } catch { try? FileManager.default.removeItem(at: temporary) }
    }

    /// "kind hits/lookups" per kind used, for the run log.
    var summary: String {
        lock.withLock {
            PipelineMemo.Kind.allCases.compactMap { kind in
                let h = hits[kind] ?? 0, n = h + (misses[kind] ?? 0)
                return n == 0 ? nil : "\(kind.rawValue) \(h)/\(n)"
            }.joined(separator: ", ")
        }
    }

    // MARK: decoded pages

    private struct Header: Codable {
        var width, height, bitsPerComponent, bitsPerPixel, bytesPerRow: Int
        var bitmapInfo: UInt32
        var spaceName: String?
        var spaceICC: Data?
        var shouldInterpolate: Bool
        var intent: Int32
    }

    /// The page decoded once: later runs rebuild the same CGImage (format, colour space, bytes) from the store
    /// instead of decoding the file again. Every run, the first included, uses the rebuilt image.
    func image(file: URL, decode: () throws -> CGImage) throws -> CGImage {
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        let key = PipelineMemo.key { $0.update(data: bytes) }
        if let stored = get(.decode, key), let image = Self.rebuild(stored) { return image }
        let image = try decode()
        guard image.colorSpace?.model != .indexed, !image.isMask, image.decode == nil,
              let space = image.colorSpace, let pixels = image.dataProvider?.data as Data? else { return image }
        let header = Header(width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent,
                            bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow,
                            bitmapInfo: image.bitmapInfo.rawValue, spaceName: space.name as String?,
                            spaceICC: space.name == nil ? space.copyICCData() as Data? : nil,
                            shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent.rawValue)
        guard let head = try? JSONEncoder().encode(header) else { return image }
        let value = PipelineMemo.data([Int32(head.count)]) + head + pixels
        guard let rebuilt = Self.rebuild(value) else { return image }
        put(.decode, key, value)
        return rebuilt
    }

    private static func rebuild(_ value: Data) -> CGImage? {
        guard value.count >= 4 else { return nil }
        let length = Int(value.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard length > 0, value.count >= 4 + length,
              let header = try? JSONDecoder().decode(Header.self, from: value.dropFirst(4).prefix(length)) else { return nil }
        let pixels = Data(value.dropFirst(4 + length))
        guard pixels.count >= header.bytesPerRow * header.height,
              let space = header.spaceName.flatMap({ CGColorSpace(name: $0 as CFString) })
                ?? header.spaceICC.flatMap({ CGColorSpace(iccData: $0 as CFData) }),
              let provider = CGDataProvider(data: pixels as CFData),
              let intent = CGColorRenderingIntent(rawValue: header.intent) else { return nil }
        return CGImage(width: header.width, height: header.height, bitsPerComponent: header.bitsPerComponent,
                       bitsPerPixel: header.bitsPerPixel, bytesPerRow: header.bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: header.bitmapInfo), provider: provider, decode: nil,
                       shouldInterpolate: header.shouldInterpolate, intent: intent)
    }
}
