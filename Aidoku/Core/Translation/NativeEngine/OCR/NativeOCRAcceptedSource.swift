import CoreGraphics
import Foundation

/// Transient provenance, deliberately excluded from legacy value equality and
/// wire/cache encoding. A missing old-cache value means unknown, never inferred.
struct NativeOCRSourceMetadata: Equatable, Sendable {
    let membership: NativeOCRAcceptedSource.Membership?
    let layoutPolygon: [CGPoint]?
    let detectorSignals: [Double]?

    /// Pixel coordinates from actual immutable BODY packets. Readings and
    /// unknown duplicate aliases are not promoted into source geometry.
    var bodySourcePolygons: [[CGPoint]]? {
        guard let m = membership else { return nil }
        guard !m.hasUntrackedInputs, !m.body.isEmpty,
              m.body.allSatisfy(m.table.packets.indices.contains) else { return [] }
        return m.body.sorted().map { m.table.packets[$0].polygon }
    }

    init(_ membership: NativeOCRAcceptedSource.Membership? = nil, layoutPolygon: [CGPoint]? = nil,
         detectorSignals: [Double]? = nil) {
        self.membership = membership
        self.layoutPolygon = layoutPolygon
        self.detectorSignals = detectorSignals
    }

    static func == (_ lhs: Self, _ rhs: Self) -> Bool { true }

    static func union(_ inputs: [Self]) -> Self {
        let known = inputs.compactMap(\.membership)
        guard let first = known.first,
              known.allSatisfy({ $0.table === first.table }) else { return .init() }
        let body = known.reduce(into: Set<Int>()) { $0.formUnion($1.body) }
        let readings = known.reduce(into: Set<Int>()) { $0.formUnion($1.readings) }.subtracting(body)
        let unknown = known.reduce(into: Set<Int>()) { $0.formUnion($1.unknownDedup) }
        return .init(.init(table: first.table, body: body, readings: readings, unknownDedup: unknown,
            hasUntrackedInputs: known.count != inputs.count || known.contains(where: \.hasUntrackedInputs)))
    }

    func retainingReading(_ reading: Self) -> Self {
        guard let guest = reading.membership else {
            guard let parent = membership else { return self }
            return .init(.init(table: parent.table, body: parent.body, readings: parent.readings,
                unknownDedup: parent.unknownDedup, hasUntrackedInputs: true))
        }
        guard let parent = membership else {
            return .init(.init(table: guest.table, body: [], readings: guest.body.union(guest.readings),
                unknownDedup: guest.unknownDedup, hasUntrackedInputs: true))
        }
        guard parent.table === guest.table else { return .init() }
        return .init(.init(table: parent.table, body: parent.body,
            readings: parent.readings.union(guest.body).union(guest.readings).subtracting(parent.body),
            unknownDedup: parent.unknownDedup.union(guest.unknownDedup),
            hasUntrackedInputs: parent.hasUntrackedInputs || guest.hasUntrackedInputs))
    }

    func retainingDuplicate(_ other: Self, exactContentWitness _: Bool) -> Self {
        let joined = Self.union([self, other])
        guard let member = joined.membership else { return joined }
        // Text equality does not turn acquired aliases into original physical
        // witnesses. Keep every source/erasure packet, but preserve an anchor's
        // own original votes even if a guest marked the same packet nonvoting.
        let originalVoting = membership.map {
            $0.body.union($0.readings).subtracting($0.unknownDedup)
        } ?? []
        let acquired = other.membership.map {
            $0.body.union($0.readings).subtracting(originalVoting)
        } ?? []
        let unknown = member.unknownDedup.union(acquired).subtracting(originalVoting)
        return .init(.init(table: member.table, body: member.body, readings: member.readings,
            unknownDedup: unknown, hasUntrackedInputs: member.hasUntrackedInputs))
    }
}

