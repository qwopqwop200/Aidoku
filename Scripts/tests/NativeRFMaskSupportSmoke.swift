import CoreGraphics
import Foundation

@main struct NativeRFMaskSupportSmoke {
    static func main() throws {
        let side = NativeRFDETRLayoutResource.maskSide
        var checks = 0
        // Exhaust source pixels, including sources smaller than the mask grid,
        // extreme aspect ratios, tiny positive corners and zero-weight borders.
        for (width, height) in [(1, 1), (3, 7), (17, 31), (16384, 1), (1, 16384), (211, 307)] {
            for index in [0, 1, side - 1, side + 1, side * side / 2, side * side - 1] {
                var logits = [Float](repeating: -1, count: side * side)
                logits[index] = 0.000001
                let mask = NativeRFDETRLayoutMask(queryID: 0, sourceWidth: width, sourceHeight: height, logits: logits)
                guard let support = mask.conservativePositivePixelBounds() else { fatalError("Missing finite sparse bound") }
                for y in 0..<height { for x in 0..<width {
                    if mask.contains(sourceX: x, sourceY: y) {
                        precondition(support.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)))
                    }
                    checks += 1
                } }
            }
        }
        for invalid in [Float.nan, Float.infinity, -Float.infinity] {
            var logits = [Float](repeating: -1, count: side * side); logits[100] = invalid
            precondition(NativeRFDETRLayoutMask(queryID: 0, sourceWidth: 128, sourceHeight: 128,
                logits: logits).conservativePositivePixelBounds() == nil)
            checks += 1
        }
        let empty = NativeRFDETRLayoutMask(queryID: 0, sourceWidth: 128, sourceHeight: 128,
            logits: [Float](repeating: 0, count: side * side))
        precondition(empty.conservativePositivePixelBounds()?.isEmpty == true)
        let full = NativeRFDETRLayoutMask(queryID: 0, sourceWidth: 128, sourceHeight: 128,
            logits: [Float](repeating: 1, count: side * side))
        precondition(full.conservativePositivePixelBounds() == nil)
        let malformed = NativeRFDETRLayoutMask(queryID: 0, sourceWidth: 128, sourceHeight: 128, logits: [1])
        precondition(malformed.conservativePositivePixelBounds() == nil)
        checks += 3
        let primitives: [NativeRFDETRLayoutPrimitive] = (0..<2).map { ordinal in
            var logits = [Float](repeating: -1, count: side * side)
            for y in 0..<side { for x in (ordinal == 0 ? 0..<70 : 95..<side) { logits[y * side + x] = 1 } }
            return .init(queryID: ordinal + 1, semanticClass: .balloon, confidence: 0.95,
                normalizedBounds: .zero, sourceBounds: .zero,
                mask: .init(queryID: ordinal + 1, sourceWidth: 128, sourceHeight: 128, logits: logits))
        }
        let result = NativeRFDETRLayoutResult(imageIdentity: "neutral-budget-fixture", sourceWidth: 128,
            sourceHeight: 128, primitives: primitives, maskQueriesOmittedByBudget: 0,
            preprocessingMilliseconds: 0, modelMilliseconds: 0, decodeMilliseconds: 0,
            computeUnits: "synthetic-no-inference", fromCache: false)
        let rectangles = [CGRect(x: 8, y: 8, width: 12, height: 12), CGRect(x: 104, y: 8, width: 12, height: 12)]
        for budget in [1, 512, 26_244, 1_048_576] {
            let ownership = NativeRFDETRLayoutApplication.independentBalloonOwnership(
                sourceBounds: rectangles, result: result, maximumPixelTests: budget)
            precondition(ownership.owners.count == 2)
            if budget == 1 {
                precondition(ownership.verifiedPixelTests == 0 && ownership.owners.allSatisfy { $0.queryID == nil })
            } else if budget == 512 {
                precondition(ownership.verifiedPixelTests == 512)
                precondition(ownership.owners[0].queryID == 1 && ownership.owners[1].queryID == nil)
                precondition(ownership.owners[0].fullyOutsideQueries == Set([2]))
                precondition(ownership.owners[1].fullyOutsideQueries.isEmpty)
            } else {
                precondition(ownership.verifiedPixelTests == 1024)
                precondition(ownership.owners[0].queryID == 1 && ownership.owners[1].queryID == 2)
                precondition(ownership.vetoesMerge(first: rectangles[0], second: rectangles[1]))
            }
            checks += 1
        }
        var bodyLogits = [Float](repeating: -1, count: side * side)
        for y in 20..<115 { for x in 25..<115 { bodyLogits[y * side + x] = 1 } }
        for y in 115..<150 { for x in 65..<72 { bodyLogits[y * side + x] = 1 } }
        let balloon = NativeRFDETRLayoutPrimitive(queryID: 9, semanticClass: .balloon, confidence: 0.87,
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            sourceBounds: CGRect(x: 0, y: 0, width: 162, height: 162),
            mask: .init(queryID: 9, sourceWidth: 162, sourceHeight: 162, logits: bodyLogits))
        func fixture(_ values: [NativeRFDETRLayoutPrimitive]) -> NativeRFDETRLayoutResult {
            .init(imageIdentity: "contour-fixture", sourceWidth: 162, sourceHeight: 162, primitives: values,
                maskQueriesOmittedByBudget: 0, preprocessingMilliseconds: 0, modelMilliseconds: 0,
                decodeMilliseconds: 0, computeUnits: "synthetic-no-inference", fromCache: false)
        }
        let source = CGRect(x: 50, y: 40, width: 30, height: 40)
        let contour = NativeRFDETRLayoutApplication.balloonContour(sourceBounds: [source], result: fixture([balloon]))!
        precondition(contour.queryID == 9 && contour.spans.count > 4)
        precondition(abs(contour.center.y * 162 - 67.5) < 2, "Tail must not drag the body center down")
        precondition(contour.rect.maxY * 162 > 140, "Contour must include the tail even though center ignores it")
        precondition(NativeRFDETRLayoutApplication.balloonContour(
            sourceBounds: [CGRect(x: 135, y: 40, width: 10, height: 10)], result: fixture([balloon])) == nil,
            "A containing detector bbox cannot replace the segmentation mask")
        let duplicate = NativeRFDETRLayoutPrimitive(queryID: 10, semanticClass: .balloon, confidence: 0.86,
            normalizedBounds: balloon.normalizedBounds, sourceBounds: balloon.sourceBounds, mask: balloon.mask)
        precondition(NativeRFDETRLayoutApplication.balloonContour(sourceBounds: [source],
            result: fixture([balloon, duplicate])) == nil, "Ambiguous mask ownership must remain unresolved")
        checks += 5
        print("{\"checks\":\(checks),\"failed\":0,\"sourceComposites\":0,\"phoneMeasured\":false}")
    }
}
