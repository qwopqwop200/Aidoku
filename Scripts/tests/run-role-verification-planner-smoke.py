#!/usr/bin/env python3
"""Synthetic production planner/DTO checks; no model, provider, labels or shared caches."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "Aidoku/Core/Translation/NativeEngine/Translation"
HARNESS = r'''
import Foundation
func NSLocalizedString(_ key: String) -> String { key }

@main struct Check {
    static func main() throws {
        typealias Planner = TranslationRoleVerificationPlanner
        let identity = String(repeating: "a", count: 64)
        let container = [0.1, 0.1, 0.6, 0.6]
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(1)
            }
            checks += 1
        }
        func segment(_ id: String, effect: Bool = false, partial: Bool = false,
                     x: Double = 0.2, owner: Int = 7, model: Bool = false) -> RemoteTranslationSegment {
            let text = "source-\(id)"
            let bounds = [x, 0.2, 0.1, 0.2]
            let contour = TranslationBackgroundRolePolicy.Contour(bounds: container,
                spans: partial ? [x, x + 0.06] : [0.1, 0.7], verified: true, modelEstimated: model)
            let rf = TranslationBackgroundRolePolicy.RFSupport(imageIdentity: identity,
                maskOwnerQuery: owner, ownerResolution: "exact", balloonConfidence: 0.95,
                balloonBBoxCoverage: 1, textConfidence: 0.9, textBBoxCoverage: 1,
                sfxConfidence: effect ? 0.95 : nil, sfxBBoxCoverage: effect ? 0.8 : nil,
                balloonBounds: container)
            return .init(id: id, text: text, bounds: bounds,
                roleEvidence: TranslationBackgroundRolePolicy.make(source: text, bounds: bounds,
                    imageIdentity: identity, contour: contour, rf: rf)!)
        }
        func request(_ segments: [RemoteTranslationSegment]) -> RemoteTranslationRequest {
            var result = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko",
                segments: segments)
            result.imageJPEG = Data([0xff, 0xd8, 0xff, 0xd9])
            result.roleEvidenceSourceImageIdentity = identity
            result.filtersSFX = true
            result.filtersBackground = true
            result.translatesPageLettering = true
            return result
        }
        func batch(_ translations: [RemoteTranslatedSegment], source: TranslationResultSource = .network)
            -> RemoteTranslationBatchResult {
            .init(translations: translations, source: source, providerRequestID: "receipt")
        }
        func background(_ segment: RemoteTranslationSegment) -> RemoteTranslatedSegment {
            .init(id: segment.id, text: segment.text, isSFX: false, textRole: .background)
        }
        func effect(_ segment: RemoteTranslationSegment) -> RemoteTranslatedSegment {
            .init(id: segment.id, text: segment.text, isSFX: true, textRole: .sfx)
        }
        func translated(_ id: String, text: String = "실제 공급자 번역",
                        role: RemoteTranslationTextRole = .dialogue) -> RemoteTranslatedSegment {
            .init(id: id, text: text, isSFX: false, textRole: role)
        }
        let a = segment("candidate"), peer = segment("peer", x: 0.4), sfx = segment("effect", effect: true, x: 0.55)
        let original = batch([background(a), translated(peer.id), effect(sfx)])
        let input = request([a, peer, sfx])
        let candidates = Planner.candidates(request: input, result: original)
        check(candidates.count == 1, "only conflicting filtered source is focused")
        let focused = candidates[0]
        try focused.validate()
        check(focused.segments == [a], "ID, source, bbox and bound evidence remain exact")
        check(focused.imageJPEG == input.imageJPEG && focused.imageDigest == input.imageDigest &&
            focused.roleEvidenceSourceImageIdentity == identity,
            "same full-page image representation and identity")
        check(focused.sourceLanguage == input.sourceLanguage && focused.targetLanguage == input.targetLanguage &&
            focused.translatesPageLettering == input.translatesPageLettering &&
            focused.filtersSFX == true && focused.filtersBackground == true, "all settings retained")
        check(Planner.candidates(request: focused, result: batch([background(a)])).isEmpty,
            "singleton retry cannot recurse or repeat an identical request")

        let verification = Planner.Verification(request: focused, result: batch([translated(a.id)]))
        let merged = Planner.merging(request: input, original: original, verifications: [verification])
        check(merged.translations == [translated(a.id), original.translations[1], original.translations[2]],
            "only provider-confirmed exact owner changes; known effect and neighbor byte-for-byte intact")
        check(merged.source == .network && merged.providerRequestID == nil, "composite has honest provenance")
        for role in [RemoteTranslationTextRole.dialogue, .narration, .storyText] {
            let result = Planner.merging(request: input, original: original, verifications: [
                .init(request: focused, result: batch([translated(a.id, role: role)]))])
            check(result.translations[0].textRole == role, "provider role survives without forced dialogue")
        }
        let malformed: [RemoteTranslationBatchResult] = [
            batch([]), batch([translated("foreign")]), batch([translated(a.id), translated(a.id)]),
            batch([translated(a.id), translated(peer.id)]), batch([background(a)]), batch([effect(a)]),
            batch([translated(a.id, text: " \n ")]), batch([translated(a.id, text: a.text)]),
            batch([.init(id: a.id, text: "value", isSFX: true, textRole: .dialogue)]),
            batch([.init(id: a.id, text: "value", isSFX: false, textRole: .sfx)]),
            batch([.init(id: a.id, text: "value", isSFX: false)]),
            batch([.init(id: a.id, text: "value", textRole: .dialogue)]),
            batch([.init(id: a.id, text: "value", isSFX: true, textRole: .dialogue)]),
            batch([translated(a.id)], source: .memoryCache), batch([translated(a.id)], source: .diskCache)
        ]
        for result in malformed {
            check(Planner.merging(request: input, original: original, verifications: [
                .init(request: focused, result: result)]) == original, "unresolved/malformed reply cannot override primary")
        }
        check(Planner.merging(request: input, original: original,
            verifications: [verification, verification]) == original, "duplicate receipts fail closed")
        check(Planner.merging(request: input, original: original, verifications: []) == original, "no checks no changes")
        var changed = focused
        changed.filtersBackground = false
        check(Planner.merging(request: input, original: original, verifications: [
            .init(request: changed, result: verification.result)]) == original, "filter-free receipt rejects")
        changed = focused
        changed.imageJPEG = Data([1, 2, 3])
        changed.roleEvidenceSourceImageIdentity = identity
        check(Planner.merging(request: input, original: original, verifications: [
            .init(request: changed, result: verification.result)]) == original, "different image receipt rejects")
        changed = focused
        changed.roleEvidenceSourceImageIdentity = String(repeating: "b", count: 64)
        check(Planner.merging(request: input, original: original, verifications: [
            .init(request: changed, result: verification.result)]) == original, "stale image identity rejects")
        for field in 0..<5 {
            var invalid = input
            if field == 0 { invalid.filtersSFX = false }
            if field == 1 { invalid.filtersBackground = nil }
            if field == 2 { invalid.imageJPEG = nil }
            if field == 3 { invalid.roleEvidenceSourceImageIdentity = nil }
            if field == 4 { invalid.roleEvidenceSourceImageIdentity = String(repeating: "b", count: 64) }
            check(Planner.candidates(request: invalid, result: original).isEmpty, "both filters and original image binding mandatory")
        }
        for sources in [
            [RemoteTranslationSegment(id: a.id, text: "changed", bounds: a.bounds, roleEvidence: a.roleEvidence), peer, sfx],
            [RemoteTranslationSegment(id: a.id, text: a.text, bounds: [0.21, 0.2, 0.1, 0.2], roleEvidence: a.roleEvidence), peer, sfx],
            [RemoteTranslationSegment(id: a.id, text: a.text, bounds: a.bounds), peer, sfx]
        ] {
            let stale = request(sources)
            check(Planner.candidates(request: stale, result: original).isEmpty, "text/box/evidence cannot be rebound by ID")
            check(Planner.merging(request: stale, original: original, verifications: [verification]) == original,
                "stale receipt cannot change new source")
        }
        for result in [batch([background(a), translated(peer.id)]),
                       batch([background(a), background(a), effect(sfx)]),
                       batch([translated(a.id), translated(peer.id), effect(sfx)])] {
            check(Planner.candidates(request: input, result: result).isEmpty, "complete unique filtered primary outcomes required")
        }
        let partial = segment("partial", partial: true)
        let partialRequest = request([partial, peer, sfx])
        let partialResult = batch([background(partial), translated(peer.id), effect(sfx)])
        check(Planner.candidates(request: partialRequest, result: partialResult).map { $0.segments[0].id } == [partial.id],
            "partial native contour uses independently bound admitted shared-container peer")
        let unrelated = segment(peer.id, x: 0.4, owner: 8)
        check(Planner.candidates(request: request([partial, unrelated, sfx]), result: partialResult).isEmpty,
            "nearby dialogue with a different owner cannot lend its role")
        check(Planner.candidates(request: partialRequest,
            result: batch([background(partial), effect(peer), effect(sfx)])).allSatisfy { $0.segments[0].id != partial.id },
            "filtered peer supplies no admitted support")
        let estimated = segment("estimated", model: true)
        check(Planner.candidates(request: request([estimated, peer]),
            result: batch([background(estimated), translated(peer.id)])).isEmpty,
            "model-estimated contour cannot certify neighbor conflict")
        let unsupportedSFX = batch([effect(a), translated(peer.id), effect(sfx)])
        check(Planner.candidates(request: input, result: unsupportedSFX).count == 1,
            "SFX decision with conflicting source geometry is inspectable; real RF effect stays protected")
        let many = (0..<7).map { segment("independent-\($0)") }
        let manyRequest = request(many), manyResult = batch(many.map(background))
        let bounded = Planner.candidates(request: manyRequest, result: manyResult)
        check(bounded.count == 4 && bounded.map { $0.segments[0].id } == many.prefix(4).map(\.id),
            "deterministic four-call budget with original independent IDs")
        let replies = bounded.reversed().map { candidate in
            Planner.Verification(request: candidate, result: batch([translated(candidate.segments[0].id)]))
        }
        let independentlyMerged = Planner.merging(request: manyRequest, original: manyResult, verifications: replies)
        check(independentlyMerged.translations.prefix(4).allSatisfy { $0.textRole == .dialogue } &&
            Array(independentlyMerged.translations.dropFirst(4)) == Array(manyResult.translations.dropFirst(4)),
            "out-of-order replies map to exact owners without loss")
        check(Planner.merging(request: input, original: original,
            verifications: Array(repeating: verification, count: 5)) == original, "excess receipts reject")
        var full = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: input.segments)
        full.copyImageRepresentation(from: input)
        full.filtersSFX = true; full.filtersBackground = true
        check(Planner.candidates(request: full, result: original).first?.segments == [a],
            "focused visual request keeps its source segment")
        func unboxed(_ id: String, box: [Double], confidence: Double = 0.91,
                     coverage: Double = 0.95, sfx: Bool = false) -> RemoteTranslationSegment {
            let text = "unboxed-\(id)"
            let rf = TranslationBackgroundRolePolicy.RFSupport(imageIdentity: identity,
                maskOwnerQuery: nil, ownerResolution: "unresolved", balloonConfidence: nil,
                balloonBBoxCoverage: nil, textConfidence: confidence, textBBoxCoverage: coverage,
                sfxConfidence: sfx ? 0.7 : nil, sfxBBoxCoverage: sfx ? 0.3 : nil)
            return .init(id: id, text: text, bounds: box,
                roleEvidence: TranslationBackgroundRolePolicy.make(source: text, bounds: box,
                    imageIdentity: identity, contour: nil, rf: rf)!)
        }
        let utteranceBox = [0.3, 0.1, 0.08, 0.4]
        let fragmentBox = [0.3, 0.4, 0.04, 0.14]
        let utterance = unboxed("long-source", box: utteranceBox)
        let fragment = unboxed("short-source", box: fragmentBox)
        let unboxedInput = request([utterance, fragment])
        let unboxedPrimary = batch([translated(utterance.id), effect(fragment)])
        let unboxedCandidates = Planner.candidates(request: unboxedInput, result: unboxedPrimary)
        check(unboxedCandidates.count == 1 && unboxedCandidates[0].segments == [fragment],
            "strong source-bound RF text and majority bbox overlap nominate unboxed filtered source")
        for unsafe in [
            unboxed(fragment.id, box: [0.5, 0.4, 0.04, 0.14]),
            unboxed(fragment.id, box: [0.3, 0.46, 0.04, 0.14]),
            unboxed(fragment.id, box: fragmentBox, confidence: 0.79),
            unboxed(fragment.id, box: fragmentBox, coverage: 0.89),
            unboxed(fragment.id, box: fragmentBox, sfx: true)
        ] {
            check(Planner.candidates(request: request([utterance, unsafe]),
                result: batch([translated(utterance.id), effect(unsafe)])).isEmpty,
                "no nearest-neighbor inference, weak text support or positive RF effect admission")
        }
        let weakPeer = unboxed(utterance.id, box: utteranceBox, confidence: 0.79)
        check(Planner.candidates(request: request([weakPeer, fragment]), result: unboxedPrimary).isEmpty,
            "admitted role without independent strong RF text support is insufficient")
        check(Planner.candidates(request: unboxedInput,
            result: batch([effect(utterance), effect(fragment)])).isEmpty, "overlap with filtered peer supplies no admitted support")
        let unchanged = Planner.merging(request: unboxedInput, original: unboxedPrimary, verifications: [
            .init(request: unboxedCandidates[0], result: batch([effect(fragment)]))])
        check(unchanged == unboxedPrimary, "unboxed overlap is inspection only; provider may reaffirm effect")
        print("PASS \(checks) synthetic role-planner checks; no actual model/provider/image quality claim")
        // Optional historical JSON replay invokes the actual production planner.
        // JPEG bytes are retained as opaque transport data, never decoded/viewed.
        for path in CommandLine.arguments.dropFirst() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let decoder = JSONDecoder()
            let savedRequest = try decoder.decode(RemoteTranslationRequest.self,
                from: JSONSerialization.data(withJSONObject: payload["request"]!))
            let savedTranslations = try decoder.decode([RemoteTranslatedSegment].self,
                from: JSONSerialization.data(withJSONObject: payload["translations"]!))
            let savedResult = batch(savedTranslations)
            let planned = Planner.candidates(request: savedRequest, result: savedResult)
            print("SAVED_JSON \(payload["label"]!) candidates=\(planned.map { $0.segments[0].id })")
        }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--saved-page", action="append", type=Path, default=[],
                        help="Read numbered translation-batches/result JSON only, without decoding JPEG pixels")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix=".role-verification-test-", dir=ROOT) as directory:
        tmp = Path(directory)
        harness = tmp / "Check.swift"
        harness.write_text(HARNESS)
        cache = tmp / "module-cache"
        cache.mkdir()
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache), SWIFT_MODULECACHE_PATH=str(cache))
        sources = ["TranslationModels.swift", "TranslationHTTPCodec.swift", "TranslationBackgroundRolePolicy.swift",
                   "TranslationSFXEvidencePolicy.swift", "TranslationStreamDecoder.swift", "TranslationEndpointPolicy.swift",
                   "TranslationImageSupport.swift", "TranslationRoleVerificationPlanner.swift"]
        start = time.monotonic()
        subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-module-cache-path", str(cache),
                        *[str(BASE / name) for name in sources], str(harness), "-o", str(tmp / "check")],
                       cwd=ROOT, env=env, check=True)
        print(f"Host-only leaf compile seconds={time.monotonic() - start:.3f}", flush=True)
        start = time.monotonic()
        saved = []
        for index, page in enumerate(args.saved_page):
            batches = json.loads(next(page.glob("*-translation-batches.json")).read_text())["value"]
            result = json.loads(next(page.glob("*-translation-result.json")).read_text())["value"]
            for batch_index, batch_value in enumerate(batches):
                request = batch_value["request"]
                jpeg = request.get("imageJPEG")
                if isinstance(jpeg, dict):
                    request["imageJPEG"] = jpeg["base64"]
                ids = {segment["id"] for segment in request["segments"]}
                payload = {"label": str(page), "request": request,
                           "translations": [segment for segment in result["translations"] if segment["id"] in ids]}
                path = tmp / f"saved-{index}-{batch_index}.json"
                path.write_text(json.dumps(payload))
                saved.append(str(path))
        subprocess.run([str(tmp / "check"), *saved], cwd=ROOT, env=env, check=True)
        print(f"Synthetic execution seconds={time.monotonic() - start:.3f}", flush=True)


if __name__ == "__main__":
    main()
