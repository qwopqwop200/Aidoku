import Foundation
import Darwin

/// Small dotenv reader: data only, with no shell execution or variable expansion.
enum HostEnvironment {
    static func read(_ file: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let text = try String(contentsOf: file, encoding: .utf8)
        var result: [String: String] = [:]
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            func invalid() -> NSError {
                NSError(domain: "HostEnvironment", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid .env syntax at line \(index + 1)"])
            }
            guard let equal = line.firstIndex(of: "=") else { throw invalid() }
            let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw invalid() }
            var value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                guard let end = value.dropFirst().firstIndex(of: quote) else { throw invalid() }
                let remainder = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
                guard remainder.isEmpty || remainder.hasPrefix("#") else { throw invalid() }
                value = String(value[value.index(after: value.startIndex)..<end])
            } else if let comment = value.range(of: "\\s+#", options: .regularExpression) {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }
    static func load(root: URL) throws {
        for (key, value) in try read(root.appendingPathComponent(".env")) {
            // An explicitly supplied shell variable, including an empty value, takes precedence.
            if getenv(key) == nil { setenv(key, value, 0) }
        }
    }
}
