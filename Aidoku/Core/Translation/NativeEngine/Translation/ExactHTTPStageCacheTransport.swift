import Foundation
import CryptoKit

/// Read-only reuse of an actual sealed HTTP stage. This boundary deliberately
/// knows nothing about renderers, source-pipeline producers or post-LLM rules.
/// An unchanged endpoint/protocol/model/request body is the same provider work.
/// The default nil directory preserves normal transport behavior on both apps.
struct ExactHTTPStageCacheTransport: TranslationHTTPTransport {
    struct Event: Codable, Sendable {
        let outcome: String
        let stageDigest: String?
        let responseBytes: Int
        let headersRecorded: Bool
    }

    private struct Receipt: Decodable {
        let schema: String
        let stageDigest: String
        let wireBodySHA256: String
        let endpoint: String
        let model: String
        let status: String
        let statusCode: Int?
        let responsePath: String?
        let responseSHA256: String?
        let responseHeaders: [String: String]?
    }

    let fallback: any TranslationHTTPTransport
    let cacheDirectory: URL?
    let forbidsNetwork: Bool
    let onEvent: (@Sendable (Event) -> Void)?

    init(fallback: any TranslationHTTPTransport, cacheDirectory: URL? = nil,
         forbidsNetwork: Bool = false,
         onEvent: (@Sendable (Event) -> Void)? = nil) {
        self.fallback = fallback
        self.cacheDirectory = cacheDirectory
        self.forbidsNetwork = forbidsNetwork
        self.onEvent = onEvent
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Same exact schema and sorted JSON as HostSealedLLMStage and its planner.
    /// Source identity and per-owner evidence are checked before serialization;
    /// everything actually supplied to the model is already in these body bytes.
    static func stageDigest(for request: URLRequest) throws -> String? {
        guard request.httpMethod == "POST", let url = request.url, let body = request.httpBody,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = payload["model"] as? String, !model.isEmpty else { return nil }
        let apiProtocol: String
        if payload["input"] != nil, url.path.hasSuffix("/responses") {
            apiProtocol = RemoteTranslationProtocol.responses.rawValue
        } else if payload["messages"] != nil, url.path.hasSuffix("/chat/completions") {
            apiProtocol = RemoteTranslationProtocol.chatCompletions.rawValue
        } else { return nil }
        let identity: [String: String] = ["schema": "actual-llm-http-request-v1",
            "endpoint": url.absoluteString, "apiProtocol": apiProtocol, "model": model,
            "wireBodySHA256": sha(body)]
        return sha(try JSONSerialization.data(withJSONObject: identity,
            options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    func data(for request: URLRequest, maximumResponseBytes: Int,
              bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        try await data(for: request, maximumResponseBytes: maximumResponseBytes,
            bypassesProxy: bypassesProxy, onBodyData: nil)
    }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool,
              onBodyData: TranslationHTTPBodyObserver?) async throws -> TranslationHTTPResponse {
        try Task.checkCancellation()
        guard let cacheDirectory, let digest = try Self.stageDigest(for: request) else {
            if forbidsNetwork {
                onEvent?(.init(outcome: "unobserved-network-forbidden", stageDigest: nil,
                    responseBytes: 0, headersRecorded: false))
                throw RemoteTranslationError.invalidResponse("Exact provider stage is unobserved or unsupported; LLM network execution is forbidden")
            }
            return try await fallback.data(for: request, maximumResponseBytes: maximumResponseBytes,
                bypassesProxy: bypassesProxy, onBodyData: onBodyData)
        }
        let root = cacheDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let receiptURL = root.appendingPathComponent(digest + ".receipt.json")
        let responseURL = root.appendingPathComponent(digest + ".response.json")
        let claimURL = root.appendingPathComponent(digest + ".claimed")
        let manager = FileManager.default
        guard manager.fileExists(atPath: receiptURL.path) else {
            // A claimed/incomplete attempt may already have consumed model
            // work. A read-only consumer never turns uncertainty into a retry.
            if manager.fileExists(atPath: claimURL.path) || manager.fileExists(atPath: responseURL.path) {
                onEvent?(.init(outcome: "incomplete-fail-closed", stageDigest: digest,
                    responseBytes: 0, headersRecorded: false))
                throw RemoteTranslationError.invalidResponse("Exact provider stage is incomplete; no automatic request retry")
            }
            if forbidsNetwork {
                onEvent?(.init(outcome: "unobserved-network-forbidden", stageDigest: digest,
                    responseBytes: 0, headersRecorded: false))
                throw RemoteTranslationError.invalidResponse("Exact provider stage is unobserved; LLM network execution is forbidden")
            }
            onEvent?(.init(outcome: "miss", stageDigest: digest, responseBytes: 0, headersRecorded: false))
            return try await fallback.data(for: request, maximumResponseBytes: maximumResponseBytes,
                bypassesProxy: bypassesProxy, onBodyData: onBodyData)
        }
        do {
            guard maximumResponseBytes > 0,
                  receiptURL.resolvingSymlinksInPath().deletingLastPathComponent() == root,
                  responseURL.resolvingSymlinksInPath().deletingLastPathComponent() == root,
                  let endpoint = request.url, let body = request.httpBody,
                  let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let model = payload["model"] as? String else { throw CocoaError(.coderReadCorrupt) }
            let receiptSize = try receiptURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard receiptSize.isRegularFile == true, (receiptSize.fileSize ?? Int.max) <= 1_048_576 else {
                throw CocoaError(.coderReadCorrupt)
            }
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
            guard receipt.schema == "sealed-LLM-once-receipt-v1", receipt.status == "complete",
                  receipt.stageDigest == digest, receipt.wireBodySHA256 == Self.sha(body),
                  receipt.endpoint == endpoint.absoluteString, receipt.model == model,
                  let code = receipt.statusCode, (200...299).contains(code),
                  let responseHash = receipt.responseSHA256, responseHash.count == 64,
                  let declaredPath = receipt.responsePath,
                  URL(fileURLWithPath: declaredPath).lastPathComponent == responseURL.lastPathComponent else {
                throw CocoaError(.coderReadCorrupt)
            }
            let size = try responseURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true else { throw CocoaError(.coderReadCorrupt) }
            guard let bytesCount = size.fileSize, bytesCount <= maximumResponseBytes else {
                throw RemoteTranslationError.responseTooLarge
            }
            let bytes = try Data(contentsOf: responseURL)
            guard bytes.count <= maximumResponseBytes, Self.sha(bytes) == responseHash,
                  let response = HTTPURLResponse(url: endpoint, statusCode: code,
                    httpVersion: nil, headerFields: receipt.responseHeaders) else { throw CocoaError(.coderReadCorrupt) }
            try Task.checkCancellation()
            onEvent?(.init(outcome: "hit", stageDigest: digest, responseBytes: bytes.count,
                headersRecorded: receipt.responseHeaders != nil))
            if !bytes.isEmpty { onBodyData?(bytes) }
            return TranslationHTTPResponse(data: bytes, response: response, metrics: .unmeasured)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            onEvent?(.init(outcome: "invalid-fail-closed", stageDigest: digest,
                responseBytes: 0, headersRecorded: false))
            // Do not log receipt/body/headers/endpoint values or fall back to a
            // duplicate provider call after a corrupt or pending cache entry.
            throw RemoteTranslationError.invalidResponse("Exact provider stage receipt or response is invalid; network fallback refused")
        }
    }
}
