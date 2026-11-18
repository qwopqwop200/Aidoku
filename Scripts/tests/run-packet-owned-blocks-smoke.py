#!/usr/bin/env python3
"""Check source-owned block splitting using synthetic detector records, no pixels."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts'))
from swift_replay_cache import compile_replay

carrier = ROOT / 'Scripts/tests/run-paragraph-fragment-pipeline-smoke.py'
ns = {'__file__': str(carrier)}
exec(carrier.read_text().split('tests =')[0], ns)
support = ns['support'].replace('    var translation: String?',
    '    var sourceRoleEvidence: NativeTranslationRoleEvidence?\n    var translation: String?')
translation = ROOT / 'Aidoku/Core/Translation'
ocr = translation / 'NativeEngine/OCR'
sources = [ocr / (name + '.swift') for name in ('BrowserOCRSourceOrientation',
    'NativeOCRDetectorSeedEvidence', 'NativeOCRSourceROIProbabilityEvidence', 'NativeOCRAcceptedSource')]
sources += [translation / 'NativeParagraphFragmentGrouping.swift',
    translation / 'NativeParagraphFragmentGrouping+Pipeline.swift',
    translation / 'NativeEngine/Translation/TranslationBackgroundRolePolicy.swift']
main = support + r'''
typealias G = NativeParagraphFragmentGrouping
typealias E = NativeOCRDetectorSeedEvidence
func checked(_ condition: Bool, _ message: String = "", line: Int = #line) {
    if !condition {
        FileHandle.standardError.write(Data("check failed at generated line \(line): \(message)\n".utf8))
        exit(1)
    }
}
for scale: Int in [1, 2] {
    let size = 1000 * scale
    let packets: [NativeOCRAcceptedSource.Packet] = (0..<4).map { (i: Int) -> NativeOCRAcceptedSource.Packet in
        let x = (100 + (i % 2) * 30) * scale, y = (100 + (i / 2) * 400) * scale
        let width = 20 * scale, height = 200 * scale
        let component = E.Component(seed: y * size + x, pixelCount: width * height, meanProbability: 1,
            runs: (y..<(y + height)).map { E.Run(y: $0, x: x, count: width) })
        let seed = E(ownerID: "test:\(i)", parentBoxIndex: i, provenance: "db-complete-cc-candidates-v2",
            threshold: 0.9, mapOriginX: 0, mapOriginY: 0, mapFullWidth: size, mapFullHeight: size,
            sourceWidth: size, sourceHeight: size, components: [component], ownershipVersion: 2, completeCCScan: true,
            ambiguousComponents: [], candidateComponents: [])
        precondition(seed.isValid)
        let box = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
        return .init(polygon: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)],
            text: ["a", "b", "c", "d"][i], score: 0.99, orientation: .vertical,
            orientationIsEstimated: false, sourceTileBounds: nil, erasurePolygons: [],
            detectorSeedEvidence: [seed])
    }
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: size, height: size)
    let scopes = [G.TextScope(owner: 10, box: CGRect(x: 0.09, y: 0.09, width: 0.07, height: 0.22), confidence: 0.9),
                  G.TextScope(owner: 20, box: CGRect(x: 0.09, y: 0.49, width: 0.07, height: 0.22), confidence: 0.9)]
    for source in ["abcd", "acbd"] {
        var region = ReaderTranslationRegion(id: "source", rect: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.6), source: source)
        region.sourceImageAspectRatio = 1
        region.sourceOrientation = .vertical
        region.acceptedSource = .init(.init(table: table, body: Set(0..<4), readings: [], unknownDedup: [], hasUntrackedInputs: false))
        let output = G.reconcilingObservations([region], scopes: scopes)
        precondition(output.count == 2)
        let bodies = output.map { $0.acceptedSource.membership!.body }
        precondition(Set(bodies) == Set([Set([0, 1]), Set([2, 3])]))
        precondition(output.map(\.source) == ["ab", "cd"])
        precondition(output.allSatisfy { $0.acceptedSource.membership!.table === table })
        let incomplete = G.reconcilingObservations([region], scopes: [scopes[0]])
        precondition(incomplete.count == 1 && incomplete[0].source == source)
    }
}
func rowPacket(_ i: Int, x: Int, y: Int, width: Int, height: Int,
               text: String? = nil, vertical: Bool = false) -> NativeOCRAcceptedSource.Packet {
    let component = E.Component(seed: y * 1000 + x, pixelCount: width * height, meanProbability: 1,
        runs: (y..<(y + height)).map { E.Run(y: $0, x: x, count: width) })
    let seed = E(ownerID: "row:\(i)", parentBoxIndex: i, provenance: "db-complete-cc-candidates-v2",
        threshold: 0.9, mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
        sourceWidth: 1000, sourceHeight: 1000, components: [component], ownershipVersion: 2,
        completeCCScan: true, ambiguousComponents: [], candidateComponents: [])
    precondition(seed.isValid)
    return .init(polygon: [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
        CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)],
        text: text ?? ["one", "two"][i], score: 0.99,
        orientation: vertical ? .vertical : .horizontal, orientationIsEstimated: false,
        sourceTileBounds: nil, erasurePolygons: [], detectorSeedEvidence: [seed])
}
for fault in 0...5 {
    let packets = [rowPacket(0, x: 100, y: 100, width: 400, height: fault == 2 ? 64 : 40),
        rowPacket(1, x: fault == 1 ? 300 : 100, y: fault == 3 ? 800 : fault == 2 ? 209 : 185,
                  width: 320, height: fault == 2 ? 38 : 40)]
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    var input = packets.enumerated().map { i, p -> ReaderTranslationRegion in
        let xs = p.polygon.map(\.x), ys = p.polygon.map(\.y)
        var region = ReaderTranslationRegion(id: "row-\(i)",
            rect: CGRect(x: xs.min()! / 1000, y: ys.min()! / 1000,
                width: (xs.max()! - xs.min()!) / 1000, height: (ys.max()! - ys.min()!) / 1000), source: p.text)
        region.sourceOrientation = .horizontal
        region.sourceImageAspectRatio = 1
        region.acceptedSource = .init(.init(table: table, body: [i], readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return region
    }
    if fault == 4 { input[1].detectorSeedEvidence = packets[1].detectorSeedEvidence }
    if fault == 5 {
        let original = packets[0].detectorSeedEvidence![0]
        let foreign = E(ownerID: "foreign-grid", parentBoxIndex: 0, provenance: original.provenance,
            threshold: 0.9, mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
            sourceWidth: 2000, sourceHeight: 1000, components: original.components, ownershipVersion: 2,
            completeCCScan: true, ambiguousComponents: [], candidateComponents: [])
        precondition(foreign.isValid)
        input[0].detectorSeedEvidence = [foreign]
    }
    let output = G.reconcilingObservations(input, scopes: [])
    precondition(output.count == (fault == 0 || fault == 4 ? 1 : 2), "row certificate fault=\(fault)")
    if fault == 4 { precondition(output[0].detectorSeedEvidence?.count == 2) }
}
// Unequal-length private columns share heads, scale and RF ownership, not a fixed glyph-count cap.
for fault in 0...3 {
    let packets = [rowPacket(0, x: 100, y: 100, width: 18, height: 124, text: "abcdefg", vertical: true),
        rowPacket(1, x: fault == 2 ? 170 : 130, y: fault == 1 ? 125 : 101,
            width: 14, height: 70, text: "hijk", vertical: true)]
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let input = packets.enumerated().map { i, p -> ReaderTranslationRegion in
        let xs = p.polygon.map(\.x), ys = p.polygon.map(\.y)
        var r = ReaderTranslationRegion(id: "heads-\(i)", rect: CGRect(x: xs.min()! / 1000, y: ys.min()! / 1000,
            width: (xs.max()! - xs.min()!) / 1000, height: (ys.max()! - ys.min()!) / 1000), source: p.text)
        r.sourceOrientation = .vertical; r.sourceImageAspectRatio = 1
        r.acceptedSource = .init(.init(table: table, body: [i], readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return r
    }
    let scope = G.TextScope(owner: 7, box: CGRect(x: 0.09, y: 0.09, width: 0.1, height: 0.15), confidence: 0.9)
    let output = G.reconcilingObservations(input, scopes: fault == 3 ? [] : [scope])
    checked(output.count == (fault == 0 ? 1 : 2), "private heads fault=\(fault)")
}
// Exact private detector subsets resolve alias ownership; geometry alone cannot.
for fault in 0...2 {
    let a = rowPacket(0, x: 130, y: 100, width: 20, height: 220, text: "a", vertical: true)
    let b = rowPacket(1, x: 100, y: 100, width: 20, height: 100, text: "b", vertical: true)
    let c = rowPacket(2, x: 100, y: 210, width: 20, height: 110, text: "c", vertical: true)
    let aggregate = NativeOCRAcceptedSource.Packet(polygon: [CGPoint(x: 100, y: 100), CGPoint(x: 120, y: 100),
        CGPoint(x: 120, y: 320), CGPoint(x: 100, y: 320)], text: "bc", score: 0.99,
        orientation: .vertical, orientationIsEstimated: false, sourceTileBounds: nil, erasurePolygons: [],
        detectorSeedEvidence: b.detectorSeedEvidence! + (fault == 2 ? [] : c.detectorSeedEvidence!))
    let table = NativeOCRAcceptedSource.PacketTable(packets: [a, b, c, aggregate], width: 1000, height: 1000)
    var parent = ReaderTranslationRegion(id: "alias-parent", rect: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.22),
        source: fault == 1 ? "ax" : "abc")
    parent.sourceOrientation = .vertical; parent.sourceImageAspectRatio = 1
    parent.acceptedSource = .init(.init(table: table, body: [0, 1, 3], readings: [], unknownDedup: [1], hasUntrackedInputs: false))
    var child = ReaderTranslationRegion(id: "alias-child", rect: CGRect(x: 0.1, y: 0.21, width: 0.02, height: 0.11), source: "c")
    child.sourceOrientation = .vertical; child.sourceImageAspectRatio = 1
    child.acceptedSource = .init(.init(table: table, body: [2], readings: [], unknownDedup: [], hasUntrackedInputs: false))
    let output = G.reconcilingObservations([parent, child], scopes: [])
    checked(output.count == (fault == 0 ? 1 : 2), "private alias fault=\(fault)")
    if fault == 0 {
        checked(output[0].source == "abc")
        checked(output[0].acceptedSource.membership!.body == [0, 3])
        checked(output[0].acceptedSource.membership!.readings == [1, 2])
        checked(output[0].acceptedSource.membership!.unknownDedup.isEmpty)
    }
}
for foreignClaim in [false, true] {
    let shared = E.Component(seed: 100100, pixelCount: 4000, meanProbability: 1,
        runs: (100..<300).map { E.Run(y: $0, x: 100, count: 20) })
    let peer = E.Component(seed: 100130, pixelCount: 4000, meanProbability: 1,
        runs: (100..<300).map { E.Run(y: $0, x: 130, count: 20) })
    let packets: [NativeOCRAcceptedSource.Packet] = (0..<(foreignClaim ? 4 : 3)).map { i in
        let x = i == 2 ? 130 : 100, y = i == 1 ? 200 : 100, height = i < 2 ? 100 : 200
        let candidates: [E.Candidate] = i < 2 ? [.init(component: shared,
            competingOwnerIDs: ["claim:\(1 - i)"], outsideCompetingCells: [2000])] : []
        let seed = E(ownerID: "claim:\(i)", parentBoxIndex: i, provenance: "db-complete-cc-candidates-v2",
            threshold: 0.9, mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
            sourceWidth: 1000, sourceHeight: 1000, components: i < 2 ? [] : [i == 2 ? peer : shared],
            ownershipVersion: 2, completeCCScan: true, ambiguousComponents: [], candidateComponents: candidates)
        precondition(seed.isValid)
        return .init(polygon: [CGPoint(x: x, y: y), CGPoint(x: x + 20, y: y),
            CGPoint(x: x + 20, y: y + height), CGPoint(x: x, y: y + height)],
            text: ["a", "b", "z", "unused"][i], score: 0.99, orientation: .vertical,
            orientationIsEstimated: false, sourceTileBounds: nil, erasurePolygons: [], detectorSeedEvidence: [seed])
    }
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let input = (0..<2).map { i -> ReaderTranslationRegion in
        var region = ReaderTranslationRegion(id: "closed-\(i)",
            rect: CGRect(x: i == 0 ? 0.1 : 0.13, y: 0.1, width: 0.02, height: 0.2), source: i == 0 ? "ab" : "z")
        region.sourceOrientation = .vertical
        region.sourceImageAspectRatio = 1
        region.acceptedSource = .init(.init(table: table, body: i == 0 ? [0, 1] : [2],
            readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return region
    }
    let scope = G.TextScope(owner: 4, box: CGRect(x: 0.09, y: 0.09, width: 0.07, height: 0.22), confidence: 0.9)
    let output = G.reconcilingObservations(input, scopes: [scope])
    precondition(output.count == (foreignClaim ? 2 : 1), "closed ownership foreign=\(foreignClaim)")
    if !foreignClaim { precondition(output[0].acceptedSource.membership!.body == [0, 1, 2]) }
}
for fault in 0...5 {
    var boxes: [(x: Int, y: Int, height: Int)] = [(100, 100, 200), (130, 100, 200),
        (fault == 2 ? 220 : 160, fault == 1 ? 80 : 145, fault == 1 ? 240 : 100)]
    var groups = [[0, 1], [2]]
    if fault == 3 { boxes += [(190, 100, 200), (220, 100, 200)]; groups += [[3, 4]] }
    if fault >= 4 {
        boxes = [(100, 140, 100), (130, 100, 200), (160, 100, 200), (70, 100, 240)]
        groups = [[0, 1, 2], [3]]
        if fault == 5 { boxes.append((190, 140, 100)); groups = [[0, 1, 2, 4], [3]] }
    }
    let packets = boxes.enumerated().map { i, box in
        rowPacket(i, x: box.x, y: box.y, width: 20, height: box.height,
            text: ["a", "b", "z", "c", "d"][i], vertical: true)
    }
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let input = groups.enumerated().map { i, members -> ReaderTranslationRegion in
        let points = members.flatMap { packets[$0].polygon }, xs = points.map(\.x), ys = points.map(\.y)
        var region = ReaderTranslationRegion(id: "bounded-\(i)",
            rect: CGRect(x: xs.min()! / 1000, y: ys.min()! / 1000,
                width: (xs.max()! - xs.min()!) / 1000, height: (ys.max()! - ys.min()!) / 1000),
            source: members.map { packets[$0].text }.joined())
        region.sourceOrientation = .vertical
        region.sourceImageAspectRatio = 1
        region.acceptedSource = .init(.init(table: table, body: Set(members), readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return region
    }
    let scope = G.TextScope(owner: 4, box: CGRect(x: 0.06, y: 0.07, width: 0.21, height: 0.35), confidence: 0.9)
    let output = G.reconcilingObservations(input, scopes: [scope])
    precondition(output.count == (fault == 0 || fault == 4 ? 1 : groups.count), "bounded singleton fault=\(fault)")
    let inventory = output.flatMap { $0.acceptedSource.membership!.body }
    precondition(Set(inventory) == Set(packets.indices) && inventory.count == packets.count)
}
for fault in 0...5 {
    let childX = fault == 2 ? 125 : 105, childY = fault == 1 ? 500 : fault == 4 ? 180 : 310
    let packets = [rowPacket(0, x: 100, y: 100, width: 20, height: 200, text: "a", vertical: true),
        rowPacket(1, x: 130, y: 100, width: 20, height: 200, text: "b", vertical: true),
        rowPacket(2, x: childX, y: childY, width: fault == 3 ? 5 : 10, height: 40, text: "z", vertical: true)]
    let groups = fault == 5 ? [[0], [2]] : [[0, 1], [2]]
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let input = groups.enumerated().map { i, members -> ReaderTranslationRegion in
        let points = members.flatMap { packets[$0].polygon }, xs = points.map(\.x), ys = points.map(\.y)
        var region = ReaderTranslationRegion(id: "tail-\(i)",
            rect: CGRect(x: xs.min()! / 1000, y: ys.min()! / 1000,
                width: (xs.max()! - xs.min()!) / 1000, height: (ys.max()! - ys.min()!) / 1000),
            source: members.map { packets[$0].text }.joined())
        region.sourceOrientation = .vertical
        region.sourceImageAspectRatio = 1
        region.acceptedSource = .init(.init(table: table, body: Set(members), readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return region
    }
    let scope = G.TextScope(owner: 4, box: CGRect(x: 0.09, y: 0.09, width: 0.07, height: 0.47), confidence: 0.9)
    let output = G.reconcilingObservations(input, scopes: [scope])
    precondition(output.count == (fault == 0 ? 1 : 2), "paragraph tail fault=\(fault)")
}
for fault in 0...5 {
    var packets = [rowPacket(0, x: 100, y: 100, width: 20, height: 200, text: "a", vertical: true),
        rowPacket(1, x: fault == 3 ? 170 : 130, y: fault == 2 ? 120 : 101,
            width: 8, height: fault == 1 ? 130 : 190, text: "b", vertical: true)]
    if fault == 4 { packets.append(rowPacket(2, x: 82, y: 101, width: 8, height: 190, text: "c", vertical: true)) }
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let input = packets.enumerated().map { i, packet -> ReaderTranslationRegion in
        let xs = packet.polygon.map(\.x), ys = packet.polygon.map(\.y)
        var region = ReaderTranslationRegion(id: "extent-\(i)",
            rect: CGRect(x: xs.min()! / 1000, y: ys.min()! / 1000,
                width: (xs.max()! - xs.min()!) / 1000, height: (ys.max()! - ys.min()!) / 1000), source: packet.text)
        region.sourceOrientation = .vertical
        region.sourceImageAspectRatio = 1
        region.acceptedSource = .init(.init(table: table, body: [i], readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return region
    }
    let scopes = fault == 5 ? [
        G.TextScope(owner: 4, box: CGRect(x: 0.09, y: 0.09, width: 0.035, height: 0.23), confidence: 0.9),
        G.TextScope(owner: 5, box: CGRect(x: 0.125, y: 0.09, width: 0.02, height: 0.23), confidence: 0.9)
    ] : [G.TextScope(owner: 4, box: CGRect(x: 0.07, y: 0.09, width: 0.12, height: 0.23), confidence: 0.9)]
    let output = G.reconcilingObservations(input, scopes: scopes)
    precondition(output.count == (fault == 0 ? 1 : packets.count), "matched extents fault=\(fault)")
}
for fault in 0...3 {
    let packets = [rowPacket(0, x: 100, y: 100, width: 400, height: 40),
        rowPacket(1, x: fault == 2 ? 135 : 115, y: fault == 3 ? 300 : 185, width: 400, height: 40)]
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let input = packets.enumerated().map { i, p -> ReaderTranslationRegion in
        let xs = p.polygon.map(\.x), ys = p.polygon.map(\.y)
        var region = ReaderTranslationRegion(id: "centered-\(i)",
            rect: CGRect(x: xs.min()! / 1000, y: ys.min()! / 1000,
                width: (xs.max()! - xs.min()!) / 1000, height: (ys.max()! - ys.min()!) / 1000), source: p.text)
        region.sourceOrientation = .horizontal
        region.sourceImageAspectRatio = 1
        region.acceptedSource = .init(.init(table: table, body: [i], readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return region
    }
    let scopes = fault == 1 ? [
        G.TextScope(owner: 4, box: CGRect(x: 0.09, y: 0.09, width: 0.45, height: 0.065), confidence: 0.9),
        G.TextScope(owner: 5, box: CGRect(x: 0.09, y: 0.175, width: 0.45, height: 0.06), confidence: 0.9)
    ] : [G.TextScope(owner: 4, box: CGRect(x: 0.09, y: 0.09, width: 0.45, height: 0.3), confidence: 0.9)]
    let output = G.reconcilingObservations(input, scopes: scopes)
    precondition(output.count == (fault == 0 ? 1 : 2), "centered horizontal rows fault=\(fault)")
}
for sameHead in [false, true] {
    let packets = (0..<4).map { i in
        rowPacket(i, x: 100 + 30 * i, y: sameHead || i < 2 ? 100 : 140,
            width: 20, height: 200, text: ["a", "b", "c", "d"][i], vertical: true)
    }
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    var region = ReaderTranslationRegion(id: "head-veto", rect: CGRect(x: 0.1, y: 0.1, width: 0.11, height: 0.24), source: "abcd")
    region.sourceOrientation = .vertical
    region.sourceImageAspectRatio = 1
    region.acceptedSource = .init(.init(table: table, body: Set(0..<4), readings: [], unknownDedup: [], hasUntrackedInputs: false))
    let scopes = [G.TextScope(owner: 4, box: CGRect(x: 0.09, y: 0.09, width: 0.065, height: 0.26), confidence: 0.9),
        G.TextScope(owner: 5, box: CGRect(x: 0.155, y: 0.09, width: 0.065, height: 0.26), confidence: 0.9)]
    let output = G.reconcilingObservations([region], scopes: scopes)
    precondition(output.count == (sameHead ? 1 : 2), "original column heads same=\(sameHead)")
}
for fault in 0...3 {
    let shifted = fault == 1
    let packets = [rowPacket(0, x: 100, y: 100, width: 20, height: 200, text: "a", vertical: true),
        rowPacket(1, x: 130, y: 100, width: 20, height: 190, text: "b", vertical: true),
        rowPacket(2, x: 190, y: shifted ? 140 : 100, width: 20, height: shifted ? 150 : 200, text: "c", vertical: true),
        rowPacket(3, x: 220, y: shifted ? 140 : 100, width: 20, height: 190, text: "d", vertical: true)]
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let face = ReaderTranslationBalloonInterior(rect: CGRect(x: 0.09, y: 0.09, width: fault == 3 ? 0.07 : 0.16, height: 0.26),
        center: CGPoint(x: 0.17, y: 0.22), spans: Array(repeating: [0.09, fault == 3 ? 0.16 : 0.25], count: 16).flatMap { $0 },
        contourVerified: fault != 2)
    let input = [[0, 1], [2, 3]].enumerated().map { i, members -> ReaderTranslationRegion in
        let points = members.flatMap { packets[$0].polygon }, xs = points.map(\.x), ys = points.map(\.y)
        var region = ReaderTranslationRegion(id: "native-spacing-\(i)",
            rect: CGRect(x: xs.min()! / 1000, y: ys.min()! / 1000,
                width: (xs.max()! - xs.min()!) / 1000, height: (ys.max()! - ys.min()!) / 1000),
            source: members.map { packets[$0].text }.joined())
        region.sourceOrientation = .vertical
        region.sourceImageAspectRatio = 1
        region.balloonInterior = face
        region.acceptedSource = .init(.init(table: table, body: Set(members), readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return region
    }
    let scopes = [G.TextScope(owner: 4, box: CGRect(x: 0.09, y: 0.09, width: 0.07, height: 0.26), confidence: 0.9),
        G.TextScope(owner: 5, box: CGRect(x: 0.18, y: 0.09, width: 0.07, height: 0.26), confidence: 0.9)]
    let output = G.reconcilingObservations(input, scopes: scopes)
    precondition(output.count == (fault == 0 ? 1 : 2), "native spacing scope fault=\(fault)")
}
for wordText in ["z", "tail"] {
    for fault in 0...5 {
        let childX = fault == 1 ? 510 : 450, childY = fault == 2 ? 285 : 140, childHeight = fault == 3 ? 80 : 120
        let packets = [rowPacket(0, x: 100, y: 100, width: 400, height: 200, text: "A"),
            rowPacket(1, x: childX, y: childY, width: 150, height: childHeight, text: wordText),
            rowPacket(2, x: fault == 5 ? 150 : 100, y: fault == 5 ? 100 : 330,
                width: fault == 5 ? 370 : 360, height: 200, text: "B")]
        let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
        let input = [[0, 2], [1]].enumerated().map { i, members -> ReaderTranslationRegion in
            let points = members.flatMap { packets[$0].polygon }, xs = points.map(\.x), ys = points.map(\.y)
            var region = ReaderTranslationRegion(id: "inline-\(i)",
                rect: CGRect(x: xs.min()! / 1000, y: ys.min()! / 1000,
                    width: (xs.max()! - xs.min()!) / 1000, height: (ys.max()! - ys.min()!) / 1000),
                source: members.map { packets[$0].text }.joined())
            region.sourceOrientation = .horizontal
            region.sourceImageAspectRatio = 1
            region.acceptedSource = .init(.init(table: table, body: Set(members), readings: [], unknownDedup: [], hasUntrackedInputs: false))
            return region
        }
        let scopes: [G.TextScope] = fault == 4 ? [
            .init(owner: 4, box: CGRect(x: 0.09, y: 0.09, width: 0.42, height: 0.45), confidence: 0.9),
            .init(owner: 5, box: CGRect(x: 0.44, y: 0.13, width: 0.17, height: 0.14), confidence: 0.9)
        ] : []
        let output = G.reconcilingObservations(input, scopes: scopes)
        precondition(output.count == (fault == 0 ? 1 : 2), "inline word fault=\(fault)")
        if fault == 0 { precondition(output[0].source == "A" + wordText + "B") }
        let inventory = output.flatMap { $0.acceptedSource.membership!.body }
        precondition(Set(inventory) == Set(0..<3) && inventory.count == 3)
    }
}
for fault in 0...5 {
    let packets = [rowPacket(0, x: 100, y: 100, width: 20, height: 200, text: "a", vertical: true),
        rowPacket(1, x: 146, y: fault == 2 ? 140 : 100, width: 20, height: 160, text: "b", vertical: true),
        rowPacket(2, x: 172, y: fault == 2 ? 140 : 100, width: 20, height: 160, text: "c", vertical: true),
        rowPacket(3, x: 130, y: fault == 1 ? 500 : 120, width: fault == 3 ? 4 : 10, height: 40, text: "z", vertical: true)]
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let groups = fault == 5 ? [[0], [1], [2], [3]] : [[0], [1, 2], [3]]
    let input = groups.enumerated().map { i, body -> ReaderTranslationRegion in
        let points = body.flatMap { packets[$0].polygon }, xs = points.map(\.x), ys = points.map(\.y)
        var r = ReaderTranslationRegion(id: "slot-\(i)",
            rect: CGRect(x: xs.min()! / 1000, y: ys.min()! / 1000,
                width: (xs.max()! - xs.min()!) / 1000, height: (ys.max()! - ys.min()!) / 1000),
            source: body.map { packets[$0].text }.joined())
        r.sourceOrientation = .vertical
        r.sourceImageAspectRatio = 1
        r.acceptedSource = .init(.init(table: table, body: Set(body), readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return r
    }
    var scopes = [G.TextScope(owner: 4, box: CGRect(x: 0.08, y: 0.08, width: 0.3, height: 0.6), confidence: 0.9)]
    if fault == 4 { scopes.append(.init(owner: 5, box: input.last!.rect, confidence: 0.99)) }
    let output = G.reconcilingObservations(input, scopes: scopes)
    if fault == 0 { precondition(output.count == 1, "measured interior slot did not connect") }
    else { precondition(output.contains { $0.acceptedSource.membership!.body == Set([3]) }, "unproved interior slot fault=\(fault)") }
    let inventory = output.flatMap { $0.acceptedSource.membership!.body }
    precondition(Set(inventory) == Set(packets.indices) && inventory.count == packets.count)
}
for fault in 0...4 {
    var packets = [rowPacket(0, x: 400, y: 100, width: 20, height: 130, text: "a", vertical: true),
        rowPacket(1, x: 388, y: fault == 1 ? 180 : 200, width: 10, height: fault == 4 ? 120 : fault == 1 ? 50 : 60, text: "b", vertical: true),
        rowPacket(2, x: 388, y: fault == 1 ? 290 : 270, width: 10, height: 50, text: "c", vertical: true),
        rowPacket(3, x: fault == 2 ? 430 : 406, y: 240, width: 10, height: 40, text: "z", vertical: true)]
    if fault == 4 { packets.remove(at: 2) }
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let groups = fault == 4 ? [[0], [1], [2]] : [[0], [1, 2], [3]]
    let input = groups.enumerated().map { i, body -> ReaderTranslationRegion in
        let points = body.flatMap { packets[$0].polygon }, xs = points.map(\.x), ys = points.map(\.y)
        var r = ReaderTranslationRegion(id: "staggered-\(i)",
            rect: CGRect(x: xs.min()! / 1000, y: ys.min()! / 1000,
                width: (xs.max()! - xs.min()!) / 1000, height: (ys.max()! - ys.min()!) / 1000),
            source: body.map { packets[$0].text }.joined())
        r.sourceOrientation = .vertical
        r.sourceImageAspectRatio = 1
        r.acceptedSource = .init(.init(table: table, body: Set(body), readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return r
    }
    var scopes = [G.TextScope(owner: 4, box: CGRect(x: 0.35, y: 0.08, width: 0.15, height: 0.3), confidence: 0.9)]
    if fault == 3 { scopes.append(.init(owner: 5, box: input.last!.rect, confidence: 0.99)) }
    let output = G.reconcilingObservations(input, scopes: scopes)
    if fault == 0 {
        precondition(output.count == 1, "continued tail missed its fragmented neighboring column")
        precondition(output[0].source == "azbc", "continued column reordered its upper and lower fragments")
    } else { precondition(output.count > 1, "unproved staggered columns fault=\(fault)") }
    let inventory = output.flatMap { $0.acceptedSource.membership!.body }
    precondition(Set(inventory) == Set(packets.indices) && inventory.count == packets.count)
}
for sharedOwner in [false, true] {
    let packets = (0..<6).map { i in
        rowPacket(i, x: 100 + (i / 2) * 60 + (i % 2) * 20, y: 100, width: 21, height: 200,
                  text: String(UnicodeScalar(97 + i)!), vertical: true)
    }
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let input = (0..<3).map { i -> ReaderTranslationRegion in
        var r = ReaderTranslationRegion(id: "cadence-\(i)",
            rect: CGRect(x: Double(100 + i * 60) / 1000, y: 0.1, width: 0.041, height: 0.2),
            source: packets[i * 2].text + packets[i * 2 + 1].text)
        r.sourceOrientation = .vertical
        r.sourceImageAspectRatio = 1
        r.acceptedSource = .init(.init(table: table, body: [i * 2, i * 2 + 1], readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return r
    }
    let scopes: [G.TextScope] = sharedOwner ? [
        .init(owner: 0, box: input[0].rect.union(input[1].rect), confidence: 0.9),
        .init(owner: 1, box: input[2].rect, confidence: 0.9)
    ] : input.enumerated().map { .init(owner: $0.offset, box: $0.element.rect, confidence: 0.9) }
    let output = G.reconcilingObservations(input, scopes: scopes)
    if sharedOwner {
        precondition(output.contains { $0.acceptedSource.membership!.body == Set([4, 5]) }, "private rows crossed an established RF block")
    } else { precondition(output.count == 1, "quantized adjacent columns lost their common cadence") }
    let inventory = output.flatMap { $0.acceptedSource.membership!.body }
    precondition(Set(inventory) == Set(packets.indices) && inventory.count == packets.count)
}
for fault in 0...4 {
    var packets = [rowPacket(0, x: 100, y: 100, width: fault == 4 ? 100 : 20, height: 200, text: "a", vertical: true),
        rowPacket(1, x: fault == 1 ? 150 : 100, y: fault == 2 ? 600 : 320,
                  width: fault == 4 ? 100 : 20, height: 160, text: "b", vertical: true)]
    if fault == 3 { packets.append(rowPacket(2, x: 100, y: 500, width: 20, height: 100, text: "c", vertical: true)) }
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let input = packets.enumerated().map { i, p -> ReaderTranslationRegion in
        let box = p.polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        var r = ReaderTranslationRegion(id: "continuation-\(i)",
            rect: CGRect(x: box.minX / 1000, y: box.minY / 1000, width: box.width / 1000, height: box.height / 1000), source: p.text)
        r.sourceOrientation = .vertical
        r.sourceImageAspectRatio = 1
        r.acceptedSource = .init(.init(table: table, body: [i], readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return r
    }
    let scopes = input.enumerated().map { G.TextScope(owner: $0.offset, box: $0.element.rect, confidence: 0.9) }
    let output = G.reconcilingObservations(input, scopes: scopes)
    precondition(output.count == (fault == 0 ? 1 : input.count), "unique private continuation fault=\(fault)")
    let inventory = output.flatMap { $0.acceptedSource.membership!.body }
    precondition(Set(inventory) == Set(packets.indices) && inventory.count == packets.count)
}
for fault in 0...2 {
    let words = fault == 1 ? ["a", "ab", "b"] : ["a", "ab", "bc", "b", "cX"]
    let source = fault == 0 ? "ababcbcX" : fault == 1 ? "abab" : "missing"
    let packets = (words + ["z"]).enumerated().map { i, text in
        rowPacket(i, x: 100 + i * 30, y: 100, width: 20, height: 200, text: text, vertical: true)
    }
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let groups = [Array(words.indices), [words.count]]
    let input = groups.enumerated().map { i, body -> ReaderTranslationRegion in
        let points = body.flatMap { packets[$0].polygon }, xs = points.map(\.x)
        var r = ReaderTranslationRegion(id: "complete-read-\(i)",
            rect: CGRect(x: xs.min()! / 1000, y: 0.1, width: (xs.max()! - xs.min()!) / 1000, height: 0.2),
            source: i == 0 ? source : "z")
        r.sourceOrientation = .vertical
        r.sourceImageAspectRatio = 1
        r.acceptedSource = .init(.init(table: table, body: Set(body), readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return r
    }
    let scope = G.TextScope(owner: 4, box: CGRect(x: 0.09, y: 0.09, width: 0.3, height: 0.22), confidence: 0.9)
    let output = G.reconcilingObservations(input, scopes: [scope])
    precondition(output.count == (fault == 0 ? 1 : 2), "complete immutable read fault=\(fault)")
    if fault == 0 { precondition(output[0].source == "z" + source, "unique complete chain changed the original transcription") }
    let inventory = output.flatMap { $0.acceptedSource.membership!.body }
    precondition(Set(inventory) == Set(packets.indices) && inventory.count == packets.count)
}
for fault in 0...5 {
    let envelope = fault >= 4
    let packets = [rowPacket(0, x: 100, y: 100, width: 20, height: envelope ? 160 : 200, text: "a", vertical: true),
        rowPacket(1, x: 130, y: envelope ? 140 : 100, width: envelope ? 20 : 16,
                  height: envelope ? 160 : 100, text: "b", vertical: true),
        rowPacket(2, x: envelope ? 160 : fault == 3 ? 180 : 154, y: fault == 2 ? 140 : 100,
                  width: envelope ? 20 : 10, height: envelope ? (fault == 4 ? 220 : 240) : fault == 1 ? 50 : 100,
                  text: "z", vertical: true)]
    let table = NativeOCRAcceptedSource.PacketTable(packets: packets, width: 1000, height: 1000)
    let input = [[0, 1], [2]].enumerated().map { i, body -> ReaderTranslationRegion in
        let points = body.flatMap { packets[$0].polygon }, xs = points.map(\.x), ys = points.map(\.y)
        var r = ReaderTranslationRegion(id: "envelope-boundary-\(i)",
            rect: CGRect(x: xs.min()! / 1000, y: ys.min()! / 1000,
                width: (xs.max()! - xs.min()!) / 1000, height: (ys.max()! - ys.min()!) / 1000),
            source: body.map { packets[$0].text }.joined())
        r.sourceOrientation = .vertical
        r.sourceImageAspectRatio = 1
        r.acceptedSource = .init(.init(table: table, body: Set(body), readings: [], unknownDedup: [], hasUntrackedInputs: false))
        return r
    }
    let scope = G.TextScope(owner: 4, box: CGRect(x: 0.09, y: 0.09, width: 0.2, height: 0.3), confidence: 0.9)
    let output = G.reconcilingObservations(input, scopes: [scope])
    precondition(output.count == (fault == 0 || fault == 4 ? 1 : 2), "paragraph envelope / cadence boundary fault=\(fault)")
    let inventory = output.flatMap { $0.acceptedSource.membership!.body }
    precondition(Set(inventory) == Set(packets.indices) && inventory.count == packets.count)
}
print("Packet-owned blocks: conservation, claims, native spacing, unique reads, paragraph envelopes and cadence boundaries passed")
'''
cache = ROOT / 'build/packet-owned-blocks-smoke'
main = main.replace('precondition(', 'checked(')
cache.mkdir(parents=True, exist_ok=True)
binary = cache / 'smoke'
compile_replay(cache, sources, main, binary)
subprocess.run([str(binary)], check=True)
