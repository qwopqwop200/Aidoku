import CoreGraphics
import Foundation

/// Geometry context only. Existing support/frame/semantic admission remains mandatory.
@available(iOS 18.0, *)
enum NativeOCRResidualRFTextAlong {
    typealias M = NativeOCRSourceComponentMeasurements.Measurement
    static func candidates(_ m: M, scopes: [NativeOCRResidualRFTextFeatures.Scope],
                           frameWidth: Int, frameHeight: Int, allowedKeys: Set<String>? = nil) -> [NativeOCRResidualCandidate] {
        guard m.polygon.count == 4, m.rect.width > 0, m.rect.height > 0,
              allowedKeys?.isEmpty != true else { return [] }
        struct Match { let rect: CGRect; let confidence: Double; let along: ClosedRange<CGFloat> }
        var matches: [Match] = []
        for scope in scopes where scope.semanticClass == 0 && scope.confidence >= 0.85 && scope.confidence.isFinite {
            let r = scope.rect
            guard !r.isNull, !r.isInfinite, r.width > 0, r.height > 0 else { continue }
            let corners = [CGPoint(x:r.minX,y:r.minY), .init(x:r.maxX,y:r.minY),
                           .init(x:r.maxX,y:r.maxY), .init(x:r.minX,y:r.maxY)].map(m.project)
            guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            let x0 = corners.map(\.x).min()!, x1 = corners.map(\.x).max()!
            let y0 = corners.map(\.y).min()!, y1 = corners.map(\.y).max()!
            let normalOverlap = max(0, min(m.rect.maxX,x1) - max(m.rect.minX,x0))
            let alongOverlap = max(0, min(m.rect.maxY,y1) - max(m.rect.minY,y0))
            guard normalOverlap >= m.rect.width * 0.7,
                  alongOverlap >= min(m.rect.height,y1-y0) * 0.3,
                  max(0,y0-m.rect.maxY,m.rect.minY-y1) <= m.rect.width else { continue }
            matches.append(.init(rect:r,confidence:scope.confidence,along:y0...y1))
        }
        // Finite top-three menu. Tie ordering is numeric geometry, never a page/query ID.
        matches.sort {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            for pair in [($0.rect.minX,$1.rect.minX),($0.rect.minY,$1.rect.minY),
                         ($0.rect.maxX,$1.rect.maxX),($0.rect.maxY,$1.rect.maxY)] {
                if pair.0 != pair.1 { return pair.0 < pair.1 }
            }
            return false
        }
        var result: [NativeOCRResidualCandidate] = []
        for (rank,match) in matches.prefix(3).enumerated() {
            for (name,pad) in [("0",CGFloat(0)),("05",CGFloat(0.05)),("10",CGFloat(0.1))] {
                let key = "rf-text-along-v1-r\(rank)-p\(name)"
                if let allowedKeys, !allowedKeys.contains(key) { continue }
                let a = match.along.lowerBound-pad*m.rect.width, b = match.along.upperBound+pad*m.rect.width
                guard b > a else { continue }
                let q = [CGPoint(x:m.rect.minX,y:a),.init(x:m.rect.maxX,y:a),
                         .init(x:m.rect.maxX,y:b),.init(x:m.rect.minX,y:b)].map(m.restore)
                guard q.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 &&
                    $0.x <= CGFloat(frameWidth) && $0.y <= CGFloat(frameHeight) }) else { continue }
                result.append(.init(key:key,polygon:q))
            }
        }
        return result
    }
}
