#!/usr/bin/env python3
"""Verify that legacy request context cannot reach the translation wire or cache."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "Aidoku/Core/Translation/NativeEngine/Translation"
SOURCE = r'''
import Foundation
import CoreFoundation
import CoreGraphics
import ImageIO
func NSLocalizedString(_ key: String) -> String { key }
@main struct Check {
    static func main() throws {
        let bounds = [0.1, 0.2, 0.3, 0.4]
        let identity = String(repeating: "a", count: 64)
        let evidence = TranslationBackgroundRolePolicy.make(source: "原文", bounds: bounds,
            imageIdentity: identity,
            contour: .init(bounds: bounds, spans: [0.1, 0.4], verified: true, modelEstimated: false), rf: nil)
        var request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko",
            segments: [.init(id: "line", text: "原文", bounds: bounds, roleEvidence: evidence)])
        request.imageJPEG = Data([0xff, 0xd8, 0xff, 0xd9])
        request.roleEvidenceSourceImageIdentity = identity
        request.filtersSFX = true
        request.filtersBackground = true
        request.translatesPageLettering = true
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        saved["context"] = ["legacy OCR alternative", "prev: unrelated text"]
        let restored = try JSONDecoder().decode(RemoteTranslationRequest.self,
            from: JSONSerialization.data(withJSONObject: saved))
        let encoded = try JSONEncoder().encode(restored)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("context"))
        precondition(restored.canonicalizedForTranslationSemantics().request.segments.count == 1)
        let candidates = (0..<65).map { index in
            NativeTranslationBatchCandidate(inputIndex: index,
                segment: .init(id: "s\(index)", text: "文字\(index)"))
        }
        let plans = NativeTranslationBatchPlanner.makeBatches(candidates: candidates,
            sourceLanguage: "ja", targetLanguage: "ko")
        precondition(plans.map { $0.request.segments.count } == [64, 1])
        for plan in plans {
            let body = try JSONEncoder().encode(plan.request)
            precondition(!String(decoding: body, as: UTF8.self).contains("context"))
        }
        for proto in [RemoteTranslationProtocol.responses, .chatCompletions] {
            let configuration = RemoteTranslationConfiguration(provider: .custom, apiProtocol: proto,
                baseURL: "https://translator.example", model: "test", credentialAccount: "test")
            let body = try TranslationHTTPCodec.requestBody(configuration: configuration, request: restored)
            let root = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let instruction: String
            let text: String
            if proto == .responses {
                instruction = root["instructions"] as! String
                let content = (root["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
                text = content.first { $0["type"] as? String == "input_text" }!["text"] as! String
            } else {
                let messages = root["messages"] as! [[String: Any]]
                instruction = messages[0]["content"] as! String
                let content = messages[1]["content"] as! [[String: Any]]
                text = content.first { $0["type"] as? String == "text" }!["text"] as! String
            }
            let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            precondition(payload["context"] == nil && !instruction.contains("Use context only"))
            let segment = (payload["segments"] as! [[String: Any]])[0]
            precondition(segment["text"] as? String == "原文" && segment["box_2d"] as? [Int] == [200, 100, 600, 400])
            precondition(segment["role_evidence"] == nil && !instruction.contains("contour=observed enclosing outline"))
            precondition(!String(decoding: body, as: UTF8.self).contains("legacy OCR alternative"))
            var edge = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko",
                segments: [.init(id: "edge", text: "原文", bounds: [0.9, 0.95, 0.4, 0.3])])
            edge.imageJPEG = request.imageJPEG
            let edgeBody = try TranslationHTTPCodec.requestBody(configuration: configuration, request: edge)
            let edgeRoot = try JSONSerialization.jsonObject(with: edgeBody) as! [String: Any]
            let edgeText: String
            if proto == .responses {
                let content = (edgeRoot["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
                edgeText = content.first { $0["type"] as? String == "input_text" }!["text"] as! String
            } else {
                let content = (edgeRoot["messages"] as! [[String: Any]])[1]["content"] as! [[String: Any]]
                edgeText = content.first { $0["type"] as? String == "text" }!["text"] as! String
            }
            let edgePayload = try JSONSerialization.jsonObject(with: Data(edgeText.utf8)) as! [String: Any]
            let edgeSegment = (edgePayload["segments"] as! [[String: Any]])[0]
            precondition(edgeSegment["box_2d"] as? [Int] == [950, 900, 1000, 1000] && edgeSegment["bbox"] == nil)
        }
        print("PASS legacy context and internal contour omitted from both provider wires and prompt")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="aidoku-context-removal-") as folder:
    tmp = Path(folder)
    main = tmp / "Check.swift"
    main.write_text(SOURCE)
    binary = tmp / "check"
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library",
        *[str(BASE / name) for name in ["TranslationModels.swift", "TranslationHTTPCodec.swift", "NativeTranslationBatchPlanner.swift",
            "TranslationBackgroundRolePolicy.swift", "TranslationSFXEvidencePolicy.swift",
            "TranslationStreamDecoder.swift", "TranslationEndpointPolicy.swift", "TranslationImageSupport.swift"]],
        str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
