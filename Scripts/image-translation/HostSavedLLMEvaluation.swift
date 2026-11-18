import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// Host-only experiment boundary: replace exactly the six role definitions in
/// the serialized instruction line; every other prompt and wire field is fixed.
private final class HostRoleDescriptionTransport: TranslationHTTPTransport, @unchecked Sendable {
    private let base = BoundedURLSessionTransport()
    private let replacement: String?
    private let lock = NSLock()
    private var rows: [[String: Any]] = []

    init(replacement: String?) throws {
        if let replacement {
            guard !replacement.isEmpty, !replacement.contains("\n"),
                ("text_role: " + replacement).count <= 1800,
                ["dialogue=", "narration=", "story_text=", "background=", "sfx=", "error="].allSatisfy(replacement.contains)
            else { throw HostError.message("Role descriptions must be one English line, six roles and at most1800 characters") }
        }
        self.replacement = replacement
    }

    func audits(reset: Bool = false) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let result = rows
        if reset { rows.removeAll() }
        return result
    }

    private func rewritten(_ request: URLRequest) throws -> URLRequest {
        guard let body = request.httpBody else { return request }
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            let instructions = object["instructions"] as? String else {
            throw HostError.message("Role-only evaluation expects the configured Responses instruction field")
        }
        var lines = instructions.components(separatedBy: "\n")
        let indices = lines.indices.filter { lines[$0].hasPrefix("text_role: ") }
        guard indices.count == 1, let index = indices.first else { throw HostError.message("Role instruction boundary changed") }
        let previous = lines[index]
        let beforeOtherPrompt = lines.enumerated().filter { $0.offset != index }.map(\.element).joined(separator: "\n")
        object.removeValue(forKey: "instructions")
        let otherWire = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if let replacement { lines[index] = "text_role: " + replacement }
        let afterOtherPrompt = lines.enumerated().filter { $0.offset != index }.map(\.element).joined(separator: "\n")
        guard beforeOtherPrompt == afterOtherPrompt else { throw HostError.message("Non-role prompt changed") }
        let newInstructions = lines.joined(separator: "\n")
        if replacement != nil && newInstructions.count > 1800 {
            throw HostError.message("Complete instruction block exceeds1800 characters; fixed non-role guidance cannot be shortened")
        }
        object["instructions"] = newInstructions
        let rewritten = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var check = try JSONSerialization.jsonObject(with: rewritten) as! [String: Any]
        check.removeValue(forKey: "instructions")
        guard try JSONSerialization.data(withJSONObject: check, options: [.sortedKeys]) == otherWire else {
            throw HostError.message("Non-instruction wire fields changed")
        }
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let row: [String: Any] = ["roleLineCharacters": lines[index].count, "totalInstructionCharacters": newInstructions.count,
            "fixedInstructionCharacters": newInstructions.count - lines[index].count,
            "roleLineSHA256": hash(Data(lines[index].utf8)),
            "baselineRoleLineSHA256": hash(Data(previous.utf8)), "otherPromptSHA256": hash(Data(beforeOtherPrompt.utf8)),
            "otherWireSHA256": hash(otherWire), "nonRolePromptIdentical": true, "nonRoleWireIdentical": true,
            "temperature": object["temperature"] as Any? ?? NSNull(), "topP": object["top_p"] as Any? ?? NSNull(),
            "topK": object["top_k"] as Any? ?? NSNull(), "repetitionPenalty": object["repetition_penalty"] as Any? ?? NSNull()]
        lock.lock(); rows.append(row); lock.unlock()
        var result = request
        if replacement != nil { result.httpBody = rewritten }
        return result
    }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        try await base.data(for: rewritten(request), maximumResponseBytes: maximumResponseBytes, bypassesProxy: bypassesProxy)
    }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool,
              onBodyData: TranslationHTTPBodyObserver?) async throws -> TranslationHTTPResponse {
        try await base.data(for: rewritten(request), maximumResponseBytes: maximumResponseBytes,
            bypassesProxy: bypassesProxy, onBodyData: onBodyData)
    }
}

