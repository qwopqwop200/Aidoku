import Foundation
import Network

/// An app-local SOCKS5 relay. It never terminates TLS or reads HTTP bodies.
/// All mutable listener/connection state belongs to one serial queue.
final class HTTPSBypassProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.aidoku.https-bypass", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [UUID: Tunnel] = [:]
    private var startup: CheckedContinuation<NWEndpoint, Error>?
    private var endpoint: NWEndpoint?
    private var fragmentedConnections = 0

    func start() async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let endpoint = self.endpoint { continuation.resume(returning: endpoint); return }
                guard self.listener == nil else { continuation.resume(throwing: URLError(.cannotConnectToHost)); return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.startup = continuation
                    listener.newConnectionHandler = { [weak self] client in
                        guard let self, self.connections.count < 64 else { client.cancel(); return }
                        let id = UUID()
                        let tunnel = Tunnel(client: client, queue: self.queue, fragmented: { [weak self] in
                            self?.fragmentedConnections += 1
                        }, closed: { [weak self] in self?.connections.removeValue(forKey: id) })
                        self.connections[id] = tunnel
                        tunnel.start()
                    }
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                            case .ready:
                                guard let port = listener.port else { self.stopOnQueue(); return }
                                let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
                                self.endpoint = endpoint
                                self.startup?.resume(returning: endpoint)
                                self.startup = nil
                            case .failed, .cancelled: self.stopOnQueue()
                            default: break
                        }
                    }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                        if self?.startup != nil { self?.stopOnQueue() }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    func fragmentCount() async -> Int {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.fragmentedConnections) } }
    }

    private func stopOnQueue() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        endpoint = nil
        startup?.resume(throwing: URLError(.cannotConnectToHost))
        startup = nil
        Array(connections.values).forEach { $0.close() }
    }
}

private extension HTTPSBypassProxy {
    final class Tunnel {
        let client: NWConnection
        let queue: DispatchQueue
        let fragmented: () -> Void
        let closed: () -> Void
        var remote: NWConnection?
        var buffer = Data()
        var timer: DispatchSourceTimer?
        var lastActivity = ProcessInfo.processInfo.systemUptime
        var connected = false
        var finished = false
        var resolution: Task<Void, Never>?
        var endedReaders: Set<ObjectIdentifier> = []
        var clientReadEnded = false

        init(client: NWConnection, queue: DispatchQueue, fragmented: @escaping () -> Void, closed: @escaping () -> Void) {
            self.client = client; self.queue = queue; self.fragmented = fragmented; self.closed = closed
        }

        func start() {
            client.stateUpdateHandler = { [weak self] state in
                switch state {
                    case .ready: self?.readGreeting()
                    case .failed, .cancelled: self?.close()
                    default: break
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastActivity > (self.connected ? 120 : 15) { self.close() }
            }
            self.timer = timer
            timer.resume()
            client.start(queue: queue)
        }

        func close() {
            guard !finished else { return }
            finished = true
            timer?.cancel(); timer = nil
            resolution?.cancel(); resolution = nil
            client.stateUpdateHandler = nil
            remote?.stateUpdateHandler = nil
            client.cancel(); remote?.cancel()
            buffer.removeAll()
            closed()
        }

        func receiveExactly(_ count: Int, then: @escaping (Data) -> Void) {
            guard !finished else { return }
            if buffer.count >= count {
                let data = Data(buffer.prefix(count))
                buffer = Data(buffer.dropFirst(count))
                then(data)
                return
            }
            client.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { [weak self] data, _, done, error in
                guard let self, !self.finished else { return }
                if let data { self.buffer.append(data); self.lastActivity = ProcessInfo.processInfo.systemUptime }
                guard error == nil, !done || self.buffer.count >= count else { self.close(); return }
                self.receiveExactly(count, then: then)
            }
        }

        func send(_ data: Data, to connection: NWConnection, then: @escaping () -> Void) {
            guard !finished else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.finished else { return }
                guard error == nil else { self.close(); return }
                self.lastActivity = ProcessInfo.processInfo.systemUptime
                then()
            })
        }

        func readGreeting() {
            receiveExactly(2) { [self] header in
                guard header[0] == 5, header[1] > 0 else { close(); return }
                receiveExactly(Int(header[1])) { [self] methods in
                    guard methods.contains(0) else { send(Data([5, 255]), to: client) { self.close() }; return }
                    send(Data([5, 0]), to: client) { self.readDestination() }
                }
            }
        }

