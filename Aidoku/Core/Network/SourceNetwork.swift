import Foundation
import Network
import Nuke
import WebKit

/// Shared by source interpreters, page images, downloads and source web views.
/// Tracking and translation API sessions keep their existing network policies.
actor SourceNetwork {
    static let shared = SourceNetwork()
    static let enabledKey = "Network.httpsBypass"
    private let bypassEnabled: @Sendable () -> Bool
    private let proxy = HTTPSBypassProxy()
    private var startup: Task<NWEndpoint, Error>?
    private var proxiedSession: URLSession?
    private var proxiedLoader: DataLoader?
    private let directLoader: DataLoader = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        return DataLoader(configuration: config)
    }()

    init(enabled: @escaping @Sendable () -> Bool = { SourceNetwork.isEnabled }) { bypassEnabled = enabled }

    deinit { proxy.stop(); proxiedSession?.invalidateAndCancel() }

    nonisolated static var isEnabled: Bool {
        if #available(iOS 17.0, *) { return UserDefaults.standard.bool(forKey: enabledKey) }
        return false
    }

    @available(iOS 17.0, *)
    func proxyConfiguration() async throws -> ProxyConfiguration {
        if startup == nil { startup = Task { try await proxy.start() } }
        do {
            let endpoint = try await startup!.value
            try Task.checkCancellation()
            var config = ProxyConfiguration(socksv5Proxy: endpoint)
            config.allowFailover = false
            return config
        } catch {
            if !(error is CancellationError) { startup = nil }
            throw error
        }
    }

    func configuration(_ base: URLSessionConfiguration = .default, bypass: Bool? = nil) async throws -> URLSessionConfiguration {
        guard let config = base.copy() as? URLSessionConfiguration else { throw URLError(.unknown) }
        if #available(iOS 17.0, *), bypass ?? bypassEnabled() {
            config.proxyConfigurations = [try await proxyConfiguration()]
        }
        return config
    }

    func session() async throws -> URLSession {
        guard bypassEnabled() else { return .shared }
        if let proxiedSession { return proxiedSession }
        let config = try await configuration(bypass: true)
        if let proxiedSession { return proxiedSession }
        let session = URLSession(configuration: config)
        proxiedSession = session
        return session
    }

    func imageLoader() async throws -> DataLoader {
        guard bypassEnabled() else { return directLoader }
        if let proxiedLoader { return proxiedLoader }
        let config = try await configuration(bypass: true)
        if let proxiedLoader { return proxiedLoader }
        config.urlCache = nil
        let loader = DataLoader(configuration: config)
        proxiedLoader = loader
        return loader
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session().data(for: request)
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await session().download(for: request)
    }

    func object<T: Decodable>(from url: URL) async throws -> T { try await object(from: URLRequest(url: url)) }
    func object<T: Decodable>(from request: URLRequest) async throws -> T {
        let (data, _) = try await data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Tests the configured path even before the user enables it; never stores bodies.
    @available(iOS 17.0, *)
    func test(url: URL) async throws -> (status: Int, fragmented: Bool) {
        // A separate probe prevents concurrent downloads from inflating its result.
        let probe = HTTPSBypassProxy()
        defer { probe.stop() }
        var route = ProxyConfiguration(socksv5Proxy: try await probe.start())
        route.allowFailover = false
        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [route]
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (response.statusCode, await probe.fragmentCount() > 0)
    }

    /// Apply before the first navigation; WK networking lives in another process.
    @MainActor static func configure(_ store: WKWebsiteDataStore) async throws {
        SourceWebStores.stores.add(store)
        if #available(iOS 17.0, *) {
            store.proxyConfigurations = isEnabled ? [try await shared.proxyConfiguration()] : []
        }
    }

    @MainActor static func refreshWebStores() async throws {
        for store in SourceWebStores.stores.allObjects { try await configure(store) }
    }
}

@MainActor private enum SourceWebStores {
    static let stores = NSHashTable<WKWebsiteDataStore>.weakObjects()
}

/// Keeps Nuke's streaming, cancellation, cookie and image-cache behavior intact.
final class SourceImageDataLoader: DataLoading, @unchecked Sendable {
    private let network: SourceNetwork
    init(network: SourceNetwork = .shared) { self.network = network }
    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        let operation = Operation()
        operation.setTask(Task {
            do {
                let loader = try await network.imageLoader()
                try Task.checkCancellation()
                operation.setLoad(loader.loadData(with: request, didReceiveData: didReceiveData, completion: completion))
            } catch { completion(error) }
        })
        return operation
    }

    private final class Operation: Cancellable, @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var load: (any Cancellable)?
        private var cancelled = false
        func setTask(_ task: Task<Void, Never>) {
            lock.lock(); let cancelled = cancelled; self.task = task; lock.unlock()
            if cancelled { task.cancel() }
        }
        func setLoad(_ load: any Cancellable) {
            lock.lock(); let cancelled = cancelled; self.load = load; lock.unlock()
            if cancelled { load.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let task = task; let load = load; lock.unlock()
            task?.cancel(); load?.cancel()
        }
    }
}
