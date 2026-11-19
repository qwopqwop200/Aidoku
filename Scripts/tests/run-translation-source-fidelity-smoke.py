#!/usr/bin/env python3
"""Compile the production codec; check fidelity contracts and unchanged per-ID wire data.

No provider calls, image inference, credentials or shared CLI cache are used.
This verifies prompt transport, not whether a live model obeys the prompt.
"""
from pathlib import Path
import subprocess
import re
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Translation'
SOURCE = r'''
import Foundation
import CoreFoundation
import CoreGraphics
import ImageIO
import Darwin
// Host-only localization compatibility; all request/cache/codec logic below is production.
func NSLocalizedString(_ key: String) -> String { key }
@main struct Check {
    static func main() async throws {
        setbuf(stdout, nil)
        try TranslationWireContractChecks.languageNamesAndDirections(
            sourceCodes: supportedSourceCodes, targetCodes: supportedTargetCodes)
        do { try MetadataPromptContractChecks.run() }
        catch { print("FAIL metadata contract: \(String(reflecting: error))"); exit(1) }
        try TranslationWireContractChecks.pageRequirements()
        print("PASS page admission: both protocols × image presence × nil/false/true classification flags")
        // The retired environment toggle must not resurrect crop attachments.
        setenv("AIDOKU_TRANSLATION_ROLE_DETAIL_IMAGES", "1", 1)
        try TranslationWireContractChecks.classificationParity()
        unsetenv("AIDOKU_TRANSLATION_ROLE_DETAIL_IMAGES")
        print("PASS one unchanged page image with four bound regions, both protocols and both output modes; old crop toggle ignored")
        print("PASS schema/compact/stream/final classification parity, exact fields, unchanged translated text, temperature zero and one instruction message")
        try TranslationWireContractChecks.finishAndCanonicalValidation()
        print("PASS final/SSE chat requires stop; canonical restoration drops/rejects escaped-only blank text")
        // Independent synthetic source units must not disappear behind a valid neighboring translation.
        let lobeRequest = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: [
            .init(id: "upper-lobe", text: "午前は図書館へ"),
            .init(id: "lower-lobe", text: "午後は公園へ")])
        try lobeRequest.validate()
        let lobeIDs = lobeRequest.segments.map(\.id)
        let upper = ["id": "upper-lobe", "text": "오전에는 도서관으로"]
        let lower = ["id": "lower-lobe", "text": "오후에는 공원으로"]
        var lobeCases = 0
        for proto in [RemoteTranslationProtocol.responses, .chatCompletions] {
            func envelope(_ translations: [[String: String]]) throws -> Data {
                let text = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": translations]), as: UTF8.self)
                let body: [String: Any]
                if proto == .responses {
                    body = ["output": [["content": [["type": "output_text", "text": text]]]]]
                } else {
                    body = ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": text]]]]
                }
                return try JSONSerialization.data(withJSONObject: body)
            }
            for invalid in [[lower], [upper, upper]] {
                do {
                    _ = try TranslationHTTPCodec.responseTranslations(from: envelope(invalid),
                        protocol: proto, expectedSegmentIDs: lobeIDs)
                    preconditionFailure("Missing or duplicate lobe ID was accepted")
                } catch RemoteTranslationError.invalidResponse(_) { }
                lobeCases += 1
            }
            let translated = try TranslationHTTPCodec.responseTranslations(from: envelope([lower, upper]),
                protocol: proto, expectedSegmentIDs: lobeIDs)
            precondition(translated.map(\.id) == lobeIDs)
            precondition(translated.map(\.text) == [upper["text"]!, lower["text"]!])
            precondition(Set(translated.map(\.id)).count == 2)
            lobeCases += 1
        }
        print("PASS synthetic source-lobe response conservation cases=\(lobeCases): missing/duplicate IDs reject, reversed replies restore exact owners and text")
        let segments = [RemoteTranslationSegment(id: "region-7", text: "あ……その…", bounds: [0.1, 0.1, 0.1, 0.2]),
                        RemoteTranslationSegment(id: "region-10", text: "い：1年A組甘莉です", bounds: [0.4, 0.4, 0.1, 0.2]),
                        RemoteTranslationSegment(id: "idiom", text: "でっでもマリイさんにばかりに辛い目は」"),
                        RemoteTranslationSegment(id: "experiencer", text: "それでアンタにぴーぴー泣かれるほうが迷惑だわっ」"),
                        RemoteTranslationSegment(id: "reaction", text: "「んもうっ」")]
        let requiredConfig = RemoteTranslationConfiguration(provider: .custom, apiProtocol: .responses,
            baseURL: "https://test.invalid/v1", model: "test", credentialAccount: "test")
        var pageSample = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: segments)
        pageSample.translatesPageLettering = true
        pageSample.imageJPEG = Data([0xff, 0xd8, 0xff, 0xd9])
        pageSample.filtersSFX = true
        pageSample.filtersBackground = true
        let pageBody = try JSONSerialization.jsonObject(with:
            TranslationHTTPCodec.requestBody(configuration: requiredConfig, request: pageSample)) as! [String: Any]
        let pagePrompt = pageBody["instructions"] as! String
        let previousDefaultPromptBytes = 1_013 // v30, immediately before the eight-reviewer compression.
        print("METRIC default page prompt: \(pagePrompt.count) characters, \(pagePrompt.utf8.count) UTF-8 bytes; baseline \(previousDefaultPromptBytes) bytes; reduction \(previousDefaultPromptBytes - pagePrompt.utf8.count) bytes")
        // Historical compression measurement, not a ceiling on later approved prompt changes.
        var count = 0
        for proto in [RemoteTranslationProtocol.responses, .chatCompletions] {
            for image in [false, true] { for sfx in [false, true] { for background in [false, true] {
                for compact in [false, true] {
                    var request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: segments)
                    request.filtersSFX = sfx; request.filtersBackground = background
                    // Only the image + both role fields is a valid page-lettering request.
                    // Other combinations exercise optional low-level codec fields, not the metadata service route.
                    request.translatesPageLettering = image && sfx && background
                    if image { request.imageJPEG = Data([0xff, 0xd8, 0xff, 0xd9]) }
                    let config = RemoteTranslationConfiguration(provider: .custom, apiProtocol: proto,
                        baseURL: "https://test.invalid/v1", model: "test", credentialAccount: "test",
                        instructions: "Use restrained Korean dialogue.")
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
                        if let parts = messages[1]["content"] as? [[String: Any]] { content = parts }
                        else { content = [["text": messages[1]["content"] as! String]] }
                    }
                    precondition(!instructions.isEmpty)
                    precondition(instructions.contains("Names: use established target-language forms, otherwise transliterate."))
                    precondition(!instructions.contains("supported transliteration") && !instructions.contains("retain the name"))
                    precondition(instructions.contains("Source language: Japanese. Target language: Korean."))
                    precondition(instructions.contains("into Korean") && !instructions.contains("into target_language"))
                    precondition(instructions.contains("regardless of role") == (sfx || background))
                    precondition(instructions.contains("not a role label") == (sfx || background))
                    precondition(instructions.contains("Task/style guidance; other rules take priority:"))
                    precondition(!instructions.contains("Use context only to resolve ambiguity."))
                    precondition(!instructions.contains("OCR alternatives require"))
                    precondition(instructions.components(separatedBy: config.instructions).count == 2)
                    precondition((body["temperature"] as? NSNumber)?.doubleValue == 1.0)
                    precondition(instructions.utf8.count < 2_500)
                    let textPart = content.first { $0["text"] is String }!["text"] as! String
                    let wire = try JSONSerialization.jsonObject(with: Data(textPart.utf8)) as! [String: Any]
                    precondition(wire["context"] == nil)
                    precondition(wire["source_language"] as? String == "Japanese")
                    precondition(wire["target_language"] as? String == "Korean")
                    let sent = wire["segments"] as! [[String: Any]]
                    precondition(sent.map { $0["id"] as! String } == segments.map(\.id))
                    precondition(sent.map { $0["text"] as! String } == segments.map(\.text))
                    precondition(wire["glossary"] == nil && !instructions.lowercased().contains("glossary"))
                    precondition(!instructions.contains("ruby") && !instructions.contains("pronunciation"))
                    let persisted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
                    precondition(persisted["glossary"] == nil)
                    for index in sent.indices {
                        // Image-backed recovery retains each source location even without classification filters.
                        let expectedBoxes: [[Int]?] = [[100, 100, 300, 200], [400, 400, 600, 500], nil, nil, nil]
                        precondition((sent[index]["box_2d"] as? [Int]) == (image || background ? expectedBoxes[index] : nil))
                    }
                    let key = TranslationCacheKey(configuration: config, endpoint: try config.validatedEndpoint(), request: request)
                    var previous = try JSONSerialization.jsonObject(with: JSONEncoder().encode(key)) as! [String: Any]
                    previous["version"] = TranslationCacheKey.schemaVersion - 1
                    let old = try JSONDecoder().decode(TranslationCacheKey.self, from: JSONSerialization.data(withJSONObject: previous))
                    precondition(key != old && key.version == TranslationCacheKey.schemaVersion)
                    count += 1
                }
            } } }
        }
        for target in ["ko", "en", "ja", "fr", "zh-Hant", "ar"] {
            for proto in [RemoteTranslationProtocol.responses, .chatCompletions] {
                let request = RemoteTranslationRequest(sourceLanguage: "auto", targetLanguage: target,
                    sourceText: "Example text")
                let config = RemoteTranslationConfiguration(provider: .custom, apiProtocol: proto,
                    baseURL: "https://test.invalid/v1", model: "test", credentialAccount: "test")
                let body = try JSONSerialization.jsonObject(with:
                    TranslationHTTPCodec.requestBody(configuration: config, request: request)) as! [String: Any]
                precondition((body["temperature"] as? NSNumber)?.doubleValue == 1.0)
                precondition((body["seed"] as? NSNumber)?.intValue == 0)
                let dataText: String
                if proto == .responses {
                    let content = (body["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
                    precondition(content.count == 1 && content[0]["type"] as? String == "input_text")
                    dataText = content[0]["text"] as! String
                } else {
                    let messages = body["messages"] as! [[String: Any]]
                    precondition(messages.map { $0["role"] as? String } == ["system", "user"])
                    dataText = messages[1]["content"] as! String
                }
                let payload = try JSONSerialization.jsonObject(with: Data(dataText.utf8)) as! [String: Any]
                precondition(payload["target_language"] as? String == TranslationHTTPCodec.languageName(target))
                precondition(payload["source_language"] as? String == "Auto-detect from input")
                precondition((payload["segments"] as! [[String: Any]])[0]["text"] as? String == "Example text")
                let item = try TranslationWireContractChecks.itemSchema(body, proto)
                for branch in TranslationWireContractChecks.branches(item) {
                    precondition(Set(branch["required"] as! [String]) == ["id", "text"])
                }
            }
        }
        print("PASS text-only codec transport: 6 target languages × 2 protocols, id/text-only output fields")
        setenv("AIDOKU_VLLM_FRESH_PREFIX", "1", 1)
        let saltRequest = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko",
            segments: [.init(id: "one", text: "こんにちは")])
        let saltConfig = RemoteTranslationConfiguration(provider: .custom, apiProtocol: .responses,
            baseURL: "https://test.invalid/v1", model: "test", credentialAccount: "test")
        let saltedBodies = try (0..<2).map { _ -> [String: Any] in
            try JSONSerialization.jsonObject(with: TranslationHTTPCodec.requestBody(
                configuration: saltConfig, request: saltRequest)) as! [String: Any]
        }
        let salts = saltedBodies.compactMap { $0["cache_salt"] as? String }
        precondition(salts.count == 2 && salts[0] != salts[1])
        precondition(salts.allSatisfy { Data(base64Encoded: $0)?.count == 32 })
        let chatSaltConfig = RemoteTranslationConfiguration(provider: .custom, apiProtocol: .chatCompletions,
            baseURL: "https://test.invalid/v1", model: "test", credentialAccount: "test")
        let chatSaltedBodies = try (0..<2).map { _ -> [String: Any] in
            try JSONSerialization.jsonObject(with: TranslationHTTPCodec.requestBody(
                configuration: chatSaltConfig, request: saltRequest)) as! [String: Any]
        }
        let chatSalts = chatSaltedBodies.compactMap { $0["cache_salt"] as? String }
        precondition(chatSalts.count == 2 && chatSalts[0] != chatSalts[1])
        precondition(chatSalts.allSatisfy { Data(base64Encoded: $0)?.count == 32 })
        unsetenv("AIDOKU_VLLM_FRESH_PREFIX")
        print("PASS opt-in fresh vLLM prefix salt: unique 256-bit salts in both protocols")
        let legacy = Data(#"[{"id":"legacy","text":"이름","isSFX":false}]"#.utf8)
        let oldSegments = try JSONDecoder().decode([RemoteTranslatedSegment].self, from: legacy)
        precondition(oldSegments[0].textRole == nil)
        let oldWire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldSegments)) as! [[String: Any]]
        precondition(oldWire[0]["textRole"] == nil)
        let roles: [RemoteTranslationTextRole] = [.dialogue, .narration, .storyText, .sfx, .background]
        for proto in [RemoteTranslationProtocol.responses, .chatCompletions] {
            for role in roles {
                let item: [String: Any] = ["id": "role", "text_role": role.rawValue, "text": "번역문"]
                let envelope = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": [item]]), as: UTF8.self)
                let root: [String: Any] = proto == .responses
                    ? ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": envelope]]]]]
                    : ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": envelope]]]]
                let parsed = try TranslationHTTPCodec.responseTranslations(from: JSONSerialization.data(withJSONObject: root),
                    protocol: proto, expectedSegmentIDs: ["role"], sfxSourceTexts: ["role": "原文"], backgroundSourceTexts: ["role": "原文"])
                precondition(parsed[0].textRole == role)
                precondition(parsed[0].text == "번역문")
                let roundTrip = try JSONDecoder().decode([RemoteTranslatedSegment].self, from: JSONEncoder().encode(parsed))
                precondition(roundTrip == parsed)
                let sourceRequest = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: [.init(id: "caller", text: "原文")])
                let canonical = sourceRequest.canonicalizedForTranslationSemantics()
                let remote = RemoteTranslatedSegment(id: "segment-0", text: parsed[0].text, isSFX: parsed[0].isSFX, textRole: role)
                let restored = try canonical.restoringCallerSegmentIDs(in: .init(translations: [remote], source: .network, providerRequestID: nil))
                precondition(restored.translations[0].id == "caller" && restored.translations[0].textRole == role)
            }
            func decodeItem(_ item: [String: Any]) throws -> [RemoteTranslatedSegment] {
                let envelope = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": [item]]), as: UTF8.self)
                let root: [String: Any] = proto == .responses
                    ? ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": envelope]]]]]
                    : ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": envelope]]]]
                return try TranslationHTTPCodec.responseTranslations(from: JSONSerialization.data(withJSONObject: root),
                    protocol: proto, expectedSegmentIDs: ["role"], sfxSourceTexts: ["role": "原文"],
                    backgroundSourceTexts: ["role": "原文"])
            }
            let valid: [String: Any] = ["id": "role", "text": "번역문", "text_role": "dialogue"]
            let parsedValid = try decodeItem(valid)
            precondition(parsedValid[0].isSFX == false && parsedValid[0].textRole == .dialogue)
            for invalid in [
                ["id": "role", "text": "번역문", "is_sfx": false, "text_role": "dialogue"],
                ["id": "role", "text": "번역문", "text_role": "dialogue", "editorial_role": "none"],
                ["id": "role", "text": "번역문", "text_role": "sfx", "editorial_role": "work_title"],
                ["id": "role", "text": "번역문"],
            ] as [[String: Any]] {
                do {
                    _ = try decodeItem(invalid)
                    preconditionFailure("Inconsistent or incomplete image role accepted")
                } catch RemoteTranslationError.invalidResponse(_) { }
            }
        }
        print("PASS legacy absent role, JSON roundtrip, 5 roles × 2 protocols, explicit text-only final parse and caller ID restoration")
        let left = RemoteTranslationSegment(id: "left", text: "それでアンタにぴーぴー泣かれるほうが迷惑だわっ」", bounds: [0.1, 0.1, 0.1, 0.5])
        let right = RemoteTranslationSegment(id: "right", text: "だからアンタはこんな事しなくていいって言ったでしょうがっ", bounds: [0.8, 0.1, 0.1, 0.5])
        let duplicated = "“그러니까 당신은 이런 짓 안 해도 된다고 말했잖아요!”"
        var paired = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: [left, right])
        paired.imageJPEG = Data([1, 2, 3]); paired.filtersSFX = true; paired.filtersBackground = true
        paired.translatesPageLettering = true
        let result = RemoteTranslationBatchResult(translations: [.init(id: "left", text: duplicated, isSFX: false, textRole: .dialogue),
            .init(id: "right", text: duplicated, isSFX: false, textRole: .narration)], source: .network, providerRequestID: "initial")
        precondition(TranslationHTTPCodec.independentSourceRetryIDs(request: paired, result: result) == ["left", "right"])
        let isolated = TranslationHTTPCodec.independentSourceRetryRequest(id: "left", request: paired)!
        precondition(isolated.segments == [left] && isolated.imageJPEG == paired.imageJPEG)
        precondition(isolated.filtersSFX == nil && isolated.filtersBackground == nil)
        precondition(isolated.translatesPageLettering == true)
        precondition(TranslationHTTPCodec.independentSourceRetryIDs(request: isolated, result: result).isEmpty)
        precondition(TranslationHTTPCodec.independentSourceRetryRequest(id: "missing", request: paired) == nil)
        let distinct = RemoteTranslationBatchResult(translations: [.init(id: "left", text: "네가 그렇게 훌쩍훌쩍 울어대는 쪽이 더 민폐라고!"),
            .init(id: "right", text: duplicated)], source: .network, providerRequestID: nil)
        precondition(TranslationHTTPCodec.independentSourceRetryIDs(request: paired, result: distinct).isEmpty)
        let similar = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: [left,
            .init(id: "right", text: left.text + "！")])
        precondition(TranslationHTTPCodec.independentSourceRetryIDs(request: similar, result: result).isEmpty)
        let short = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: [
            .init(id: "left", text: "うん"), .init(id: "right", text: "はい")])
        precondition(TranslationHTTPCodec.independentSourceRetryIDs(request: short, result: result).isEmpty)
        let copied = RemoteTranslationBatchResult(translations: [.init(id: "left", text: duplicated, isSFX: true),
            .init(id: "right", text: duplicated, isSFX: false)], source: .network, providerRequestID: nil)
        precondition(TranslationHTTPCodec.independentSourceRetryIDs(request: paired, result: copied).isEmpty)
        let original = RemoteTranslationBatchResult(translations: [.init(id: "left", text: left.text),
            .init(id: "right", text: left.text)], source: .network, providerRequestID: nil)
        precondition(TranslationHTTPCodec.independentSourceRetryIDs(request: paired, result: original).isEmpty)
        let capped = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: (0..<8).map {
            .init(id: "slot-\($0)", text: $0 % 2 == 0 ? left.text : right.text)
        })
        let capResult = RemoteTranslationBatchResult(translations: capped.segments.map { .init(id: $0.id, text: duplicated) },
            source: .network, providerRequestID: nil)
        precondition(TranslationHTTPCodec.independentSourceRetryIDs(request: capped, result: capResult) == ["slot-0", "slot-1", "slot-2", "slot-3"])
        print("PASS actual 0408 duplicate candidate, distinct/similar/short/SFX/source-copy exclusions, stable 4-ID cap, exact isolated source ownership")
        var calls = [RemoteTranslationRequest]()
        let repaired = try await TranslationHTTPCodec.recoveringIndependentSourceAlignment(request: paired, result: result) { retry in
            calls.append(retry)
            let id = retry.segments[0].id
            return .init(translations: [.init(id: id, text: id == "left" ? "네가 그렇게 훌쩍훌쩍 울어대는 쪽이 더 민폐라고!" : duplicated)],
                source: .network, providerRequestID: "retry")
        }
        precondition(calls.map { $0.segments[0].id } == ["left", "right"])
        precondition(calls.allSatisfy { $0.segments.count == 1 })
        precondition(repaired.translations.map(\.id) == result.translations.map(\.id))
        precondition(repaired.translations[0].text != duplicated && repaired.translations[1].text == duplicated)
        precondition(repaired.translations.map(\.isSFX) == [false, false])
        precondition(repaired.translations.map(\.textRole) == [.dialogue, .narration])
        let unchanged = try await TranslationHTTPCodec.recoveringIndependentSourceAlignment(request: paired, result: distinct) { _ in
            preconditionFailure("Normal batch must make no retry")
        }
        precondition(unchanged.translations == distinct.translations)
        var confirmations = 0
        let confirmed = try await TranslationHTTPCodec.recoveringIndependentSourceAlignment(request: paired, result: result) { retry in
            confirmations += 1
            return .init(translations: [.init(id: retry.segments[0].id, text: duplicated)], source: .network, providerRequestID: nil)
        }
        precondition(confirmations == 2 && confirmed.translations == result.translations)
        do {
            _ = try await TranslationHTTPCodec.recoveringIndependentSourceAlignment(request: paired, result: result) { _ in
                .init(translations: [.init(id: "foreign", text: duplicated)], source: .network, providerRequestID: nil)
            }
            preconditionFailure("Foreign retry ID accepted")
        } catch RemoteTranslationError.invalidResponse { }
        for invalid in [[], [RemoteTranslatedSegment(id: "left", text: "  ")],
            [.init(id: "left", text: duplicated), .init(id: "right", text: duplicated)]] {
            do {
                _ = try await TranslationHTTPCodec.recoveringIndependentSourceAlignment(request: paired, result: result) { _ in
                    .init(translations: invalid, source: .network, providerRequestID: nil)
                }
                preconditionFailure("Invalid retry cardinality/text accepted")
            } catch RemoteTranslationError.invalidResponse { }
        }
        var errorCalls = 0
        do {
            _ = try await TranslationHTTPCodec.recoveringIndependentSourceAlignment(request: paired, result: result) { retry in
                errorCalls += 1
                if errorCalls == 2 { throw RemoteTranslationError.httpStatus(503, requestID: nil) }
                return .init(translations: [.init(id: retry.segments[0].id, text: duplicated)], source: .network, providerRequestID: nil)
            }
            preconditionFailure("Failed second retry returned partial batch")
        } catch RemoteTranslationError.httpStatus(503, _) { }
        precondition(errorCalls == 2)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TranslationHTTPCodec.recoveringIndependentSourceAlignment(request: paired, result: result) { _ in
                preconditionFailure("Cancelled retry reached transport")
            }
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancellation ignored") }
        catch is CancellationError { }
        print("PASS cancellation, provider failure, empty/extra/missing IDs and blank text reject atomically without partial batch")
        print("PASS mocked recovery helper: 2 isolated calls, no calls for normal batch, corrected mapping, legitimate repeated output accepted, foreign ID rejected")
        // Transport keeps faithful names and real descriptive clauses exactly as returned;
        // this change must not heuristically delete Korean clauses or constrain punctuation.
        let faithful = "저… 1학년 A반 아마리입니다."
        let description = "향기가 달콤하다."
        let output = ["translations": [["id": "region-7", "text": description], ["id": "region-10", "text": faithful]]]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
        let envelope: [String: Any] = ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": encoded]]]]
        let decoded = try TranslationHTTPCodec.responseTranslations(from: JSONSerialization.data(withJSONObject: envelope),
            protocol: .chatCompletions, expectedSegmentIDs: ["region-7", "region-10"])
        precondition(decoded.map(\.text) == [description, faithful])
        print("PASS \(count) codec variants: source/IDs/hints/bbox preserved; glossary absent from prompt, wire and persisted request")
    }
}
'''
# Reuse the focused pure-Foundation checks exercised by the iOS suite.
# No UIKit, app build, fixtures, provider calls or separate copied test oracle.
TEST_SOURCE = ROOT / 'AidokuTests/Translation/NativeEngine/TranslationHTTPCodecTests.swift'
shared = TEST_SOURCE.read_text().split('// BEGIN SHARED TRANSLATION WIRE CONTRACT CHECKS\n', 1)[1]
shared = shared.split('// END SHARED TRANSLATION WIRE CONTRACT CHECKS', 1)[0]
metadata = (ROOT / 'Aidoku/Core/Translation/TitleTranslation.swift').read_text()
metadata_contract = metadata.split('// BEGIN METADATA PROMPT CONTRACT\n', 1)[1].split('// END METADATA PROMPT CONTRACT', 1)[0]
metadata_tests = (ROOT / 'AidokuTests/Translation/TitleTranslationTests.swift').read_text()
metadata_checks = metadata_tests.split('// BEGIN SHARED METADATA PROMPT CHECKS\n', 1)[1].split('// END SHARED METADATA PROMPT CHECKS', 1)[0]
assert 'result.metadataInstructions = kind.instructions' in metadata
assert 'String(TranslationCacheKey.schemaVersion)' in metadata
settings_source = (ROOT / 'Aidoku/Core/Translation/ReaderTranslationSettings.swift').read_text()
assert 'instructions: metadataInstructions.isEmpty ? RemoteTranslationConfiguration.defaultInstructions : metadataInstructions' in settings_source
# Read the actual application lists so newly added languages automatically enter this matrix.
detector_source = (BASE / 'AutomaticSourceLanguageDetector.swift').read_text()
source_codes = re.search(r'static let supportedLanguageCodes: Set<String> = (\[.*?\])', detector_source, re.S).group(1)
settings_view = (ROOT / 'Aidoku/Features/Settings/ReaderTranslationSettingsView.swift').read_text()
target_block = settings_view.split('private let languages: [(String, String)] = [', 1)[1].split(']', 1)[0]
target_codes = '[' + ', '.join('"' + code + '"' for code in re.findall(r'\("([^"]+)",', target_block)) + ']'
language_lists = '\nlet supportedSourceCodes: [String] = ' + source_codes + '\nlet supportedTargetCodes: [String] = ' + target_codes
with tempfile.TemporaryDirectory(prefix='aidoku-source-fidelity-') as folder:
    tmp = Path(folder)
    main = tmp / 'Check.swift'
    main.write_text(SOURCE + "\n" + shared + "\n" + metadata_contract + "\n" + metadata_checks + language_lists)
    binary = tmp / 'check'
    start = time.monotonic()
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library',
        *[str(BASE / f) for f in ['TranslationModels.swift', 'TranslationHTTPCodec.swift',
            'TranslationBackgroundRolePolicy.swift', 'TranslationSFXEvidencePolicy.swift',
            'TranslationStreamDecoder.swift', 'TranslationEndpointPolicy.swift', 'TranslationImageSupport.swift']],
        str(main), '-o', str(binary)], check=True)
    print(f'Build seconds {time.monotonic() - start:.3f}', flush=True)
    start = time.monotonic()
    subprocess.run([str(binary)], check=True)
    print(f'Test seconds {time.monotonic() - start:.3f}', flush=True)
