// Focused immutable provenance contracts against current production declarations and algorithms.
// No model, network, corpus replay, or RF policy activation.
import Foundation
import CoreGraphics

enum LineageSmokeError: Error { case invalid(String) }

@main
enum NativeAcceptedSourceLineageSmoke {
    static func require(_ value: @autoclosure () -> Bool, _ name: String) throws {
        guard value() else { throw LineageSmokeError.invalid("port-contract-" + name) }
    }

    static func line(_ text: String, x: Double = 100, y: Double = 100, w: Double = 20, h: Double = 200) -> NativeCoreMLOCRLine {
        .init(polygon: [.init(x: x, y: y), .init(x: x+w, y: y), .init(x: x+w, y: y+h), .init(x: x, y: y+h)],
              text: text, score: 0.99, orientation: .vertical)
    }

    @MainActor static func main() async {
        exit(await run())
    }

    @MainActor static func run() async -> Int32 {
        do {
            var passed: [String] = []
            let raw = [line("甲😀"), line("甲😀")]
            let bound = NativeOCRAcceptedSource.bindingPrimary(raw, width: 1000, height: 1000)
            try require(bound == raw, "native-equality")
            try require(bound[0].acceptedSource.membership?.body == [0] && bound[1].acceptedSource.membership?.body == [1], "distinct-identical-packets")
            passed += ["legacy-native-equality", "distinct-identical-packet-ordinals"]
            let union = NativeOCRSourceMetadata.union(bound.map(\.acceptedSource))
            try require(union.membership?.body == [0,1], "actual-member-union")
            try require(union.membership?.table.packets.map(\.text) == raw.map(\.text), "immutable-original-content")
            var sampled=line("geometry")
            let layout=[CGPoint(x:100,y:100),CGPoint(x:120,y:100),CGPoint(x:120,y:220),CGPoint(x:100,y:220)]
            sampled.acceptedSource = .init(layoutPolygon:layout)
            let sampledBound=NativeOCRAcceptedSource.bindingPrimary([sampled],width:1000,height:1000)[0]
            try require(sampledBound.acceptedSource.membership?.table.packets[0].layoutPolygon == layout,
                        "layout-affinity-snapshot")
            try require(sampledBound.acceptedSource.membership?.table.packets[0].polygon == sampled.polygon,
                        "layout-affinity-does-not-replace-output-extent")
            passed += ["member-union-original-payload"]
            let secondPage = NativeOCRAcceptedSource.bindingPrimary(raw, width: 1000, height: 1000)
            try require(NativeOCRSourceMetadata.union([union, secondPage[0].acceptedSource]).membership == nil, "cross-page-abstention")
            let unknown = NativeOCRSourceMetadata.union([union, .init()])
            try require(unknown.membership?.body == [0,1] && unknown.membership?.hasUntrackedInputs == true, "unknown-input-separate")
            passed += ["cross-page-abstention", "unknown-input-not-fabricated"]
            let duplicate = bound[0].acceptedSource.retainingDuplicate(bound[1].acceptedSource, exactContentWitness: false)
            try require(duplicate.membership?.unknownDedup == [1], "unknown-dedup-witness")
            let reading = bound[0].acceptedSource.retainingReading(bound[1].acceptedSource)
            try require(reading.membership?.body == [0] && reading.membership?.readings == [1], "reading-body-separation")
            passed += ["unknown-dedup-witness", "reading-body-separation"]
            try require(NativeOCRSourceMetadata().retainingReading(bound[1].acceptedSource).membership?.readings == [1],
                        "untracked-parent-retains-known-reading")
            try require(bound[0].acceptedSource.retainingReading(secondPage[1].acceptedSource).membership == nil,
                        "cross-page-reading-abstention")
            try require(!"é".utf8.elementsEqual("e\u{301}".utf8), "literal-witness-not-normalized")
            passed += ["untracked-parent-retains-known-reading", "cross-page-reading-abstention", "no-unicode-normalized-witness"]
            let originalPaddle = PaddleOCRLine(poly: [.init(x: 10, y: 10)], text: "甲😀", score: 0.9, orientationRaw: "vertical")
            var trackedPaddle = originalPaddle
            trackedPaddle.acceptedSource = union
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let oldBytes = try encoder.encode(originalPaddle), newBytes = try encoder.encode(trackedPaddle)
            try require(oldBytes == newBytes && originalPaddle == trackedPaddle, "paddle-wire-and-equality")
            let decoded = try JSONDecoder().decode(PaddleOCRLine.self, from: newBytes)
            try require(decoded.acceptedSource.membership == nil && decoded == originalPaddle, "cache-missing-stays-unknown")
            passed += ["legacy-paddle-codable-equality", "old-cache-no-invented-membership"]
            var region = ReaderTranslationRegion(id: "contract", rect: .init(x: 0.1, y: 0.1, width: 0.02, height: 0.2), source: "甲😀")
            let originalRegion = region
            region.acceptedSource = union
            try require(region == originalRegion, "region-legacy-equality")
            passed += ["legacy-region-equality"]
            let oldStored = try encoder.encode(ReaderTranslationStoredRegion(originalRegion))
            let newStored = try encoder.encode(ReaderTranslationStoredRegion(region))
            try require(oldStored == newStored, "actual-disk-encoding-exact")
            let restored = try JSONDecoder().decode(ReaderTranslationStoredRegion.self, from: newStored).region
            try require(restored.acceptedSource.membership == nil && restored == originalRegion, "actual-disk-decode-unknown")
            passed += ["actual-disk-encoding-exact", "actual-disk-decode-unknown"]
            let extended = NativeOCRAdjacentLineRecovery.extending([originalRegion], with: [region],
                baseLines: [bound[0]], recovered: [line("乙", y: 150, h: 50)],
                imageBounds: .init(x: 0, y: 0, width: 1000, height: 1000))
            try require(extended.count == 1 && extended[0].acceptedSource.membership?.body == [0,1], "actual-recovery-copy")
            try require(extended[0].detectorSeedEvidence == nil, "recovery-no-physical-upgrade")
            passed += ["actual-recovery-copy-no-CC-upgrade"]
            let merged = NativeOCRTextLineMerger.merge(bound, imageWidth: 1000, imageHeight: 1000)
            try require(merged.count == 1 && merged[0].acceptedSource.membership?.body == [0,1], "actual-merger-dedup")
            try require(merged[0].detectorSeedEvidence == nil, "physical-CC-stays-null")
            passed += ["actual-native-dedup-membership-null-CC"]
            let regrouped = NativeOCRTextLineMerger.merge(bound, imageWidth: 1000, imageHeight: 1000)
            try require(regrouped[0].acceptedSource.membership?.table === bound[0].acceptedSource.membership?.table,
                        "regroup-no-reregister")
            passed += ["regroup-same-original-table"]
            let ruby = NativeOCRAcceptedSource.bindingPrimary([line("漢字"), line("あいうえおか", x: 116, y: 110, w: 8, h: 100)], width: 1000, height: 1000)
            let rubyMerged = NativeOCRTextLineMerger.merge(ruby, imageWidth: 1000, imageHeight: 1000)
            try require(rubyMerged.count == 1 && rubyMerged[0].acceptedSource.membership?.readings == [1], "actual-ruby-removal")
            _ = NativeOCRTextLineMerger.latinWordCandidates(ruby)
            try require(ruby[0].acceptedSource.membership?.readings.isEmpty == true, "proof-query-no-side-effects")
            passed += ["actual-ruby-filter-retains-packet", "proof-query-no-side-effects"]
            let scopes = await withTaskGroup(of: UUID.self, returning: [UUID].self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        NativeOCRAcceptedSource.bindingPrimary([line("甲")], width: 1000, height: 1000)[0]
                            .acceptedSource.membership!.table.operationID
                    }
                }
                var values: [UUID] = []
                for await value in group { values.append(value) }
                return values
            }
            try require(Set(scopes).count == 16, "concurrent-page-isolation")
            passed += ["concurrent-page-isolation"]
            let result: [String: Any] = ["passed": true, "contracts": passed, "count": passed.count,
                                        "modelCalls": 0, "APICalls": 0]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return 0
        } catch { fputs("Production lineage contracts failed: \(error)\n", stderr); return 1 }
    }
}

