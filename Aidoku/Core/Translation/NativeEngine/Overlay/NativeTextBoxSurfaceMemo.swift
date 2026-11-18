import CoreGraphics
import Foundation

/// Invocation-local memo of immutable source queries. Never retains sampled pixels.
final class NativeTextBoxSurfaceMemo {
    struct OwnerKey: Hashable {
        let x: UInt64
        let y: UInt64
        let width: UInt64
        let height: UInt64

        init(_ rect: CGRect) {
            x = Double(rect.origin.x).bitPattern
            y = Double(rect.origin.y).bitPattern
            width = Double(rect.size.width).bitPattern
            height = Double(rect.size.height).bitPattern
        }
    }

    /// Exact owner repetition is necessary for an immutable page query to hit.
    /// Unique owners never allocate the larger query keys or pollute the memo.
    static func repeatedOwners(_ owners: [CGRect], eligible: [Bool]) -> Set<OwnerKey> {
        guard owners.count == eligible.count, owners.count <= 4_096 else { return [] }
        var seen: Set<OwnerKey> = []
        var repeated: Set<OwnerKey> = []
        for index in owners.indices where eligible[index] {
            let owner = owners[index]
            guard !owner.isNull, !owner.isInfinite, owner.width > 0, owner.height > 0,
                  [owner.minX, owner.minY, owner.maxX, owner.maxY].allSatisfy(\.isFinite) else { continue }
            let key = OwnerKey(owner)
            if !seen.insert(key).inserted { repeated.insert(key) }
        }
        return repeated
    }

    struct Key: Hashable {
        let frame: OwnerKey
        let owner: OwnerKey
        let roi: OwnerKey
        let projection: OwnerKey
        let width: Int
        let height: Int

        init(frame: CGRect, owner: CGRect, roi: CGRect, projection: CGRect, width: Int, height: Int) {
            self.frame = OwnerKey(frame)
            self.owner = OwnerKey(owner)
            self.roi = OwnerKey(roi)
            self.projection = OwnerKey(projection)
            self.width = width
            self.height = height
        }
    }

    private enum Entry {
        case absent
        case surface(NativeTextBoxContainment.Surface)

        var spanCount: Int {
            if case .surface(let surface) = self { return surface.spans.count }
            return 0
        }
    }

    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var spanCount = 0
    private let maximumEntries = 32
    private let maximumSpans = 8_192

    func lookup(_ key: Key) -> (found: Bool, surface: NativeTextBoxContainment.Surface?) {
        guard let entry = entries[key] else { return (false, nil) }
        switch entry {
        case .absent: return (true, nil)
        case .surface(let surface): return (true, surface)
        }
    }

    func insert(_ surface: NativeTextBoxContainment.Surface?, for key: Key) {
        guard entries[key] == nil else { return }
        let incoming = surface?.spans.count ?? 0
        guard incoming <= maximumSpans else { return }
        while entries.count >= maximumEntries || spanCount + incoming > maximumSpans {
            let oldest = order.removeFirst()
            spanCount -= entries.removeValue(forKey: oldest)?.spanCount ?? 0
        }
        entries[key] = surface.map(Entry.surface) ?? .absent
        order.append(key)
        spanCount += incoming
    }
}
