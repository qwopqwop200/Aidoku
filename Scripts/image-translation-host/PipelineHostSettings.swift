import Foundation

// Host settings: dotenv reading and CLI > shell > .env > default resolution. Uses only Foundation and the
// translation model types (run-image-environment-smoke.py compiles it alone). The API key is never printed or written.

struct PipelineHostError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

/// Small dotenv reader: data only, with no shell execution or variable expansion.
enum PipelineDotEnv {
    static func parse(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            // The message names the line only; the value may be a credential.
            let invalid = PipelineHostError("Invalid .env syntax at line \(index + 1)")
            guard let equal = line.firstIndex(of: "=") else { throw invalid }
            let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw invalid }
            var value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                guard let end = value.dropFirst().firstIndex(of: quote) else { throw invalid }
                let remainder = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
                guard remainder.isEmpty || remainder.hasPrefix("#") else { throw invalid }
                value = String(value[value.index(after: value.startIndex)..<end])
            } else if let comment = value.range(of: "\\s+#", options: .regularExpression) {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }

    /// The dotenv file: `AIDOKU_ENV_FILE` when set (an empty value disables it), else `<root>/.env`.
    static func file(root: URL, environment: [String: String]) -> URL? {
        guard let explicit = environment["AIDOKU_ENV_FILE"] else { return root.appendingPathComponent(".env") }
        return explicit.isEmpty ? nil : URL(fileURLWithPath: explicit, relativeTo: root).standardizedFileURL
    }

    /// Shell environment plus dotenv values for keys the shell did not set.
    /// An explicitly supplied shell variable, including an empty one, wins.
    static func merged(root: URL, environment: [String: String]) throws -> [String: String] {
        guard let file = file(root: root, environment: environment),
              FileManager.default.fileExists(atPath: file.path) else { return environment }
        let values = try parse(try String(contentsOf: file, encoding: .utf8))
        return environment.merging(values) { shell, _ in shell }
    }
}

/// Supplies the resolved API key to RemoteTranslationClient at request time.
struct PipelineHostCredentialStore: TranslationCredentialProviding {
    let account: String
    let secret: String
    func secret(for account: String) throws -> String {
        guard account == self.account, !secret.isEmpty else { throw RemoteTranslationError.missingCredential }
        return secret
    }
}

enum PipelineHostMode: String {
    /// S1-S10 with the real provider (S5 through PipelineTranslation / RemoteTranslationClient).
    case live
    /// S1-S10 with saved translations; no provider call.
    case replay
    /// S1-S4 only; recognized blocks are written, nothing is translated or rendered.
    case ocrOnly = "ocr-only"
}

struct PipelineHostSettings {
    static let defaultManifest = "pipeline-generalization-20261117/evaluation-audit/CANONICAL-GROUPED-SOURCE-MANIFEST.json"
    static let readingDirections = ["rightToLeft", "leftToRight", "topToBottom"]
    /// The app caps image-attached provider calls at three (ReaderTranslationService.translatePipeline).
    static let maximumProviderConcurrency = 3

    var images: [(id: String, path: String)] = []
    var output: URL?
    var jobs = 3
    var writers = 2
    var writePNG = true
    var split: String?
    var limit: Int?
    var printSettings = false
    var ocrOnly = false
    var replay: URL?
    var fillUnmatched = false
    /// Stage checkpoints: written to OUTPUT/stages, and reused from an earlier run up to `resume`.
    var saveStages = false
    var stagesFrom: URL?
    /// First recomputed stage (`PipelineHostStages.Resume`): s4, s5, s7 or s8.
    var resume = "s8"
    var translateDelay: UInt64 = 0
    var readingDirection = "rightToLeft"

    var baseURL = ""
    var model = ""
    var apiProtocol: RemoteTranslationProtocol = .chatCompletions
    var reasoningEffort: OpenAIReasoningEffort = .modelDefault
    var timeout: Double = 60
    var sourceLanguage = "auto"
    var targetLanguage = "ko"
    var keyEnv = "AIDOKU_TRANSLATION_API_KEY"
    var credentialGeneration: UInt64?
    var allowLocalHTTP = false
    var providerConcurrency = maximumProviderConcurrency
    /// Resolved API key; never printed or written.
    fileprivate(set) var credential = ""

    var mode: PipelineHostMode { ocrOnly ? .ocrOnly : replay != nil ? .replay : .live }

