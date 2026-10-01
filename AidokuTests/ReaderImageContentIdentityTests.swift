import Testing
import Foundation
import Nuke
@testable import Aidoku

struct ReaderImageContentIdentityTests {
    @MainActor @Test func replacedLocalFileUsesNewPixelCacheIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("page.png")
        try Data("old pixels".utf8).write(to: file, options: .atomic)
        let first = await ReaderPageView.imageRequest(url: file)
        let repeated = await ReaderPageView.imageRequest(url: file)
        #expect(first.imageID == repeated.imageID)
        try Data("new pixels".utf8).write(to: file, options: .atomic)
        let replaced = await ReaderPageView.imageRequest(url: file)
        #expect(first.imageID != replaced.imageID)
        #expect(replaced.urlRequest?.url == file)
        #expect(replaced.imageID == (await ReaderImageContentIdentity.localFileRequestIdentity(file)))
        #expect(await ReaderImageContentIdentity.localFileRequestIdentity(URL(string: "https://example.com/page.png")!) == nil)
    }

    private let hash = "f71c81e179c49d058275918fe1699f4427957c295d0ac933b3f36f6e0b6d5a79"

    private func remote(epoch: String = "1790658001", shard: Int = 1, header: String = "reader") -> ImageRequest {
        var transport = URLRequest(url: URL(string: "https://a\(shard).gold-usergeneratedcontent.net/\(epoch)/\(0x9a7)/\(hash).avif")!)
        transport.setValue(header, forHTTPHeaderField: "Referer")
        return ImageRequest(urlRequest: transport)
    }

    @Test func routingRotationReusesIdentityWithoutChangingTransport() {
        var first = remote()
        var rotated = remote(epoch: "1790744401", shard: 2)
        let transport = rotated.urlRequest
        #expect(first.imageID != rotated.imageID)
        ReaderImageContentIdentity.applyStableRemoteIdentity(to: &first, sourceKey: "multi.hitomi")
        ReaderImageContentIdentity.applyStableRemoteIdentity(to: &rotated, sourceKey: "multi.hitomi")
        #expect(first.imageID == rotated.imageID)
        #expect(rotated.urlRequest == transport)
        var differentHeader = remote(header: "other-reader")
        ReaderImageContentIdentity.applyStableRemoteIdentity(to: &differentHeader, sourceKey: "multi.hitomi")
        #expect(first.imageID != differentHeader.imageID)
    }

    @Test func unrelatedOrAmbiguousURLsKeepTheirIdentity() {
        let url = remote().url!.absoluteString
        let variants = [
            url.replacingOccurrences(of: "a1.gold-usergeneratedcontent.net", with: "other.invalid"),
            url + "?token=secret", url.replacingOccurrences(of: "/2471/", with: "/0/"),
            url.replacingOccurrences(of: hash, with: "not-a-hash"),
            url.replacingOccurrences(of: ".avif", with: ".jpg")
        ]
        for variant in variants {
            var request = ImageRequest(urlRequest: URLRequest(url: URL(string: variant)!))
            let original = request.imageID
            ReaderImageContentIdentity.applyStableRemoteIdentity(to: &request, sourceKey: "multi.hitomi")
            #expect(request.imageID == original)
        }
        var otherSource = remote()
        let original = otherSource.imageID
        ReaderImageContentIdentity.applyStableRemoteIdentity(to: &otherSource, sourceKey: "other")
        #expect(otherSource.imageID == original)
        var avif = remote()
        var webp = ImageRequest(urlRequest: URLRequest(url: URL(string: url.replacingOccurrences(of: ".avif", with: ".webp"))!))
        ReaderImageContentIdentity.applyStableRemoteIdentity(to: &avif, sourceKey: "multi.hitomi")
        ReaderImageContentIdentity.applyStableRemoteIdentity(to: &webp, sourceKey: "multi.hitomi")
        #expect(avif.imageID != webp.imageID)
    }

    @Test func rotatedURLLoadsOriginalBytesFromDiskWithoutNetwork() async throws {
        let cache = try DataCache(name: "reader-routing-" + UUID().uuidString)
        defer { cache.removeAll() }
        let transport = RoutingUnexpectedNetwork()
        let pipeline = ImagePipeline {
            $0.dataCache = cache
            $0.imageCache = nil
            $0.dataLoader = transport
        }
        var old = remote()
        var rotated = remote(epoch: "1790744401", shard: 2)
        ReaderImageContentIdentity.applyStableRemoteIdentity(to: &old, sourceKey: "multi.hitomi")
        ReaderImageContentIdentity.applyStableRemoteIdentity(to: &rotated, sourceKey: "multi.hitomi")
        let data = Data("cached-original-image-bytes".utf8)
        pipeline.cache.storeCachedData(data, for: old)
        #expect(pipeline.cache.containsCachedImage(for: rotated))
        let result = try await pipeline.data(for: rotated)
        #expect(result.0 == data)
        #expect(transport.requests == 0)
        ReaderImageDownloadCache.removeCachedImageAndOriginal(for: rotated, pipeline: pipeline)
        #expect(!pipeline.cache.containsCachedImage(for: old))
    }

    @Test func identityUsesContentAndProcessingSettings() {
        let first = ReaderImageContentIdentity.base64Key("abc", processorSettingsKey: "plain")
        #expect(first == "reader-base64-v2-ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad-plain")
        #expect(first == ReaderImageContentIdentity.base64Key(String(["a", "b", "c"].joined()), processorSettingsKey: "plain"))
        #expect(first != ReaderImageContentIdentity.base64Key("abd", processorSettingsKey: "plain"))
        #expect(first != ReaderImageContentIdentity.base64Key("abc", processorSettingsKey: "cropped"))
    }

    @Test func largePayloadIdentityIsRepeatableAndSensitiveToLastByte() {
        let payload = String(repeating: "YWJj", count: 32_768)
        let first = ReaderImageContentIdentity.base64Key(payload, processorSettingsKey: "plain")
        #expect(first == ReaderImageContentIdentity.base64Key(payload, processorSettingsKey: "plain"))
        #expect(first != ReaderImageContentIdentity.base64Key(payload + "AA==", processorSettingsKey: "plain"))
    }
}

private final class RoutingUnexpectedNetwork: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }
    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        lock.withLock { count += 1 }
        completion(URLError(.notConnectedToInternet))
        return Token()
    }
    private struct Token: Cancellable { func cancel() {} }
}
