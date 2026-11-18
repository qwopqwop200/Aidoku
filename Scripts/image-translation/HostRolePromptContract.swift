import Foundation
import CoreGraphics
import CryptoKit

/// Serialized production prompt proof, without model requests or source images.
@available(macOS 15.0, *)
enum HostRolePromptContract {
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor static func run(_ args: [String]) async -> Int32 {
        do {
            guard args.count == 4 || args.count == 5 else { throw HostError.message("Expected role file, baseline reply, output and optional cache identity") }
            let expectedCachePolicy = args.count == 5 ? args[4] : "page-lettering-v36-gt-preserving-role-definitions"
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"]!)
            try HostEnvironment.load(root: root)
            let options = try HostOptions(root: root, arguments: [])
            let roles = try String(contentsOfFile: args[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
            let oldAudit = (baseline["wireScopeAudit"] as! [[String: Any]])[0]
            let settings = ReaderTranslationSettings(includePageImage: true, sourceLanguage: options.source, targetLanguage: options.target,
                filterSFXWithLLM: true, filterBackgroundWithLLM: true)
            let region = ReaderTranslationRegion(id: "contract-only", rect: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.2), source: "確認")
            var request = ReaderTranslationService.plans(regions: [region], settings: settings)[0].request
            // Presence-only serializer token: no decoder or model consumes it.
            request.imageJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9])
            func instruction(_ value: RemoteTranslationRequest) throws -> String {
                let body = try TranslationHTTPCodec.requestBody(configuration: options.configuration, request: value)
                let root = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                guard let instructions = root["instructions"] as? String else { throw HostError.message("Expected Responses instructions") }
                return instructions
            }
            let instructions = try instruction(request)
            let lines = instructions.components(separatedBy: "\n")
            let roleLines = lines.filter { $0.hasPrefix("text_role: ") }
            guard roleLines == ["text_role: " + roles], instructions.count <= 1800 else {
                throw HostError.message("Compiled production role definitions or length differ from the evaluated candidate")
            }
            let other = lines.filter { !$0.hasPrefix("text_role: ") }.joined(separator: "\n")
            guard hash(other) == oldAudit["otherPromptSHA256"] as? String else { throw HostError.message("A non-role instruction changed") }
            var nonPage = request
            nonPage.translatesPageLettering = nil
            let legacyInstructions = try instruction(nonPage)
            let legacyRole = legacyInstructions.components(separatedBy: "\n").filter { $0.hasPrefix("text_role: ") }
            guard legacyRole.count == 1, hash(legacyRole[0]) == oldAudit["roleLineSHA256"] as? String else {
                throw HostError.message("Non-page classification prompt changed")
            }
            let endpoint = try options.configuration.validatedEndpoint()
            let key = TranslationCacheKey(configuration: options.configuration, endpoint: endpoint, request: request)
            guard key.letteringPolicy == expectedCachePolicy else {
                throw HostError.message("New role prompt must invalidate old page translation cache entries")
            }
            let report: [String: Any] = ["compiledRoleLineSHA256": hash(roleLines[0]), "roleLineCharacters": roleLines[0].count,
                "completeInstructionCharacters": instructions.count, "otherPromptSHA256": hash(other),
                "nonRoleInstructionsIdentical": true, "legacyNonPageRolePromptIdentical": true,
                "translationCacheVersionUpdated": expectedCachePolicy != "page-lettering-v34-user-explicit-roles",
                "expectedCachePolicyMatched": true, "cachePolicy": expectedCachePolicy, "model": options.model, "protocol": options.apiProtocol.rawValue,
                "timeout": options.timeout, "sourceImagesRead": 0, "providerRequestsSent": 0, "checksPassed": 5]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: args[3]), options: .atomic)
            print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
            return 0
        } catch { fputs("Role prompt contract failed: \(error)\n", stderr); return 1 }
    }
}
