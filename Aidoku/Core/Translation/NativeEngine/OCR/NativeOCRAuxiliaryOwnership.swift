import CoreGraphics
import Foundation

/// Resolve partial DB-component aliases across independently recognized columns.
/// Removal changes ownership only: every removed polygon remains fully covered
/// by a substantial, retained body polygon belonging to another column.
@available(iOS 18.0, *)
enum NativeOCRAuxiliaryOwnership {
    private struct Body {
        let region: Int
        let polygon: [CGPoint]
        let bounds: CGRect
        let area: CGFloat
    }

    static func deduplicating(_ input: [PaddleOCRLine]) -> [PaddleOCRLine] {
        let lines = deduplicatingClipped(input)
        guard lines.count > 1 else { return lines }
        let eligible = lines.map { line in
            line.sourceOrientation == .vertical && line.singleVerticalColumn == true
                && line.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 2
        }
        var bodies: [Body] = []
        var ownBodies = [[Body]](repeating: [], count: lines.count)
        for index in lines.indices where eligible[index] {
            let font = lines[index].boundingRect.width
            guard font.isFinite, font > 0 else { continue }
            for polygon in lines[index].auxiliaryInkPolygons {
                guard let bounds = convexBounds(polygon), bounds.width >= font * 0.25,
                      bounds.height >= font * 0.75 else { continue }
                let body = Body(region: index, polygon: polygon, bounds: bounds, area: polygonArea(polygon))
                bodies.append(body)
                ownBodies[index].append(body)
            }
        }
        guard !bodies.isEmpty else { return lines }
        let spatial = NativeOCRSpatialIndex(boxes: bodies.map(\.bounds))
        return lines.enumerated().map { index, line in
            guard eligible[index], !ownBodies[index].isEmpty else { return line }
            let font = line.boundingRect.width
            var removed = Set<Int>()
            for (offset, polygon) in line.auxiliaryInkPolygons.enumerated() {
                guard let bounds = convexBounds(polygon), bounds.width <= font * 0.2 else { continue }
                let area = polygonArea(polygon)
                // A component already rooted in our own substantial body is
                // ambiguous ownership, not a proven foreign sliver.
                guard !ownBodies[index].contains(where: { contains(polygon, in: $0.polygon) }) else { continue }
                let ownDistance = ownBodies[index].map { abs($0.bounds.midX - bounds.midX) }.min() ?? .infinity
                let foreign = spatial.indices(intersecting: bounds).contains { bodyIndex in
                    let body = bodies[bodyIndex]
                    return body.region != index && body.area >= area * 8
                        && body.bounds.width >= bounds.width * 3
                        && abs(body.bounds.midX - bounds.midX) < ownDistance
                        && contains(polygon, in: body.polygon)
                }
                if foreign { removed.insert(offset) }
            }
            guard !removed.isEmpty else { return line }
            return removingAuxiliaryPolygons(removed, from: line)
        }
    }

