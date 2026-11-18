import Foundation
import CryptoKit

@main enum GeometryRepresentativeSmoke {
    typealias S = NativeOCRGeometryRepresentativeSelection
    typealias G = NativeOCRIndividualGeometryHypotheses
    static func quad(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [G.Point] {
        [.init(x:x,y:y), .init(x:x+w,y:y), .init(x:x+w,y:y+h), .init(x:x,y:y+h)]
    }
    static func output(_ polygons: [[G.Point]], _ scores: [Double?]) -> G.Output {
        let records = polygons.enumerated().map { i,q in
            G.Record(requestID:"test",sourceIndex:i,sourceParent:99,sourceMembers:[],
                alternativeID:"corrected/\(i)",origin:.corrected,originalDetectorIndex:nil,polygon:q)
        }
        let out = G.emit(requestID:"test",corrected:records,originals:[])
        return .init(mode:out.mode,individuals:zip(out.individuals,scores).map {
            .init(polygon:$0.0.polygon,provenance:$0.0.provenance,bboxConfidence:$0.1)
        },counts:out.counts,events:out.events)
    }
    static func model(_ json: String) throws -> S.Model { try JSONDecoder().decode(S.Model.self, from:Data(json.utf8)) }
    static func main() throws {
        if CommandLine.arguments.count > 1 { try replay(); return }
        let m = try model(#"{"schema":"numeric-hist-gradient-boost-v1","bias":0,"learningRate":1,"featureNames":["bboxConfidence"],"trees":[[{"feature":0,"threshold":0.65,"left":1,"right":2},{"feature":-1,"value":0.4},{"feature":-1,"value":0.9}]]}"#)
        let q = quad(0,0,10,100), small = quad(0.1,0.1,9.8,99.8)
        let input = output([q,small,quad(20,0,10,100)], [0.6,0.7,0.8])
        let cfg = S.Configuration(overlapThreshold:0.9,scoreMargin:0.1)
        let r = try S.apply(input, context:.init(), model:m, configuration:cfg)
        precondition(r.report.keptIndices == [1,2])
        precondition(r.output.individuals == [input.individuals[1],input.individuals[2]])
        precondition(r.report.replacements[0].inputIndex == 0 && r.report.replacements[0].representativeIndex == 1)
        precondition(r.output.individuals.allSatisfy { $0.provenance.allSatisfy { $0.sourceMembers.isEmpty } })
        let guarded = try S.apply(input,context:.init(),model:m,
            configuration:.init(overlapThreshold:0.9,scoreMargin:0,ambiguityMargin:0.6))
        precondition(guarded.report.ambiguityFallbackIndices == [0])
        precondition(guarded.output.individuals == input.individuals)
        precondition(guarded.report.replacements.isEmpty)
        let paintRows = input.individuals.prefix(2).enumerated().map { i,row in
            let p = G.Record(requestID:"test",sourceIndex:i,sourceParent:99,sourceMembers:[],
                alternativeID:"source-paint/0/\(i)/ink/mode",origin:.corrected,
                originalDetectorIndex:nil,polygon:row.polygon)
            return G.Individual(polygon:row.polygon,provenance:[p],bboxConfidence:row.bboxConfidence)
        }
        let paintInput = G.Output(mode:input.mode,individuals:paintRows,counts:input.counts,events:input.events)
        let paint = try S.apply(paintInput,context:.init(),model:m,
            configuration:.init(overlapThreshold:0.9,scoreMargin:0,ambiguityMargin:0.6))
        precondition(paint.report.ambiguityFallbackIndices.isEmpty && paint.output.individuals.count == 1)
        // Close quality scores abstain instead of arbitrarily selecting an area.
        let uncertain = try S.apply(output([q,small],[0.7,0.7]),context:.init(),model:m,configuration:cfg)
        precondition(uncertain.output.individuals.count == 2)
        let reversed = output([q,Array(q.reversed())],[0.7,0.7])
        let exact = try S.apply(reversed,context:.init(),model:m,configuration:cfg)
        precondition(exact.report.keptIndices == [0] && exact.report.replacements[0].polygonIoU == 1)
        let missing = try S.apply(output([q,small],[nil,0.7]),context:.init(),model:m,
            configuration:.init(overlapThreshold:0.9,scoreMargin:0,minimumScore:0.95))
        precondition(missing.report.keptIndices == [0])
        precondition(missing.report.admittedOutIndices == [1])
        let f = try S.features(output([q,small],[0.6,0.7]),context:.init(),
            names:["iou/corrected","candidateCoverage/corrected","referenceCoverage/corrected","iou/absent"])
        precondition(f.allSatisfy { abs($0[0]-1)<1e-9 && abs($0[1]-1)<1e-9 && abs($0[2]-1)<1e-9 && $0[3]==0 })
        let textContext = S.Context(layout:[.init(polygon:q,confidence:0.9,semanticClass:1)])
        let semantic = try S.features(output([q],[0.6]),context:textContext,
            names:["rf0/coverage","rf1/coverage","rf2/coverage","rf3/coverage"])
        precondition(semantic == [[0,1,0,0]])
        let originalRecord = G.Record(requestID:"test",sourceIndex:8,sourceParent:8,sourceMembers:[8],
            alternativeID:"original/8",origin:.sourceOriginal,originalDetectorIndex:8,polygon:small)
        let referenceBank = G.Output(mode:input.mode,individuals:[input.individuals[0],
            .init(polygon:small,provenance:[originalRecord],bboxConfidence:0.7)],counts:input.counts,events:[])
        let pruned = G.selecting(referenceBank,indices:[0])
        let referenceNames = ["iou/original","referenceConfidence/original"]
        let beforePruning = try S.features(referenceBank,context:.init(),names:referenceNames)
        let afterPruning = try S.features(pruned,context:.init(),names:referenceNames,referenceInventory:referenceBank)
        precondition(afterPruning == [beforePruning[0]] && pruned.individuals.count == 1)
        let p = G.Record(requestID:"x",sourceIndex:9,sourceParent:3,sourceMembers:[],
            alternativeID:"source-paint/10/20/ink-v1/mode",origin:.corrected,originalDetectorIndex:nil,polygon:q)
        precondition(S.family(p) == "paint/ink-v1")
        let cycle = try model(#"{"schema":"numeric-hist-gradient-boost-v1","bias":0,"learningRate":1,"featureNames":["bboxConfidence"],"trees":[[{"feature":0,"threshold":0.5,"left":0,"right":0}]]}"#)
        do { try cycle.validate(); preconditionFailure("cycle accepted") } catch S.Failure.invalidModel { }
        do { _ = try S.features(input,context:.init(),names:["absoluteWidth"]); preconditionFailure("unknown feature") }
        catch S.Failure.unknownFeature { }
        let disabled = try S.configured(input,context:.init(),environment:[:])
        precondition(disabled == nil)
        let empty = try S.apply(output([],[]),context:.init(),model:m,configuration:cfg)
        precondition(empty.report.keptIndices.isEmpty)
        print("PASS: representative election, uncertainty abstention, directional support, immutable polygons/provenance, no query ownership, missing confidence, model validation, disabled policy and empty input")
    }
    struct Saved: Decodable { let page:String; let sourceSHA256:String; let output:G.Output }
    struct Request: Decodable {
        let page:String; let geometry:String; let geometrySHA256:String
        let context:String; let contextSHA256:String; let output:String
    }
    static func digest(_ data:Data)->String { SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined() }
    static func replay() throws {
        let policy = try JSONDecoder().decode(S.Policy.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
        try policy.model.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        while let line = readLine() {
            let request = try JSONDecoder().decode(Request.self,from:Data(line.utf8))
            let bytes = try Data(contentsOf:URL(fileURLWithPath:request.geometry))
            let contextBytes = try Data(contentsOf:URL(fileURLWithPath:request.context))
            guard digest(bytes)==request.geometrySHA256, digest(contextBytes)==request.contextSHA256 else {
                throw S.Failure.invalidConfiguration
            }
            let saved = try JSONDecoder().decode(Saved.self,from:bytes)
            guard saved.page==request.page else { throw S.Failure.invalidConfiguration }
            let context = try JSONDecoder().decode(S.Context.self,from:contextBytes)
            let witness: NativeOCRGeometryWitnessAdmission.Result?
            if CommandLine.arguments[1].contains("witness") {
                witness = try NativeOCRGeometryWitnessAdmission.apply(saved.output)
            } else { witness = nil }
            let signal: NativeOCRGeometrySignalAdmission.Result?
            if CommandLine.arguments[1].contains("signals") {
                func evidence(_ items: [S.Evidence]) -> [NativeOCRGeometrySignalAdmission.Evidence] {
                    items.map { .init(polygon:$0.polygon,confidence:$0.confidence,semanticClass:$0.semanticClass) }
                }
                signal = try NativeOCRGeometrySignalAdmission.apply(witness?.output ?? saved.output,
                    context:.init(detectors:evidence(context.detectors),recognition:evidence(context.recognition),
                        layout:evidence(context.layout)))
            } else { signal = nil }
            let portfolio = try NativeOCRGeometryPortfolioAdmission.configured(signal?.output ?? witness?.output ?? saved.output,
                referenceInventory:saved.output,context:context)
            let result = try S.apply(portfolio?.output ?? signal?.output ?? witness?.output ?? saved.output,context:context,
                model:policy.model,configuration:policy.configuration,referenceInventory:saved.output)
            let originalIndices = result.report.keptIndices.map { index in
                let portfolioIndex = portfolio?.report.keptIndices[index] ?? index
                let signalIndex = signal?.report.keptIndices[portfolioIndex] ?? portfolioIndex
                return witness?.report.keptIndices[signalIndex] ?? signalIndex
            }
            var value:[String:Any] = ["page":saved.page,"sourceSHA256":saved.sourceSHA256,
                "geometryInputSHA256":request.geometrySHA256,"contextSHA256":request.contextSHA256,
                "GTAtInference":false,"output":try JSONSerialization.jsonObject(with:encoder.encode(result.output)),
                "keptOriginalInputIndices":originalIndices,
                "representativeInputStage":signal == nil ? "bbox-confidence-admitted" : "geometry-signal-admitted",
                "representatives":try JSONSerialization.jsonObject(with:encoder.encode(result.report))]
            if let portfolio {
                value["geometryPortfolioAdmission"] = try JSONSerialization.jsonObject(with:encoder.encode(portfolio.report))
            }
            if let signal {
                value["geometrySignalAdmission"] = try JSONSerialization.jsonObject(with:encoder.encode(signal.report))
            }
            if let witness {
                value["geometryWitnessAdmission"] = try JSONSerialization.jsonObject(with:encoder.encode(witness.report))
            }
            try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:URL(fileURLWithPath:request.output),options:.atomic)
            print(request.page); fflush(stdout)
        }
    }
}
