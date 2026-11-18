import CoreGraphics
import Foundation

enum HostDump { static func capture(_ stage: String, _ value: [String: Any]) {} }

@main struct RFReplaySmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        func rejects(_ body: () throws -> Void) {
            var rejected = false
            do { try body() } catch { rejected = true }
            check(rejected, "invalid input must fail")
        }
        func image(_ gray: CGFloat) -> CGImage {
            let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return context.makeImage()!
        }
        let input = image(1), changed = image(0)
        let identity = try NativeRFDETRSourceImage.decode(input).identity
        let context = try HostRFLayoutReplay.Context(root: root, cache: temporary, sourceSHA256: String(repeating: "a", count: 64), width: 8, height: 8)
        let cells = NativeRFDETRLayoutResource.maskSide * NativeRFDETRLayoutResource.maskSide
        let logits = (0..<cells).map { Float($0 % 31) - 15 }
        let mask = NativeRFDETRLayoutMask(queryID: 7, sourceWidth: 8, sourceHeight: 8, logits: logits)
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
        var balloon = NativeRFDETRLayoutPrimitive(queryID: 7, semanticClass: .balloon, confidence: 0.73,
            normalizedBounds: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), sourceBounds: rect, mask: mask)
        balloon.supportPolygon = [.init(x: 1, y: 2), .init(x: 4, y: 2), .init(x: 4, y: 6), .init(x: 1, y: 6)]
        let frame = NativeRFDETRLayoutPrimitive(queryID: 7, semanticClass: .frame, confidence: 0.4,
            normalizedBounds: balloon.normalizedBounds, sourceBounds: rect, mask: mask)
        func result(_ primitives: [NativeRFDETRLayoutPrimitive]) -> NativeRFDETRLayoutResult {
            .init(imageIdentity: identity, sourceWidth: 8, sourceHeight: 8, primitives: primitives,
                maskQueriesOmittedByBudget: 2, preprocessingMilliseconds: 1, modelMilliseconds: 3,
                decodeMilliseconds: 2, computeUnits: "test", fromCache: false,
                classEvidence: [.init(queryID: 7, logits: [-3, 1, 0, 0, 0], probabilities: [0.047, 0.731, 0.5, 0.5, 0.5],
                    normalizedBounds: balloon.normalizedBounds, sourceBounds: rect, mask: mask)])
        }
        try HostRFLayoutReplay.$context.withValue(context) {
            check(try HostRFLayoutReplay.read(image: input, maximumMasks: 1) == nil, "cold miss")
            let cold = try HostRFLayoutReplay.store(result([balloon, frame]), maximumMasks: 1)
            check(!cold.fromCache && cold.modelMilliseconds == 3, "cold timings")
            let warm = try HostRFLayoutReplay.read(image: input, maximumMasks: 1)!
            check(warm.fromCache && warm.modelMilliseconds == 0, "warm timings")
            check(warm.primitives.count == 2 && warm.maskQueriesOmittedByBudget == 2, "all primitives and budget")
            check(warm.primitives[0].supportPolygon == balloon.supportPolygon, "polygon")
            check(warm.primitives[0].confidence == balloon.confidence && warm.primitives[0].sourceBounds == rect, "exact geometry and score")
            check(warm.primitives.allSatisfy { $0.mask?.logits == logits && $0.mask?.queryID == 7 }, "duplicate class mask exact")
            check(context.statistics["RF_model_calls"] as? Int == 1 && context.statistics["RF_replay_hits"] as? Int == 1, "counts")
            let winner = try HostRFLayoutReplay.store(result([]), maximumMasks: 1)
            check(winner.primitives.count == 2, "first complete result wins")
            rejects { _ = try HostRFLayoutReplay.read(image: changed, maximumMasks: 1) }
            check(try HostRFLayoutReplay.read(image: input, maximumMasks: 0) == nil, "budget key")
            let empty = try HostRFLayoutReplay.store(result([]), maximumMasks: 0)
            check(empty.primitives.isEmpty, "empty mask payload")
            rejects { _ = try HostRFLayoutReplay.read(image: input, maximumMasks: -1) }
            let text = NativeRFDETRLayoutPrimitive(queryID: 7, semanticClass: .text, confidence: 0.8,
                normalizedBounds: balloon.normalizedBounds, sourceBounds: rect, mask: mask)
            let sfx = NativeRFDETRLayoutPrimitive(queryID: 7, semanticClass: .soundEffect, confidence: 0.7,
                normalizedBounds: balloon.normalizedBounds, sourceBounds: rect, mask: mask)
            _ = try HostRFLayoutReplay.store(result([text, sfx, balloon, frame]), maximumMasks: 160)
            let allClasses = try HostRFLayoutReplay.read(image: input, maximumMasks: 160)!
            check(allClasses.primitives.count == 4, "all semantic classes retained at live budget")
            check(allClasses.classEvidence.count == 1 && allClasses.classEvidence[0].logits[0] == -3, "raw RF logits preserved")
            check(allClasses.classEvidence[0].probabilities[0] == 0.047, "below-threshold text probability preserved")
            check(allClasses.classEvidence[0].mask?.logits == logits, "raw hypothesis mask reference restored")
            check(allClasses.primitives.allSatisfy { $0.mask?.logits == logits }, "text/SFX masks survive disk roundtrip")
            rejects { _ = try HostRFLayoutReplay.read(image: input, maximumMasks: 161) }
            let folder = context.directory.appendingPathComponent("masks-1/" + context.sourceSHA256)
            let metadata = folder.appendingPathComponent("record.json")
            let original = try Data(contentsOf: metadata)
            let record = try JSONDecoder().decode(HostRFLayoutReplay.Record.self, from: original)
            let blob = folder.appendingPathComponent(record.maskSHA256 + ".f32")
            let originalMask = try Data(contentsOf: blob)
            check(originalMask.count == cells * 4, "shared mask stored once")
            try Data([0]).write(to: blob)
            rejects { _ = try HostRFLayoutReplay.read(image: input, maximumMasks: 1) }
            try originalMask.write(to: blob)
            try Data("{}".utf8).write(to: metadata)
            rejects { _ = try HostRFLayoutReplay.read(image: input, maximumMasks: 1) }
            try original.write(to: metadata)
            let other = try HostRFLayoutReplay.Context(root: root, cache: temporary, sourceSHA256: String(repeating: "b", count: 64), width: 8, height: 8)
            try HostRFLayoutReplay.$context.withValue(other) {
                check(try HostRFLayoutReplay.read(image: input, maximumMasks: 1) == nil, "source key")
            }
            let wrong = try HostRFLayoutReplay.Context(root: root, cache: temporary, sourceSHA256: context.sourceSHA256, width: 9, height: 8)
            HostRFLayoutReplay.$context.withValue(wrong) {
                rejects { _ = try HostRFLayoutReplay.read(image: input, maximumMasks: 1) }
            }
        }
        print("RF full-result replay: \(checks) checks passed; no model calls")
    }
}
