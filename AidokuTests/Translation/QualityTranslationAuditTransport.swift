import CoreFoundation
import CryptoKit
import Foundation
@testable import Aidoku

/// Opt-in test evidence only. Never persists requests, headers, URLs or credentials.
/// Audit parsing/writing cannot alter the response or add a transport request.
actor QualityTranslationAuditTransport: TranslationHTTPTransport {
    enum Classification: String, Codable, Sendable {
        case `true`, `false`, missing, invalid
    }

    struct Translation: Encodable, Sendable {
        let id: String
        let text: String?
        let is_sfx: Classification
        let textRole: String?

        private enum CodingKeys: String, CodingKey { case id, text, is_sfx, classification, text_role }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encodeIfPresent(text, forKey: .text)
            try values.encode(is_sfx, forKey: .classification)
            try values.encodeIfPresent(textRole, forKey: .text_role)
            switch is_sfx {
            case .true: try values.encode(true, forKey: .is_sfx)
            case .false: try values.encode(false, forKey: .is_sfx)
            case .missing, .invalid: break
            }
        }
    }

    struct Entry: Encodable, Sendable {
        let pageID: String?
        let requestSegmentIDs: [String]
        let requestSourceSHA256: [String: String]
        let translations: [Translation]
        let elapsedMilliseconds: Double
        let usage: [String: Double]
    }

    private let base: any TranslationHTTPTransport
    private var outputDirectory: URL?
    private var captured: [Entry] = []
    private var pageID: String?

    init(base: any TranslationHTTPTransport, outputDirectory: URL? = nil) {
        self.base = base
        self.outputDirectory = outputDirectory
    }

    /// The optional directory enables capture only; filesystem I/O occurs exclusively in flush.
    /// Set before starting a page. In-flight requests keep their original opt-in state.
    func setOutputDirectory(_ directory: URL?) { outputDirectory = directory }
    func records() -> [Entry] { captured }
    func reset() { captured.removeAll(keepingCapacity: true) }
    func setPageID(_ value: String?) { pageID = value }

    /// Call after measured page completion and render saving, never in the transport path.
    func flush(to file: URL) throws {
        let data = try JSONEncoder().encode(captured)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    func data(for request: URLRequest, maximumResponseBytes: Int,
              bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        guard outputDirectory != nil else {
            return try await base.data(for: request, maximumResponseBytes: maximumResponseBytes, bypassesProxy: bypassesProxy)
        }
        let page = pageID
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await base.data(for: request, maximumResponseBytes: maximumResponseBytes,
                                         bypassesProxy: bypassesProxy)
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let entry = Self.entry(request: request, response: result.data, elapsed: elapsed, pageID: page)
        captured.append(entry)
        return result
    }

    private static func entry(request: URLRequest, response: Data, elapsed: Double, pageID: String?) -> Entry {
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let pieces = authorization.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let token = pieces.count == 2 && pieces[0].lowercased() == "bearer"
            ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        func redact(_ text: String) -> String {
            var value = text
            for secret in [authorization, token] where !secret.isEmpty {
                value = value.replacingOccurrences(of: secret, with: "[REDACTED]")
            }
            return value
        }
        func object(_ data: Data?) -> [String: Any] {
            guard let data else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        func textContent(_ value: Any?, type: String) -> String? {
            if let text = value as? String { return text }
            guard let parts = value as? [[String: Any]] else { return nil }
            let texts = parts.filter { $0["type"] as? String == type }.compactMap { $0["text"] as? String }
            return texts.count == 1 ? texts[0] : nil
        }

        let body = object(request.httpBody)
        let responses = body["input"] != nil
        let messages = body[responses ? "input" : "messages"] as? [[String: Any]] ?? []
        let sourceText = textContent(messages.last?["content"], type: responses ? "input_text" : "text")
        let source = object(sourceText?.data(using: .utf8))
        let sourceSegments = source["segments"] as? [[String: Any]] ?? []
        let ids = sourceSegments.compactMap { $0["id"] as? String }.map(redact)
        var sourceHashes: [String: String] = [:]
        for segment in sourceSegments {
            guard let id = segment["id"] as? String, let text = segment["text"] as? String else { continue }
            // Hash only this text field. No request body, headers or credentials enter the digest.
            sourceHashes[redact(id)] = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        let root = object(response)
        let envelope: String?
        if responses {
            let texts = (root["output"] as? [[String: Any]] ?? []).flatMap {
                $0["content"] as? [[String: Any]] ?? []
            }.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }
            envelope = texts.count == 1 ? texts[0] : nil
        } else {
            let choices = (root["choices"] as? [[String: Any]] ?? []).filter {
                ($0["index"] as? NSNumber)?.intValue == 0
            }
            let message = choices.count == 1 ? choices[0]["message"] as? [String: Any] : nil
            envelope = textContent(message?["content"], type: "text")
        }
        let translations = (object(envelope?.data(using: .utf8))["translations"] as? [[String: Any]] ?? []).compactMap { item -> Translation? in
            guard let id = item["id"] as? String else { return nil }
            let flag: Classification
            if item["is_sfx"] == nil {
                flag = .missing
            } else if let value = item["is_sfx"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
                flag = value.boolValue ? .true : .false
            } else {
                flag = .invalid
            }
            return Translation(id: redact(id), text: (item["text"] as? String).map(redact), is_sfx: flag, textRole: (item["text_role"] as? String).map(redact))
        }
        let rawUsage = root["usage"] as? [String: Any] ?? [:]
        var usage: [String: Double] = [:]
        for key in ["prompt_tokens", "completion_tokens", "total_tokens", "input_tokens", "output_tokens"] {
            if let number = rawUsage[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue.isFinite, number.doubleValue >= 0 {
                usage[key] = number.doubleValue
            }
        }
        return Entry(pageID: pageID.map(redact), requestSegmentIDs: ids, requestSourceSHA256: sourceHashes, translations: translations,
                     elapsedMilliseconds: elapsed, usage: usage)
    }
}
