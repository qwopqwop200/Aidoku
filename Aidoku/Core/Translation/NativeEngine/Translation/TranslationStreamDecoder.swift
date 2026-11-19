// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

/// Incremental decoder for an OpenAI-compatible Chat Completions SSE body.
/// Bytes may be split anywhere, including inside a UTF-8 scalar or a JSON
/// escape: only complete lines are decoded, so the resulting content does not
/// depend on network chunk boundaries.
struct ChatCompletionStreamDecoder {
    private var pending = Data()
    private var searchedBytes = 0
    private(set) var content = ""
    private(set) var finishReason: String?
    private(set) var refused = false
    private(set) var completed = false

    /// Returns content deltas decoded from the complete lines in `data`.
    mutating func consume(_ data: Data) throws -> [String] {
        pending.append(data)
        var deltas: [String] = []
        var lineStart = pending.startIndex
        var searchStart = pending.index(lineStart, offsetBy: searchedBytes)
        while let newline = pending[searchStart...].firstIndex(of: 0x0A) {
            // Decode before discarding bytes. Removing the prefix per line
            // repeatedly copies the remaining buffered SSE response.
            if let delta = try decode(line: Data(pending[lineStart..<newline])) {
                deltas.append(delta)
            }
            lineStart = pending.index(after: newline)
            searchStart = lineStart
        }
        searchedBytes = pending.distance(from: lineStart, to: pending.endIndex)
        if lineStart != pending.startIndex {
            pending.removeSubrange(pending.startIndex..<lineStart)
        }
        return deltas
    }

    /// Decodes a final unterminated line.
    mutating func finish() throws -> [String] {
        guard !pending.isEmpty else { return [] }
        let line = pending
        pending = Data()
        searchedBytes = 0
        return try decode(line: line).map { [$0] } ?? []
    }

    private mutating func decode(line rawLine: Data) throws -> String? {
        var line = rawLine
        if line.last == 0x0D { line.removeLast() }
        guard line.starts(with: Data("data:".utf8)) else { return nil } // comments, event:, id:, blank separators
        var payload = line.dropFirst(5)
        if payload.first == 0x20 { payload = payload.dropFirst() }
        if payload.elementsEqual(Data("[DONE]".utf8)) {
            completed = true
            return nil
        }
        guard let root = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else {
            throw RemoteTranslationError.invalidResponse("the chat completion stream is not valid JSON")
        }
        if let error = root["error"], !(error is NSNull) {
            throw RemoteTranslationError.invalidResponse("the chat completion stream returned an error")
        }
        guard let choices = root["choices"] as? [Any] else { return nil } // usage-only chunk
        var delta: String?
        for case let choice as [String: Any] in choices where (choice["index"] as? NSNumber)?.intValue ?? 0 == 0 {
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
            guard let message = choice["delta"] as? [String: Any] else { continue }
            if (message["refusal"] as? String)?.isEmpty == false { refused = true }
            if let text = message["content"] as? String, !text.isEmpty {
                delta = (delta ?? "") + text
            }
        }
        if let delta { content += delta }
        return delta
    }
}
