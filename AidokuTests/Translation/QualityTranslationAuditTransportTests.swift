import Foundation
import Testing
@testable import Aidoku

struct QualityTranslationAuditTransportTests {
    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions],
          [QualityTranslationAuditTransport.Classification.true, .false, .missing, .invalid])
    func capturesRawClassificationWithoutChangingTransport(
        apiProtocol: RemoteTranslationProtocol, classification: QualityTranslationAuditTransport.Classification
    ) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = "test-only-audit-redaction-token"
        var source = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: [.init(id: "segment-0", text: "あっ")])
        source.filtersSFX = true
        let config = RemoteTranslationConfiguration(provider: .custom, apiProtocol: apiProtocol,
            baseURL: "https://audit.invalid/v1", model: "test", credentialAccount: "test")
        var request = URLRequest(url: URL(string: "https://audit.invalid/v1")!)
        request.httpBody = try TranslationHTTPCodec.requestBody(configuration: config, request: source)
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        var item: [String: Any] = ["id": "segment-0", "text": "reply Bearer " + secret]
        switch classification {
        case .true: item["is_sfx"] = true
        case .false: item["is_sfx"] = false
        case .missing: break
        case .invalid: item["is_sfx"] = 1 // NSNumber is not necessarily a JSON boolean.
        }
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": [item]]), as: UTF8.self)
        var envelope: [String: Any] = apiProtocol == .responses
            ? ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": content]]]]]
            : ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": content]]]]
        envelope["usage"] = ["total_tokens": 7, "untrusted_text": secret]
        let response = TranslationHTTPResponse(data: try JSONSerialization.data(withJSONObject: envelope),
            response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["private": secret])!,
            metrics: .init(responseHeadersMilliseconds: 1, firstBodyByteMilliseconds: 2, bodyMilliseconds: 3, totalMilliseconds: 4))
        let base = QualityAuditFixtureTransport(response: response)
        let transport = QualityTranslationAuditTransport(base: base, outputDirectory: folder)
        await transport.setPageID("page-1")
        let returned = try await transport.data(for: request, maximumResponseBytes: 123456, bypassesProxy: true)
        #expect(returned.data == response.data)
        #expect(returned.response === response.response)
        #expect(returned.metrics == response.metrics)
        let calls = await base.calls
        #expect(calls.count == 1)
        #expect(calls.first?.request == request)
        #expect(calls.first?.limit == 123456)
        #expect(calls.first?.bypassesProxy == true)
        let records = await transport.records()
        let entry = try #require(records.first)
        #expect(entry.pageID == "page-1")
        #expect(entry.requestSegmentIDs == ["segment-0"])
        let expectedDigest = "e24f9eadaac2feb97fd3fb883a57a6f1e8052f6d5cd578220ba73a635f879700"
        #expect(entry.requestSourceSHA256 == ["segment-0": expectedDigest])
        #expect(entry.translations.first?.is_sfx == classification)
        #expect(entry.translations.first?.text == "reply [REDACTED]")
        #expect(entry.usage == ["total_tokens": 7])
        #expect(entry.elapsedMilliseconds >= 0)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try await transport.flush(to: folder.appendingPathComponent("page.json"))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let saved = try String(contentsOf: #require(files.first), encoding: .utf8)
        #expect(!saved.contains(secret))
        #expect(!saved.contains("Authorization"))
        #expect(!saved.contains("audit.invalid"))
        #expect(!saved.contains("あっ"))
        let savedEntries = try #require(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [[String: Any]])
        let savedRows = try #require(savedEntries.first?["translations"] as? [[String: Any]])
        #expect(savedRows.first?["classification"] as? String == classification.rawValue)
        if classification == .true || classification == .false {
            #expect(savedRows.first?["is_sfx"] as? Bool == (classification == .true))
        } else {
            #expect(savedRows.first?["is_sfx"] == nil)
        }
        await transport.reset()
        #expect(await transport.records().isEmpty)
        if classification == .true || classification == .false {
            let decoded = try TranslationHTTPCodec.responseTranslations(from: returned.data, protocol: apiProtocol,
                expectedSegmentIDs: ["segment-0"], sfxSourceTexts: ["segment-0": "あっ"])
            #expect(decoded.first?.isSFX == (classification == .true))
        } else {
            #expect(throws: RemoteTranslationError.self) {
                try TranslationHTTPCodec.responseTranslations(from: returned.data, protocol: apiProtocol,
                    expectedSegmentIDs: ["segment-0"], sfxSourceTexts: ["segment-0": "あっ"])
            }
        }
    }

    @Test func disabledAuditIsOnePassThrough() async throws {
        let request = URLRequest(url: URL(string: "https://audit.invalid")!)
        let response = TranslationHTTPResponse(data: Data([0, 1, 2]),
            response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        let base = QualityAuditFixtureTransport(response: response)
        let transport = QualityTranslationAuditTransport(base: base)
        let returned = try await transport.data(for: request, maximumResponseBytes: 32, bypassesProxy: false)
        #expect(returned.data == response.data)
        #expect(await transport.records().isEmpty)
        #expect(await base.calls.count == 1)
    }

    @Test func inFlightRequestKeepsPageAndCaptureDecision() async throws {
        let request = URLRequest(url: URL(string: "https://audit.invalid")!)
        let response = TranslationHTTPResponse(data: Data(),
            response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        let base = QualityAuditGatedTransport(response: response)
        let transport = QualityTranslationAuditTransport(base: base, outputDirectory: FileManager.default.temporaryDirectory)
        await transport.setPageID("first-page")
        let pending = Task { try await transport.data(for: request, maximumResponseBytes: 32, bypassesProxy: false) }
        await base.waitUntilStarted()
        await transport.setPageID("next-page")
        await transport.setOutputDirectory(nil)
        await base.release()
        let returned = try await pending.value
        #expect(returned.response === response.response)
        #expect(await transport.records().map(\.pageID) == ["first-page"])
    }
}

private actor QualityAuditFixtureTransport: TranslationHTTPTransport {
    struct Call { let request: URLRequest; let limit: Int; let bypassesProxy: Bool }
    let response: TranslationHTTPResponse
    var calls: [Call] = []
    init(response: TranslationHTTPResponse) { self.response = response }
    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        calls.append(.init(request: request, limit: maximumResponseBytes, bypassesProxy: bypassesProxy))
        return response
    }
}

private actor QualityAuditGatedTransport: TranslationHTTPTransport {
    let response: TranslationHTTPResponse
    var pending: CheckedContinuation<TranslationHTTPResponse, Never>?
    var startedWaiters: [CheckedContinuation<Void, Never>] = []
    init(response: TranslationHTTPResponse) { self.response = response }
    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        await withCheckedContinuation { continuation in
            pending = continuation
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
        }
    }
    func waitUntilStarted() async {
        guard pending == nil else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func release() {
        pending?.resume(returning: response)
        pending = nil
    }
}
