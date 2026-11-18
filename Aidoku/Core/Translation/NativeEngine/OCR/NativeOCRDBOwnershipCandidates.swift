import CoreGraphics
import Foundation

/// Complete measured CCs with explicit ambiguity. Candidate ownership is only
/// a proposal for original-RGB verification, never an erasure permission.
@available(iOS 18.0, *)
enum NativeOCRDBOwnershipCandidates {
    static func collect(map: NativeCoreMLDetectionMap, boxes: [NativeCoreMLDetectionBox],
                        sourceWidth: Int, sourceHeight: Int, geometry: NativeCoreMLDetectionMapGeometry,
                        cancellationCheck: () throws -> Void = {}) throws -> [NativeOCRDetectorSeedEvidence?] {
        let empty = [NativeOCRDetectorSeedEvidence?](repeating: nil, count: boxes.count)
        guard sourceWidth > 0, sourceHeight > 0, boxes.count <= 4096, !boxes.isEmpty,
              geometry.fullWidth > 0, geometry.fullHeight > 0,
              geometry.fullWidth <= 4_194_304 / geometry.fullHeight,
              geometry.originX >= 0, geometry.originY >= 0,
              map.width <= geometry.fullWidth - geometry.originX,
              map.height <= geometry.fullHeight - geometry.originY,
              map.width <= 2_000_000 / map.height else { return empty }
        let sx = CGFloat(geometry.fullWidth) / CGFloat(sourceWidth), sy = CGFloat(geometry.fullHeight) / CGFloat(sourceHeight)
        let polygons = boxes.map { $0.polygon.map { CGPoint(x:$0.x*sx-CGFloat(geometry.originX),y:$0.y*sy-CGFloat(geometry.originY)) } }
        func bounds(_ p:[CGPoint])->CGRect {
            guard (3...32).contains(p.count), p.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return .null}
            return CGRect(x:p.map(\.x).min()!,y:p.map(\.y).min()!,width:p.map(\.x).max()!-p.map(\.x).min()!,height:p.map(\.y).max()!-p.map(\.y).min()!)
        }
        let rects = polygons.map(bounds)
        let spatial = NativeOCRSpatialIndex(boxes: rects)
        var independent=[[NativeOCRDetectorSeedEvidence.Component]](repeating:[],count:boxes.count)
        var ambiguous=independent
        var candidates=[[NativeOCRDetectorSeedEvidence.Candidate]](repeating:[],count:boxes.count)
        var incomplete=[Bool](repeating:false,count:boxes.count)
        var ownerRuns=[Int](repeating:0,count:boxes.count),ownerPixels=ownerRuns
        let width = map.width, height = map.height
        try cancellationCheck()
        // Fuse immutable probability classification and visited-state storage.
        // Keep invalid cells distinct so the original traversal still rejects
        // at the same cell, rather than silently treating it as background.
        // State: 0 = background, 1 = foreground, 2 = visited, 3 = invalid.
        var state = [UInt8](unsafeUninitializedCapacity: map.values.count) { state, initialized in
            map.values.withUnsafeBufferPointer { values in
                for i in values.indices {
                    let p = values[i]
                    state[i] = p >= 0 && p <= 1 ? (p >= 0.9 ? 1 : 0) : 3
                }
            }
            initialized = map.values.count
        }
        var queue: [Int] = []
        queue.reserveCapacity(256)
        var pageRuns=0
        func ownerID(_ index:Int)->String {"db:\(geometry.fullWidth)x\(geometry.fullHeight):\(geometry.originX),\(geometry.originY):\(index)"}
        var next = 0
        while next < state.count {
            if next != 0 && next & 8191 == 0 { try cancellationCheck() }
            let end = min((next | 8191) + 1, state.count)
            guard let first = firstUnvisited(in: state, from: next, to: end) else {
                next = end
                continue
            }
            next = first + 1
            if state[first] == 3 { return empty }
            queue.removeAll(keepingCapacity: true)
            queue.append(first)
            var head=0,sum=0.0,edge=false
            var left=width,right=0,top=height,bottom=0
            state[first]=2
            @inline(__always)
            func enqueue(_ index: Int) -> Bool {
                switch state[index] {
                case 3:
                    return false
                case 1:
                    state[index] = 2
                    queue.append(index)
                    return true
                default:
                    return true
                }
            }
            while head<queue.count {
                if head & 1023 == 0 {try cancellationCheck()}
                let cell=queue[head];head+=1;let x=cell%map.width,y=cell/map.width
                left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
                edge = edge || x==0 || y==0 || x==map.width-1 || y==map.height-1
                sum+=Double(map.values[cell])
                // Original left, right, up, down BFS order and accumulation.
                if x > 0 && !enqueue(cell - 1) { return empty }
                if x + 1 < width && !enqueue(cell + 1) { return empty }
                if y > 0 && !enqueue(cell - width) { return empty }
                if y + 1 < height && !enqueue(cell + width) { return empty }
                // Do not silently truncate an original component.
                if queue.count>262144 {return empty}
            }
            let scope=CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1)
            let possible=spatial.indices(intersecting:scope)
            guard !possible.isEmpty else { continue }

