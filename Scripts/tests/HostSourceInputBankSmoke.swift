import Foundation

@available(macOS 15.0, *)
@main struct HostSourceInputBankSmoke {
    static func main() throws {
        typealias B = HostSourceInputBank
        var checks = 0
        for value in [Double.zero, -Double.zero, 1.0000000000000002, 1e-250, 16383.999999999998] {
            let decoded = try B.double(B.bits(value))
            precondition(decoded.bitPattern == value.bitPattern); checks += 1
        }
        for n in [1, 7, 233] {
            var values = [Float](repeating: 0, count: n * 8)
            for p in 0..<n where p % 5 != 0 {
                for c in 0..<8 { values[p * 8 + c] = c == 0 ? -Float.zero : Float((p / 3 + c) % 13) / 13 }
            }
            let runs = try B.encodeOCR(values, pixelCount: n)
            let data = try JSONEncoder().encode(runs)
            let restored = try B.decodeOCR(JSONDecoder().decode([B.OCRRun].self, from: data), pixelCount: n)
            precondition(zip(values, restored).allSatisfy { $0.bitPattern == $1.bitPattern }); checks += n * 8
        }
        var rejected = 0
        for runs in [[B.OCRRun(startPixel: -1, pixelCount: 1, laneBits: Array(repeating: "0", count: 8))],
                     [B.OCRRun(startPixel: 0, pixelCount: 2, laneBits: Array(repeating: "0", count: 8))],
                     [B.OCRRun(startPixel: 0, pixelCount: 1, laneBits: ["7fc00000"])]] {
            do { _ = try B.decodeOCR(runs, pixelCount: 1); fatalError("invalid OCR admitted") } catch { rejected += 1 }
        }
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        var sources = 0, owners = 0, scalarHashes = 0
        for page in spec {
            let source = try B.decodeOriginal(Data(contentsOf: URL(fileURLWithPath: page["original"] as! String)))
            let reference = try B.rawReference(URL(fileURLWithPath: page["rawRecord"] as! String))
            let rawHeader = try JSONDecoder().decode(HostRFRawReplay.Header.self,
                from: Data(contentsOf: URL(fileURLWithPath: page["rawRecord"] as! String)))
            let contract = B.Contract(producerSHA256: "local-test", sourceFactorySHA256: "local-test", pixelEvidenceSHA256: "actual-source",
                decoderSHA256: "actual-source", preprocessSHA256: rawHeader.identity.preprocessCodeSHA256,
                installedRFModelSHA256: rawHeader.identity.base.installedModelTreeSHA256,
                configurationSHA256: "source160alltrue", modelSetSHA256: "fixed",
                rfWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                rfSourceRevision: NativeRFDETRLayoutResource.highresSourceRevision, rfFeatureSchema: B.rfSchema)
            let result = try B.replayRF(reference: reference, source: source, expected: contract)
            let evidence = try NativePixelRFEvidence(result: result)
            for path in page["stages"] as! [String] {
                let m = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
                let b = m["cropBounds"] as! [Double]
                let crop = CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
                let local = m["memberPolygonsLocal"] as! [[[Double]]]
                let global = local.map { $0.map { CGPoint(x: $0[0] + b[0], y: $0[1] + b[1]) } }
                let support = try evidence.support(crop: crop, polygons: global, sourceIdentity: source.identity)
                guard B.floatHash(support.full) == m["fullRFSHA256"] as? String,
                      B.floatHash(support.coarse) == m["coarseRFSHA256"] as? String else {
                    throw B.Failure.invalid("actual saved RF support hashes differ: " + path)
                }
                let files = m["files"] as! [String: [String: Any]]
                let affinityData = try Data(contentsOf: URL(fileURLWithPath: path).deletingLastPathComponent()
                    .appendingPathComponent(files["affinityScores"]!["path"] as! String))
                guard B.floatHash(support.affinityScores) == HostRFRawReplay.digest(affinityData) else {
                    throw B.Failure.invalid("actual saved affinity differs")
                }
                let w = Int(crop.width), h = Int(crop.height)
                var rgb = Data(count: w * h * 3)
                rgb.withUnsafeMutableBytes { to in source.rgb.withUnsafeBytes { from in
                    for y in 0..<h { for x in 0..<(w * 3) {
                        to[y * w * 3 + x] = from[((Int(crop.minY) + y) * source.width + Int(crop.minX)) * 3 + x]
                    } }
                } }
                guard HostRFRawReplay.digest(rgb) == m["rgbSHA256"] as? String else { throw B.Failure.invalid("actual saved RGB differs") }
                owners += 1; scalarHashes += 4
            }
            sources += 1
        }
        print("{\"status\":\"PASS\",\"actualSources\":\(sources),\"actualSavedOwners\":\(owners),\"exactActualArrayHashes\":\(scalarHashes),\"typedAndOCRChecks\":\(checks),\"invalidOCRRejected\":\(rejected),\"modelCalls\":0,\"APIRequests\":0}")
    }
}
