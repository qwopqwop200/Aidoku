import Foundation

/// Incremental decoder for an OpenAI-compatible Chat Completions SSE body.
/// Only complete lines are decoded, so the content does not depend on where
/// bytes were split (even inside a UTF-8 scalar or a JSON escape).
struct ChatCompletionStreamDecoder {
    private var pending = Data()
    private var searchedBytes = 0
    private(set) var content = ""
    private(set) var finishReason: String?
    private(set) var refused = false

    mutating func consume(_ data: Data) throws {
        pending.append(data)
        var lineStart = pending.startIndex
        var searchStart = pending.index(lineStart, offsetBy: searchedBytes)
        while let newline = pending[searchStart...].firstIndex(of: 0x0A) {
            // Decode before discarding bytes; removing the prefix per line would copy the buffer repeatedly.
            try decode(line: Data(pending[lineStart..<newline]))
            lineStart = pending.index(after: newline)
            searchStart = lineStart
        }
        searchedBytes = pending.distance(from: lineStart, to: pending.endIndex)
        if lineStart != pending.startIndex {
            pending.removeSubrange(pending.startIndex..<lineStart)
        }
    }

    /// Decodes a final unterminated line.
    mutating func finish() throws {
        guard !pending.isEmpty else { return }
        let line = pending
        pending = Data()
        searchedBytes = 0
        try decode(line: line)
    }

    private mutating func decode(line rawLine: Data) throws {
        var line = rawLine
        if line.last == 0x0D { line.removeLast() }
        guard line.starts(with: Data("data:".utf8)) else { return } // comments, event:, id:, blank separators
        var payload = line.dropFirst(5)
        if payload.first == 0x20 { payload = payload.dropFirst() }
        if payload.elementsEqual(Data("[DONE]".utf8)) { return }
        guard let root = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else {
            throw RemoteTranslationError.invalidResponse("the chat completion stream is not valid JSON")
        }
        if let error = root["error"], !(error is NSNull) {
            throw RemoteTranslationError.invalidResponse("the chat completion stream returned an error")
        }
        guard let choices = root["choices"] as? [Any] else { return } // usage-only chunk
        for case let choice as [String: Any] in choices where (choice["index"] as? NSNumber)?.intValue ?? 0 == 0 {
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
            guard let message = choice["delta"] as? [String: Any] else { continue }
            if (message["refusal"] as? String)?.isEmpty == false { refused = true }
            if let text = message["content"] as? String { content += text }
        }
    }
}
