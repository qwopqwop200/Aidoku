import Foundation

/// Accepted source-only final refinement. No paths, page identities or target masks.
enum NativeSegmentationFinalPolicy {
    enum Failure: Error { case invalidInput }
    struct Member: Decodable {
        let styleFeatureIndices: [Int]?
        let styleFeatureIndex: Int?
        let boundariesByFeature: [[Double]]?
        let boundaries: [Double]?
        let groupShape: [Int]?
        let offsets: [Int]?
        let exteriorThresholds: [Int]?
        let interiorThresholdCode: Int
        let exteriorThresholdCode: Int?
        var coreRadiusPixels: Int
        let outerRadiusPixels: Int
        let styleApplyToInterior: Bool?
        let confidenceSupport: Confidence?
    }
    struct Confidence: Decodable {
        let weakExteriorDelta: Int
        let strongInteriorDelta: Int
        let strongExteriorDelta: Int
        let radius: Int
        let strongCoreRadiusPixels: Int
    }
    struct Gate: Decodable {
        let maximumSourceStrengthCode: Int
        let thresholdCode: Int
    }
    struct Policy: Decodable {
        var ensembleMembers: [Member]
        let requiredVotes: Int
        let auxiliaryPixelGate: Gate
    }
    static let frozenBaselinePolicySHA256 = "dbe62f855cc112ba607c0c1a62d136c3d20779181c0b5a8a025e1fb584db6be1"
    private static let coreZeroEnabled = ProcessInfo.processInfo.environment["AIDOKU_SEGMENTATION_CORE_ZERO"] == "1"
    static let policyRevision = coreZeroEnabled ? "source-mask-core-zero-v1" : "accepted-frozen-v1"
    // SHA256 of canonical scalar-override contract; packaged baseline bytes stay immutable.
    static let policySHA256 = coreZeroEnabled ? "1a0d65f54aacbc01caaa8ca5b96412ac6797646371a304a574f3e40e48bb1905" : frozenBaselinePolicySHA256
    static let jointModelSHA256 = "ae3460b3037f944fe222a6645a59140fa04a2083a75f7a1eaff9f5ac3bbf8f2c"
    static let auxiliaryModelSHA256 = "a8715aaba6ee893ec2fe773929fcfe96328e60a5a5d0bbf047f96df79d4e3a16"
    // Numeric learned policy only; no paths or stored masks.
    private static let encoded = [
        #"{"ensembleMembers":[{"styleFeatureIndices":[1,5],"boundariesByFeature":[[0.007290784269571304,0.024391576647758484,"#,
        #"0.04584714025259018,0.06530909240245819,0.086405448615551,0.10390748083591461,0.11988638713955879,0.137658447027206"#,
        #"42,0.1564963310956955,0.19944359362125397,0.2688936572521925,0.3494727909564972,0.4290383253246546,0.51740838587284"#,
        #"09,0.6324114426970482],[0.0,0.001896990064331462,0.005434320082161297,0.009848668648788975,0.01594484216577334,0.02"#,
        #"36356922500586,0.03546216676767287,0.04715703905005728,0.0618686730620286,0.0777325807172865,0.10233578997056603,0."#,
        #"1458884499691951,0.2147052573623887]],"groupShape":[16,14],"offsets":[3,3,10,17,27,42,64,84,121,143,183,252,389,682"#,
        #",8,9,18,26,37,50,61,100,121,147,181,256,389,525,24,24,31,40,53,71,80,107,132,166,201,259,371,603,38,38,49,58,63,82,"#,
        #"107,117,150,172,212,277,364,509,52,52,64,67,83,87,114,139,151,183,243,307,463,689,65,65,75,80,93,105,128,158,181,20"#,
        #"8,242,283,399,644,76,75,83,93,103,113,134,159,192,227,284,299,427,787,87,87,95,106,113,131,154,173,204,225,285,311,"#,
        #"436,635,100,102,106,118,125,143,158,190,212,237,304,383,518,679,117,116,123,127,137,163,178,201,238,263,299,363,465"#,
        #",661,158,149,151,173,190,189,216,244,271,301,336,394,505,770,210,224,206,213,240,265,285,294,320,355,388,449,588,76"#,
        #"0,266,250,274,286,293,306,322,355,392,384,447,503,605,818,328,346,335,338,347,360,374,412,438,481,523,574,711,954,3"#,
        #"88,388,413,392,425,425,452,473,531,535,559,642,774,845,489,489,533,489,538,543,513,554,607,633,666,767,935,1019],"i"#,
        #"nteriorThresholdCode":3071,"exteriorThresholdCode":3527,"coreRadiusPixels":1,"outerRadiusPixels":7,"styleApplyToInt"#,
        #"erior":true,"confidenceSupport":{"weakExteriorDelta":-50,"strongInteriorDelta":200,"strongExteriorDelta":200,"radiu"#,
        #"s":1,"strongCoreRadiusPixels":0,"emptyStrongFallback":"retain-weak"}},{"styleFeatureIndices":[1,5],"boundariesByFea"#,
        #"ture":[[0.007290784269571304,0.024391576647758484,0.04584714025259018,0.06530909240245819,0.086405448615551,0.10390"#,
        #"748083591461,0.11988638713955879,0.13765844702720642,0.1564963310956955,0.19944359362125397,0.2688936572521925,0.34"#,
        #"94727909564972,0.4290383253246546,0.5174083858728409,0.6324114426970482],[0.0,0.001896990064331462,0.00543432008216"#,
        #"1297,0.009848668648788975,0.01594484216577334,0.0236356922500586,0.03546216676767287,0.04715703905005728,0.06186867"#,
        #"30620286,0.0777325807172865,0.10233578997056603,0.1458884499691951,0.2147052573623887]],"groupShape":[16,14],"offse"#,
        #"ts":[3,3,10,17,27,42,64,84,121,143,183,252,389,682,8,9,18,26,37,50,61,100,121,147,181,256,389,525,24,24,31,40,53,71"#,
        #",80,107,132,166,201,259,371,603,38,38,49,58,63,82,107,117,150,172,212,277,364,509,52,52,64,67,83,87,114,139,151,183"#,
        #",243,307,463,689,65,65,75,80,93,105,128,158,181,208,242,283,399,644,76,75,83,93,103,113,134,159,192,227,284,299,427"#,
        #",787,87,87,95,106,113,131,154,173,204,225,285,311,436,635,100,102,106,118,125,143,158,190,212,237,304,383,518,679,1"#,
        #"17,116,123,127,137,163,178,201,238,263,299,363,465,661,158,149,151,173,190,189,216,244,271,301,336,394,505,770,210,"#,
        #"224,206,213,240,265,285,294,320,355,388,449,588,760,266,250,274,286,293,306,322,355,392,384,447,503,605,818,328,346"#,
        #",335,338,347,360,374,412,438,481,523,574,711,954,388,388,413,392,425,425,452,473,531,535,559,642,774,845,489,489,53"#,
        #"3,489,538,543,513,554,607,633,666,767,935,1019],"interiorThresholdCode":3071,"exteriorThresholdCode":3527,"coreRadi"#,
        #"usPixels":1,"outerRadiusPixels":7,"styleApplyToInterior":true},{"styleFeatureIndex":1,"boundaries":[0.0039215683937"#,
        #"07275,0.007290784269571304,0.01229870319366455,0.024391576647758484,0.0356514872983098,0.04584714025259018,0.056026"#,
        #"45315229893,0.06530909240245819,0.07681042701005936,0.086405448615551,0.09525485150516033,0.10390748083591461,0.110"#,
        #"91303685680032,0.11988638713955879,0.12809656048193574,0.13765844702720642,0.14653628319501877,0.1564963310956955,0"#,
        #".17116467282176018,0.19944359362125397,0.23082522302865982,0.2688936572521925,0.30759517941623926,0.349472790956497"#,
        #"2,0.38948305137455463,0.4290383253246546,0.4793240427970886,0.5174083858728409,0.5680135879665613,0.632411442697048"#,
        #"2,0.7163822390139103],"offsets":[0,3,6,10,20,28,35,42,49,56,63,68,73,79,84,91,97,103,111,126,149,169,197,226,252,27"#,
        #"6,313,338,367,411,455,533],"interiorThresholdCode":2815,"exteriorThresholdCode":3337,"coreRadiusPixels":0,"outerRad"#,
        #"iusPixels":7},{"styleFeatureIndices":[5],"boundariesByFeature":[[0.0,0.001896990064331462,0.009848668648788975,0.02"#,
        #"36356922500586,0.04715703905005728,0.0777325807172865,0.1458884499691951]],"groupShape":[8],"exteriorThresholds":[3"#,
        #"058,3649,3263,3143,3162,2949,3006,2925],"interiorThresholdCode":2815,"coreRadiusPixels":0,"outerRadiusPixels":7}],""#,
        #"requiredVotes":3,"auxiliaryPixelGate":{"maximumSourceStrengthCode":12,"thresholdCode":3140}}"#,
    ].joined()
    static let frozenBaseline = try! JSONDecoder().decode(Policy.self, from: Data(encoded.utf8))
    static let accepted: Policy = {
        var configured = frozenBaseline
        // Existing scalar override only: [1,1,0,0] -> [0,0,0,0].
        // Learned boundaries/offsets/exterior tables/model weights are untouched.
        if coreZeroEnabled {
            for index in configured.ensembleMembers.indices {
                configured.ensembleMembers[index].coreRadiusPixels = 0
            }
        }
        return configured
    }()

