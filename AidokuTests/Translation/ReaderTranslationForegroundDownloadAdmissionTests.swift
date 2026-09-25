import Foundation
import Nuke
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationForegroundDownloadAdmissionTests {
    @Test func foregroundDownloadStartsOutsideOccupiedImagePermitAndCancelsOnExit() async throws {
        let cache = try DataCache(name: "foreground-admission-" + UUID().uuidString)
        defer { cache.removeAll() }
        let pipeline = ImagePipeline {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ForegroundAdmissionURLProtocol.self]
            configuration.urlCache = nil
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.dataCache = cache
            $0.dataCachePolicy = .storeOriginalData
        }
        let gate = ForegroundAdmissionMarker()
        let occupied = Task {
            try await TranslationImageWorkBudget.shared.withPermit {
                await gate.markStarted()
                try await Task.sleep(for: .seconds(30))
            }
        }
        defer { occupied.cancel() }
        try await waitUntil { await gate.started }
        let url = URL(string: "https://foreground-admission.invalid/" + UUID().uuidString)!
        let page = Page(sourceId: "", chapterId: "admission", index: 0, imageURL: url.absoluteString)
        let preloader = ReaderTranslationPreloader(loader: ReaderTranslationImageLoader(pipeline: pipeline))
        var settings = ReaderTranslationSettings()
        settings.includePageImage = false
        let demand = Task { try await preloader.translate(page, settings: settings) }
        defer { preloader.cancel(); demand.cancel() }
        // A blocked server must begin fetching while another image task owns
        // admission, retaining compressed network state rather than any pixels.
        try await waitUntil { ForegroundAdmissionURLProtocol.started(url) }
        preloader.cancel()
        await #expect(throws: CancellationError.self) { try await demand.value }
        try await waitUntil { ForegroundAdmissionURLProtocol.stopped(url) }
        occupied.cancel()
        _ = try? await occupied.value
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor ForegroundAdmissionMarker {
    private(set) var started = false
    func markStarted() { started = true }
}

private final class ForegroundAdmissionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var starts: Set<URL> = []
    private static var stops: Set<URL> = []
    static func started(_ url: URL) -> Bool { lock.withLock { starts.contains(url) } }
    static func stopped(_ url: URL) -> Bool { lock.withLock { stops.contains(url) } }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "foreground-admission.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        _ = Self.lock.withLock { Self.starts.insert(request.url!) }
        // Deliberately leave the network response pending until cancellation.
    }
    override func stopLoading() {
        _ = Self.lock.withLock { Self.stops.insert(request.url!) }
    }
}
