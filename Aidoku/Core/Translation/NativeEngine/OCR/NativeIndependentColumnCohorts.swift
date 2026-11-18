import Foundation
import CoreGraphics

/// Geometry proposes a compartment probe; it never establishes ownership itself.
enum NativeIndependentColumnCohorts {
    struct Column { let id: Int; let box: CGRect }
    struct Witness {
        let first: [Int]
        let second: [Int]
        let firstBounds: CGRect
        let secondBounds: CGRect
    }
    static func witness(_ a: Int, _ b: Int, columns: [Column]) -> Witness? {
        guard columns.count <= 256,
              let left = columns.first(where: { $0.id == a }),
              let right = columns.first(where: { $0.id == b }), left.id != right.id else { return nil }
        let boxes = [left.box, right.box]
        guard boxes.allSatisfy({ !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height >= $0.width * 2 }) else { return nil }
        let font = min(left.box.width, right.box.width)
        let overlap = min(left.box.maxY, right.box.maxY) - max(left.box.minY, right.box.minY)
        let xgap = max(left.box.minX, right.box.minX) - min(left.box.maxX, right.box.maxX)
        guard max(left.box.width, right.box.width) <= font * 1.4,
              abs(left.box.minY - right.box.minY) > font * 1.5,
              overlap >= min(left.box.height, right.box.height) * 0.6,
              xgap >= 0, xgap <= font * 0.6 else { return nil }
        func cohort(_ anchor: Column) -> [Column] {
            columns.filter { column in
                let box = column.box
                guard !box.isNull, !box.isInfinite, box.width > 0, box.height >= box.width * 2,
                      max(box.width, anchor.box.width) <= min(box.width, anchor.box.width) * 1.4,
                      abs(box.minY - anchor.box.minY) <= font * 0.15,
                      abs(box.midX - anchor.box.midX) <= font * 3,
                      min(box.maxY, anchor.box.maxY) - max(box.minY, anchor.box.minY)
                        >= min(box.height, anchor.box.height) * 0.65 else { return false }
                return true
            }
        }
        let first = cohort(left), second = cohort(right)
        guard first.count >= 3, second.count >= 3,
              Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))) else { return nil }
        let f = first.reduce(CGRect.null) { $0.union($1.box) }, s = second.reduce(CGRect.null) { $0.union($1.box) }
        guard f.maxX <= s.minX || s.maxX <= f.minX else { return nil }
        return Witness(first: first.map(\.id).sorted(), second: second.map(\.id).sorted(), firstBounds: f, secondBounds: s)
    }
}

extension NativeIndependentColumnCohorts {
    static func boundaries(columns: [Column], inspect: (CGRect, CGRect, CGFloat) -> Bool) -> [Witness] {
        guard columns.count >= 6, columns.count <= 256 else { return [] }
        let sorted = columns.sorted { $0.box.minX == $1.box.minX ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
        var keys=Set<String>(), result:[Witness]=[], probes=0
        for i in sorted.indices { for j in sorted.indices where j>i {
            let a=sorted[i].box,b=sorted[j].box,font=min(a.width,b.width)
            guard b.minX-a.maxX>=0,b.minX-a.maxX<=font*0.6,
                  let witness=witness(sorted[i].id,sorted[j].id,columns:sorted) else { continue }
            let key=(witness.first.map(String.init).joined(separator:",")+"/"+witness.second.map(String.init).joined(separator:","))
            guard keys.insert(key).inserted else { continue }
            guard probes<8 else { return result };probes+=1
            if inspect(witness.firstBounds,witness.secondBounds,font) { result.append(witness) }
        } }
        return result
    }
    static func separates(_ a: CGRect, _ b: CGRect, boundaries:[Witness]) -> Bool {
        boundaries.contains { w in
            (w.firstBounds.contains(a) && w.secondBounds.contains(b)) ||
            (w.firstBounds.contains(b) && w.secondBounds.contains(a))
        }
    }
}