    /// Every member/strong/weak result is confined to base OR its outer radius.
    static var requiredJointRadius: Int { accepted.ensembleMembers.map(\.outerRadiusPixels).max() ?? 0 }

    struct Observations {
        let width: Int
        let height: Int
        let base: [UInt8] // Frozen boundary completion after hole filling.
        let primary: [Float]
        let boundary: [Float]
        let jointCodes: [UInt16] // Source context83 HGB; 65535 outside the domain.
        let style: [Double] // Source RGB/consensus/full-query RF, 18 features.
        let auxiliaryCodes: [UInt16] // Source style78 HGB; required at weak retained pixels.
    }
    struct Result {
        let mask: [UInt8]
        let auxiliaryRemoved: Int
    }
    static func quantize(probability: Double) throws -> UInt16 {
        guard probability.isFinite, (0...1).contains(probability) else { throw Failure.invalidInput }
        let odds = log(max(probability, 1e-12)) - log(max(1 - probability, 1e-12))
        return UInt16(max(0, min(8191, floor((odds + 24) * 8192 / 48))))
    }
    static func apply(_ input: Observations) throws -> Result {
        let w = input.width, h = input.height
        guard w > 0, h > 0, w <= 1_500_000 / h else { throw Failure.invalidInput }
        let n = w * h
        guard input.base.count == n, input.primary.count == n, input.boundary.count == n,
              input.jointCodes.count == n, input.auxiliaryCodes.count == n, input.style.count == 18,
              input.style.allSatisfy(\.isFinite),
              input.primary.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              input.boundary.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalidInput }
        let distance = chebyshev(input.base, width: w, height: h)
        let jointRadius = requiredJointRadius
        for i in 0..<n where input.base[i] != 0 || distance[i] <= jointRadius {
            guard input.jointCodes[i] < 8192 else { throw Failure.invalidInput }
        }
        var votes = [UInt8](repeating: 0, count: n)
        for member in accepted.ensembleMembers {
            let band: Int
            if let indices = member.styleFeatureIndices, let bounds = member.boundariesByFeature, let shape = member.groupShape {
                let groups = zip(indices, bounds).map { index, boundaries in boundaries.filter { $0 <= input.style[index] }.count }
                band = groups.count == 1 ? groups[0] : groups[0] * shape[1] + groups[1]
            } else if let index = member.styleFeatureIndex, let bounds = member.boundaries {
                band = bounds.filter { $0 <= input.style[index] }.count
            } else { throw Failure.invalidInput }
            let offset = member.offsets?[band] ?? 0
            let exterior = member.exteriorThresholds?[band] ?? member.exteriorThresholdCode!
            func infer(interior: Int, exterior: Int, core: Int) -> [UInt8] {
                (0..<n).map { i in
                    let base = input.base[i] != 0
                    // Never read UNCOMPUTED codes outside this member's decision domain.
                    guard base || distance[i] <= member.outerRadiusPixels else { return 0 }
                    let eligible = (!base && distance[i] <= 12) || (base && member.styleApplyToInterior == true)
                    let code = eligible ? max(0, min(8191, Int(input.jointCodes[i]) + offset)) : Int(input.jointCodes[i])
                    let retained = base && code >= interior
                    let added = !base && distance[i] <= member.outerRadiusPixels && (distance[i] <= core || code >= exterior)
                    return retained || added ? 255 : 0
                }
            }
            var mask: [UInt8]
            if let support = member.confidenceSupport {
                mask = infer(interior: member.interiorThresholdCode,
                    exterior: exterior + support.weakExteriorDelta, core: member.coreRadiusPixels)
                let strong = infer(interior: member.interiorThresholdCode + support.strongInteriorDelta,
                    exterior: exterior + support.strongExteriorDelta, core: support.strongCoreRadiusPixels)
                if strong.contains(where: { $0 != 0 }) {
                    let nearby = chebyshev(strong, width: w, height: h)
                    for i in 0..<n where nearby[i] > support.radius { mask[i] = 0 }
                }
            } else {
                mask = infer(interior: member.interiorThresholdCode, exterior: exterior, core: member.coreRadiusPixels)
            }
            for i in 0..<n where mask[i] != 0 { votes[i] += 1 }
        }
        var result = votes.map { Int($0) >= accepted.requiredVotes ? UInt8(255) : 0 }, removed = 0
        let gate = accepted.auxiliaryPixelGate
        for i in 0..<n where result[i] != 0 {
            // Float32 multiplication matches the calibrated NumPy source-vote expression.
            let strength = min(64, Int(ceil(max(input.primary[i], input.boundary[i]) * 64 - 1e-6)))
            if strength <= gate.maximumSourceStrengthCode {
                guard input.auxiliaryCodes[i] < 8192 else { throw Failure.invalidInput }
                if input.auxiliaryCodes[i] < gate.thresholdCode { result[i] = 0; removed += 1 }
            }
        }
        return Result(mask: result, auxiliaryRemoved: removed)
    }
    /// Comparison-only replacement for the style78 gate: unsupported weak islands
    /// cannot establish their own source ownership. Keep the contextual mask's
    /// complete eight-connected components that reach a directly observed
    /// primary/boundary nonweak seed. No erosion, bbox clip or style bins here.
    static func connectedWeak(mask: [UInt8], primary: [Float], boundary: [Float],
                              width w: Int, height h: Int) throws -> Result {
        guard w > 0, h > 0, w <= 1_500_000 / h else { throw Failure.invalidInput }
        let n = w * h
        guard mask.count == n, primary.count == n, boundary.count == n,
              mask.allSatisfy({ $0 == 0 || $0 == 255 }),
              primary.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              boundary.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalidInput }
        var kept = [UInt8](repeating: 0, count: n), queue = [Int]()
        queue.reserveCapacity(min(n, 65536))
        let weakLimit = accepted.auxiliaryPixelGate.maximumSourceStrengthCode
        var foreground = 0
        for i in 0..<n {
            if i % 16384 == 0 { try Task.checkCancellation() }
            guard mask[i] != 0 else { continue }
            foreground += 1
            let strength = min(64, Int(ceil(max(primary[i], boundary[i]) * 64 - 1e-6)))
            if strength > weakLimit { kept[i] = 255; queue.append(i) }
        }
        var head = 0
        while head < queue.count {
            if head % 16384 == 0 { try Task.checkCancellation() }
            let i = queue[head], x = i % w, y = i / w
            head += 1
            for yy in max(0, y - 1)...min(h - 1, y + 1) {
                for xx in max(0, x - 1)...min(w - 1, x + 1) {
                    let j = yy * w + xx
                    if mask[j] != 0 && kept[j] == 0 { kept[j] = 255; queue.append(j) }
                }
            }
        }
        try Task.checkCancellation()
        return Result(mask: kept, auxiliaryRemoved: foreground - queue.count)
    }

    /// Exact eight-connected distance, matching OpenCV DIST_C including empty seeds.
    private static func chebyshev(_ seeds: [UInt8], width w: Int, height h: Int) -> [Int] {
        var d = seeds.map { $0 == 0 ? 8192 : 0 }
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            if x > 0 { d[i] = min(d[i], d[i - 1] + 1) }
            if y > 0 {
                for sx in max(0, x - 1)...min(w - 1, x + 1) { d[i] = min(d[i], d[(y - 1) * w + sx] + 1) }
            }
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) {
            let i = y * w + x
            if x + 1 < w { d[i] = min(d[i], d[i + 1] + 1) }
            if y + 1 < h {
                for sx in max(0, x - 1)...min(w - 1, x + 1) { d[i] = min(d[i], d[(y + 1) * w + sx] + 1) }
            }
        } }
        return d
    }
}

/// Shared native-host transport for live source predictions. No file/path fields.
/// The app uses the typed policy directly; the host supplies bounded JSONL crops.
enum NativeSegmentationFinalStream {
    struct Input: Decodable {
        let width: Int
        let height: Int
        let base: [UInt8]
        let primary: [Float]
        let boundary: [Float]
        let jointCodes: [UInt16]
        let style: [Double]
        let auxiliaryCodes: [UInt16]
    }
    static func run() throws {
        while let line = readLine() {
            let input = try JSONDecoder().decode(Input.self, from: Data(line.utf8))
            let result = try NativeSegmentationFinalPolicy.apply(.init(width: input.width, height: input.height,
                base: input.base, primary: input.primary, boundary: input.boundary, jointCodes: input.jointCodes,
                style: input.style, auxiliaryCodes: input.auxiliaryCodes))
            let data = try JSONSerialization.data(withJSONObject: ["mask": result.mask,
                "auxiliaryRemoved": result.auxiliaryRemoved,
                "policySHA256": NativeSegmentationFinalPolicy.policySHA256, "GTRead": false])
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
