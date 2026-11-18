import AidokuNativeCV
import Foundation

/// Fresh prerequisites for the weight graph. Residuals are reused only from the
/// same source-font call; original priors and final ems retain distinct roles.
/// This producer does not substitute missing paired/band/image-policy features.
enum NativeSourceWeightMeasurements {
    struct Result {
        let raw866: [[Double]]
        let fill71: [[Double]]
        let paired48: [[Double]]
        let bands112: [[Double]]
        let angles131: [Double]
        let residualReused: [Bool]
        let sourceEMs: [Double]
        let mixed: [Bool]
        let physicalReferenceAvailable: [Bool]
    }
    enum Failure: Error { case invalidContext; case extraction(String) }

    static func measure(_ context: NativeAcceptedSourceFontInference.SourceFontContext,
                        styles: [[String: Any]], measurementSpec: [String: Any],
                        physicalFontPairs: [Any], referencePairs: [[String: Any]]) throws -> Result {
        let packets = context.packets, count = packets.count
        guard context.packetOrder == Array(packets.indices), styles.count == count,
              context.originalPriors.count == count, context.finalSourceEMs.count == count,
              context.measuredMemberPolygons.count == count,
              context.style187.count == count, context.angles131.count == count,
              Set(packets.map(\.sourceIdentity)).count <= 1 else { throw Failure.invalidContext }
        var raw: [[Double]] = [], fill: [[Double]] = [], paired: [[Double]] = [], bands: [[Double]] = []
        var angles: [Double] = [], reused: [Bool] = []
        var mixed: [Bool] = []
        for i in packets.indices {
            let packet = packets[i], residual = context.style187[i], em = context.finalSourceEMs[i]
            try packet.validateWeightObservations()
            guard packet.fontPriorSourcePixels == context.originalPriors[i], em.isFinite, em > 0,
                  residual.count == 262, residual.allSatisfy(\.isFinite), context.angles131[i].isFinite else {
                throw Failure.invalidContext
            }
            let weightWords = packet.wordEvidence.filter {
                $0.bbox.minX >= 0 && $0.bbox.minY >= 0 &&
                $0.bbox.maxX <= CGFloat(packet.width) + 1 && $0.bbox.maxY <= CGFloat(packet.height) + 1
            }
            let weightPolygons = weightWords.map(\.polygon)
            let measuredGeometry = context.measuredMemberPolygons[i]
            let sameGeometry = measuredGeometry.count == weightPolygons.count &&
                zip(measuredGeometry, weightPolygons).allSatisfy { original, word in
                    original.count == word.count && zip(original, word).allSatisfy {
                        abs($0.x - $1.x) <= 1e-6 && abs($0.y - $1.y) <= 1e-6
                    }
                }
            var input: [String: Any] = [
                "width": packet.width, "height": packet.height, "rgb": Data(packet.rgb),
                "ownership": Data(packet.ownMask), "bbox": [packet.bbox.minX, packet.bbox.minY,
                    packet.bbox.width, packet.bbox.height].map(Double.init),
                "prior": packet.fontPriorSourcePixels, "sourceEm": em, "text": packet.sourceText,
                "style": styles[i], "measurementSpec": measurementSpec, "physicalFontPairs": physicalFontPairs,
                "referencePairs": referencePairs, "sourceAngle": context.angles131[i],
                "memberPolygons": packet.memberPolygons.map { $0.map { [Double($0.x), Double($0.y)] } },
                "GTMaskUsed": false, "inferenceUsesGT": false
            ]
            if !sameGeometry { input["weightMemberPolygons"] = weightPolygons.map { $0.map { [Double($0.x), Double($0.y)] } } }
            var error: NSError?
            guard let values = AIDExtractSourceWeightSignals(input, &error) else {
                throw Failure.extraction(error?.localizedDescription ?? "source weight extraction")
            }
            func vector(_ key: String, _ width: Int) throws -> [Double] {
                guard let row = values[key] as? [Double], row.count == width, row.allSatisfy(\.isFinite) else {
                    throw Failure.extraction(key)
                }
                return row
            }
            let body = try vector("raw597", 597), direct = try vector("direct7", 7)
            guard body.prefix(6).allSatisfy({ $0 == 0 }) else { throw Failure.extraction("first6zero") }
            let effectiveResidual = try sameGeometry ? residual : vector("weightStyle187", 262)
            let angle = sameGeometry ? context.angles131[i] : (values["weightAngle131"] as? Double ?? .nan)
            guard angle.isFinite else { throw Failure.extraction("weightAngle131") }
            raw.append(body + direct + effectiveResidual)
            fill.append(try vector("fill71", 71))
            paired.append(try vector("paired48", 48))
            bands.append(try vector("bands112", 112)); angles.append(angle); reused.append(sameGeometry)
            guard let isMixed = values["qualifiedMixed"] as? Bool else { throw Failure.extraction("qualifiedMixed") }
            mixed.append(isMixed)
        }
        return Result(raw866: raw, fill71: fill, paired48: paired, bands112: bands,
                      angles131: angles, residualReused: reused, sourceEMs: context.finalSourceEMs,mixed:mixed,
                      physicalReferenceAvailable:physicalFontPairs.map { ($0 as? [String:Any])?["available"] as? Bool != false })
    }
}
