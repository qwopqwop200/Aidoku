#!/usr/bin/env python3
"""Synthetic SFX evidence and actual codec wire checks; no inference or response oracle.

Run from any directory. Compiler/module caches and outputs live in an isolated
temporary directory. Does not read labels, images, provider settings or credentials.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "Aidoku/Core/Translation/NativeEngine/Translation"
SOURCE = r'''
import Foundation
import Darwin
func NSLocalizedString(_ key: String) -> String { key }

@main struct Check {
    static func main() throws {
        typealias P = TranslationSFXEvidencePolicy
        typealias B = TranslationBackgroundRolePolicy
        let identity = String(repeating: "a", count: 64)
        let otherImage = String(repeating: "b", count: 64)
        let bounds = [0.2, 0.2, 0.1, 0.3]
        // Authored ambiguity families, not dataset strings or expected role answers.
        let sources = ["「あっ……」", "「えへっ", "ほっ」", "ふっ", "わああ", "こほっ", "しゅっ", "パタパタ",
                       "『「あ」』", "「あ』", "\"あ\"", "“おや”", "", "『あ』「い」"]
        let contour = B.Contour(bounds: [0.1, 0.1, 0.4, 0.6], spans: [0.1, 0.5], verified: true, modelEstimated: false)
        var evidenceCases = 0
        for source in sources where !source.isEmpty {
            let binding = P.binding(source: source, bounds: bounds, imageIdentity: identity)!
            for textScore in [0.1, 0.95] { for effectScore in [0.1, 0.95] { for hasContour in [false, true] {
                let rf = B.RFSupport(imageIdentity: identity, maskOwnerQuery: nil, ownerResolution: "unresolved",
                    balloonConfidence: nil, balloonBBoxCoverage: nil, textConfidence: textScore, textBBoxCoverage: 0.8,
                    sfxConfidence: effectScore, sfxBBoxCoverage: 0.7)
                let native = B.make(source: source, bounds: bounds, imageIdentity: identity,
                    contour: hasContour ? contour : nil, rf: rf)!
                var pixels = P.PixelObservations(binding: binding)
                pixels.alignedTextColumn = .present
                pixels.irregularGlyphScaleOrOrientation = .present
                let packet = P.make(source: source, bounds: bounds, imageIdentity: identity, nativeRF: native, pixels: pixels)!
                precondition(packet.nativeRF == native && packet.pixels == pixels)
                precondition(packet.inspectionChecks.contains(.nativeContourVersusRFSFX) == hasContour)
                precondition(packet.inspectionChecks.contains(.rfTextVersusRFSFX))
                precondition(packet.inspectionChecks.contains(.pixelEvidenceConflict))
                precondition(packet.inspectionChecks.contains(.missingPixelObservations))
                precondition(packet.isBound(source: source, bounds: bounds, imageIdentity: identity))
                precondition(!packet.isBound(source: source + "！", bounds: bounds, imageIdentity: identity))
                precondition(!packet.isBound(source: source, bounds: [0.3, 0.2, 0.1, 0.3], imageIdentity: identity))
                precondition(!packet.isBound(source: source, bounds: bounds, imageIdentity: otherImage))
                let data = try JSONEncoder().encode(packet)
                let decoded = try JSONDecoder().decode(P.Evidence.self, from: data)
                precondition(decoded == packet)
                let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                precondition(Set(object.keys) == ["policyVersion", "binding", "ocrQuotes", "nativeRF", "pixels", "inspectionChecks"])
                // Stale auxiliary observations cannot transfer across sources, bounds, or images.
                for changed in [(source + "！", bounds, identity), (source, bounds, otherImage),
                                (source, [0.3, 0.2, 0.1, 0.3], identity)] {
                    let isolated = P.make(source: changed.0, bounds: changed.1, imageIdentity: changed.2,
                        nativeRF: native, pixels: pixels)!
                    precondition(isolated.nativeRF == nil && isolated.pixels == nil)
                    precondition(isolated.inspectionChecks.contains(.missingPixelObservations))
                }
                evidenceCases += 1
            } } }
        }
        for invalid in [[], [0.0, 0.0, 0.0, 0.1], [-0.1, 0, 0.1, 0.1], [0.95, 0, 0.1, 0.1],
                        [Double.nan, 0, 0.1, 0.1], [0, 0, Double.infinity, 0.1]] {
            precondition(P.make(source: "あ", bounds: invalid, imageIdentity: identity) == nil)
        }
        precondition(P.make(source: "", bounds: bounds, imageIdentity: identity) == nil)
        precondition(P.make(source: String(repeating: "あ", count: 6000), bounds: bounds, imageIdentity: identity) == nil)
        precondition(P.make(source: "あ", bounds: bounds, imageIdentity: "not-a-hash") == nil)
        // Source-bound coverage must not disappear below the 0.5 inspection threshold.
        // These numerical shapes reproduce weak/competing/absent support, not role answers.
        for text in [0.0, 0.246, 0.913] { for effect in [0.0, 0.246, 0.501] { for coverage in [0.0, 0.189, 0.943] {
            let rf = B.RFSupport(imageIdentity: identity, maskOwnerQuery: nil, ownerResolution: "unresolved",
                balloonConfidence: nil, balloonBBoxCoverage: nil, textConfidence: text, textBBoxCoverage: coverage,
                sfxConfidence: effect, sfxBBoxCoverage: coverage)
            let native = B.make(source: "合成", bounds: bounds, imageIdentity: identity, contour: nil, rf: rf)!
            let checks = P.make(source: "合成", bounds: bounds, imageIdentity: identity, nativeRF: native)!.inspectionChecks
            let hasText = text > 0 && coverage > 0, hasEffect = effect > 0 && coverage > 0
            precondition(checks.contains(.rfTextVersusRFSFX) == (hasText && hasEffect))
            precondition(checks.contains(.rfTextOnlyPrediction) == (hasText && !hasEffect))
            precondition(checks.contains(.rfSFXOnlyPrediction) == (hasEffect && !hasText))
            precondition(checks.contains(.noRFTextOrSFXPrediction) == (!hasText && !hasEffect))
            precondition(checks.contains(.weakRFTextPrediction) == (hasText && text < 0.5))
            precondition(checks.contains(.weakRFSFXPrediction) == (hasEffect && effect < 0.5))
        } } }
        print("PASS 27 prediction-inspection matrices: weak/competing/text-only/effect-only/zero-overlap hypotheses survive without roles")
        let quoteCases: [(String, Int, Int)] = [("『「あ」』", 2, 0), ("「あ』", 0, 2), ("\"あ\"", 1, 0),
            ("「えへっ", 0, 1), ("ほっ」", 0, 1), ("しゅっ", 0, 0), ("『あ』「い」", 2, 0)]
        for (source, pairs, unmatched) in quoteCases {
            let packet = P.make(source: source, bounds: bounds, imageIdentity: identity)!
            precondition(packet.ocrQuotes.matchedPairs == pairs && packet.ocrQuotes.unmatchedCount == unmatched)
            precondition(packet.inspectionChecks.contains(.quoteEndpoints) == (pairs + unmatched > 0))
        }
        let quoted = "「あっ」"
        var observed = P.PixelObservations(binding: P.binding(source: quoted, bounds: bounds, imageIdentity: identity)!)
        observed.openingQuote = .absent; observed.closingQuote = .absent
        observed.alignedTextColumn = .absent; observed.irregularGlyphScaleOrOrientation = .present
        observed.enclosingContainer = .absent
        let conflict = P.make(source: quoted, bounds: bounds, imageIdentity: identity, pixels: observed)!
        precondition(conflict.inspectionChecks.contains(.pixelEvidenceConflict))
        precondition(!conflict.inspectionChecks.contains(.missingPixelObservations))

        // Encode real production request bodies, then inspect the provider-facing prompt and payload.
        let segments = sources.filter { !$0.isEmpty }.enumerated().map {
            RemoteTranslationSegment(id: "synthetic-\($0.offset)", text: $0.element, bounds: bounds)
        }
        var wireCases = 0
        for proto in [RemoteTranslationProtocol.responses, .chatCompletions] {
            for image in [false, true] { for sfx in [false, true] { for background in [false, true] {
                for compact in [false, true] {
                    var request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: segments)
                    request.filtersSFX = sfx; request.filtersBackground = background
                    // Deliberately synthetic nondecodable image bytes: transport only, never pixel inference.
                    if image { request.imageJPEG = Data([0xff, 0xd8, 0xff, 0xd9]) }
                    let config = RemoteTranslationConfiguration(provider: .custom, apiProtocol: proto,
                        baseURL: "https://synthetic.invalid/v1", model: "synthetic", credentialAccount: "synthetic")
                    let data = try TranslationHTTPCodec.requestBody(configuration: config, request: request,
                        chatOptions: .init(compactStructuredOutput: compact))
                    let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    let instructions: String, content: [[String: Any]]
                    if proto == .responses {
                        instructions = body["instructions"] as! String
                        content = (body["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
                    } else {
                        let messages = body["messages"] as! [[String: Any]]
                        instructions = messages[0]["content"] as! String
                        content = (messages[1]["content"] as? [[String: Any]]) ?? [["text": messages[1]["content"] as! String]]
                    }
                    if image && (sfx || background) { precondition(instructions.contains(B.instructions)) }
                    precondition(!instructions.contains("is_sfx") && !instructions.contains("editorial_role"))
                    precondition((body["temperature"] as? Double) == 1.0)
                    let expectedKeys = Set(["id", "text"] + (sfx || background ? ["text_role"] : []))
                    if compact {
                        let pattern = (body["structured_outputs"] as! [String: Any])["regex"] as! String
                        let regex = try NSRegularExpression(pattern: pattern)
                        let items = segments.map { segment in
                            "{\"id\":\"\(segment.id)\"" + (sfx || background ? ",\"text_role\":\"dialogue\"" : "") + ",\"text\":\"번역\"}"
                        }
                        let output = "{\"translations\":[" + items.joined(separator: ",") + "]}"
                        let range = NSRange(output.startIndex..<output.endIndex, in: output)
                        precondition(regex.firstMatch(in: output, range: range)?.range == range)
                    } else {
                        let formatRoot = body[proto == .responses ? "text" : "response_format"] as! [String: Any]
                        let format = formatRoot[proto == .responses ? "format" : "json_schema"] as! [String: Any]
                        let schema = format["schema"] as! [String: Any]
                        let translations = (schema["properties"] as! [String: Any])["translations"] as! [String: Any]
                        let item = translations["items"] as! [String: Any]
                        for branch in item["anyOf"] as? [[String: Any]] ?? [item] {
                            let properties = branch["properties"] as! [String: Any]
                            precondition(Set(branch["required"] as! [String]) == expectedKeys)
                            precondition(Set(properties.keys) == expectedKeys && branch["additionalProperties"] as? Bool == false)
                            var idDefinition = properties["id"] as! [String: Any]
                            if let reference = idDefinition["$ref"] as? String {
                                precondition(reference == "#/$defs/segment_id")
                                idDefinition = (schema["$defs"] as! [String: Any])["segment_id"] as! [String: Any]
                            }
                            precondition(idDefinition["enum"] as? [String] == segments.map(\.id))
                            if sfx || background {
                                let roles = (properties["text_role"] as! [String: Any])["enum"] as! [String]
                                precondition(Set(roles) == Set(RemoteTranslationTextRole.allCases.map(\.rawValue)))
                            }
                        }
                    }
                    let text = content.first { $0["text"] is String }!["text"] as! String
                    let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
                    let sent = payload["segments"] as! [[String: Any]]
                    precondition(sent.map { $0["id"] as! String } == segments.map(\.id))
                    precondition(sent.map { $0["text"] as! String } == segments.map(\.text))
                    for item in sent { precondition((item["box_2d"] as? [Int]) == (image || background ? [200, 200, 500, 300] : nil)) }
                    // No optional evidence is fabricated by the codec when none was measured.
                    precondition(sent.allSatisfy { $0["sfx_evidence"] == nil })
                    wireCases += 1
                }
            } } }
        }
        // One primary request carries the role guidance and exact source.
        var primary = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "en",
            segments: [.init(id: "primary-voice", text: "『ぐす…うぐ…", bounds: [0.84, 0.06, 0.037, 0.28])])
        primary.imageJPEG = Data([0xff, 0xd8, 0xff, 0xd9])
        primary.filtersSFX = true; primary.filtersBackground = true
        primary.translatesPageLettering = true
        let primaryConfig = RemoteTranslationConfiguration(provider: .custom, apiProtocol: .responses,
            baseURL: "https://synthetic.invalid/v1", model: "synthetic", credentialAccount: "synthetic")
        let primaryBody = try TranslationHTTPCodec.requestBody(configuration: primaryConfig, request: primary)
        let primaryWire = try JSONSerialization.jsonObject(with: primaryBody) as! [String: Any]
        let primaryInstructions = primaryWire["instructions"] as! String
        precondition(primaryInstructions.contains(TranslationHTTPCodec.imageInstructions))
        for criterion in ["isolated nonlexical cries", "Prefer sfx for ambiguous effect-like lettering",
                          "Judge each box_2d in the image", "conversational exclamations"] {
            precondition(primaryInstructions.contains(criterion), "missing visual SFX criterion: \(criterion)")
        }
        precondition(!primaryInstructions.contains("RF"))
        let rfOnly = B.make(source: primary.segments[0].text, bounds: primary.segments[0].bounds!,
            imageIdentity: identity, contour: nil,
            rf: .init(imageIdentity: identity, maskOwnerQuery: 2, ownerResolution: "exact",
                balloonConfidence: 0.9, balloonBBoxCoverage: 0.8,
                textConfidence: 0.7, textBBoxCoverage: 0.6,
                sfxConfidence: 0.4, sfxBBoxCoverage: 0.3))!
        var rfRequest = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "en",
            segments: [.init(id: "primary-voice", text: primary.segments[0].text,
                bounds: primary.segments[0].bounds, roleEvidence: rfOnly)])
        rfRequest.copyImageRepresentation(from: primary)
        rfRequest.roleEvidenceSourceImageIdentity = identity
        rfRequest.filtersSFX = true; rfRequest.filtersBackground = true
        rfRequest.translatesPageLettering = true
        let rfWire = try JSONSerialization.jsonObject(with:
            TranslationHTTPCodec.requestBody(configuration: primaryConfig, request: rfRequest)) as! [String: Any]
        let rfContent = (rfWire["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        let rfText = rfContent.first { $0["text"] is String }!["text"] as! String
        let rfPayload = try JSONSerialization.jsonObject(with: Data(rfText.utf8)) as! [String: Any]
        precondition(((rfPayload["segments"] as! [[String: Any]])[0]["role_evidence"]) == nil)
        precondition(!primaryInstructions.contains("copy source"))
        let primaryContent = (primaryWire["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        let primaryText = primaryContent.first { $0["text"] is String }!["text"] as! String
        let primaryPayload = try JSONSerialization.jsonObject(with: Data(primaryText.utf8)) as! [String: Any]
        precondition(primaryPayload["context"] == nil)
        precondition((primaryPayload["segments"] as! [[String: Any]])[0]["text"] as? String == "『ぐす…うぐ…")
        precondition(TranslationHTTPCodec.sfxPolicy == P.cacheVersion)
        precondition(P.cacheVersion != "llm-sfx-v28-source-bound-abstention")
        let classified: [String: Any] = ["translations": [
            ["id": "effect", "text": "쿵", "text_role": "sfx"],
            ["id": "inscription", "text": "출입 금지", "text_role": "background"]]]
        let classifiedContent = String(decoding: try JSONSerialization.data(withJSONObject: classified), as: UTF8.self)
        let classifiedEnvelope: [String: Any] = ["choices": [["index": 0, "finish_reason": "stop",
            "message": ["content": classifiedContent]]]]
        let retained = try TranslationHTTPCodec.responseTranslations(
            from: JSONSerialization.data(withJSONObject: classifiedEnvelope), protocol: .chatCompletions,
            expectedSegmentIDs: ["effect", "inscription"],
            sfxSourceTexts: ["effect": "ドン", "inscription": "立入禁止"],
            backgroundSourceTexts: ["effect": "ドン", "inscription": "立入禁止"])
        precondition(retained.map(\.text) == ["쿵", "출입 금지"])
        precondition(retained[0].isSFX == true && retained[0].textRole == .sfx)
        precondition(retained[1].isSFX == false && retained[1].textRole == .background)
        print("PASS \(evidenceCases) joint-evidence matrices, source/image/bounds isolation, quote syntax and invalid inputs")
        print("PASS \(wireCases) actual codec wire variants: prompt, both filters, exact per-ID source and bbox")
        print("Helper checks do not establish live provider role accuracy; source-bound transport is checked separately")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="aidoku-sfx-policy-") as folder:
    tmp = Path(folder)
    main = tmp / "Check.swift"
    main.write_text(SOURCE)
    binary = tmp / "check"
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(tmp / "clang-modules"))
    files = ["TranslationModels.swift", "TranslationHTTPCodec.swift", "TranslationBackgroundRolePolicy.swift",
             "TranslationSFXEvidencePolicy.swift", "TranslationStreamDecoder.swift", "TranslationEndpointPolicy.swift",
             "TranslationImageSupport.swift"]
    start = time.monotonic()
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-module-cache-path", str(tmp / "swift-modules"),
                    *[str(BASE / name) for name in files], str(main), "-o", str(binary)], check=True, env=env)
    print(f"Focused helper build seconds {time.monotonic() - start:.3f}", flush=True)
    start = time.monotonic()
    subprocess.run([str(binary)], check=True, env=env)
    print(f"Synthetic test seconds {time.monotonic() - start:.3f}", flush=True)