    var configuration: RemoteTranslationConfiguration {
        RemoteTranslationConfiguration(provider: .custom, apiProtocol: apiProtocol, baseURL: baseURL, model: model,
            credentialAccount: keyEnv, credentialGeneration: credentialGeneration ?? 0,
            reasoningEffort: reasoningEffort, timeout: timeout,
            allowsInsecureLocalhostForDevelopment: allowLocalHTTP)
    }

    var credentialStore: PipelineHostCredentialStore { PipelineHostCredentialStore(account: keyEnv, secret: credential) }

    /// Scheme and host of the provider endpoint (never the path, query or key).
    var endpointHost: String? {
        guard let url = URL(string: baseURL), let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// Non-secret resolved settings (`--print-settings`, run summary).
    func describe() -> [String: Any] {
        var value: [String: Any] = [
            "mode": mode.rawValue, "jobs": jobs, "writers": writers, "writePNG": writePNG,
            "readingDirection": readingDirection, "sourceLanguage": sourceLanguage, "targetLanguage": targetLanguage,
            "images": images.map { ["pageID": $0.id, "path": $0.path] },
        ]
        if let replay { value["replay"] = replay.path }
        if saveStages { value["saveStages"] = true }
        if let stagesFrom { value["stagesFrom"] = stagesFrom.path; value["resume"] = resume }
        if mode == .live {
            value["provider"] = [
                "endpoint": endpointHost ?? "", "model": model, "protocol": apiProtocol.rawValue,
                "reasoning": reasoningEffort.rawValue, "timeout": timeout, "keyEnv": keyEnv,
                "keyPresent": !credential.isEmpty, "credentialGeneration": credentialGeneration.map { Int($0) } ?? -1,
                "allowLocalHTTP": allowLocalHTTP, "concurrency": providerConcurrency,
                // Mandatory page settings (ReaderTranslationService.mandatoryPageSettings).
                "includePageImage": true, "filterSFX": true, "filterBackground": true,
            ] as [String: Any]
        }
        return value
    }

    static func parse(_ arguments: [String], environment: [String: String], root: URL) throws -> PipelineHostSettings {
        var settings = PipelineHostSettings()
        var manifest = root.deletingLastPathComponent().appendingPathComponent(defaultManifest)
        var lists: [String] = []
        var inputs: [String] = []

        func boolean(_ key: String, fallback: Bool) throws -> Bool {
            guard let value = environment[key] else { return fallback }
            switch value.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: throw PipelineHostError("Invalid boolean setting: \(key)")
            }
        }
        func integer(_ text: String, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
            guard let value = Int(text), range.contains(value) else {
                throw PipelineHostError("\(name) must be an integer in \(range.lowerBound)...\(range.upperBound)")
            }
            return value
        }
        func seconds(_ text: String, _ name: String) throws -> Double {
            guard let value = Double(text), value.isFinite, value > 0,
                  value <= RemoteTranslationConfiguration.maximumTimeout else {
                throw PipelineHostError("\(name) must be a positive number of seconds")
            }
            return value
        }
        func generation(_ text: String, _ name: String) throws -> UInt64 {
            guard let value = UInt64(text) else { throw PipelineHostError("\(name) must be a nonnegative integer") }
            return value
        }
        func choice<Value: RawRepresentable<String>>(_ text: String, _ name: String) throws -> Value {
            guard let value = Value(rawValue: text) else { throw PipelineHostError("Invalid \(name)") }
            return value
        }
        func direction(_ text: String, _ name: String) throws -> String {
            guard readingDirections.contains(text) else {
                throw PipelineHostError("\(name) must be one of \(readingDirections.joined(separator: ", "))")
            }
            return text
        }

        // Environment (shell, then .env, already merged by the caller).
        if let value = environment["AIDOKU_IMAGE_JOBS"] { settings.jobs = try integer(value, "AIDOKU_IMAGE_JOBS", 1...64) }
        settings.baseURL = environment["AIDOKU_TRANSLATION_BASE_URL"] ?? settings.baseURL
        settings.model = environment["AIDOKU_TRANSLATION_MODEL"] ?? settings.model
        if let value = environment["AIDOKU_TRANSLATION_PROTOCOL"] {
            settings.apiProtocol = try choice(value, "AIDOKU_TRANSLATION_PROTOCOL")
        }
        if let value = environment["AIDOKU_TRANSLATION_REASONING"] {
            settings.reasoningEffort = try choice(value, "AIDOKU_TRANSLATION_REASONING")
        }
        if let value = environment["AIDOKU_TRANSLATION_TIMEOUT"] {
            settings.timeout = try seconds(value, "AIDOKU_TRANSLATION_TIMEOUT")
        }
        settings.sourceLanguage = environment["AIDOKU_TRANSLATION_SOURCE"] ?? settings.sourceLanguage
        settings.targetLanguage = environment["AIDOKU_TRANSLATION_TARGET"] ?? settings.targetLanguage
        settings.keyEnv = environment["AIDOKU_TRANSLATION_KEY_ENV"] ?? settings.keyEnv
        if let value = environment["AIDOKU_TRANSLATION_CREDENTIAL_GENERATION"] {
            settings.credentialGeneration = try generation(value, "AIDOKU_TRANSLATION_CREDENTIAL_GENERATION")
        }
        settings.allowLocalHTTP = try boolean("AIDOKU_TRANSLATION_ALLOW_LOCAL_HTTP", fallback: settings.allowLocalHTTP)
        if let value = environment["AIDOKU_TRANSLATION_CONCURRENCY"] {
            settings.providerConcurrency = try integer(value, "AIDOKU_TRANSLATION_CONCURRENCY", 1...64)
        }
        if let value = environment["AIDOKU_READING_DIRECTION"] {
            settings.readingDirection = try direction(value, "AIDOKU_READING_DIRECTION")
        }

        // CLI arguments.
        var index = 0
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw PipelineHostError("\(arguments[index - 1]) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--list": lists.append(try value())
            case "--output": settings.output = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--jobs": settings.jobs = try integer(try value(), "--jobs", 1...64)
            case "--writers": settings.writers = try integer(try value(), "--writers", 1...16)
            case "--no-png": settings.writePNG = false
            case "--split": settings.split = try value()
            case "--manifest": manifest = URL(fileURLWithPath: try value())
            case "--limit": settings.limit = try integer(try value(), "--limit", 1...Int.max)
            case "--print-settings": settings.printSettings = true
            case "--ocr-only": settings.ocrOnly = true
            case "--replay-translations": settings.replay = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--replay-fill-unmatched": settings.fillUnmatched = true
            case "--save-stages": settings.saveStages = true
            case "--from-stages": settings.stagesFrom = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--from":
                settings.resume = try value()
                guard ["s4", "s5", "s7", "s8"].contains(settings.resume) else { throw PipelineHostError("Invalid --from") }
            case "--translate-delay-ms": settings.translateDelay = UInt64(try integer(try value(), "--translate-delay-ms", 0...600_000))
            case "--reading-direction": settings.readingDirection = try direction(try value(), "--reading-direction")
            case "--base-url": settings.baseURL = try value()
            case "--model": settings.model = try value()
            case "--protocol": settings.apiProtocol = try choice(try value(), "--protocol")
            case "--reasoning": settings.reasoningEffort = try choice(try value(), "--reasoning")
            case "--timeout": settings.timeout = try seconds(try value(), "--timeout")
            case "--source": settings.sourceLanguage = try value()
            case "--target": settings.targetLanguage = try value()
            case "--key-env": settings.keyEnv = try value()
            case "--credential-generation": settings.credentialGeneration = try generation(try value(), "--credential-generation")
            case "--allow-local-http": settings.allowLocalHTTP = true
            case "--provider-concurrency":
                settings.providerConcurrency = try integer(try value(), "--provider-concurrency", 1...64)
            case "--":
                inputs += arguments[(index + 1)...]
                index = arguments.count
                continue
            default:
                guard !argument.hasPrefix("-") else { throw PipelineHostError("Unknown option: \(argument)") }
                inputs.append(argument)
            }
            index += 1
        }
        settings.providerConcurrency = min(settings.providerConcurrency, maximumProviderConcurrency)
        settings.credential = environment[settings.keyEnv] ?? ""