enum NativeOCRAcceptedSource {
    /// Availability-neutral exact snapshot. Keep every original packet field,
    /// not a NativeCoreMLOCRLine value whose type is unavailable before iOS 18.
    struct Packet: Equatable, Sendable {
        let polygon: [CGPoint]
        let text: String
        let score: Double
        let orientation: BrowserOCRSourceOrientation
        let orientationIsEstimated: Bool
        let sourceTileBounds: CGRect?
        let erasurePolygons: [[CGPoint]]
        let detectorSeedEvidence: [NativeOCRDetectorSeedEvidence]?
        var detectorSignals: [Double]? = nil
        var layoutPolygon: [CGPoint]? = nil
        /// Stable relation geometry; observed source extent remains immutable.
        var groupingPolygon: [CGPoint] { layoutPolygon ?? polygon }
    }

    /// One immutable table per accepted-primary page operation. Identical packets
    /// have distinct ordinals; a second page can never union into this table.
    final class PacketTable: Sendable {
        let operationID = UUID()
        let width: Int
        let height: Int
        let packets: [Packet]
        /// Complement ordinals form a contiguous suffix in the combined packet bank.
        let legacyPacketStart: Int?

        init(packets: [Packet], width: Int, height: Int, legacyPacketStart: Int? = nil) {
            self.width = width
            self.height = height
            self.packets = packets
            self.legacyPacketStart = legacyPacketStart
        }
    }

    struct Membership: Sendable {
        let table: PacketTable
        let body: Set<Int>
        let readings: Set<Int>
        let unknownDedup: Set<Int>
        let hasUntrackedInputs: Bool
        var isLegacyComplement: Bool {
            guard let start = table.legacyPacketStart, !body.isEmpty else { return false }
            return body.allSatisfy { $0 >= start }
        }
    }

    /// Called only at accepted-primary ingress, not by regrouping, recovery or
    /// cached decoding. Copies carry this token by value through actual members.
    @available(iOS 18.0, *)
    static func bindingPrimary(_ lines: [NativeCoreMLOCRLine], width: Int, height: Int) -> [NativeCoreMLOCRLine] {
        // The live raw path already bound ALL accepted observations before
        // direct-witness suppression. Rebinding only survivors would discard
        // original packets and their unknown-dedup receipts.
        if let first = lines.first?.acceptedSource.membership,
           first.table.width == width, first.table.height == height,
           lines.allSatisfy({ line in
               guard let m = line.acceptedSource.membership else { return false }
               return m.table === first.table && !m.hasUntrackedInputs && !m.body.isEmpty
                   && m.body.union(m.readings).union(m.unknownDedup).allSatisfy(m.table.packets.indices.contains)
           }) { return lines }
        let table = PacketTable(packets: lines.map(Packet.init), width: width, height: height)
        return lines.enumerated().map { index, line in
            var value = line
            value.acceptedSource = .init(.init(table: table, body: [index], readings: [],
                unknownDedup: [], hasUntrackedInputs: false),layoutPolygon:line.acceptedSource.layoutPolygon)
            return value
        }
    }
}

extension NativeOCRAcceptedSource.Packet {
    @available(iOS 18.0, *)
    init(_ line: NativeCoreMLOCRLine) {
        let layout=line.acceptedSource.layoutPolygon.map { q -> [CGPoint] in
            guard q.count == 4,line.polygon.count == 4 else { return q }
            // Reading-direction normalization can cycle the output vertices.
            // Preserve the layout's geometry while using that same edge basis.
            let edge=CGPoint(x:line.polygon[1].x-line.polygon[0].x,y:line.polygon[1].y-line.polygon[0].y)
            let start=(0..<4).max { a,b in
                func alignment(_ i:Int)->CGFloat {
                    let dx=q[(i+1)%4].x-q[i].x,dy=q[(i+1)%4].y-q[i].y
                    return (edge.x*dx+edge.y*dy)/max(0.000001,hypot(dx,dy))
                }
                return alignment(a)<alignment(b)
            }!
            return (0..<4).map { q[(start+$0)%4] }
        }
        self.init(polygon: line.polygon, text: line.text, score: line.score, orientation: line.orientation,
            orientationIsEstimated: line.orientationIsEstimated, sourceTileBounds: line.sourceTileBounds,
            erasurePolygons: line.erasurePolygons, detectorSeedEvidence: line.detectorSeedEvidence,
            detectorSignals: line.acceptedSource.detectorSignals, layoutPolygon:layout)
    }
}