    /// A DB component cut at a competing detection edge is owned by the
    /// neighbouring region retaining its complete rectangle. The retained
    /// component covers every removed point; recognition and main polygons stay exact.
    private static func deduplicatingClipped(_ lines: [PaddleOCRLine]) -> [PaddleOCRLine] {
        guard lines.contains(where: { $0.sourceOrientation == .vertical && $0.singleVerticalColumn == true
            && $0.auxiliaryInkPolygons.count > 1 }) else { return lines }
        struct Component {
            let region: Int
            let offset: Int
            let bounds: CGRect
        }
        var components: [Component] = []
        for region in lines.indices where lines[region].sourceOrientation == .vertical
            && lines[region].text.unicodeScalars.lazy.filter({ CharacterSet.letters.contains($0) }).count >= 2 {
            for (offset, polygon) in lines[region].auxiliaryInkPolygons.enumerated() {
                guard polygon.count == 4, let bounds = convexBounds(polygon),
                      polygon.enumerated().allSatisfy({ offset, point in !polygon.prefix(offset).contains(point) }),
                      polygon.allSatisfy({ ($0.x == bounds.minX || $0.x == bounds.maxX)
                          && ($0.y == bounds.minY || $0.y == bounds.maxY) }) else { continue }
                components.append(.init(region: region, offset: offset, bounds: bounds))
            }
        }
        guard components.count > 1 else { return lines }
        let spatial = NativeOCRSpatialIndex(boxes: components.map(\.bounds))
        var removed = [Set<Int>](repeating: [], count: lines.count)
        for component in components {
            let line = lines[component.region], box = component.bounds
            let ownerBounds = line.boundingRect
            guard line.singleVerticalColumn == true, line.auxiliaryInkPolygons.count > 1,
                  box.height >= box.width * 2, ownerBounds.width > 0,
                  ownerBounds.origin.x.isFinite, ownerBounds.origin.y.isFinite,
                  ownerBounds.width.isFinite, ownerBounds.height.isFinite,
                  line.auxiliaryInkPolygons.enumerated().contains(where: { offset, polygon in
                      guard offset != component.offset, let other = convexBounds(polygon) else { return false }
                      return !other.intersects(box) && other.height >= box.height * 0.5
                          && other.width >= box.width
                  }) else { continue }
            let tolerance = ownerBounds.width * 0.01
            let clipped = spatial.indices(intersecting: box).contains { index in
                let owner = components[index], full = owner.bounds
                let foreignBounds = lines[owner.region].boundingRect
                guard owner.region != component.region, full.contains(box),
                      full.minY == box.minY, full.maxY == box.maxY,
                      full.width > box.width,
                      foreignBounds.origin.x.isFinite, foreignBounds.origin.y.isFinite,
                      foreignBounds.width.isFinite, foreignBounds.height.isFinite,
                      foreignBounds.contains(full) else { return false }
                return (full.minX == box.minX && full.maxX > ownerBounds.maxX
                    && abs(box.maxX - ownerBounds.maxX) <= tolerance)
                    || (full.maxX == box.maxX && full.minX < ownerBounds.minX
                    && abs(box.minX - ownerBounds.minX) <= tolerance)
            }
            if clipped { removed[component.region].insert(component.offset) }
        }
        return lines.enumerated().map { index, line in
            guard !removed[index].isEmpty else { return line }
            return removingAuxiliaryPolygons(removed[index], from: line)
        }
    }

    private static func removingAuxiliaryPolygons(_ removed: Set<Int>, from line: PaddleOCRLine) -> PaddleOCRLine {
        let polygons = line.auxiliaryInkPolygons.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        let removedBounds = removed.compactMap { convexBounds(line.auxiliaryInkPolygons[$0]) }
        let retainedBounds = polygons.compactMap(convexBounds)
        // Legacy rect-only evidence has no polygon ownership proof. Keep
        // it unless it is exactly the alias of a removed polygon.
        let rects = line.auxiliaryInkRects.filter { !removedBounds.contains($0) || retainedBounds.contains($0) }
        return PaddleOCRLine(poly: line.poly, text: line.text, score: line.score, orientationRaw: line.orientationRaw,
            singleVerticalColumn: line.singleVerticalColumn, auxiliaryInkRects: rects, auxiliaryInkPolygons: polygons,
            detectorSeedEvidence: nil, acceptedSource: line.acceptedSource)
    }

    private static func convexBounds(_ polygon: [CGPoint]) -> CGRect? {
        guard (3...32).contains(polygon.count), polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var direction: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count], c = polygon[(index + 2) % polygon.count]
            let turn = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(turn) < 1e-8 { continue }
            if direction == 0 { direction = turn }
            if turn * direction < 0 { return nil }
        }
        guard direction != 0, polygonArea(polygon) > 0 else { return nil }
        guard polygon.indices.allSatisfy({ index in
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            return polygon.allSatisfy { point in
                ((b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)) * direction >= -1e-8
            }
        }) else { return nil }
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private static func contains(_ inner: [CGPoint], in outer: [CGPoint]) -> Bool {
        // Convexity has already been checked. Checking every vertex proves
        // containment of every edge and the complete filled polygon.
        let signed = zip(outer, outer.dropFirst() + [outer[0]]).reduce(CGFloat.zero) {
            $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y
        }
        let sign: CGFloat = signed > 0 ? 1 : -1
        return inner.allSatisfy { point in
            outer.indices.allSatisfy { index in
                let a = outer[index], b = outer[(index + 1) % outer.count]
                return ((b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)) * sign >= -1e-8
            }
        }
    }

    private static func polygonArea(_ polygon: [CGPoint]) -> CGFloat {
        abs(zip(polygon, polygon.dropFirst() + [polygon[0]]).reduce(CGFloat.zero) {
            $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y
        }) / 2
    }
}