        func readDestination() {
            receiveExactly(4) { [self] header in
                guard header[0] == 5, header[1] == 1, header[2] == 0 else { reject(); return }
                switch header[3] {
                    case 1: receiveExactly(6) { [self] data in
                        connect(host: data.prefix(4).map(String.init).joined(separator: "."), portBytes: data.suffix(2))
                    }
                    case 4: receiveExactly(18) { [self] data in
                        guard let address = IPv6Address(Data(data.prefix(16))) else { reject(); return }
                        connect(host: address.debugDescription, portBytes: data.suffix(2))
                    }
                    case 3: receiveExactly(1) { [self] length in
                        guard length[0] > 0 else { reject(); return }
                        receiveExactly(Int(length[0]) + 2) { [self] data in
                            guard let host = String(data: data.dropLast(2), encoding: .utf8),
                                  host.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), !host.contains("/"), !host.contains(":") else { reject(); return }
                            connect(host: host, portBytes: data.suffix(2))
                        }
                    }
                    default: reject()
                }
            }
        }

        func reject() { send(Data([5, 1, 0, 1, 0, 0, 0, 0, 0, 0]), to: client) { self.close() } }

        func connect(host: String, portBytes: Data.SubSequence) {
            let octets = Array(portBytes)
            guard let port = NWEndpoint.Port(rawValue: UInt16(octets[0]) * 256 + UInt16(octets[1])) else { reject(); return }
            if !host.contains(".") || host.lowercased().hasSuffix(".local") || IPv4Address(host) != nil || IPv6Address(host) != nil {
                open(addresses: [host], port: port)
                return
            }
            resolution = Task { [weak self] in
                do {
                    let addresses = try await HTTPSDNSResolver.shared.addresses(for: host)
                    guard let self else { return }
                    self.queue.async {
                        guard !self.finished else { return }
                        self.lastActivity = ProcessInfo.processInfo.systemUptime
                        self.open(addresses: Array(addresses.prefix(6)), port: port)
                    }
                } catch {
                    guard let self else { return }
                    self.queue.async { if !self.finished { self.reject() } }
                }
            }
        }

        func open(addresses: [String], port: NWEndpoint.Port) {
            guard !finished else { return }
            remote?.stateUpdateHandler = nil
            remote?.cancel()
            guard let host = addresses.first else { reject(); return }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.connectionTimeout = 15
            let parameters = NWParameters(tls: nil, tcp: tcp)
            let privacy = NWParameters.PrivacyContext(description: "Aidoku HTTPS bypass upstream")
            privacy.disableLogging()
            parameters.setPrivacyContext(privacy)
            let remote = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
            self.remote = remote
            remote.stateUpdateHandler = { [weak self, weak remote] state in
                guard let self, let remote, !self.finished, self.remote === remote else { return }
                switch state {
                    case .ready:
                        self.connected = true
                        self.send(Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), to: self.client) {
                            self.relay(from: remote, to: self.client)
                            self.readHello(remote: remote)
                        }
                    case .failed, .waiting:
                        if self.connected { self.close() } else { self.open(addresses: Array(addresses.dropFirst()), port: port) }
                    case .cancelled: self.close()
                    default: break
                }
            }
            remote.start(queue: queue)
            // Try another resolved address if one family has no usable route.
            queue.asyncAfter(deadline: .now() + 3) { [weak self, weak remote] in
                guard let self, let remote, !self.finished, !self.connected, self.remote === remote else { return }
                self.open(addresses: Array(addresses.dropFirst()), port: port)
            }
        }

        func readHello(remote: NWConnection) {
            guard !finished else { return }
            let inspection = TLSClientHello.inspect(buffer)
            if clientReadEnded, inspection == .incomplete {
                let data = buffer; buffer.removeAll()
                send(data, to: remote) { self.finishReading(from: self.client, to: remote) }
                return
            }
            switch inspection {
                case .split(let first, let second):
                    buffer.removeAll()
                    fragmented()
                    send(first, to: remote) {
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
                            guard let self else { return }
                            self.send(second, to: remote) { self.continueClient(remote: remote) }
                        }
                    }
                case .passthrough:
                    let data = buffer; buffer.removeAll()
                    send(data, to: remote) { self.continueClient(remote: remote) }
                case .incomplete:
                    client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
                        guard let self, !self.finished else { return }
                        if let data { self.buffer.append(data); self.lastActivity = ProcessInfo.processInfo.systemUptime }
                        guard error == nil else { self.close(); return }
                        self.clientReadEnded = done
                        self.readHello(remote: remote)
                    }
            }
        }

        func continueClient(remote: NWConnection) {
            if clientReadEnded { finishReading(from: client, to: remote) } else { relay(from: client, to: remote) }
        }

        // One bounded buffer per direction, with send completion providing backpressure.
        func relay(from source: NWConnection, to destination: NWConnection) {
            guard !finished else { return }
            source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
                guard let self, !self.finished else { return }
                guard error == nil else { self.close(); return }
                if let data, !data.isEmpty {
                    self.send(data, to: destination) {
                        if done { self.finishReading(from: source, to: destination) } else { self.relay(from: source, to: destination) }
                    }
                } else if done { self.finishReading(from: source, to: destination) } else { self.relay(from: source, to: destination) }
            }
        }

        // A half-close must still allow the response in the opposite direction.
        func finishReading(from source: NWConnection, to destination: NWConnection) {
            guard !finished, endedReaders.insert(ObjectIdentifier(source)).inserted else { return }
            destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil || self.endedReaders.count == 2 { self.close() }
            })
        }
    }
}