        guard !(settings.ocrOnly && settings.replay != nil) else {
            throw PipelineHostError("Choose either --ocr-only or --replay-translations")
        }
        guard !settings.fillUnmatched || settings.replay != nil else {
            throw PipelineHostError("--replay-fill-unmatched needs --replay-translations")
        }
        if let stagesFrom = settings.stagesFrom {
            guard FileManager.default.fileExists(atPath: stagesFrom.appendingPathComponent("stages").path) else {
                throw PipelineHostError("--from-stages needs a run saved with --save-stages")
            }
            guard settings.mode != .live else { throw PipelineHostError("--from-stages needs --replay-translations or --ocr-only") }
        } else if arguments.contains("--from") {
            throw PipelineHostError("--from needs --from-stages")
        }
        // The pipeline always uses the manga recognizer (Japanese and Chinese source text).
        let source = settings.sourceLanguage == "zh-Hans" || settings.sourceLanguage == "zh-Hant" ? "zh" : settings.sourceLanguage
        guard ["auto", "ja", "zh"].contains(source) else {
            throw PipelineHostError("The pipeline's manga recognizer supports only Japanese and Chinese source text; "
                + "choose ja, zh-Hans, zh-Hant or auto.")
        }
        try RemoteTranslationRequest(sourceLanguage: settings.sourceLanguage, targetLanguage: settings.targetLanguage,
                                     sourceText: "validation").validate()
        if settings.mode == .live {
            guard !settings.baseURL.isEmpty, !settings.model.isEmpty else {
                throw PipelineHostError("Live translation needs --base-url and --model (or AIDOKU_TRANSLATION_BASE_URL / "
                    + "AIDOKU_TRANSLATION_MODEL in the shell or .env); use --ocr-only or --replay-translations offline")
            }
            _ = try settings.configuration.validatedEndpoint()
            guard !settings.credential.isEmpty else {
                throw PipelineHostError("Missing API key: set \(settings.keyEnv) in the shell or .env")
            }
            guard settings.credential.utf8.count <= 16 * 1024,
                  !settings.credential.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
                throw PipelineHostError("The API key in \(settings.keyEnv) is malformed")
            }
        }

        // Inputs.
        var collected: [(id: String, path: String)] = []
        for input in inputs { collected += try expand(input) }
        for list in lists { collected += try readList(URL(fileURLWithPath: list)) }
        if let split = settings.split {
            guard ["dev", "train", "test"].contains(split) else { throw PipelineHostError("--split must be dev, train or test") }
            let data = try Data(contentsOf: manifest)
            let pages = ((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?["pages"] as? [[String: Any]] ?? []
            for page in pages where page["split"] as? String == split {
                if let id = page["page_id"] as? String, let path = page["image_path"] as? String { collected.append((id, path)) }
            }
        }
        settings.images = unique(collected)
        if let limit = settings.limit { settings.images = Array(settings.images.prefix(limit)) }
        guard !settings.images.isEmpty else { throw PipelineHostError("No input pages") }
        return settings
    }

    static func pageID(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        return stem == "input" ? url.deletingLastPathComponent().lastPathComponent : stem
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "gif", "bmp"]

    static func expand(_ path: String) throws -> [(id: String, path: String)] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw PipelineHostError("Input does not exist: \(path)")
        }
        guard isDirectory.boolValue else { return [(pageID(for: path), path)] }
        return try FileManager.default.contentsOfDirectory(atPath: path).sorted()
            .filter { !$0.hasPrefix(".") && imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { name in
                let full = (path as NSString).appendingPathComponent(name)
                return (pageID(for: full), full)
            }
    }

    /// A JSON array of paths or {"page_id", "image_path"} objects, or a text file with one path per line.
    /// Relative paths resolve against the list's folder.
    static func readList(_ list: URL) throws -> [(id: String, path: String)] {
        let data = try Data(contentsOf: list)
        func resolve(_ path: String) -> String {
            path.hasPrefix("/") ? path : list.deletingLastPathComponent().appendingPathComponent(path).path
        }
        if list.pathExtension.lowercased() == "json" {
            guard let items = (try JSONSerialization.jsonObject(with: data)) as? [Any] else {
                throw PipelineHostError("List must be a JSON array: \(list.path)")
            }
            return try items.flatMap { item -> [(id: String, path: String)] in
                if let path = item as? String { return try expand(resolve(path)) }
                guard let object = item as? [String: Any], let path = object["image_path"] as? String else {
                    throw PipelineHostError("Invalid list entry in \(list.path)")
                }
                return [((object["page_id"] as? String) ?? pageID(for: path), resolve(path))]
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw PipelineHostError("List must be UTF-8: \(list.path)") }
        return try text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }.flatMap { try expand(resolve($0)) }
    }

    /// Drops repeated files (same resolved path) and makes page ids unique (`page`, `page-2`, ...).
    static func unique(_ images: [(id: String, path: String)]) -> [(id: String, path: String)] {
        var seenPaths = Set<String>()
        var seenIDs = Set<String>()
        var result: [(id: String, path: String)] = []
        for image in images {
            let canonical = URL(fileURLWithPath: image.path).standardizedFileURL.resolvingSymlinksInPath().path
            guard seenPaths.insert(canonical).inserted else { continue }
            let base = image.id.replacingOccurrences(of: "/", with: "_")
            var id = base
            var suffix = 2
            while !seenIDs.insert(id).inserted {
                id = "\(base)-\(suffix)"
                suffix += 1
            }
            result.append((id, image.path))
        }
        return result
    }
}