            // Every horizontal foreground neighbour belongs to this 4-connected
            // component. Once the BFS completes, each left edge starts one run.
            var runs: [NativeOCRDetectorSeedEvidence.Run] = []
            for cell in queue {
                let y = cell / width, x = cell % width
                guard x == 0 || state[cell - 1] != 2 else { continue }
                var length = 1
                while x + length < width && state[cell + length] == 2 { length += 1 }
                runs.append(.init(y: y + geometry.originY, x: x + geometry.originX, count: length))
                if runs.count > 4096 { break }
            }
            // Over-budget components only invalidate owners they actually
            // touch. Keep the sparse run allocation bounded on dense noise.
            if runs.count > 4096 {
                for index in possible where !rects[index].isNull {
                    if queue.contains(where: { cell in
                        let center = CGPoint(x: CGFloat(cell % width) + 0.5, y: CGFloat(cell / width) + 0.5)
                        return rects[index].contains(center) && contains(center, in: polygons[index])
                    }) { incomplete[index] = true }
                }
                continue
            }
            runs.sort { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
            var touched: [Int] = [], counts: [Int] = []
            for index in possible where !rects[index].isNull {
                let count = containedPixelCount(runs: runs, polygon: polygons[index],
                                               bounds: rects[index], geometry: geometry, width: width)
                if count > 0 { touched.append(index); counts.append(count) }
            }
            if touched.isEmpty { continue }
            if edge {
                for index in touched { incomplete[index] = true }
                continue
            }
            pageRuns += runs.count
            if pageRuns > 16384 { return empty }
            let seed = runs[0].y * geometry.fullWidth + runs[0].x
            let component = NativeOCRDetectorSeedEvidence.Component(
                seed: seed, pixelCount: queue.count, meanProbability: sum / Double(queue.count), runs: runs)
            let full=touched.indices.filter {counts[$0]==queue.count}
            let uniqueFull=full.count==1 ? touched[full[0]] : nil
            for (offset,index) in touched.enumerated() {
                ownerRuns[index]+=runs.count;ownerPixels[index]+=queue.count
                if ownerRuns[index]>4096 || ownerPixels[index]>262144 {incomplete[index]=true;continue}
                if touched.count==1 && counts[offset]==queue.count {independent[index].append(component)}
                else if uniqueFull==index {
                    let peers=touched.indices.filter{touched[$0] != index}
                    candidates[index].append(.init(component:component,competingOwnerIDs:peers.map{ownerID(touched[$0])},outsideCompetingCells:peers.map{queue.count-counts[$0]}))
                } else {ambiguous[index].append(component)}
                if independent[index].count+ambiguous[index].count+candidates[index].count>256 {incomplete[index]=true}
            }
        }
        return boxes.indices.map { index in
            guard !incomplete[index],ownerPixels[index]>0 else{return nil}
            let result=NativeOCRDetectorSeedEvidence(ownerID:ownerID(index),parentBoxIndex:index,
                provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:geometry.originX,mapOriginY:geometry.originY,
                mapFullWidth:geometry.fullWidth,mapFullHeight:geometry.fullHeight,sourceWidth:sourceWidth,sourceHeight:sourceHeight,
                components:independent[index],ownershipVersion:2,completeCCScan:true,
                ambiguousComponents:ambiguous[index],candidateComponents:candidates[index])
            return result.isValid ? result:nil
        }
    }

    // Foreground and invalid cells both have the low bit set; visited cells
    // and background clear it. Preserve row-major seed and cancellation order.
    private static func firstUnvisited(in state: [UInt8], from start: Int, to end: Int) -> Int? {
        state.withUnsafeBytes { bytes in
            var i = start
            while i + 8 <= end {
                let word = bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                let flags = UInt64(littleEndian: word) & 0x0101_0101_0101_0101
                if flags != 0 { return i + flags.trailingZeroBitCount / 8 }
                i += 8
            }
            while i < end {
                if bytes[i] & 1 != 0 { return i }
                i += 1
            }
            return nil
        }
    }

    private static func intersectionX(from point: CGPoint, to other: CGPoint, at y: CGFloat) -> CGFloat? {
        guard (point.y > y) != (other.y > y) else { return nil }
        return (other.x - point.x) * (y - point.y) / (other.y - point.y) + point.x
    }

    private static func contains(_ center: CGPoint, in polygon: [CGPoint]) -> Bool {
        var inside = false
        var previous = polygon[polygon.count - 1]
        for point in polygon {
            if let crossing = intersectionX(from: point, to: previous, at: center.y), center.x < crossing {
                inside.toggle()
            }
            previous = point
        }
        return inside
    }

    /// Rasterize the same strict ray crossing at cell centres once per occupied
    /// row. A crossing at coordinate c toggles membership at ceil(c - 0.5).
    private static func containedPixelCount(
        runs: [NativeOCRDetectorSeedEvidence.Run], polygon: [CGPoint], bounds: CGRect,
        geometry: NativeCoreMLDetectionMapGeometry, width: Int
    ) -> Int {
        var row = -1
        var crossings: [Int] = []
        crossings.reserveCapacity(polygon.count)
        var count = 0
        for run in runs {
            let y = run.y - geometry.originY
            let centerY = CGFloat(y) + 0.5
            if y != row {
                row = y
                crossings.removeAll(keepingCapacity: true)
                var previous = polygon[polygon.count - 1]
                for point in polygon {
                    if let crossing = intersectionX(from: point, to: previous, at: centerY), !crossing.isNaN {
                        let clipped = max(0, min(CGFloat(width), crossing))
                        crossings.append(Int(ceil(clipped - 0.5)))
                    }
                    previous = point
                }
                crossings.sort()
            }
            let left = run.x - geometry.originX, right = left + run.count
            // Starting at the right, each pair of crossings encloses an
            // interval. A lone effective crossing extends to the left edge.
            var index = crossings.count
            while index > 0 {
                let end = min(right, crossings[index - 1])
                let start = max(left, index >= 2 ? crossings[index - 2] : 0)
                if start < end {
                    let first = CGPoint(x: CGFloat(start) + 0.5, y: centerY)
                    let last = CGPoint(x: CGFloat(end - 1) + 0.5, y: centerY)
                    if bounds.contains(first) && bounds.contains(last) {
                        count += end - start
                    } else {
                        for x in start..<end where bounds.contains(CGPoint(x: CGFloat(x) + 0.5, y: centerY)) {
                            count += 1
                        }
                    }
                }
                index -= 2
            }
        }
        return count
    }
}