/// Evaluate the current native LLM request contract on frozen final OCR owners.
/// This path never changes OCR geometry, consults GT, reruns OCR, or renders pages.
@available(macOS 15.0, *)
enum HostSavedLLMEvaluation {
    private struct Input: Decodable {
        let page: String
        let image: String
        let regions: [Region]
    }
    private struct Rect: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
    private struct Region: Decodable {
        let id: String
        let source: String
        let rect: Rect
        let confidence: Double
        var native: ReaderTranslationRegion {
            var result = ReaderTranslationRegion(id: id,
                rect: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), source: source)
            result.confidence = confidence
            return result
        }
    }
    @MainActor static func run(_ args: [String]) async -> Int32 {
        do {
            guard args.count == 3 else { throw HostError.message("Expected input manifest and output directory") }
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"]!)
            try HostEnvironment.load(root: root)
            let options = try HostOptions(root: root, arguments: [])
            let model = options.model, configuration = options.configuration
            _ = try configuration.validatedEndpoint()
            let settings = ReaderTranslationSettings(includePageImage: true,
                sourceLanguage: options.source, targetLanguage: options.target,
                translationSourceLanguages: options.translationSourceLanguages,
                filterSFXWithLLM: true, filterBackgroundWithLLM: true,
                rightToLeftPanelOrder: options.rtl, modelTier: options.tier)
            let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            let out = URL(fileURLWithPath: args[2]); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let roleFile = ProcessInfo.processInfo.environment["AIDOKU_EVAL_ROLE_DESCRIPTION_FILE"]
            let replacement = try roleFile.map { try String(contentsOfFile: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
            let transport = try HostRoleDescriptionTransport(replacement: replacement)
            let client = RemoteTranslationClient(transport: transport)
            for path in paths {
                let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                let destination = out.appendingPathComponent(input.page + ".json")
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                let started = Date()
                _ = transport.audits(reset: true)
                var report: [String: Any] = ["page": input.page, "model": model, "inputIDs": input.regions.map(\.id),
                    "protocol": options.apiProtocol.rawValue, "timeout": options.timeout]
                do {
                    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: input.image) as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw HostError.message("Cannot decode source page") }
                    let jpeg = try HostTranslationParity.translationJPEG(image)
                    let page = RemoteTranslationPageImage(jpeg: jpeg, sourceIdentity: try NativeRFDETRSourceImage.decode(image).identity)
                    let regions = input.regions.map(\.native)
                    // The production planner adds the mandatory role flags and bounds.
                    // No benchmark labels or alternate filtering-only prompt are supplied.
                    let plans = ReaderTranslationService.plans(regions: regions, settings: settings)
                    var batches: [[String: Any]] = [], translations: [RemoteTranslatedSegment] = []
                    for plan in plans {
                        var request = plan.request
                        page.apply(to: &request)
                        request.preparedImageDataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
                        let batchStarted = Date()
                        let canonical = request.canonicalizedForTranslationSemantics()
                        let response = try await client.translate(canonical.request, configuration: configuration)
                        let result = try canonical.restoringCallerSegmentIDs(in: response)
                        translations += result.translations
                        batches.append(["ids": request.segments.map(\.id), "seconds": Date().timeIntervalSince(batchStarted),
                            "providerRequestID": result.providerRequestID as Any? ?? NSNull()])
                    }
                    report["status"] = "complete"
                    report["translations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(translations))
                    report["batches"] = batches
                } catch {
                    report["status"] = "failed"
                    report["error"] = String(describing: error)
                }
                report["seconds"] = Date().timeIntervalSince(started)
                report["rolePromptOverride"] = replacement != nil
                report["wireScopeAudit"] = transport.audits()
                try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: destination, options: .atomic)
                print("LLM evaluation \(input.page) \(report["status"]!) \(Date().timeIntervalSince(started))s")
                fflush(stdout)
            }
            return 0
        } catch { fputs("Saved LLM evaluation failed: \(error)\n", stderr); return 1 }
    }
}
