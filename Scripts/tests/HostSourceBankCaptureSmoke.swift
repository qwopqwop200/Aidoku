import CoreGraphics
import Foundation
import ImageIO

@available(macOS 15.0, *)
@main struct HostSourceBankCaptureSmoke {
    static func main() throws {
        typealias C = HostSourceBankCapture
        let jobs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        var actual = 0, rejected = 0
        for job in jobs {
            let source = try HostSourceInputBank.decodeOriginal(Data(contentsOf: URL(fileURLWithPath: job["original"] as! String)))
            let record = URL(fileURLWithPath: job["record"] as! String)
            let h = try JSONDecoder().decode(HostRFRawReplay.Header.self, from: Data(contentsOf: record))
            let ledger = job["diagnostics"] as! [String: Any]
            let row = (ledger["rawRecords"] as! [[String: Any]])[0]
            let receipt = (row["consumers"] as! [[String: Any]])[0]
            let consumer = receipt["consumer"] as! [String: Any]
            let constant = String(repeating: "a", count: 64)
            let input = HostSourceInputBank.Contract(producerSHA256: constant, sourceFactorySHA256: constant,
                pixelEvidenceSHA256: constant, decoderSHA256: consumer["decoderCodeSHA256"] as! String,
                preprocessSHA256: h.identity.preprocessCodeSHA256, installedRFModelSHA256: h.identity.base.installedModelTreeSHA256,
                configurationSHA256: constant, modelSetSHA256: constant, rfWeightsSHA256: h.identity.base.expectedWeightsSHA256,
                rfSourceRevision: h.identity.base.sourceRevision, rfFeatureSchema: HostSourceInputBank.rfSchema)
            let contract = C.Contract(input: input, compiledSourceFingerprint: consumer["hostBuildFingerprint"] as! String,
                compiledSourceSHA256: ["test-frozen-stub-compilation": constant], modelBinding: ["test": "no-neural-model"],
                rfClassCoordinateFeatureSchema: ["test": "actual raw RF native decoder"], additionalConfiguration: [:],
                maximumStageBytes: 10_000_000, maximumDiagnosticBytes: 1_000_000)
            let resolution = try C.resolveRaw(source: source, contract: contract, diagnostics: ledger, archive: record.deletingLastPathComponent())
            precondition(resolution.reference.identitySHA256 == row["rawIdentitySHA256"] as! String)
            actual += 1
            for field in ["consumerKeySHA256", "typedNumericSHA256", "retainAllQueryMasks", "hostBuildFingerprint"] {
                var badReceipt = receipt, badConsumer = consumer
                if field == "retainAllQueryMasks" { badConsumer[field] = false }
                else if field == "hostBuildFingerprint" { badConsumer[field] = constant }
                else { badReceipt[field] = "invalid" }
                badReceipt["consumer"] = badConsumer
                var badRow = row; badRow["consumers"] = [badReceipt]
                do {
                    _ = try C.resolveRaw(source: source, contract: contract,
                        diagnostics: ["schema": "host-rf-raw-archive-v2", "rawRecords": [badRow]], archive: record.deletingLastPathComponent())
                    fatalError("invalid consumer admitted")
                } catch { rejected += 1 }
            }
            if actual == 1 {
                let original = URL(fileURLWithPath: job["original"] as! String)
                let bytes = try Data(contentsOf: original)
                let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil)!
                let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
                let binding = try HostEnsembleEvidence.sourceStageBinding(original: image, sourceURL: original, fallbackURL: nil)
                let packet = NativeMainEnsembleOCREvidence.Packet(binding: binding)
                let emptyDirectory = output.appendingPathComponent("empty-" + UUID().uuidString)
                let empty = try C.capture(root: output, originalURL: original, source: image, regions: [], packet: packet,
                    pageDirectory: emptyDirectory, pageCohort: "stub-observed-empty", pageOrder: 0, contract: contract)
                precondition(empty.observedEmpty && empty.observedOwners == 0 && HostOperationalAppearance.stubCalls == 0)
                let emptyJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: empty.manifest)) as! [String: Any]
                precondition(emptyJSON["complete"] as? Bool == true)
                let missingDirectory = output.appendingPathComponent("missing-" + UUID().uuidString)
                do {
                    _ = try C.capture(root: output, originalURL: original, source: image,
                        regions: [.init(id: "synthetic-hook-only", source: "stub observation", rect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), polygon: [])],
                        packet: packet, pageDirectory: missingDirectory, pageCohort: "stub-no-constructor", pageOrder: 0, contract: contract)
                    fatalError("missing constructor admitted")
                } catch { rejected += 1 }
                let missing = try JSONSerialization.jsonObject(with: Data(contentsOf: missingDirectory.appendingPathComponent("source-bank.json"))) as! [String: Any]
                precondition(missing["complete"] as? Bool == false && HostOperationalAppearance.stubCalls == 1)
                let artifacts = missing["smallVectorArtifacts"] as! [[String: Any]]
                precondition(artifacts.count == 1)
                let vectorBytes = try Data(contentsOf: URL(fileURLWithPath: artifacts[0]["path"] as! String))
                precondition(HostRFRawReplay.digest(vectorBytes) == artifacts[0]["SHA256"] as! String)
            }
        }
        let tagged = try C.exactJSON(["float": Float(bitPattern: 0x80000000), "double": Double(bitPattern: 0x3ff0000000000001), "boolean": true]) as! [String: Any]
        precondition((tagged["float"] as! [String: String])["$f32"] == "80000000")
        precondition((tagged["double"] as! [String: String])["$f64"] == "3ff0000000000001")
        precondition(tagged["boolean"] as? Bool == true)
        print("{\"status\":\"PASS\",\"actualRawConsumerReceipts\":\(actual),\"invalidOrMissingRejected\":\(rejected),\"emptyCohortNoAuxCall\":true,\"missingConstructorIncomplete\":true,\"exactSmallVectors\":true,\"modelCalls\":0,\"APIRequests\":0,\"scope\":\"Actual RF receipt/input/payload verification plus stub orchestration; no capture/E2E claim\"}")
    }
}
