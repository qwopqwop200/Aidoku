import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

// Compatibility utility for the existing graph assertions; no app caller remains.
private extension NativeParagraphFragmentGrouping {
    static func connectedObservations(_ indices: [Int], links: [Edge]) -> Bool {
        let ids = Set(indices)
        guard !indices.isEmpty, indices.count <= 256, ids.count == indices.count,
              links.allSatisfy({ ids.contains($0.first) && ids.contains($0.second) }) else { return false }
        var graph = ObservationGraph(indices)
        graph.join(links)
        return graph.groups.count == 1
    }
}

struct NativeParagraphFragmentGroupingTests {
    private typealias Atom = NativeParagraphFragmentGrouping.Atom

    @Test func sharedContextUsesPhysicalPacketAdjacencyInBothWritingDirections() {
        for scale: CGFloat in [0.5, 1, 2] { for horizontal in [false, true] {
            let size = Int(1000 * scale)
            func quad(_ box: CGRect) -> [CGPoint] {
                [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                 CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
                    .map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
            }
            let boxes = horizontal ? [CGRect(x: 100, y: 100, width: 100, height: 20),
                                      CGRect(x: 100, y: 130, width: 100, height: 20)] :
                [CGRect(x: 130, y: 100, width: 20, height: 100), CGRect(x: 100, y: 100, width: 20, height: 100)]
            // Deliberately change transcription length and punctuation without
            // changing any source geometry or the immutable operation identity.
            for words in [["x", "z"], ["甲…", "乙…"], [String(repeating: "a", count: 20), String(repeating: "z", count: 20)]] {
                let bound = NativeOCRAcceptedSource.bindingPrimary(boxes.enumerated().map { i, box in
                    NativeCoreMLOCRLine(polygon: quad(box), text: words[i], score: 0.98,
                                       orientation: horizontal ? .horizontal : .vertical)
                }, width: size, height: size)
                let input = bound.enumerated().map { i, line -> ReaderTranslationRegion in
                    let b = boxes[i].applying(.init(scaleX: 0.001, y: 0.001))
                    var r = ReaderTranslationRegion(id: "source-\(i)", rect: b, source: line.text)
                    r.polygon = quad(boxes[i]).map { CGPoint(x: $0.x / CGFloat(size), y: $0.y / CGFloat(size)) }
                    r.acceptedSource = line.acceptedSource
                    r.sourceOrientation = line.orientation
                    r.sourceImageAspectRatio = 1
                    return r
                }
                let scope = NativeParagraphFragmentGrouping.TextScope(owner: 71,
                    box: CGRect(x: 0.08, y: 0.08, width: 0.15, height: 0.15), confidence: 0.9)
                for rows in [input, Array(input.reversed())] {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(rows, scopes: [scope])
                    #expect(result.count == 1, "horizontal=\(horizontal), scale=\(scale), words=\(words)")
                    #expect(result.first?.acceptedSource.membership?.body == [0, 1])
                    #expect(result.first?.acceptedSource.membership?.table === bound[0].acceptedSource.membership?.table)
                    #expect(result.first?.acceptedSource.membership?.hasUntrackedInputs == false)
                    #expect(result.first?.source == words.joined())
                }
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: []).count == 2)
                var split = input
                for i in split.indices {
                    split[i].balloonInterior = .init(rect: split[i].rect,
                        center: CGPoint(x: split[i].rect.midX, y: split[i].rect.midY),
                        spans: [Double(i)], contourVerified: true)
                }
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(split, scopes: [scope]).count == 2)
            }
        } }
    }

    @Test func unverifiedMiddleSourceCannotBridgeDistinctVerifiedBalloons() {
        let lines = NativeOCRAcceptedSource.bindingPrimary((0..<3).map { i in
            let x = CGFloat(100 + i * 30)
            return NativeCoreMLOCRLine(polygon: [CGPoint(x: x, y: 100), CGPoint(x: x + 20, y: 100),
                CGPoint(x: x + 20, y: 200), CGPoint(x: x, y: 200)], text: "body\(i)", score: 0.98, orientation: .vertical)
        }, width: 1000, height: 1000)
        let input = lines.enumerated().map { i, line -> ReaderTranslationRegion in
            let b = CGRect(x: CGFloat(100 + i * 30) / 1000, y: 0.1, width: 0.02, height: 0.1)
            var r = ReaderTranslationRegion(id: "bridge-\(i)", rect: b, source: line.text)
            r.polygon = line.polygon.map { CGPoint(x: $0.x / 1000, y: $0.y / 1000) }
            r.acceptedSource = line.acceptedSource
            r.sourceOrientation = .vertical
            r.sourceImageAspectRatio = 1
            if i != 1 {
                r.balloonInterior = .init(rect: b, center: CGPoint(x: b.midX, y: b.midY),
                                          spans: [Double(i)], contourVerified: true)
            }
            return r
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 7,
            box: CGRect(x: 0.08, y: 0.08, width: 0.15, height: 0.15), confidence: 0.9)
        for rows in [input, Array(input.reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(rows, scopes: [scope])
            #expect(result.count >= 2)
            #expect(result.allSatisfy { !($0.acceptedSource.membership!.body.isSuperset(of: [0, 2])) })
            #expect(result.reduce(into: Set<Int>()) { $0.formUnion($1.acceptedSource.membership!.body) } == [0, 1, 2])
        }
    }

    @Test func recordedEmptyComponentInventoryIsNotSeedlessFallbackPermission() {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let observed = Evidence(ownerID: "observed-empty", parentBoxIndex: 0,
            provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
            mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
            sourceWidth: 1000, sourceHeight: 1000, components: [], ownershipVersion: 2,
            completeCCScan: true, ambiguousComponents: [], candidateComponents: [])
        let lines = NativeOCRAcceptedSource.bindingPrimary((0..<2).map { i in
            let x = CGFloat(100 + i * 30)
            return NativeCoreMLOCRLine(polygon: [CGPoint(x: x, y: 100), CGPoint(x: x + 20, y: 100),
                CGPoint(x: x + 20, y: 200), CGPoint(x: x, y: 200)], text: "列\(i)本文", score: 0.98,
                orientation: .vertical, detectorSeedEvidence: [observed])
        }, width: 1000, height: 1000)
        let input = lines.enumerated().map { i, line -> ReaderTranslationRegion in
            let b = CGRect(x: CGFloat(100 + i * 30) / 1000, y: 0.1, width: 0.02, height: 0.1)
            var r = ReaderTranslationRegion(id: "empty-observation-\(i)", rect: b, source: line.text)
            r.polygon = line.polygon.map { CGPoint(x: $0.x / 1000, y: $0.y / 1000) }
            r.acceptedSource = line.acceptedSource
            r.detectorSeedEvidence = line.detectorSeedEvidence
            r.sourceOrientation = .vertical
            r.sourceImageAspectRatio = 1
            return r
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 7,
            box: CGRect(x: 0.08, y: 0.08, width: 0.15, height: 0.15), confidence: 0.9)
        for rows in [input, Array(input.reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(rows, scopes: [scope])
            #expect(result.count == 2)
            #expect(result.reduce(into: Set<Int>()) { $0.formUnion($1.acceptedSource.membership!.body) } == [0, 1])
            #expect(result.allSatisfy { $0.acceptedSource.membership!.table === lines[0].acceptedSource.membership!.table })
        }
    }

    private func commonModeledBalloon(_ regions: [ReaderTranslationRegion]) -> [NativeParagraphFragmentGrouping.TextScope] {
        let box = regions.compactMap { $0.balloonInterior?.rect }.reduce(CGRect.null) { $0.union($1) }
        return box.isNull || box.isEmpty ? [] : [.init(owner: 42, box: box, confidence: 0.95)]
    }

    @Test func columnGeometryDoesNotTreatTranscriptionLengthAsFontSize() {
        for text in ["x", "xxxx", "xxxxxxxxxxxxxxxx"] {
            let right = Atom(index: 0, source: text, box: CGRect(x: 30, y: 10, width: 10, height: 100),
                             orientation: .vertical, owner: nil)
            let left = Atom(index: 1, source: "abcdefghij", box: CGRect(x: 15, y: 10, width: 10, height: 100),
                            orientation: .vertical, owner: nil)
            let links = NativeParagraphFragmentGrouping.measuredColumnEdges(atoms: [right, left])
            #expect(links.contains { Set([$0.first, $0.second]) == Set([0, 1]) })
        }
    }

    @Test func observationGraphKeepsSparseIDsIndependentOfReadingDirection() {
        typealias Edge = NativeParagraphFragmentGrouping.Edge
        let edges = [Edge(first: 8, second: 19, reason: "a"), .init(first: 19, second: -3, reason: "b"),
                     .init(first: -3, second: 8, reason: "cycle")]
        for order in [edges, Array(edges.reversed()), edges + edges] {
            var graph = NativeParagraphFragmentGrouping.ObservationGraph([42, 8, -3, 19])
            graph.join(order)
            #expect(graph.groups.count == 2 && graph.groups[graph.root(8)] == [-3, 8, 19])
            #expect(graph.groups[graph.root(42)] == [42])
            #expect(NativeParagraphFragmentGrouping.connectedObservations([8, -3, 19], links: order))
            #expect(!NativeParagraphFragmentGrouping.connectedObservations([8, -3, 19, 42], links: order))
        }
        #expect(!NativeParagraphFragmentGrouping.connectedObservations([], links: []))
        #expect(!NativeParagraphFragmentGrouping.connectedObservations([8, 8], links: []))
        #expect(!NativeParagraphFragmentGrouping.connectedObservations([8], links: edges))
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func repeatedOriginalGuttersNeedIndependentIntervalWitnesses(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        for count in [3, 4, 6] { for indented in [false, true] {
            let columns = indented ? 3 : 2, bad = count / 2
            func input(fault: Int = 0, jitter: Bool = false, groups: Int? = nil) -> [ReaderTranslationRegion] {
                let groups = groups ?? count, hidden = fault == 3 || fault == 10
                let width = CGFloat(columns - 1) * 0.025 + 0.02
                let pitch = width + (fault == 13 ? 0.005 : fault == 14 ? 0.006 : 0.015)
                let total = groups * columns
                let boxes = (0..<(total + (hidden ? 1 : 0))).map { index -> CGRect in
                    if index == total {
                        return fault == 10 ? .init(x: 0.8, y: 0.1, width: 0.01, height: 0.02) :
                            .init(x: 0.1 + width + 0.003, y: 0.15, width: 0.006, height: 0.02)
                    }
                    let group = index / columns, col = index % columns
                    let shift: CGFloat = group >= bad ? (fault == 1 ? 0.003 : jitter ? 0.001 : 0) : 0
                    let short = indented && col == 1
                    let broken = fault == 9 && group == bad && col == columns - 1
                    return .init(x: 0.1 + CGFloat(group) * pitch + CGFloat(col) * 0.025 + shift,
                        y: broken ? 0.14 : short ? 0.14 : 0.1, width: 0.02, height: broken ? 0.14 : short ? 0.08 : 0.18)
                }
                let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                    let group = index / columns, x = Int((box.minX * 1000).rounded()) + 2
                    let y = Int((box.minY * 1000).rounded()) + (fault == 2 && group == bad ? 4 : 2)
                    let last = Int((box.maxY * 1000).rounded()) - 2
                    let component = Evidence.Component(seed: y * 1000 + x, pixelCount: (last - y) * 10, meanProbability: 0.95,
                        runs: (y..<last).map { .init(y: $0, x: x, count: 10) })
                    let orphan = Evidence.Component(seed: 90000 + x, pixelCount: 2, meanProbability: 0.95,
                        runs: [.init(y: 90, x: x, count: 2)])
                    let affected = group == bad && index % columns == 0
                    let mapWidth = fault == 12 && group == bad ? 1001 : 1000
                    let own = mapWidth == 1000 ? component : Evidence.Component(seed: y * mapWidth + x,
                        pixelCount: component.pixelCount, meanProbability: 0.95, runs: component.runs)
                    let evidence = Evidence(ownerID: "packet-\(index)", parentBoxIndex: index,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                        mapOriginX: 0, mapOriginY: 0, mapFullWidth: mapWidth, mapFullHeight: 1000,
                        sourceWidth: size, sourceHeight: size, components: [own], ownershipVersion: 2,
                        completeCCScan: true, ambiguousComponents: fault == 6 && affected ? [orphan] : [],
                        candidateComponents: fault == 11 && affected ?
                            [.init(component: orphan, competingOwnerIDs: ["foreign"], outsideCompetingCells: [1])] : [])
                    let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    let q: [CGPoint] = fault == 10 && index == total ? [] : [
                        .init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)]
                    return .init(polygon: q, text: "列\(index)本文", score: 0.95, orientation: .vertical,
                        detectorSeedEvidence: fault == 5 && affected ? nil : [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                var regions = (0..<groups).map { group -> ReaderTranslationRegion in
                    let ids = Array((group * columns)..<((group + 1) * columns))
                    var r = ReaderTranslationRegion(id: "block-\(group)", rect: ids.map { boxes[$0] }.reduce(CGRect.null) { $0.union($1) },
                        source: ids.reversed().map { lines[$0].text }.joined())
                    r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = false; r.sourceImageAspectRatio = 1
                    r.acceptedSource = .union(ids.map { bound[$0].acceptedSource })
                    if fault == 7 && group == bad {
                        let fresh = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                        r.acceptedSource = .union(ids.map { fresh[$0].acceptedSource })
                    }
                    if fault == 8 && group == bad {
                        r.balloonInterior = .init(rect: r.rect, center: .init(x: r.rect.midX, y: r.rect.midY),
                            spans: Array(repeating: [Double(r.rect.minX), Double(r.rect.maxX)], count: 8).flatMap { $0 }, contourVerified: true)
                    }
                    return r
                }
                if fault == 4 { regions.append(.init(id: "unknown", rect: .init(x: 0.1 + width + 0.003, y: 0.15, width: 0.006, height: 0.02), source: "別")) }
                return regions
            }
            for values in [input(), input(jitter: true)] { for ordered in [values, Array(values.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [])
                #expect(result.count == 1 && result[0].source == values.reversed().map(\.source).joined(),
                    "recurrent positive count=\(count) indented=\(indented) scale=\(scale)")
                let m = result[0].acceptedSource.membership!
                #expect(m.body == Set(0..<(count * columns)) && m.readings.isEmpty && m.unknownDedup.isEmpty)
                #expect(m.table === values[0].acceptedSource.membership!.table && !m.hasUntrackedInputs)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: []) == result)
            } }
            let values = input(), pair = input(groups: 2)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(pair, scopes: []) == pair)
            let separateQueries = values.enumerated().map { NativeParagraphFragmentGrouping.TextScope(owner: $0.offset, box: $0.element.rect, confidence: 0.95) }
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: separateQueries).count == 1)
            for fault in 1...14 {
                let negative = input(fault: fault), result = NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [])
                #expect(!result.contains { $0.acceptedSource.membership?.body == Set(0..<(count * columns)) },
                    "recurrent negative fault=\(fault) count=\(count) indented=\(indented) scale=\(scale)")
                let bodies = result.compactMap { $0.acceptedSource.membership?.body }.flatMap { $0 }
                #expect(bodies.count == count * columns && Set(bodies) == Set(0..<(count * columns)))
                if fault == 4 { #expect(result.contains { $0.id == "unknown" }) }
            }
        } }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func privateHeadsKeepUnclaimedAmbiguityUnowned(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        for count in [2, 3] {
            func input(fault: Int = 0, extra: Bool = true, profile: Int = 0) -> [ReaderTranslationRegion] {
                let foreign = fault == 1 || fault == 2 || fault == 8 || fault == 9
                let boxes = (0..<(count + (foreign ? 1 : 0))).map { index -> CGRect in
                    if index == count {
                        return fault == 2 ? .init(x: 0.18, y: 0.11, width: 0.008, height: 0.01) :
                            .init(x: 0.7, y: 0.1, width: 0.02, height: 0.08)
                    }
                    return .init(x: 0.2 - CGFloat(index) * 0.03, y: index == 1 ? 0.126 : 0.1,
                        width: 0.025, height: index == 1 ? 0.274 : 0.3)
                }
                let orphan = Evidence.Component(seed: 115183, pixelCount: 4, meanProbability: 0.95,
                    runs: [.init(y: 115, x: 183, count: 2), .init(y: 116, x: 183, count: 2)])
                let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                    let x = fault == 5 && index == 1 ? 240 : Int((box.midX * 1000).rounded()) - 3
                    let y = fault == 6 && index == 1 ? 180 : index == count ? 105 : 130
                    let last = index == count ? 170 : 397
                    let component = Evidence.Component(seed: y * 1000 + x, pixelCount: (last - y) * 6, meanProbability: 0.95,
                        runs: (y..<last).map { .init(y: $0, x: x, count: 6) })
                    let ambiguous = (index == 1 && extra && fault != 3) || (index == count && (fault == 1 || fault == 9))
                    let evidence = Evidence(ownerID: "column-\(index)", parentBoxIndex: index,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                        mapOriginX: fault == 9 && index == count ? 1 : 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                        sourceWidth: size, sourceHeight: size, components: fault == 4 && index == 1 ? [] : [component],
                        ownershipVersion: 2, completeCCScan: true, ambiguousComponents: ambiguous ? [orphan] : [],
                        candidateComponents: fault == 3 && index == 1 ?
                            [.init(component: orphan, competingOwnerIDs: ["foreign-owner"], outsideCompetingCells: [1])] : [])
                    let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    let polygon: [CGPoint] = fault == 8 && index == count ? [] : [
                        .init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)]
                    return .init(polygon: polygon, text: "列\(index)本文", score: 0.95, orientation: .vertical,
                        detectorSeedEvidence: [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                return (0..<count).map { index in
                    var region = ReaderTranslationRegion(id: "column-\(index)", rect: boxes[index], source: lines[index].text)
                    region.sourceOrientation = .vertical; region.sourceSingleVerticalColumn = true; region.sourceImageAspectRatio = 1
                    region.acceptedSource = bound[index].acceptedSource; region.detectorSeedEvidence = lines[index].detectorSeedEvidence
                    if fault == 10 && index == 1 { region.sourceImageAspectRatio = 1.2 }
                    if fault == 7 && index == 1 {
                        let m = region.acceptedSource.membership!
                        region.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [], unknownDedup: m.body, hasUntrackedInputs: false))
                    }
                    if profile != 0 && index == 1 {
                        region.balloonInterior = .init(rect: .init(x: 0.17, y: profile == 1 ? 0.14 : 0.12,
                            width: 0.025, height: profile == 1 ? 0.26 : 0.29),
                            center: .init(x: 0.1825, y: profile == 3 ? 0.45 : 0.25), spans: Array(repeating: [0.17, 0.195], count: 16).flatMap { $0 },
                            contourVerified: true)
                    }
                    return region
                }
            }
            let values = input(), scope = NativeParagraphFragmentGrouping.TextScope(owner: 4,
                box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.65)
            for initial in [values, input(extra: false), input(profile: 1), input(extra: false, profile: 1)] {
                for ordered in [initial, Array(initial.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
                #expect(result.count == 1 && result[0].source == initial.map(\.source).joined())
                let m = result[0].acceptedSource.membership!
                #expect(m.body == Set(0..<count) && m.readings.isEmpty && m.unknownDedup.isEmpty && !m.hasUntrackedInputs)
                #expect(m.table === initial[0].acceptedSource.membership!.table)
                let original = initial[1].acceptedSource.membership!.table.packets[1].detectorSeedEvidence![0]
                #expect(m.table.packets[1].detectorSeedEvidence![0] == original)
                #expect(result[0].detectorSeedEvidence?.first(where: { $0.ownerID == original.ownerID }) == original)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            } }
            for fault in 1...10 {
                let negative = input(fault: fault)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [scope]) == negative,
                    "private head fault=\(fault) count=\(count) scale=\(scale)")
            }
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: []) == values)
            // A complete native face remains authoritative; it must not be
            // silently treated as an absent profile by independent RF proofs.
            let completeFace = input(profile: 2)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(completeFace, scopes: [scope]) == completeFace)
            let invalidCenter = input(profile: 3)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(invalidCenter, scopes: [scope]) == invalidCenter)
            let wrongFrame = input(fault: 10, profile: 1)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(wrongFrame, scopes: [scope]) == wrongFrame)
            var unknown = values
            unknown.append(.init(id: "unknown", rect: .init(x: 0.185, y: 0.17, width: 0.01, height: 0.02), source: "別"))
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(unknown, scopes: [scope]) == unknown)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func commonColumnFramePreservesSlantedOriginalReading(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale), words = ["あいうえおかき", "さしすせそたちつてとなに", "はひふへほまみむめもやゆ"]
        for count in [2, 3] { for degrees: CGFloat in [-30, -10, 10, 30] {
            func input(fault: Int = 0) -> [ReaderTranslationRegion] {
                let total = count + (fault == 1 ? 1 : 0)
                let boxes = (0..<total).map { index -> CGRect in
                    if index == count { return .init(x: 0.223, y: 0.3, width: 0.004, height: 0.02) }
                    return .init(x: 0.23 - CGFloat(index) * 0.08, y: index == 0 ? 0.15 : 0.2,
                        width: 0.07, height: index == 0 ? 0.4 : 0.87)
                }
                let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                    let angle = (fault == 2 ? (index == 0 ? -30 : 30) : degrees) * .pi / 180
                    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                        .init(x: cos(angle) * x + sin(angle) * y + 0.5,
                              y: -sin(angle) * x + cos(angle) * y + 0.18)
                    }
                    var rows: [Int: Set<Int>] = [:]
                    let first = Int((box.minY * 1000).rounded()) + 5, last = Int((box.maxY * 1000).rounded()) - 5
                    for row in first..<last {
                        let p = point(box.midX, (CGFloat(row) + 0.5) / 1000)
                        let x = Int((p.x * 1000).rounded()), y = Int((p.y * 1000).rounded())
                        for cell in (x - 2)...(x + 2) { rows[y, default: []].insert(cell) }
                    }
                    let runs = rows.keys.sorted().map { y in
                        Evidence.Run(y: y, x: rows[y]!.min()!, count: rows[y]!.max()! - rows[y]!.min()! + 1)
                    }
                    let component = Evidence.Component(seed: runs[0].y * 2000 + runs[0].x,
                        pixelCount: runs.reduce(0) { $0 + $1.count }, meanProbability: 0.95, runs: runs)
                    let evidence = Evidence(ownerID: "column-\(index)", parentBoxIndex: index,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                        mapOriginX: 0, mapOriginY: 0, mapFullWidth: 2000, mapFullHeight: 2000,
                        sourceWidth: size * 2, sourceHeight: size * 2, components: fault == 3 && index == 0 ? [] : [component],
                        ownershipVersion: 2, completeCCScan: true,
                        ambiguousComponents: fault == 3 && index == 0 ? [component] : [], candidateComponents: [])
                    let q = [point(box.minX, box.minY), point(box.maxX, box.minY),
                        point(box.maxX, box.maxY), point(box.minX, box.maxY)].map {
                            CGPoint(x: $0.x * CGFloat(size), y: $0.y * CGFloat(size))
                        }
                    return .init(polygon: fault == 4 && index == 0 ? Array(q.prefix(3)) : q,
                        text: index == count ? "別" : words[index], score: 0.95, orientation: .vertical,
                        detectorSeedEvidence: fault == 5 && index == 0 ? nil : [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size * 2, height: size * 2)
                return (0..<count).map { index in
                    let q = lines[index].polygon.map { CGPoint(x: $0.x / CGFloat(size * 2), y: $0.y / CGFloat(size * 2)) }
                    let box = q.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                    var region = ReaderTranslationRegion(id: "column-\(index)", rect: box, source: words[index])
                    region.sourceOrientation = .vertical; region.sourceSingleVerticalColumn = true; region.sourceImageAspectRatio = 1
                    region.polygon = q
                    region.acceptedSource = bound[index].acceptedSource
                    return region
                }
            }
            let values = input(), scope = NativeParagraphFragmentGrouping.TextScope(owner: 4,
                box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.65)
            let projected = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(projected.count == 1,
                "slanted source unit count=\(count) degrees=\(degrees) scale=\(scale)")
            #expect(projected[0].acceptedSource.membership?.body.isSuperset(of: [0, 1]) == true)
            for ordered in [values, Array(values.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
                #expect(result.count == 1 && result[0].source == words.prefix(count).joined(),
                    "slanted positive count=\(count) degrees=\(degrees) scale=\(scale)")
                let m = result[0].acceptedSource.membership!
                #expect(m.body == Set(0..<count) && m.readings.isEmpty && m.unknownDedup.isEmpty && !m.hasUntrackedInputs)
                #expect(m.table === values[0].acceptedSource.membership!.table && m.table.packets[0].polygon.count == 4)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
            // Thirty-degree placement intentionally reverses global bbox-midX
            // for the first two observations. The original column frame must
            // supply their reading order rather than that fallback sort.
            if degrees == 30 { #expect(values[0].rect.midX < values[1].rect.midX) }
            for fault in 1...5 {
                let negative = input(fault: fault)
                let local = NativeParagraphFragmentGrouping.TextScope(owner: 4,
                    box: negative.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.65)
                if fault != 1 {
                    let preserved = NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [local])
                    #expect(preserved.count == negative.count,
                        "slanted proof fault=\(fault) count=\(count) degrees=\(degrees) scale=\(scale)")
                    #expect(preserved.allSatisfy { $0.acceptedSource.membership?.body.count == 1 })
                }
                // Other angles can already have legitimate incumbent column
                // links. This placement specifically requires the new frame;
                // retain any old partial links but never admit the full cohort.
                if degrees == 30 && count == 2 {
                    let rejected = NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [local])
                    #expect(!rejected.contains { $0.acceptedSource.membership?.body == Set(0..<count) },
                        "slanted admission fault=\(fault) count=\(count) scale=\(scale)")
                }
            }
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: []) == values)
        } }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func horizontalInventoryVetoIsLocalToItsOriginalComponent(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        for columns in [2, 4] {
            func input(fault: Int = 0) -> [ReaderTranslationRegion] {
                let boxes = (0..<(columns + (fault == 6 ? 5 : 4))).map { index -> CGRect in
                    if index == columns + 4 { return .init(x: 0.105, y: 0.22, width: 0.012, height: 0.015) }
                    if index == columns + 3 {
                        return .init(x: fault == 1 ? 0.105 : 0.405, y: 0.22, width: 0.012, height: 0.015)
                    }
                    if index > columns {
                        return .init(x: 0.38 + Double(index - columns - 1) * 0.03, y: 0.1, width: 0.02, height: 0.16)
                    }
                    return .init(x: 0.1 + Double(index) * 0.025, y: 0.1, width: 0.02, height: 0.16)
                }
                let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                    let x = Int((box.minX * 1000).rounded()) + 2, y = Int((box.minY * 1000).rounded()) + 2
                    let length = Int((box.height * 1000).rounded()) - 4
                    let component = Evidence.Component(seed: y * 1000 + x, pixelCount: length * 6, meanProbability: 0.95,
                        runs: (y..<(y + length)).map { .init(y: $0, x: x, count: 6) })
                    let evidence = Evidence(ownerID: "source-\(index)", parentBoxIndex: index,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                        mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                        sourceWidth: size, sourceHeight: size, components: [component], ownershipVersion: 2,
                        completeCCScan: true, ambiguousComponents: fault == 2 && index == columns + 3 ? [component] : [], candidateComponents: [])
                    let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: "列\(index)文",
                        score: 0.95, orientation: index == columns + 3 ? .horizontal : .vertical,
                        detectorSeedEvidence: fault == 3 && index == columns + 3 ? nil : [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                let groups = [Array(0..<columns), [columns], [columns + 1, columns + 2], [columns + 3]]
                return groups.enumerated().compactMap { index, ids in
                    var region = ReaderTranslationRegion(id: "part-\(index)",
                        rect: ids.map { boxes[$0] }.reduce(CGRect.null) { $0.union($1) },
                        source: ids.reversed().map { lines[$0].text }.joined())
                    region.sourceOrientation = index == 3 ? .horizontal : .vertical
                    region.sourceSingleVerticalColumn = ids.count == 1 && index != 3; region.sourceImageAspectRatio = 1
                    if fault != 4 || index != 3 { region.acceptedSource = .union(ids.map { bound[$0].acceptedSource }) }
                    if fault == 5 && index == 3 {
                        region.acceptedSource = NativeOCRAcceptedSource.bindingPrimary([lines[columns + 3]], width: size, height: size)[0].acceptedSource
                    }
                    return region
                }
            }
            let values = input(), scope = NativeParagraphFragmentGrouping.TextScope(owner: 7,
                box: values.prefix(3).map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.65)
            for ordered in [values, Array(values.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
                #expect(result.count == 3)
                #expect(result.contains { $0.acceptedSource.membership?.body == Set(0...columns) &&
                    $0.source == values[1].source + values[0].source })
                #expect(result.contains(values[2]) && result.contains(values[3]))
                #expect(result.allSatisfy { $0.acceptedSource.membership?.table === values[0].acceptedSource.membership?.table })
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
            for fault in 1...6 {
                let negative = input(fault: fault)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [scope]) == negative,
                    "horizontal inventory fault=\(fault) columns=\(columns) scale=\(scale)")
            }
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: []) == values)
            let broad = NativeParagraphFragmentGrouping.TextScope(owner: 7, box: scope.box.insetBy(dx: -0.05, dy: -0.05), confidence: 0.95)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [broad]) == values)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func closedOriginalColumnsPreserveIndentedHeads(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale), words = ["あいうえおかきくけ", "さしすせそたちつ", "なにぬねのはひ"]
        func input(fault: Int = 0) -> [ReaderTranslationRegion] {
            let boxes: [CGRect] = [
                .init(x: 0.16, y: 0.05, width: 0.024, height: 0.153),
                .init(x: 0.182, y: 0.07, width: 0.014, height: fault == 1 ? 0.09 : 0.133),
                .init(x: 0.196, y: fault == 2 ? 0.085 : 0.05, width: 0.025, height: fault == 2 ? 0.118 : 0.122)]
            let count = fault == 3 ? 4 : 3
            let lines = (0..<count).map { index -> NativeCoreMLOCRLine in
                let box = index == 3 ? CGRect(x: 0.185, y: 0.055, width: 0.006, height: 0.01) : boxes[index]
                let x = Int((box.midX * 1000).rounded()) - 3, y = Int((box.minY * 1000).rounded()) + 3
                let length = Int((box.height * 1000).rounded()) - 6
                let component = Evidence.Component(seed: y * 1000 + x, pixelCount: length * 6, meanProbability: 0.95,
                    runs: (y..<(y + length)).map { .init(y: $0, x: x, count: 6) })
                let evidence = Evidence(ownerID: "column-\(index)", parentBoxIndex: index,
                    provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                    mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                    sourceWidth: size, sourceHeight: size, components: fault == 4 && index == 1 ? [] : [component],
                    ownershipVersion: 2, completeCCScan: true,
                    ambiguousComponents: fault == 4 && index == 1 ? [component] : [], candidateComponents: [])
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                let polygon: [CGPoint] = index == 0 ? [
                    .init(x: b.minX + b.width * 0.2, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX - b.width * 0.2, y: b.maxY), .init(x: b.minX, y: b.maxY)] : [
                    .init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)]
                return .init(polygon: polygon, text: index == 3 ? "別" : words[index], score: 0.95,
                    orientation: .vertical, detectorSeedEvidence: fault == 5 && index == 1 ? nil : [evidence])
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: words[1] + words[0])
            body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
            body.acceptedSource = .union(bound.prefix(2).map(\.acceptedSource))
            if fault == 6 {
                let m = body.acceptedSource.membership!
                body.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [], unknownDedup: [1], hasUntrackedInputs: false))
            }
            var peer = ReaderTranslationRegion(id: "peer", rect: boxes[2], source: words[2])
            peer.sourceOrientation = .vertical; peer.sourceSingleVerticalColumn = true; peer.sourceImageAspectRatio = 1
            peer.acceptedSource = bound[2].acceptedSource
            var result = [body, peer]
            if fault == 7 { result.append(.init(id: "untracked", rect: .init(x: 0.185, y: 0.055, width: 0.006, height: 0.01), source: "別")) }
            return result
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 4,
            box: .init(x: 0.158, y: 0.048, width: 0.066, height: 0.158), confidence: 0.95)
        for values in [input(), Array(input().reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count == 1 && result[0].source == words[2] + words[1] + words[0])
            let m = result[0].acceptedSource.membership!
            #expect(m.body == [0, 1, 2] && m.readings.isEmpty && m.unknownDedup.isEmpty && !m.hasUntrackedInputs)
            #expect(m.table === values[0].acceptedSource.membership!.table)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
        }
        for fault in 1...7 {
            let values = input(fault: fault)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
        }
        for scopes: [NativeParagraphFragmentGrouping.TextScope] in [[],
            [.init(owner: 4, box: scope.box, confidence: 0.79)],
            [scope, .init(owner: 5, box: scope.box, confidence: 0.95)]] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(input(), scopes: scopes) == input())
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func overlappingSelectedReadRequiresExactPrivatePartition(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        func fixture(fault: Int = 0) -> [ReaderTranslationRegion] {
            let boxes: [CGRect] = [
                .init(x: 0.34, y: 0.1, width: 0.03, height: 0.1),
                .init(x: 0.34, y: 0.22, width: 0.03, height: 0.12),
                .init(x: 0.34, y: 0.1, width: 0.03, height: 0.24),
                .init(x: 0.30, y: 0.1, width: 0.03, height: 0.24)]
            func record(_ index: Int) -> Evidence {
                let box = boxes[index], x = Int((box.midX * 1000).rounded()) - 4
                let y = Int((box.minY * 1000).rounded()) + 3, length = Int((box.height * 1000).rounded()) - 6
                let component = Evidence.Component(seed: y * 1000 + x, pixelCount: length * 8, meanProbability: 0.95,
                    runs: (y..<(y + length)).map { .init(y: $0, x: x, count: 8) })
                return .init(ownerID: "source-\(index)", parentBoxIndex: index, provenance: "db-complete-cc-candidates-v2",
                    threshold: 0.9, mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                    sourceWidth: size, sourceHeight: size, components: fault == 3 && index == 0 ? [] : [component],
                    ownershipVersion: 2, completeCCScan: true,
                    ambiguousComponents: fault == 3 && index == 0 ? [component] : [], candidateComponents: [])
            }
            var top = record(0)
            if fault == 2 { top = record(1) } // Same broad scope cannot replace exact record identity.
            let texts = ["旧観測文", "末尾文句", fault == 8 ? "別の全体観測文" : "新観測文章末尾文句", "独立左側文章保持"]
            let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: texts[index], score: 0.95,
                    orientation: .vertical, detectorSeedEvidence: fault == 1 && index == 2 ? nil :
                        index == 2 ? [top, record(1)] : [record(index)])
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            let table = bound[0].acceptedSource.membership!.table
            var selected = ReaderTranslationRegion(id: "selected", rect: boxes[2], source: texts[2])
            selected.sourceOrientation = .vertical; selected.sourceSingleVerticalColumn = true
            selected.sourceImageAspectRatio = 1
            selected.acceptedSource = .init(.init(table: table, body: [2, 1], readings: [],
                unknownDedup: [1], hasUntrackedInputs: fault == 4))
            var peer = ReaderTranslationRegion(id: "peer", rect: boxes[0].union(boxes[3]), source: texts[0] + texts[3])
            peer.sourceOrientation = .vertical; peer.sourceSingleVerticalColumn = false; peer.sourceImageAspectRatio = 1
            peer.acceptedSource = .union([bound[0].acceptedSource, bound[3].acceptedSource])
            peer.auxiliaryInkRects = [boxes[0]]
            peer.auxiliaryInkPolygons = [[.init(x: 0.34, y: 0.1), .init(x: 0.37, y: 0.1), .init(x: 0.37, y: 0.2)]]
            peer.polygon = [.init(x: peer.rect.minX, y: peer.rect.minY), .init(x: peer.rect.maxX, y: peer.rect.minY),
                .init(x: peer.rect.maxX, y: peer.rect.maxY), .init(x: peer.rect.minX, y: peer.rect.maxY)]
            peer.isRecoveredLine = true
            if fault == 5 { peer.acceptedSource = .init() }
            if fault == 9 {
                let other = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                peer.acceptedSource = .union([other[0].acceptedSource, other[3].acceptedSource])
            }
            var result = [selected, peer]
            if fault == 6 {
                result.append(.init(id: "untracked-interior", rect: .init(x: 0.335, y: 0.16, width: 0.003, height: 0.03), source: "別"))
            }
            if fault == 7 {
                var competitor = peer
                competitor = .init(id: "competing", rect: peer.rect, source: peer.source)
                competitor.sourceOrientation = .vertical; competitor.sourceImageAspectRatio = 1
                competitor.acceptedSource = peer.acceptedSource
                result.append(competitor)
            }
            return result
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 4,
            box: .init(x: 0.29, y: 0.09, width: 0.09, height: 0.26), confidence: 0.95)
        for input in [fixture(), fixture().reversed().map { $0 }] {
            var events: [[String]] = []
            let output = NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [scope], didCoalesce: { events.append($0) })
            #expect(output.count == 1)
            guard let value = output.first, let m = value.acceptedSource.membership else { return }
            #expect(value.source == "新観測文章末尾文句独立左側文章保持")
            #expect(m.body == [2, 3] && m.readings == [0, 1] && m.unknownDedup.isEmpty && !m.hasUntrackedInputs)
            #expect(m.table === input[0].acceptedSource.membership!.table && m.table.packets[0].text == "旧観測文")
            #expect(value.auxiliaryInkRects == input.first(where: { $0.id == "peer" })!.auxiliaryInkRects && value.isRecoveredLine)
            #expect(value.auxiliaryInkPolygons.contains(input.first(where: { $0.id == "peer" })!.polygon))
            #expect(value.unitMemberRects.contains(input.first(where: { $0.id == "peer" })!.rect))
            #expect(events.count == 1 && Set(events[0]) == ["selected", "peer"])
            let second = NativeParagraphFragmentGrouping.reconcilingObservations(output, scopes: [scope])
            #expect(second == output && second[0].acceptedSource.membership!.readings == [0, 1])
        }
        for fault in 1...9 {
            let input = fixture(fault: fault)
            let output = NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [scope])
            #expect(output.count == input.count)
            let selected = output.first(where: { $0.id == "selected" })!
            #expect(selected.source == input[0].source && selected.acceptedSource.membership!.unknownDedup == [1])
        }
        for scopes: [NativeParagraphFragmentGrouping.TextScope] in [[],
            [.init(owner: 4, box: scope.box, confidence: 0.79)],
            [scope, .init(owner: 5, box: scope.box, confidence: scope.confidence)]] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(fixture(), scopes: scopes).count == 2)
        }
    }

    @Test func nestedObservationsRetainPrimaryAndRejectAmbiguity() {
        var body = ReaderTranslationRegion(id: "primary", rect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.3), source: "今日は良い天気")
        body.confidence = 0.93
        let child = ReaderTranslationRegion(id: "detail", rect: .init(x: 0.15, y: 0.15, width: 0.02, height: 0.03), source: "良い")
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 0, box: body.rect, confidence: 0.9)
        for input in [[body, child], [child, body]] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [scope])
            #expect(result.count == 1 && result[0].id == body.id)
            #expect(result[0].source == body.source && result[0].rect == body.rect && result[0].confidence == body.confidence)
            #expect(Set(result[0].unitMemberRects.map { $0.debugDescription }) == Set(input.map { $0.rect.debugDescription }))
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: []) == input)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [
                .init(owner: 0, box: body.rect, confidence: 0.79)]) == input)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [scope,
                .init(owner: 1, box: body.rect, confidence: 0.9)]) == input)
        }
        let different = ReaderTranslationRegion(id: "different", rect: child.rect, source: "違う文")
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([body, different], scopes: [scope]) == [body, different])
        let second = ReaderTranslationRegion(id: "competing", rect: body.rect, source: body.source + "です")
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([body, second, child], scopes: [scope])
            .first(where: { $0.id == child.id }) != nil)
        body.balloonInterior = .init(rect: body.rect, center: .init(x: 0.2, y: 0.2), spans: [0.1, 0.3], contourVerified: true)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([body, child], scopes: [scope]) == [body, child])
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func columnContinuationPreservesInterveningMarks(scale: CGFloat) {
        func region(_ id: String, _ source: String, _ rect: CGRect,
                    _ orientation: BrowserOCRSourceOrientation = .vertical) -> ReaderTranslationRegion {
            var r = ReaderTranslationRegion(id: id, rect: rect.applying(.init(scaleX: scale, y: scale)), source: source)
            r.sourceOrientation = orientation; r.sourceImageAspectRatio = 1
            return r
        }
        let upper = region("upper", "続く…", .init(x: 0.1, y: 0.1, width: 0.02, height: 0.1))
        let mark = region("mark", "っ", .init(x: 0.106, y: 0.205, width: 0.008, height: 0.01), .horizontal)
        let lower = region("lower", "文章", .init(x: 0.1, y: 0.23, width: 0.02, height: 0.1))
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 4, box: upper.rect.union(lower.rect), confidence: 0.6)
        for input in [[upper, mark, lower], [lower, upper, mark]] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [scope])
            #expect(result.count == 1 && result[0].source == "続く…っ文章")
            #expect(result[0].unitMemberRects.count == 3 && result[0].rect == upper.rect.union(lower.rect))
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: []) == input)
        }
        let splitScopes = [upper, lower].enumerated().map {
            NativeParagraphFragmentGrouping.TextScope(owner: $0.offset, box: $0.element.rect, confidence: 0.9)
        }
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([upper, lower], scopes: splitScopes).count == 2)
        let outside = region("far", "別の文章", .init(x: 0.2, y: 0.23, width: 0.02, height: 0.1))
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([upper, outside], scopes: [
            .init(owner: 4, box: upper.rect.union(outside.rect), confidence: 0.9)]).count == 2)
        var compactTail = [
            NativeParagraphFragmentGrouping.Atom(index: 0, source: "本文", box: CGRect(x: 0.10, y: 0.10, width: 0.02, height: 0.12)
                .applying(.init(scaleX: scale, y: scale)), orientation: .vertical, owner: 1, sourceColumnWidth: 0.02 * scale),
            NativeParagraphFragmentGrouping.Atom(index: 1, source: "符", box: CGRect(x: 0.105, y: 0.215, width: 0.01, height: 0.018)
                .applying(.init(scaleX: scale, y: scale)), orientation: .vertical, owner: 1, sourceColumnWidth: 0.018 * scale)
        ]
        #expect(NativeParagraphFragmentGrouping.columnRelations(atoms: compactTail).count == 1)
        compactTail[1].sourceColumnWidth = nil
        // A possible geometric continuation cannot certify a source whose
        // original column evidence is unavailable. Exercise the admission API,
        // rather than the retired helper's combined geometry/evidence gate.
        let untracked = compactTail.map { atom -> ReaderTranslationRegion in
            var value = ReaderTranslationRegion(id: "untracked-\(atom.index)", rect: atom.box, source: atom.source)
            value.sourceOrientation = .vertical
            value.sourceSingleVerticalColumn = true
            return value
        }
        let context = NativeParagraphFragmentGrouping.TextScope(owner: 1,
            box: untracked.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(untracked, scopes: [context]) == untracked)
        #expect(untracked.allSatisfy { $0.acceptedSource.membership == nil })
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func multiColumnTailRequiresScopeCoverage(scale: CGFloat) {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.08, height: 0.12).applying(.init(scaleX: scale, y: scale))
        var body = ReaderTranslationRegion(id: "body", rect: box, source: "右の列左の列")
        body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false
        var tail = ReaderTranslationRegion(id: "tail", rect: CGRect(x: 0.1, y: 0.23, width: 0.02, height: 0.08)
            .applying(.init(scaleX: scale, y: scale)), source: "続き")
        tail.sourceOrientation = .vertical; tail.sourceSingleVerticalColumn = true
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: box.union(tail.rect), confidence: 0.9)
        for input in [[body, tail], [tail, body]] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [scope])
            #expect(result.count == 1 && result[0].source == body.source + tail.source)
            #expect(result[0].unitMemberRects.count == 2)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            let broad = NativeParagraphFragmentGrouping.TextScope(owner: 1,
                box: scope.box.insetBy(dx: -0.1 * scale, dy: -0.1 * scale), confidence: 0.9)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [broad]) == input)
        }
        var duplicate = ReaderTranslationRegion(id: tail.id, rect: tail.rect, source: "左の列")
        duplicate.sourceOrientation = .vertical; duplicate.sourceSingleVerticalColumn = true
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([body, duplicate], scopes: [scope]).count == 2)
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func measuredColumnsRequireIndependentAgreement(scale: CGFloat) {
        func region(_ id: String, _ x: CGFloat, _ source: String) -> ReaderTranslationRegion {
            var r = ReaderTranslationRegion(id: id,
                rect: CGRect(x: x, y: 0.1, width: 0.02, height: 0.12).applying(.init(scaleX: scale, y: scale)), source: source)
            r.sourceOrientation = .vertical
            let face = CGRect(x: 0.08, y: 0.08, width: 0.1, height: 0.16).applying(.init(scaleX: scale, y: scale))
            r.balloonInterior = .init(rect: face, center: .init(x: r.rect.midX, y: r.rect.midY),
                spans: [0.08 * Double(scale), 0.18 * Double(scale)], contourVerified: true)
            return r
        }
        let right = region("right", 0.14, "右の列"), left = region("left", 0.11, "左の列")
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 2, box: right.rect.union(left.rect), confidence: 0.95)
        for input in [[left, right], [right, left]] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [scope])
            #expect(result.count == 1 && result[0].source == right.source + left.source)
            #expect(result[0].rect == right.rect.union(left.rect))
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: []) == input)
        }
        var disjoint = left
        disjoint.balloonInterior = .init(rect: left.balloonInterior!.rect, center: left.balloonInterior!.center,
            spans: [0.01 * Double(scale), 0.04 * Double(scale)], contourVerified: true)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([right, disjoint], scopes: [scope]).count == 2)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([right, disjoint], scopes: [scope],
            balloons: commonModeledBalloon([right, disjoint])).count == 1)
        disjoint.balloonInterior?.contourVerified = false
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([right, disjoint], scopes: [scope],
            balloons: commonModeledBalloon([right, disjoint])).count == 2)
        disjoint = left
        disjoint.balloonInterior = .init(rect: left.balloonInterior!.rect, center: .zero,
            spans: left.balloonInterior!.spans, contourVerified: true)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([right, disjoint], scopes: [scope],
            balloons: commonModeledBalloon([right, disjoint])).count == 2)
        let axes = [
            NativeParagraphFragmentGrouping.Atom(index: 0, source: "本文", box: CGRect(x: 0.10, y: 0.10, width: 0.018, height: 0.15)
                .applying(.init(scaleX: scale, y: scale)), orientation: .vertical, owner: 1, sourceColumnWidth: 0.03 * scale),
            NativeParagraphFragmentGrouping.Atom(index: 1, source: "末尾", box: CGRect(x: 0.08, y: 0.12, width: 0.014, height: 0.08)
                .applying(.init(scaleX: scale, y: scale)), orientation: .vertical, owner: 1, sourceColumnWidth: 0.03 * scale)
        ]
        let measuredEdges = NativeParagraphFragmentGrouping.measuredColumnEdges(atoms: axes, allowing: { id in axes.first { $0.index == id }?.sourceColumnWidth != nil })
        #expect(measuredEdges.count == 1)
        var unmeasuredAxes = axes
        for i in unmeasuredAxes.indices { unmeasuredAxes[i].sourceColumnWidth = nil }
        let unmeasuredEdges = NativeParagraphFragmentGrouping.measuredColumnEdges(atoms: unmeasuredAxes, allowing: { id in unmeasuredAxes.first { $0.index == id }?.sourceColumnWidth != nil })
        #expect(unmeasuredEdges.isEmpty)
        var partitionedRight = right, partitionedLeft = left
        var rightBands = Array(repeating: [0.125 * Double(scale), 0.18 * Double(scale)], count: 4).flatMap { $0 }
        let leftBands = Array(repeating: [0.08 * Double(scale), 0.125 * Double(scale)], count: 4).flatMap { $0 }
        partitionedRight.balloonInterior = .init(rect: right.balloonInterior!.rect, center: right.balloonInterior!.center,
            spans: rightBands, contourVerified: true)
        partitionedLeft.balloonInterior = .init(rect: left.balloonInterior!.rect, center: left.balloonInterior!.center,
            spans: leftBands, contourVerified: true)
        for values in [[partitionedRight, partitionedLeft], [partitionedLeft, partitionedRight]] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count == 1 && result[0].source == right.source + left.source)
        }
        rightBands[2] = 0.126 * Double(scale)
        partitionedRight.balloonInterior = .init(rect: right.balloonInterior!.rect, center: right.balloonInterior!.center,
            spans: rightBands, contourVerified: true)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([partitionedRight, partitionedLeft], scopes: [scope]).count == 2)
        var nativeRight = right
        var nativeLeft = ReaderTranslationRegion(id: left.id, rect: left.rect.offsetBy(dx: -0.015 * scale, dy: 0), source: left.source)
        nativeLeft.sourceOrientation = .vertical; nativeLeft.sourceSingleVerticalColumn = true
        let nativeRegions = [nativeRight, nativeLeft]
        let lines = nativeRegions.map { region -> NativeCoreMLOCRLine in
            let box = region.rect.applying(.init(scaleX: 1000, y: 1000))
            return .init(polygon: [.init(x: box.minX, y: box.minY), .init(x: box.maxX, y: box.minY),
                .init(x: box.maxX, y: box.maxY), .init(x: box.minX, y: box.maxY)], text: region.source, score: 0.95, orientation: .vertical)
        }
        let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: 1000, height: 1000)
        let commonFace = ReaderTranslationBalloonInterior(rect: right.balloonInterior!.rect,
            center: .init(x: 0.13 * scale, y: 0.15 * scale), spans: [0.08 * Double(scale), 0.18 * Double(scale)], contourVerified: true)
        nativeRight.balloonInterior = commonFace; nativeLeft.balloonInterior = commonFace
        nativeRight.acceptedSource = bound[0].acceptedSource; nativeLeft.acceptedSource = bound[1].acceptedSource
        nativeRight.sourceImageAspectRatio = 1; nativeLeft.sourceImageAspectRatio = 1
        let nativeResult = NativeParagraphFragmentGrouping.reconcilingObservations([nativeRight, nativeLeft], scopes: [])
        #expect(nativeResult.count == 1 && nativeResult[0].source == nativeRight.source + nativeLeft.source)
        nativeLeft.balloonInterior = .init(rect: commonFace.rect, center: commonFace.center,
            spans: [0.08 * Double(scale), 0.17 * Double(scale)], contourVerified: true)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([nativeRight, nativeLeft], scopes: []).count == 2)
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func modelShortColumnRequiresCompleteMaskSupportAndExhaustiveTextScope(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let width = Int(1000 * scale)
        for aspect in [1.0, 1.25] {
            let height = Int(Double(width) / aspect)
            func input(bothLong: Bool = false, wideGlyph: Bool = false, candidateOnly: Bool = false,
                       missingEvidence: Bool = false, outside: Bool = false, ambiguousOutside: Bool = false,
                       hole: Bool = false, differentMask: Bool = false, malformed: Bool = false,
                       uncertain: Bool = false, sameTable: Bool = true, model: Bool = true,
                       sourceConflict: Bool = false) -> [ReaderTranslationRegion] {
                let boxes = [CGRect(x: 0.16, y: 0.1, width: wideGlyph ? 0.04 : 0.02, height: bothLong ? 0.18 : 0.06),
                             CGRect(x: 0.13, y: 0.1, width: 0.02, height: 0.2)]
                let words = ["短文", "長い本文の列"]
                func component(_ x: Int, _ tall: Int) -> Evidence.Component {
                    .init(seed: 110000 + x, pixelCount: tall * 5, meanProbability: 0.95,
                        runs: (110..<(110 + tall)).map { .init(y: $0, x: x, count: 5) })
                }
                let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
                    let b = box.applying(.init(scaleX: CGFloat(width), y: CGFloat(height)))
                    let own = component(i == 0 ? (outside ? 205 : 165) : 135, i == 0 ? (bothLong ? 160 : 40) : 180)
                    let borrowed = i == 0 && candidateOnly
                    let evidence = Evidence(ownerID: i == 0 ? "short" : "left", parentBoxIndex: i,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9, mapOriginX: 0, mapOriginY: 0,
                        mapFullWidth: 1000, mapFullHeight: 1000, sourceWidth: width, sourceHeight: height,
                        components: borrowed ? [] : [own], ownershipVersion: 2, completeCCScan: true,
                        ambiguousComponents: i == 0 && ambiguousOutside ? [component(205, 2)] : [],
                        candidateComponents: borrowed ? [.init(component: own, competingOwnerIDs: ["left"], outsideCompetingCells: [1])] : [])
                    #expect(evidence.isValid)
                    return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95,
                        orientation: .vertical, detectorSeedEvidence: i == 1 && missingEvidence ? nil : [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: width, height: height)
                return boxes.enumerated().map { i, box -> ReaderTranslationRegion in
                    var r = ReaderTranslationRegion(id: "column-\(i)", rect: box, source: words[i])
                    r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = true; r.sourceImageAspectRatio = aspect
                    r.acceptedSource = bound[i].acceptedSource
                    if i == 0 && !sameTable {
                        r.acceptedSource = NativeOCRAcceptedSource.bindingPrimary([lines[i]], width: width, height: height)[0].acceptedSource
                    }
                    if i == 0 && uncertain {
                        let m = r.acceptedSource.membership!
                        r.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [], unknownDedup: m.body, hasUntrackedInputs: false))
                    }
                    var spans: [Double] = Array(repeating: [0.11, 0.19], count: 4).flatMap { $0 }
                    if hole { spans[2] = -1; spans[3] = -1 }
                    if i == 0 && differentMask { spans[0] = 0.115 }
                    if i == 0 && sourceConflict { spans[0] = 0.14 }
                    if malformed { spans.removeLast() }
                    r.balloonInterior = .init(rect: .init(x: 0.11, y: 0.08, width: 0.08, height: 0.26),
                        center: .init(x: box.midX, y: 0.24), spans: spans, contourVerified: false, modelEstimated: model)
                    return r
                }
            }
            let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
                box: .init(x: 0.13, y: 0.1, width: 0.05, height: 0.2), confidence: 0.95)
            for values in [input(), Array(input().reversed()), input(bothLong: true), input(differentMask: true)] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
                #expect(result.count == 1 && result[0].source == "短文長い本文の列")
                #expect(result[0].acceptedSource.membership?.body == Set([0, 1]))
                #expect(result[0].balloonInterior?.contourVerified != true)
                #expect(result[0].unitMemberRects.count == 2)
                #expect(values.allSatisfy { result[0].rect.insetBy(dx: -1e-12, dy: -1e-12).contains($0.rect) })
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
            for (index, values) in [input(wideGlyph: true), input(candidateOnly: true),
                           input(missingEvidence: true), input(outside: true), input(ambiguousOutside: true),
                           input(hole: true), input(sourceConflict: true), input(malformed: true),
                           input(uncertain: true), input(sameTable: false), input(model: false)].enumerated() {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values,
                    "model-column negative \(index)")
            }
            let differentBackground = input(differentMask: true)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(differentBackground,
                scopes: [.init(owner: scope.owner, box: scope.box, confidence: 0.79)]) == differentBackground)
            let broad = NativeParagraphFragmentGrouping.TextScope(owner: 1,
                box: .init(x: 0.09, y: 0.06, width: 0.11, height: 0.3), confidence: 0.95)
            let partial = input()
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(partial, scopes: [broad]) == partial)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(partial, scopes: []) == partial)
            let wide = input(wideGlyph: true)
            let wideScope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
                box: .init(x: 0.13, y: 0.1, width: 0.07, height: 0.2), confidence: 0.95)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(wide, scopes: [wideScope]) == wide)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func modelOriginalGridRequiresClosedCompleteCohort(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let width = Int(1000 * scale)
        for blocks in [2, 3] { for columns in [2, 3] { for aspect in [1.0, 1.25] {
            let height = Int(Double(width) / aspect), count = blocks * columns
            let originalBoxes = (0..<count).map { CGRect(x: 0.1 + Double($0) * 0.025, y: 0.1, width: 0.02, height: 0.2) }
            let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
                box: originalBoxes.reduce(CGRect.null) { $0.union($1) }, confidence: 0.75)
            // One explicit modeled RF owner replaces the old unconditional
            // callback. Its paper envelope supplies context, not source ownership.
            func commonModeledBalloon(_ regions: [ReaderTranslationRegion]) -> [NativeParagraphFragmentGrouping.TextScope] {
                let papers = regions.compactMap { region in
                    region.balloonInterior.flatMap { $0.modelEstimated == true ? $0.rect : nil }
                }
                let box = papers.reduce(CGRect.null) { $0.union($1) }
                return box.isNull || box.isEmpty ? [] : [.init(owner: 42, box: box, confidence: 0.95)]
            }
            func input(missing: Bool = false, model: Bool = true, otherCaption: Bool = false,
                       singleFirst: Bool = false, allSingle: Bool = false,
                       croppedProfile: Bool = false, differentBand: Bool = false,
                       missingProfile: Bool = false, separatedColumns: Bool = false,
                       shortLeading: Bool = false, raggedBody: Bool = false,
                       longPrefix: Bool = false, trailingPrefix: Bool = false,
                       compactStrip: Bool = false, comparablePrefix: Bool = false,
                       offsetProfile: Bool = false, differentHull: Bool = false,
                       nonNestedProfile: Bool = false, candidateOutsideCrop: Bool = false,
                       internalRaggedBody: Bool = false, alignedTail: Bool = false,
                       inkStartShift: Int = 0, inkEndShift: Int = 0, differentDetectorGrid: Bool = false,
                       leadingColumns: Int = 1, leadingInkShift: Int = 0,
                       nativeSideColumn: Bool = false, nativeHullMismatch: Bool = false,
                       nativeBody: Bool = false, nativeSourceClipped: Bool = false,
                       sourceBandConflict: Bool = false) -> [ReaderTranslationRegion] {
                let boxes = originalBoxes.enumerated().map { i, box in
                    var value = box.offsetBy(dx: separatedColumns && i >= columns ? 0.06 : 0, dy: 0)
                    if shortLeading && i == count - 1 {
                        value.size.height = longPrefix ? 0.36 : alignedTail ? 0.2 : comparablePrefix ? 0.16 : 0.06
                        if trailingPrefix { value.origin.x -= CGFloat(count) * 0.025 }
                    }
                    if shortLeading && raggedBody && i == 0 { value.size.height = 0.1 }
                    if internalRaggedBody && i == 1 { value.size.height = 0.1 }
                    if compactStrip { value.size.height = raggedBody && i == 0 ? 0.04 : 0.08 }
                    return value
                }
                let words = (0..<count).map { i in
                    internalRaggedBody && i == 1 ? "短文" : compactStrip ? "列\(i)文" :
                        shortLeading && i == count - 1 && !alignedTail ? "短\(i)文" : "列\(shortLeading ? i : i % columns)本文"
                }
                let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
                    let b = box.applying(.init(scaleX: CGFloat(width), y: CGFloat(height))), x = Int((box.minX * 1000).rounded()) + 5
                    let start = Int((box.minY * 1000).rounded()) + 10 + (alignedTail && i == count - 1 ? inkStartShift : 0) +
                        (shortLeading && i == count - 1 ? leadingInkShift : 0)
                    let end = Int(((box.minY + box.height) * 1000).rounded()) - 10 + (alignedTail && i == count - 1 ? inkEndShift : 0)
                    let component = Evidence.Component(seed: start * 1000 + x, pixelCount: (end - start) * 5, meanProbability: 0.95,
                        runs: (start..<end).map { .init(y: $0, x: x, count: 5) })
                    let evidence = Evidence(ownerID: "column-\(i)", parentBoxIndex: i,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9, mapOriginX: 0, mapOriginY: 0,
                        mapFullWidth: 1000, mapFullHeight: differentDetectorGrid && i == count - 1 ? 1002 : 1000,
                        sourceWidth: width, sourceHeight: height,
                        components: [component], ownershipVersion: 2, completeCCScan: true,
                        ambiguousComponents: [], candidateComponents: candidateOutsideCrop && i == 0 ? [
                            .init(component: .init(seed: 495000 + x, pixelCount: 5, meanProbability: 0.95,
                                runs: [.init(y: 495, x: x, count: 5)]), competingOwnerIDs: ["foreign-column"], outsideCompetingCells: [1])
                        ] : [])
                    #expect(evidence.isValid)
                    return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95,
                        orientation: .vertical, detectorSeedEvidence: missing && i == 0 ? nil : [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: width, height: height)
                let groups = shortLeading ? [Array(0..<(count - leadingColumns))] + ((count - leadingColumns)..<count).map { [$0] } :
                    (0..<blocks).flatMap { block -> [[Int]] in
                    let ids = Array((block * columns)..<((block + 1) * columns))
                    return allSingle || (singleFirst && block == 0) ? ids.map { [$0] } : [ids]
                }
                var result = groups.enumerated().map { block, ids -> ReaderTranslationRegion in
                    let box = ids.map { boxes[$0] }.reduce(CGRect.null) { $0.union($1) }
                    var r = ReaderTranslationRegion(id: "block-\(block)", rect: box, source: ids.reversed().map { words[$0] }.joined())
                    r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = ids.count == 1; r.sourceImageAspectRatio = aspect
                    r.acceptedSource = .init(.init(table: bound[0].acceptedSource.membership!.table,
                        body: Set(ids), readings: [], unknownDedup: [], hasUntrackedInputs: false))
                    let cropped = croppedProfile && block == groups.count - 1
                    let offset = offsetProfile && block == groups.count - 1
                    let left = trailingPrefix ? 0.05 : 0.08
                    let rows = offsetProfile ? (offset && !nonNestedProfile ? 43 : 44) : (cropped ? 3 : 4)
                    var spans = Array(repeating: [left, 0.36], count: rows).flatMap { $0 }
                    if differentBand && block == groups.count - 1 { spans[2] = 0.085 }
                    if sourceBandConflict && block == groups.count - 1 {
                        for row in stride(from: 0, to: spans.count, by: 2) { spans[row] = 0.12 }
                    }
                    let right = differentHull && block == groups.count - 1 ? 0.37 : 0.36
                    if differentHull && block == groups.count - 1 { spans[spans.count - 1] = right }
                    r.balloonInterior = .init(rect: .init(x: left, y: offset ? 0.09 : 0.08, width: right - left,
                        height: offsetProfile ? (offset && !nonNestedProfile ? 0.43 : 0.44) : (cropped ? 0.33 : 0.44)),
                        center: .init(x: box.midX, y: 0.2), spans: spans,
                        contourVerified: false, modelEstimated: model)
                    if missingProfile { r.balloonInterior = nil }
                    if (nativeSideColumn && block == groups.count - 1) || (nativeBody && block == 0) {
                        r.balloonInterior = .init(rect: .init(x: nativeSourceClipped ? 0.12 : nativeHullMismatch ? 0.1 : 0.04, y: 0.07,
                            width: 0.34, height: 0.48), center: .init(x: box.midX, y: box.midY),
                            spans: Array(repeating: [Double(box.minX), Double(box.maxX)], count: 6).flatMap { $0 },
                            contourVerified: true, modelEstimated: false)
                    }
                    return r
                }
                if otherCaption {
                    var extra = ReaderTranslationRegion(id: "other-caption", rect: .init(x: 0.3, y: 0.36, width: 0.02, height: 0.12), source: "別の本文")
                    extra.sourceOrientation = .vertical; extra.sourceSingleVerticalColumn = true; extra.sourceImageAspectRatio = aspect
                    extra.balloonInterior = result[0].balloonInterior
                    result.append(extra)
                }
                return result
            }
            let values = input()
            for ordered in [values, Array(values.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
                #expect(result.count == 1, "grid blocks=\(blocks) columns=\(columns) aspect=\(aspect) scale=\(scale) result=\(result.map(\.source))")
                #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                #expect(result[0].source == values.reversed().map(\.source).joined())
                #expect(result[0].balloonInterior?.contourVerified != true)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
            let captionScope = NativeParagraphFragmentGrouping.TextScope(owner: 2,
                box: .init(x: 0.3, y: 0.36, width: 0.02, height: 0.12), confidence: 0.75)
            for values in [input(missing: true), input(model: false), input(otherCaption: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope, captionScope]) == values)
            }
            let mixed = input(singleFirst: true)
            // The complete private original graph already proves the source
            // relationship; an estimated paper mask or missing RF-mask callback
            // must not make that proof weaker than the same unprofiled grid.
            for result in [NativeParagraphFragmentGrouping.reconcilingObservations(mixed, scopes: [scope])] {
                #expect(result.count == 1 && result[0].source == mixed.reversed().map(\.source).joined())
                #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
            for ordered in [mixed, Array(mixed.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
                #expect(result.count == 1 && result[0].source == mixed.reversed().map(\.source).joined())
                #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                #expect(result[0].balloonInterior?.contourVerified != true)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
            let incomplete = input(missing: true, singleFirst: true)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(incomplete, scopes: [scope],
                balloons: commonModeledBalloon(incomplete)) == incomplete)
            let captions = input(otherCaption: true, singleFirst: true)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(captions, scopes: [scope],
                balloons: commonModeledBalloon(captions)) == captions)
            let separate = NativeParagraphFragmentGrouping.reconcilingObservations(captions, scopes: [scope, captionScope],
                balloons: commonModeledBalloon(captions))
            #expect(separate.count == 2 && separate.contains { $0.id == "other-caption" && $0.source == "別の本文" })
            let strongScope = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner, box: scope.box, confidence: 0.95)
            for values in [input(croppedProfile: true), input(offsetProfile: true)] {
                for ordered in [values, Array(values.reversed())] {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [strongScope])
                    #expect(result.count == 1 && result[0].source == values.reversed().map(\.source).joined())
                    #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                }
            }
            for values in [input(croppedProfile: true, differentBand: true), input(offsetProfile: true, differentHull: true),
                           input(offsetProfile: true, nonNestedProfile: true),
                           input(allSingle: true, croppedProfile: true, differentBand: true)] {
                for ordered in [values, Array(values.reversed())] {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [strongScope])
                    #expect(result.count == 1 && result[0].source == values.reversed().map(\.source).joined())
                    #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope]) == ordered)
                }
            }
            for values in [input(croppedProfile: true, sourceBandConflict: true), input(offsetProfile: true, sourceBandConflict: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [strongScope]) == values)
            }
            for crop in [false, true] {
                let singles = input(allSingle: true, croppedProfile: crop)
                for (ordered, evidenceScope) in [singles, Array(singles.reversed())].flatMap({ values in
                    [scope, strongScope].map { (values, $0) }
                }) {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [evidenceScope])
                    #expect(result.count == 1 && result[0].source == singles.reversed().map(\.source).joined())
                    #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [evidenceScope]) == result)
                }
            }
            for values in [input(otherCaption: true, allSingle: true), input(missing: true, allSingle: true),
                           input(allSingle: true, croppedProfile: true, sourceBandConflict: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [strongScope, captionScope]) == values)
            }
            let singleCaptions = input(otherCaption: true, allSingle: true)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(singleCaptions, scopes: [strongScope, captionScope],
                balloons: commonModeledBalloon(singleCaptions)) == singleCaptions)
            // A shared coarse model mask is not shared paragraph ownership.
            // The separate caption needs a complete independent source. Close
            // column contacts additionally need independent strong RF evidence;
            // untracked captions and unresolved close contacts still veto.
            for gap in [nil, 0.5, 1.5] as [CGFloat?] {
            let foreignBox = gap.map { CGRect(x: originalBoxes.last!.minX, y: 0.3 + 0.02 * aspect * $0,
                                              width: 0.02, height: 0.12) } ?? captionScope.box
            var trackedCaptions = singleCaptions
            var foreignRegion = ReaderTranslationRegion(id: "other-caption", rect: foreignBox, source: "別の本文")
            foreignRegion.sourceOrientation = .vertical; foreignRegion.sourceSingleVerticalColumn = true
            foreignRegion.sourceImageAspectRatio = aspect; foreignRegion.balloonInterior = singleCaptions.last!.balloonInterior
            trackedCaptions[trackedCaptions.count - 1] = foreignRegion
            let originalTable = singleCaptions[0].acceptedSource.membership!.table
            var captionLines = originalTable.packets.map {
                NativeCoreMLOCRLine(polygon: $0.polygon, text: $0.text, score: $0.score,
                    orientation: $0.orientation, detectorSeedEvidence: $0.detectorSeedEvidence)
            }
            let captionBox = foreignBox.applying(.init(scaleX: CGFloat(width), y: CGFloat(height)))
            let inkX = Int((foreignBox.minX * 1000).rounded()) + 5, inkY = Int((foreignBox.minY * 1000).rounded()) + 10
            let captionInk = Evidence.Component(seed: inkY * 1000 + inkX, pixelCount: 500, meanProbability: 0.95,
                runs: (inkY..<(inkY + 100)).map { .init(y: $0, x: inkX, count: 5) })
            let captionEvidence = Evidence(ownerID: "separate-caption", parentBoxIndex: count,
                provenance: "db-complete-cc-candidates-v2", threshold: 0.9, mapOriginX: 0, mapOriginY: 0,
                mapFullWidth: 1000, mapFullHeight: 1000, sourceWidth: width, sourceHeight: height,
                components: [captionInk], ownershipVersion: 2, completeCCScan: true,
                ambiguousComponents: [], candidateComponents: [])
            captionLines.append(.init(polygon: [.init(x: captionBox.minX, y: captionBox.minY),
                .init(x: captionBox.maxX, y: captionBox.minY), .init(x: captionBox.maxX, y: captionBox.maxY),
                .init(x: captionBox.minX, y: captionBox.maxY)], text: "別の本文", score: 0.95,
                orientation: .vertical, detectorSeedEvidence: [captionEvidence]))
            let captionBound = NativeOCRAcceptedSource.bindingPrimary(captionLines, width: width, height: height)
            for index in trackedCaptions.indices {
                trackedCaptions[index].acceptedSource = .init(.init(table: captionBound[0].acceptedSource.membership!.table,
                    body: index == trackedCaptions.count - 1 ? [count] : singleCaptions[index].acceptedSource.membership!.body,
                    readings: [], unknownDedup: [], hasUntrackedInputs: false))
            }
            let strongCaption = NativeParagraphFragmentGrouping.TextScope(owner: captionScope.owner,
                box: foreignBox, confidence: 0.95)
            let weakCaption = NativeParagraphFragmentGrouping.TextScope(owner: captionScope.owner,
                box: foreignBox, confidence: 0.75)
            for ordered in [trackedCaptions, Array(trackedCaptions.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [strongScope, strongCaption])
                if gap.map({ $0 <= 1 }) == true {
                    #expect(result == ordered) // Another RF ID cannot cut a connected original column.
                } else {
                    #expect(result.count == 2)
                    #expect(result.contains { $0.id == "other-caption" && $0.acceptedSource.membership?.body == [count] })
                    #expect(result.contains { $0.acceptedSource.membership?.body == Set(0..<count) })
                }
                for scopes in [[strongScope, weakCaption], [strongScope]] {
                    let separated = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: scopes)
                    if gap == nil {
                        // A fully tracked exterior source needs no independent
                        // RF certificate when its ink has no connection to the
                        // strong current text scope. It remains unchanged.
                        #expect(separated.count == 2)
                        #expect(separated.contains { $0 == trackedCaptions.last! })
                        #expect(separated.contains { $0.acceptedSource.membership?.body == Set(0..<count) })
                    } else {
                        #expect(separated == ordered) // Close continuation still contradicts exclusion.
                    }
                }
            }
            }
            let originalBlocks = input(missingProfile: true)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(originalBlocks, scopes: [scope]) == originalBlocks)
            for ordered in [originalBlocks, Array(originalBlocks.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [strongScope])
                #expect(result.count == 1 && result[0].source == originalBlocks.reversed().map(\.source).joined())
                #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [strongScope]) == result)
            }
            let missingGrid = input(missing: true, missingProfile: true)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(missingGrid, scopes: [strongScope]) == missingGrid)
            // Some shifted blocks lie wholly outside this narrower query.
            // They must stay unchanged, not veto its independently closed
            // first component. A clipped/overbroad query may still reject it.
            let partialGrid = input(singleFirst: true, missingProfile: true, separatedColumns: true)
            let partialResult = NativeParagraphFragmentGrouping.reconcilingObservations(partialGrid, scopes: [strongScope])
            let firstBody = Set(0..<columns)
            #expect(partialGrid.dropFirst(columns).allSatisfy(partialResult.contains))
            #expect(partialResult.allSatisfy { value in
                let body = value.acceptedSource.membership!.body
                return body.isSubset(of: firstBody) ? body.count == 1 || body == firstBody : partialGrid.contains(value)
            })
            #expect(partialResult.reduce(into: Set<Int>()) { $0.formUnion($1.acceptedSource.membership!.body) } == Set(0..<count))
            #expect(partialResult.filter { $0.acceptedSource.membership!.body == firstBody }.allSatisfy {
                $0.source == partialGrid.prefix(columns).reversed().map(\.source).joined()
            })
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(partialResult, scopes: [strongScope]) == partialResult)
            let completeSingles = input(allSingle: true, missingProfile: true)
            let completeResult = NativeParagraphFragmentGrouping.reconcilingObservations(completeSingles, scopes: [strongScope])
            #expect(completeResult.count == 1 && completeResult[0].acceptedSource.membership?.body == Set(0..<count))
            for ordered in [completeSingles, Array(completeSingles.reversed())] {
                let weakResult = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
                #expect(weakResult.count == 1 && weakResult[0].source == completeSingles.reversed().map(\.source).joined())
                #expect(weakResult[0].acceptedSource.membership?.body == Set(0..<count))
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(weakResult, scopes: [scope]) == weakResult)
            }
            let weakIncomplete = input(missing: true, allSingle: true, missingProfile: true)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(weakIncomplete, scopes: [scope]) == weakIncomplete)
            let unsupportedScope = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner, box: scope.box, confidence: 0.2)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(completeSingles, scopes: [unsupportedScope]) == completeSingles)
            let modeledSingles = input(allSingle: true)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(modeledSingles, scopes: [scope]).count == 1)
            let separated = input(allSingle: true, missingProfile: true, separatedColumns: true)
            let coarse = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                box: scope.box.union(scope.box.offsetBy(dx: 0.06, dy: 0)), confidence: 0.95)
            for ordered in [separated, Array(separated.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [coarse])
                #expect(result.count == 2)
                #expect(Set(result.map { $0.acceptedSource.membership!.body }) == [Set(0..<columns), Set(columns..<count)])
                #expect(result.reduce(0) { $0 + $1.unitMemberRects.count } == count)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [coarse]) == result)
            }
            for values in [input(missing: true, allSingle: true, missingProfile: true, separatedColumns: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [coarse]) == values)
            }
            for partiallyAggregated in [input(singleFirst: true, missingProfile: true, separatedColumns: true),
                                        input(singleFirst: true, missingProfile: true, separatedColumns: true, compactStrip: true)] {
                let local = NativeParagraphFragmentGrouping.TextScope(owner: coarse.owner,
                    box: partiallyAggregated.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                let locallyGrouped = NativeParagraphFragmentGrouping.reconcilingObservations(partiallyAggregated, scopes: [local])
                #expect(locallyGrouped.count == 2)
                #expect(Set(locallyGrouped.map { $0.acceptedSource.membership!.body }) == [Set(0..<columns), Set(columns..<count)])
                #expect(locallyGrouped.contains { $0.source == partiallyAggregated.prefix(columns).reversed().map(\.source).joined() })
                #expect(locallyGrouped.contains { $0.source == partiallyAggregated.dropFirst(columns).reversed().map(\.source).joined() })
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(locallyGrouped, scopes: [local]) == locallyGrouped)
            }
            let weakCoarse = NativeParagraphFragmentGrouping.TextScope(owner: coarse.owner, box: coarse.box, confidence: 0.75)
            let weakGroups = NativeParagraphFragmentGrouping.reconcilingObservations(separated, scopes: [weakCoarse])
            #expect(weakGroups.count == 2)
            #expect(Set(weakGroups.map { $0.acceptedSource.membership!.body }) == [Set(0..<columns), Set(columns..<count)])
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(weakGroups, scopes: [weakCoarse]) == weakGroups)
            let leading = input(missingProfile: true, shortLeading: true)
            var unprovenBlock = leading
            unprovenBlock[unprovenBlock.count - 1].sourceSingleVerticalColumn = false
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(unprovenBlock, scopes: [strongScope]) == unprovenBlock)
            for ordered in [leading, Array(leading.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
                #expect(result.count == 1 && result[0].source == leading.reversed().map(\.source).joined(),
                    "prefix blocks=\(blocks) columns=\(columns) scale=\(scale) aspect=\(aspect) output=\(result.map(\.source))")
                #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
            for values in [input(missing: true, missingProfile: true, shortLeading: true)] {
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [local]) == values)
            }
            for values in [input(missingProfile: true, shortLeading: true, raggedBody: true),
                           input(missingProfile: true, shortLeading: true, raggedBody: true, leadingInkShift: 2),
                           input(missingProfile: true, shortLeading: true, longPrefix: true),
                           input(missingProfile: true, shortLeading: true, trailingPrefix: true)] {
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [local])
                let expected = values.sorted { $0.rect.midX > $1.rect.midX }.map(\.source).joined()
                #expect(result.count == 1 && result[0].source == expected)
                #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                let weak = NativeParagraphFragmentGrouping.TextScope(owner: local.owner, box: local.box, confidence: 0.75)
                // A complete, independently owned original graph is stronger
                // than the former rectangular-body/short-prefix heuristic.
                // The coarse scope must still account for the entire graph.
                let connected = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [weak])
                #expect(connected.count == 1 && connected[0].source == expected)
                #expect(connected[0].acceptedSource.membership?.body == Set(0..<count))
            }
            let strip = input(singleFirst: true, missingProfile: true, compactStrip: true)
            let stripScope = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                box: strip.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.75)
            for ordered in [strip, Array(strip.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [stripScope])
                #expect(result.count == 1 && result[0].source == strip.reversed().map(\.source).joined())
                #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                #expect(result[0].unitMemberRects.count == strip.count)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [stripScope]) == result)
            }
            for values in [input(missing: true, singleFirst: true, missingProfile: true, compactStrip: true)] {
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [local]) == values)
            }
            let raggedStrip = input(singleFirst: true, missingProfile: true, raggedBody: true, compactStrip: true)
            let raggedScope = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                box: raggedStrip.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
            let raggedResult = NativeParagraphFragmentGrouping.reconcilingObservations(raggedStrip, scopes: [raggedScope])
            if aspect == 1 {
                #expect(raggedResult.count == 1 && raggedResult[0].source == raggedStrip.reversed().map(\.source).joined())
                #expect(raggedResult[0].acceptedSource.membership?.body == Set(0..<count))
            } else {
                // At this physical aspect the shortened axis is also outside
                // the independent column-width ratio, which is not relaxed.
                #expect(raggedResult == raggedStrip)
            }
            let weakRaggedScope = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                box: raggedScope.box, confidence: 0.75)
            let weakRagged = NativeParagraphFragmentGrouping.reconcilingObservations(raggedStrip, scopes: [weakRaggedScope])
            if aspect == 1 {
                #expect(weakRagged.count == 1 && weakRagged[0].source == raggedStrip.reversed().map(\.source).joined())
                #expect(weakRagged[0].acceptedSource.membership?.body == Set(0..<count))
            } else {
                #expect(weakRagged == raggedStrip)
            }
            let belowFloor = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner, box: stripScope.box, confidence: 0.2)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(strip, scopes: [belowFloor]) == strip)
            let fullHeightMixed = input(singleFirst: true, missingProfile: true)
            let fullHeightResult = NativeParagraphFragmentGrouping.reconcilingObservations(fullHeightMixed, scopes: [strongScope])
            #expect(fullHeightResult.count == 1 && fullHeightResult[0].acceptedSource.membership?.body == Set(0..<count))
            let weakFullHeight = NativeParagraphFragmentGrouping.reconcilingObservations(fullHeightMixed, scopes: [scope])
            #expect(weakFullHeight.count == 1 && weakFullHeight[0].source == fullHeightMixed.reversed().map(\.source).joined())
            #expect(weakFullHeight[0].acceptedSource.membership?.body == Set(0..<count))
            for ragged in [false, true] {
                let values = input(shortLeading: true, raggedBody: ragged, comparablePrefix: true)
                let weak = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
                #expect(weak.count == 1 && weak[0].source == values.reversed().map(\.source).joined())
                #expect(weak[0].acceptedSource.membership?.body == Set(0..<count))
                for ordered in [values, Array(values.reversed())] {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [strongScope])
                    #expect(result.count == 1 && result[0].source == values.reversed().map(\.source).joined())
                    #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                    #expect(result[0].balloonInterior?.contourVerified != true)
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [strongScope]) == result)
                }
            }
            for values in [input(shortLeading: true, raggedBody: true, trailingPrefix: true, comparablePrefix: true),
                           input(shortLeading: true, leadingInkShift: 2),
                           input(differentBand: true, shortLeading: true, comparablePrefix: true)] {
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [local])
                #expect(result.count == 1 && result[0].acceptedSource.membership?.body == Set(0..<count))
                #expect(result[0].source == values.sorted { $0.rect.midX > $1.rect.midX }.map(\.source).joined())
                let weak = NativeParagraphFragmentGrouping.TextScope(owner: local.owner, box: local.box, confidence: 0.75)
                let weakResult = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [weak])
                let sameBands = values.allSatisfy { $0.balloonInterior?.rect == values[0].balloonInterior?.rect &&
                    $0.balloonInterior?.spans == values[0].balloonInterior?.spans }
                if sameBands {
                    #expect(weakResult.count == 1 && weakResult[0].source == result[0].source)
                    #expect(weakResult[0].acceptedSource.membership?.body == Set(0..<count))
                } else {
                    #expect(weakResult == values)
                }
            }
            for values in [input(missing: true, shortLeading: true, comparablePrefix: true),
                           input(model: false, shortLeading: true, comparablePrefix: true),
                           input(shortLeading: true, comparablePrefix: true, sourceBandConflict: true)] {
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [local]) == values)
            }
            // A closed strong scope with complete owned source-grid evidence
            // does not require every ragged letter to start on the same DB row.
            for leads in [1, 2] { for shift in [-2, 0, 1, 2] {
                let values = input(shortLeading: true, raggedBody: true, leadingColumns: leads, leadingInkShift: shift)
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                for ordered in [values, Array(values.reversed())] {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [local])
                    #expect(result.count == 1 && result[0].source == values.reversed().map(\.source).joined())
                    #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [local]) == result)
                }
            } }
            let distinctGrid = input(shortLeading: true, raggedBody: true, differentDetectorGrid: true)
            let distinctScope = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                box: distinctGrid.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
            let distinctResult = NativeParagraphFragmentGrouping.reconcilingObservations(distinctGrid, scopes: [distinctScope])
            #expect(distinctResult.count == 1 && distinctResult[0].source == distinctGrid.reversed().map(\.source).joined())
            #expect(distinctResult[0].acceptedSource.membership?.body == Set(0..<count))
            let weakDistinctScope = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                box: distinctScope.box, confidence: 0.75)
            let weakDistinct = NativeParagraphFragmentGrouping.reconcilingObservations(distinctGrid, scopes: [weakDistinctScope])
            #expect(weakDistinct.count == 1 && weakDistinct[0].source == distinctResult[0].source)
            #expect(weakDistinct[0].acceptedSource.membership?.body == Set(0..<count))
            for values in [input(missing: true, shortLeading: true, raggedBody: true),
                           input(shortLeading: true, raggedBody: true, candidateOutsideCrop: true)] {
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [local]) == values)
            }
            let additionalCaption = input(otherCaption: true, shortLeading: true, comparablePrefix: true)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(additionalCaption,
                scopes: [strongScope, captionScope]) == additionalCaption)
            let native = input(shortLeading: true, trailingPrefix: true, comparablePrefix: true, nativeSideColumn: true)
            let nativeScope = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                box: native.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
            for ordered in [native, Array(native.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [nativeScope])
                #expect(result.count == 1 && result[0].source == native.map(\.source).joined())
                #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [nativeScope]) == result)
            }
            for (variant, values) in [input(shortLeading: true, trailingPrefix: true, comparablePrefix: true, leadingInkShift: 2, nativeSideColumn: true),
                           input(shortLeading: true, trailingPrefix: true, comparablePrefix: true, differentDetectorGrid: true, nativeSideColumn: true),
                           input(nativeBody: true)].enumerated() {
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                for ordered in [values, Array(values.reversed())] {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [local])
                    #expect(result.count == 1 && result[0].source == values.sorted { $0.rect.midX > $1.rect.midX }.map(\.source).joined(),
                        "native variant=\(variant) blocks=\(blocks) columns=\(columns) aspect=\(aspect) output=\(result.map(\.source))")
                    #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [local]) == result)
                }
                let weak = NativeParagraphFragmentGrouping.TextScope(owner: local.owner, box: local.box, confidence: 0.75)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [weak]) == values)
            }
            for values in [input(missing: true, shortLeading: true, trailingPrefix: true, comparablePrefix: true, nativeSideColumn: true),
                           input(model: false, shortLeading: true, trailingPrefix: true, comparablePrefix: true, nativeSideColumn: true),
                           input(shortLeading: true, trailingPrefix: true, comparablePrefix: true, candidateOutsideCrop: true, nativeSideColumn: true),
                           input(shortLeading: true, trailingPrefix: true, comparablePrefix: true, nativeSideColumn: true, nativeHullMismatch: true),
                           input(shortLeading: true, trailingPrefix: true, comparablePrefix: true, nativeSideColumn: true, nativeSourceClipped: true),
                           input(nativeBody: true, nativeSourceClipped: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [nativeScope]) == values)
            }
            for offset in [false, true] {
                let tail = input(croppedProfile: !offset, shortLeading: true, trailingPrefix: true,
                    comparablePrefix: true, offsetProfile: offset)
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: tail.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                for ordered in [tail, Array(tail.reversed())] {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [local])
                    #expect(result.count == 1, "cropped tail offset=\(offset) aspect=\(aspect) scale=\(scale) blocks=\(blocks) columns=\(columns)")
                    #expect(result[0].source == tail.map(\.source).joined())
                    #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [local]) == result)
                }
            }
            for values in [input(croppedProfile: true, shortLeading: true, trailingPrefix: true,
                                 comparablePrefix: true, differentHull: true),
                           input(shortLeading: true, trailingPrefix: true, comparablePrefix: true,
                                 offsetProfile: true, nonNestedProfile: true)] {
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [local],
                    balloons: commonModeledBalloon(values))
                #expect(result.count == 1 && result[0].source == values.map(\.source).joined())
                #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                let weak = NativeParagraphFragmentGrouping.TextScope(owner: local.owner, box: local.box, confidence: 0.75)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [weak],
                    balloons: commonModeledBalloon(values)) == values)
            }
            for values in [input(croppedProfile: true, shortLeading: true, trailingPrefix: true,
                                 comparablePrefix: true, candidateOutsideCrop: true),
                           input(croppedProfile: true, shortLeading: true, trailingPrefix: true,
                                 comparablePrefix: true, sourceBandConflict: true)] {
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [local],
                    balloons: commonModeledBalloon(values)) == values)
            }
            for shifts in [(0, 0), (-1, 1), (1, -1), (-2, 0), (0, 2)] {
                let values = input(shortLeading: true, trailingPrefix: true, internalRaggedBody: true,
                    alignedTail: true, inkStartShift: shifts.0, inkEndShift: shifts.1)
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                for ordered in [values, Array(values.reversed())] {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [local])
                    #expect(result.count == 1 && result[0].source == values.map(\.source).joined())
                    #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [local]) == result)
                }
                let weak = NativeParagraphFragmentGrouping.TextScope(owner: local.owner, box: local.box, confidence: 0.75)
                let weakAligned = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [weak])
                #expect(weakAligned.count == 1 && weakAligned[0].source == values.map(\.source).joined())
                #expect(weakAligned[0].acceptedSource.membership?.body == Set(0..<count))
            }
            let offsetGridTail = input(shortLeading: true, trailingPrefix: true, internalRaggedBody: true,
                alignedTail: true, differentDetectorGrid: true)
            let offsetGridScope = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                box: offsetGridTail.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
            let offsetGridResult = NativeParagraphFragmentGrouping.reconcilingObservations(offsetGridTail, scopes: [offsetGridScope])
            #expect(offsetGridResult.count == 1 && offsetGridResult[0].source == offsetGridTail.map(\.source).joined())
            #expect(offsetGridResult[0].acceptedSource.membership?.body == Set(0..<count))
            let weakOffsetGridScope = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                box: offsetGridScope.box, confidence: 0.75)
            let weakOffset = NativeParagraphFragmentGrouping.reconcilingObservations(offsetGridTail, scopes: [weakOffsetGridScope])
            #expect(weakOffset.count == 1 && weakOffset[0].source == offsetGridResult[0].source)
            #expect(weakOffset[0].acceptedSource.membership?.body == Set(0..<count))
            for values in [input(shortLeading: true, trailingPrefix: true, candidateOutsideCrop: true, internalRaggedBody: true, alignedTail: true)] {
                let local = NativeParagraphFragmentGrouping.TextScope(owner: scope.owner,
                    box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [local]) == values)
            }
        } } }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func overlappingMeasuredFacesNeedSharedCompleteInkAndExteriorSupport(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let width = Int(1000 * scale)
        for aspect in [1.0, 1.25] {
            let height = Int(Double(width) / aspect)
            let boxes = [CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.3),
                         CGRect(x: 0.11, y: 0.15, width: 0.02, height: 0.2)]
            func input(independent: Bool = true, shared: Bool = true, verified: Bool = true,
                       matchingFace: Bool = true, complete: Bool = true, sameTable: Bool = true,
                       exterior: Bool = true, inside: Bool = true) -> [ReaderTranslationRegion] {
                func component(_ x: Int, _ y: Int) -> Evidence.Component {
                    .init(seed: y * 1000 + x, pixelCount: 2, meanProbability: 0.95,
                        runs: [.init(y: y, x: x, count: 2)])
                }
                let common = component(inside ? 120 : 300, 220)
                let own = component(exterior ? 180 : 120, 200)
                let words = ["外側の観測", "内側の観測"]
                let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
                    let b = box.applying(.init(scaleX: CGFloat(width), y: CGFloat(height)))
                    let ambiguous = i == 1 && !shared ? component(124, 220) : common
                    let evidence = Evidence(ownerID: i == 0 ? "outer" : "inner", parentBoxIndex: i,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9, mapOriginX: 0, mapOriginY: 0,
                        mapFullWidth: 1000, mapFullHeight: 1000, sourceWidth: width, sourceHeight: height,
                        components: i == 0 && independent ? [own] : [], ownershipVersion: 2, completeCCScan: true,
                        ambiguousComponents: [ambiguous], candidateComponents: [])
                    #expect(evidence.isValid)
                    return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95,
                        orientation: .vertical, detectorSeedEvidence: [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: width, height: height)
                return boxes.enumerated().map { i, box -> ReaderTranslationRegion in
                    var r = ReaderTranslationRegion(id: "observation-\(i)", rect: box, source: words[i])
                    r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = true; r.sourceImageAspectRatio = aspect
                    r.acceptedSource = bound[i].acceptedSource
                    if i == 1 && !sameTable {
                        r.acceptedSource = NativeOCRAcceptedSource.bindingPrimary([lines[i]], width: width, height: height)[0].acceptedSource
                    }
                    if i == 1 && !complete {
                        let m = r.acceptedSource.membership!
                        r.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [], unknownDedup: m.body, hasUntrackedInputs: false))
                    }
                    r.balloonInterior = .init(rect: .init(x: 0.09, y: 0.09, width: 0.13, height: 0.34),
                        center: .init(x: i == 0 ? 0.16 : 0.12, y: 0.2),
                        spans: i == 1 && !matchingFace ? [0.3, 0.43, 0.3, 0.43] : [0.09, 0.22, 0.09, 0.22],
                        contourVerified: verified, modelEstimated: !verified)
                    return r
                }
            }
            let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
                box: .init(x: 0.09, y: 0.09, width: 0.13, height: 0.34), confidence: 0.95)
            for values in [input(), Array(input().reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
                #expect(result.count == 1 && result[0].source == "外側の観測内側の観測")
                #expect(result[0].rect == boxes[0] && result[0].unitMemberRects.count == 2)
                #expect(result[0].acceptedSource.membership?.body == Set([0, 1]))
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
            for (failure, values) in [input(independent: false), input(shared: false), input(verified: false),
                           input(matchingFace: false), input(complete: false), input(sameTable: false),
                           input(exterior: false), input(inside: false)].enumerated() {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values,
                    "Measured-face rejection \(failure), scale \(scale), aspect \(aspect)")
            }
            let unscoped = input()
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(unscoped, scopes: []) == unscoped)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func sharedObservationColumnExtendsOnlyWithClosedIndependentEvidence(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let width = Int(1000 * scale)
        for aspect in [1.0, 1.25] {
            let height = Int(Double(width) / aspect)
            let words = ["外側の観測", "内側の観測", "本文右列", "本文左列"]
            func input(independent: Bool = true, shared: Bool = true, unmatched: Bool = false,
                       candidate: Bool = false, wide: Bool = false, sameTable: Bool = true,
                       foreignCaption: Bool = false, danglingOwner: Bool = false) -> [ReaderTranslationRegion] {
                var boxes = [CGRect(x: 0.16, y: 0.1, width: wide ? 0.07 : 0.04, height: 0.2),
                    CGRect(x: 0.16, y: 0.16, width: 0.02, height: 0.14),
                    CGRect(x: 0.155, y: 0.1, width: 0.02, height: 0.2),
                    CGRect(x: 0.13, y: 0.1, width: 0.02, height: 0.2)]
                var text = words
                if foreignCaption {
                    boxes += (0..<4).map { CGRect(x: 0.13 + Double($0) * 0.025, y: 0.5, width: 0.02, height: 0.2) }
                    text += (0..<4).map { "別列\($0)文" }
                }
                if danglingOwner { boxes.append(.init(x: 0.14, y: 0.33, width: 0.02, height: 0.05)); text.append("別字") }
                func component(_ x: Int, _ y: Int, _ bottom: Int) -> Evidence.Component {
                    let runs = (y...bottom).map { Evidence.Run(y: $0, x: x, count: 6) }
                    return .init(seed: y * 1000 + x, pixelCount: runs.count * 6, meanProbability: 0.95, runs: runs)
                }
                let common = component(169, 170, 290), own = component(wide ? 218 : 184, 110, 240)
                let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
                    let b = box.applying(.init(scaleX: CGFloat(width), y: CGFloat(height)))
                    let ambiguous = i == 0 ? [common] + (unmatched ? [component(176, 150, 155)] : []) :
                        i == 1 ? [shared ? common : component(172, 170, 290)] : []
                    let evidence = Evidence(ownerID: "packet-\(i)", parentBoxIndex: i,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9, mapOriginX: 0, mapOriginY: 0,
                        mapFullWidth: 1000, mapFullHeight: 1000, sourceWidth: width, sourceHeight: height,
                        components: i == 0 ? (independent ? [own] : []) : i > 1 ? [component(
                            Int((box.minX * 1000).rounded()) + 5,
                            Int((box.minY * 1000).rounded()) + 10,
                            Int((box.maxY * 1000).rounded()) - 10)] : [],
                        ownershipVersion: 2, completeCCScan: true, ambiguousComponents: ambiguous,
                        candidateComponents: candidate && i == 0 ? [.init(component: component(177, 145, 150),
                            competingOwnerIDs: ["other"], outsideCompetingCells: [6])] : [])
                    #expect(evidence.isValid)
                    return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: text[i], score: 0.95,
                        orientation: .vertical, detectorSeedEvidence: [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: width, height: height)
                var values = boxes.enumerated().map { i, box -> ReaderTranslationRegion in
                    var r = ReaderTranslationRegion(id: "observation-\(i)", rect: box, source: text[i])
                    r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = true; r.sourceImageAspectRatio = aspect
                    r.acceptedSource = bound[i].acceptedSource
                    if i < 2 {
                        r.balloonInterior = .init(rect: .init(x: 0.12, y: 0.08, width: 0.13, height: 0.24),
                            center: .init(x: i == 0 ? 0.19 : 0.17, y: 0.2), spans: [0.12, 0.25, 0.12, 0.25],
                            contourVerified: true, modelEstimated: false)
                    }
                    return r
                }
                values[2] = ReaderTranslationRegion(id: values[2].id, rect: boxes[2].union(boxes[3]), source: words[2] + words[3])
                values[2].sourceOrientation = .vertical; values[2].sourceImageAspectRatio = aspect
                values[2].sourceSingleVerticalColumn = false
                values[2].unitMemberRects = [boxes[2], boxes[3]]
                values[2].acceptedSource = .union(bound[2...3].map(\.acceptedSource))
                let profile = ReaderTranslationBalloonInterior(rect: .init(x: 0.12, y: 0.08, width: 0.13, height: 0.64),
                    center: .init(x: 0.18, y: 0.4), spans: [0.12, 0.25, 0.12, 0.25], contourVerified: false, modelEstimated: true)
                if foreignCaption { values[2].balloonInterior = profile }
                var result = Array(values.prefix(3))
                if foreignCaption {
                    for start in [4, 6] {
                        var block = ReaderTranslationRegion(id: values[start].id, rect: boxes[start].union(boxes[start + 1]),
                            source: text[start + 1] + text[start])
                        block.sourceOrientation = .vertical; block.sourceSingleVerticalColumn = false; block.sourceImageAspectRatio = aspect
                        block.acceptedSource = .union(bound[start...(start + 1)].map(\.acceptedSource))
                        block.unitMemberRects = [boxes[start], boxes[start + 1]]; block.balloonInterior = profile
                        result.append(block)
                    }
                }
                if danglingOwner { result.append(values.last!) }
                if !sameTable {
                    result[1].acceptedSource = NativeOCRAcceptedSource.bindingPrimary([lines[1]], width: width, height: height)[0].acceptedSource
                }
                return result
            }
            let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
                box: .init(x: 0.12, y: 0.08, width: 0.13, height: 0.24), confidence: 0.95)
            for values in [input(), Array(input().reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
                #expect(result.count == 1 && result[0].source == words.joined())
                #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2, 3]))
                #expect(result[0].rect == values.map(\.rect).reduce(CGRect.null) { $0.union($1) })
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
            for values in [input(independent: false), input(shared: false), input(sameTable: false)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
            }
            for values in [input(unmatched: true), input(candidate: true), input(wide: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]).count == 2)
            }
            let values = input()
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: []) == values)
            let ownScope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
                box: .init(x: 0.13, y: 0.1, width: 0.07, height: 0.2), confidence: 0.95)
            let otherScope = NativeParagraphFragmentGrouping.TextScope(owner: 2,
                box: .init(x: 0.13, y: 0.5, width: 0.095, height: 0.2), confidence: 0.95)
            for values in [input(foreignCaption: true), Array(input(foreignCaption: true).reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [ownScope, otherScope])
                #expect(result.count == 2)
                #expect(result.contains { $0.acceptedSource.membership?.body == Set([0, 1, 2, 3]) })
                #expect(result.contains { $0.acceptedSource.membership?.body == Set([4, 5, 6, 7]) })
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [ownScope, otherScope]) == result)
            }
            let unsupported = input(independent: false, foreignCaption: true)
            let isolated = NativeParagraphFragmentGrouping.reconcilingObservations(unsupported, scopes: [ownScope, otherScope])
            #expect(isolated.count == 4 && isolated.contains { $0.acceptedSource.membership?.body == Set([4, 5, 6, 7]) },
                    "isolated partitions \(isolated.map { $0.acceptedSource.membership?.body.sorted() ?? [] })")
            // Unresolved shared ownership stays unresolved, but cannot poison
            // the complete, disconnected text scope below it.
            for original in unsupported.prefix(3) { #expect(isolated.contains(original)) }
            let danglingScope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
                box: .init(x: 0.13, y: 0.1, width: 0.07, height: 0.28), confidence: 0.95)
            let dangling = input(foreignCaption: true, danglingOwner: true)
            let incomplete = NativeParagraphFragmentGrouping.reconcilingObservations(dangling, scopes: [danglingScope, otherScope])
            #expect(incomplete.contains { $0.acceptedSource.membership?.body == Set([4, 5, 6, 7]) })
            #expect(incomplete.contains(dangling.last!))
            #expect(Set(incomplete.flatMap { $0.acceptedSource.membership!.body }) == Set(0...8))
            #expect(incomplete.reduce(0) { $0 + $1.acceptedSource.membership!.body.count } == 9)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func primaryColumnUsesPacketsInsteadOfParagraphEnvelope(scale: CGFloat) {
        let boxes = [CGRect(x: 0.14, y: 0.1, width: 0.02, height: 0.3),
                     CGRect(x: 0.1, y: 0.1, width: 0.02, height: 0.05),
                     CGRect(x: 0.098, y: 0.16, width: 0.02, height: 0.1)]
            .map { $0.applying(.init(scaleX: scale, y: scale)) }
        let words = ["右の長い列", "左の先頭", "左の続き"]
        let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
            let b = box.applying(.init(scaleX: 1000, y: 1000))
            return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95, orientation: .vertical)
        }
        let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: 1000, height: 1000)
        var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: words[0] + words[1])
        body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
        body.acceptedSource = .union(bound.prefix(2).map(\.acceptedSource))
        var tail = ReaderTranslationRegion(id: "tail", rect: boxes[2], source: words[2])
        tail.sourceOrientation = .vertical; tail.sourceSingleVerticalColumn = true; tail.sourceImageAspectRatio = 1
        tail.acceptedSource = bound[2].acceptedSource
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: body.rect, confidence: 0.95)
        for input in [[body, tail], [tail, body]] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [scope])
            #expect(result.count == 1 && result[0].source == words.joined())
            #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            #expect(result[0].unitMemberRects.count == 2)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
        }
        var unknown = tail; unknown.acceptedSource = .init()
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([body, unknown], scopes: [scope]).count == 2)
        unknown.acceptedSource = NativeOCRAcceptedSource.bindingPrimary([lines[2]], width: 1000, height: 1000)[0].acceptedSource
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([body, unknown], scopes: [scope]).count == 2)
        let m = tail.acceptedSource.membership!
        unknown.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [], unknownDedup: m.body, hasUntrackedInputs: false))
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([body, unknown], scopes: [scope]).count == 2)
        var internalHead = ReaderTranslationRegion(id: body.id, rect: body.rect, source: words[1] + words[0])
        internalHead.sourceOrientation = .vertical; internalHead.sourceImageAspectRatio = 1
        internalHead.acceptedSource = body.acceptedSource
        let preservedOrder = NativeParagraphFragmentGrouping.reconcilingObservations([internalHead, tail], scopes: [scope])
        #expect(preservedOrder.count == 1 && preservedOrder[0].source == internalHead.source + tail.source)
        var changed = ReaderTranslationRegion(id: tail.id, rect: tail.rect, source: "異なる認識")
        changed.sourceOrientation = .vertical; changed.sourceImageAspectRatio = 1; changed.acceptedSource = tail.acceptedSource
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([body, changed], scopes: [scope]).count == 2)
        for (texts, unique) in [(["文続", "文", "後半"], true), (["文", "文", "後半"], false),
                                (["右 の列", "前 半", "後 半"], true), ([" 右列", "左列 ", "後半"], true)] {
            let prefixLines = lines.enumerated().map { index, line in
                NativeCoreMLOCRLine(polygon: line.polygon, text: texts[index], score: 0.95, orientation: .vertical)
            }
            let prefixBound = NativeOCRAcceptedSource.bindingPrimary(prefixLines, width: 1000, height: 1000)
            for separator in ["", " \n"] {
                var prefixBody = ReaderTranslationRegion(id: body.id, rect: body.rect, source: texts[0] + separator + texts[1])
                prefixBody.sourceOrientation = .vertical; prefixBody.sourceSingleVerticalColumn = false; prefixBody.sourceImageAspectRatio = 1
                prefixBody.acceptedSource = .union(prefixBound.prefix(2).map(\.acceptedSource))
                var prefixTail = ReaderTranslationRegion(id: tail.id, rect: tail.rect, source: texts[2])
                prefixTail.sourceOrientation = .vertical; prefixTail.sourceSingleVerticalColumn = true; prefixTail.sourceImageAspectRatio = 1
                prefixTail.acceptedSource = prefixBound[2].acceptedSource
                for values in [[prefixBody, prefixTail], [prefixTail, prefixBody]] {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
                    if unique {
                        #expect(result.count == 1 && result[0].source == prefixBody.source + texts[2])
                        #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
                    } else {
                        #expect(result == values)
                    }
                }
            }
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func primaryPacketInsertionPreservesEveryOriginalSequence(scale: CGFloat) {
        let boxes = [CGRect(x: 0.14, y: 0.1, width: 0.02, height: 0.3),
                     CGRect(x: 0.1, y: 0.2, width: 0.02, height: 0.1),
                     CGRect(x: 0.1, y: 0.1, width: 0.02, height: 0.08)]
            .map { $0.applying(.init(scaleX: scale, y: scale)) }
        let words = ["右の長い列", "左の後半", "左の前半"]
        let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
            let b = box.applying(.init(scaleX: 1000, y: 1000))
            return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95, orientation: .vertical)
        }
        let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: 1000, height: 1000)
        var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: words[0] + words[1])
        body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
        body.acceptedSource = .union(bound.prefix(2).map(\.acceptedSource))
        var head = ReaderTranslationRegion(id: "head", rect: boxes[2], source: words[2])
        head.sourceOrientation = .vertical; head.sourceSingleVerticalColumn = true; head.sourceImageAspectRatio = 1
        head.acceptedSource = bound[2].acceptedSource
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: body.rect, confidence: 0.95)
        for input in [[body, head], [head, body]] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [scope])
            #expect(result.count == 1 && result[0].source == words[0] + words[2] + words[1])
            #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            #expect(result[0].unitMemberRects.count == 2)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
        }
        func formatted(_ original: ReaderTranslationRegion, _ source: String) -> ReaderTranslationRegion {
            var value = ReaderTranslationRegion(id: original.id, rect: original.rect, source: source)
            value.sourceOrientation = original.sourceOrientation; value.sourceSingleVerticalColumn = original.sourceSingleVerticalColumn
            value.sourceImageAspectRatio = original.sourceImageAspectRatio; value.acceptedSource = original.acceptedSource
            return value
        }
        for separator in [" ", "\t\n", "\u{00A0}\u{3000}"] {
            let formattedBody = formatted(body, "\n" + words[0] + separator + words[1] + "\t")
            let formattedHead = formatted(head, "\u{2003}" + words[2] + "\n")
            let expected = "\n" + words[0] + formattedHead.source + separator + words[1] + "\t"
            for values in [[formattedBody, formattedHead], [formattedHead, formattedBody]] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
                #expect(result.count == 1 && result[0].source == expected)
                #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
                #expect(result[0].acceptedSource.membership?.table === body.acceptedSource.membership?.table)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
        }
        for source in ["右の 長い列" + words[1], words[0] + "\u{200B}" + words[1], words[0] + "異" + words[1]] {
            let changed = formatted(body, source)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations([changed, head], scopes: [scope]) == [changed, head])
        }
        // Missing lineage is never permission to insert text.
        var conflicting = head
        let m = head.acceptedSource.membership!
        conflicting.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [], unknownDedup: [], hasUntrackedInputs: true))
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([body, conflicting], scopes: [scope]).count == 2)
        let middleBox = CGRect(x: 0.1, y: 0.185, width: 0.02, height: 0.01)
            .applying(.init(scaleX: 1000 * scale, y: 1000 * scale))
        let middleLine = NativeCoreMLOCRLine(polygon: [
            .init(x: middleBox.minX, y: middleBox.minY), .init(x: middleBox.maxX, y: middleBox.minY),
            .init(x: middleBox.maxX, y: middleBox.maxY), .init(x: middleBox.minX, y: middleBox.maxY)],
            text: "間の断片", score: 0.95, orientation: .vertical)
        let cyclic = NativeOCRAcceptedSource.bindingPrimary([lines[1], lines[2], middleLine], width: 1000, height: 1000)
        var reverse = ReaderTranslationRegion(id: "reverse", rect: boxes[1].union(boxes[2]), source: words[1] + words[2])
        reverse.sourceOrientation = .vertical; reverse.sourceImageAspectRatio = 1
        reverse.acceptedSource = .union(cyclic.prefix(2).map(\.acceptedSource))
        var middle = ReaderTranslationRegion(id: "middle", rect: middleBox.applying(.init(scaleX: 0.001, y: 0.001)), source: middleLine.text)
        middle.sourceOrientation = .vertical; middle.sourceImageAspectRatio = 1; middle.acceptedSource = cyclic[2].acceptedSource
        let reverseScope = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: reverse.rect, confidence: 0.95)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([reverse, middle], scopes: [reverseScope]) == [reverse, middle])
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func closedSharedCarrierRequiresCompleteOwnership(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale), words = ["左の本文", "右の本文", "短列"]
        let boxes = [CGRect(x: 0.14, y: 0.10, width: 0.03, height: 0.18),
                     CGRect(x: 0.19, y: 0.10, width: 0.02, height: 0.18),
                     CGRect(x: 0.12, y: 0.10, width: 0.04, height: 0.08)]
        func input(foreign: Bool = false, reciprocal: Bool = true, outsideQuad: Bool = false,
                   model: Bool = true, clippedModel: Bool = false, untracked: Bool = false,
                   extraMember: Bool = false, horizontal: Bool = false,
                   repeatedWord: Bool = false, outsideOwnWord: Bool = true) -> [ReaderTranslationRegion] {
            let words = ["左の本文", "右の本文", repeatedWord ? "本文" : "短列"]
            let start = outsideQuad ? 100 : 130, count = 160 - start
            let shared = Evidence.Component(seed: 120000 + start, pixelCount: count, meanProbability: 0.95,
                runs: [.init(y: 120, x: start, count: count)])
            let seeds = (0..<3).map { index -> Evidence in
                let own = Evidence.Component(seed: index == 0 ? 180165 : 120195, pixelCount: 2, meanProbability: 0.95,
                    runs: [.init(y: index == 0 ? 180 : 120, x: index == 0 ? 165 : 195, count: 2)])
                let separate = Evidence.Component(seed: outsideOwnWord ? 110125 : 110145, pixelCount: 2, meanProbability: 0.95,
                    runs: [.init(y: 110, x: outsideOwnWord ? 125 : 145, count: 2)])
                return .init(ownerID: "owner-\(index)", parentBoxIndex: index, provenance: "db-complete-cc-candidates-v2",
                    threshold: 0.9, mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                    sourceWidth: size, sourceHeight: size,
                    components: index == 2 ? (repeatedWord ? [separate] : []) :
                        (index == 0 && repeatedWord && reciprocal ? [] : [own]), ownershipVersion: 2,
                    completeCCScan: true, ambiguousComponents: index == 0 && reciprocal ? [shared] : [],
                    candidateComponents: index == 2 ? [.init(component: shared,
                        competingOwnerIDs: [foreign ? "foreign" : "owner-0"], outsideCompetingCells: [140 - start])] : [])
            }
            let allSeedsValid = seeds.allSatisfy { $0.isValid }
            #expect(allSeedsValid)
            let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[index], score: 0.95,
                    orientation: horizontal && index == 2 ? .horizontal : .vertical, detectorSeedEvidence: [seeds[index]])
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: words[1] + words[0])
            body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
            body.acceptedSource = .union(bound.prefix(2).map(\.acceptedSource))
            body.detectorSeedEvidence = Evidence.preservingUnion([[seeds[0]], [seeds[1]]])
            var fragment = ReaderTranslationRegion(id: "fragment", rect: boxes[2], source: words[2])
            fragment.sourceOrientation = horizontal ? .horizontal : .vertical
            fragment.sourceSingleVerticalColumn = true; fragment.sourceImageAspectRatio = 1
            if !untracked { fragment.acceptedSource = bound[2].acceptedSource }
            fragment.detectorSeedEvidence = [seeds[2]]
            if model {
                let left = clippedModel ? 0.15 : 0.08
                let profile = ReaderTranslationBalloonInterior(rect: .init(x: left, y: 0.08, width: 0.23 - left, height: 0.22),
                    center: .init(x: 0.17, y: 0.16), spans: Array(repeating: [left, 0.23], count: 4).flatMap { $0 },
                    contourVerified: false, modelEstimated: true)
                body.balloonInterior = profile; fragment.balloonInterior = profile
            }
            var result = [body, fragment]
            if extraMember {
                var extra = ReaderTranslationRegion(id: "untracked-extra", rect: .init(x: 0.175, y: 0.20, width: 0.01, height: 0.02), source: "別文")
                extra.sourceOrientation = .vertical; extra.sourceSingleVerticalColumn = true; extra.sourceImageAspectRatio = 1
                result.append(extra)
            }
            return result
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: boxes.reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
        for values in [input(), Array(input().reversed()), input(model: false), input(clippedModel: true)] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count == 1 && result[0].source == words[1] + words[0] + words[2])
            #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            #expect(result[0].unitMemberRects.count == 2 && result[0].rect == scope.box)
            #expect(result[0].detectorSeedEvidence?.count == 3)
            let retainedCarrier = result[0].detectorSeedEvidence?.first { $0.ownerID == "owner-2" }
            #expect(retainedCarrier?.components.isEmpty == true && retainedCarrier?.candidateComponents?.count == 1)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values,
                scopes: [.init(owner: scope.owner, box: scope.box, confidence: 0.79)]) == values)
        }
        for values in [input(foreign: true), input(reciprocal: false), input(outsideQuad: true),
                       input(untracked: true), input(extraMember: true)] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
        }
        // Closed mixed-direction glyph contact has the same physical evidence
        // as a vertical carrier. Repeated text additionally needs independent
        // PRIVATE ink outside the other source's original quads in both ways.
        for values in [input(horizontal: true), input(model: false, horizontal: true),
                       input(horizontal: true, repeatedWord: true)] {
            for ordered in [values, Array(values.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
                #expect(result.count == 1 && result[0].source == values[0].source + values[1].source)
                #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
                #expect(result[0].acceptedSource.membership?.table === values[0].acceptedSource.membership?.table)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(ordered,
                    scopes: [.init(owner: scope.owner, box: scope.box, confidence: 0.79)]) == ordered)
            }
        }
        for negative in [input(horizontal: true, repeatedWord: true, outsideOwnWord: false),
                         input(foreign: true, horizontal: true), input(reciprocal: false, horizontal: true),
                         input(outsideQuad: true, horizontal: true), input(untracked: true, horizontal: true),
                         input(extraMember: true, horizontal: true)] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [scope]) == negative)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func componentBridgeRequiresReciprocalMultiColumnEvidence(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(100 * scale)
        let c0 = Evidence.Component(seed: 1210, pixelCount: 2, meanProbability: 0.95, runs: [.init(y: 12, x: 10, count: 2)])
        let c1 = Evidence.Component(seed: 2714, pixelCount: 2, meanProbability: 0.95,
            runs: [.init(y: 27, x: 14, count: 1), .init(y: 28, x: 14, count: 1)])
        let independent = Evidence.Component(seed: 1518, pixelCount: 2, meanProbability: 0.95, runs: [.init(y: 15, x: 18, count: 2)])
        func evidence(_ id: String, _ index: Int, components: [Evidence.Component], ambiguous: [Evidence.Component] = [],
                      candidates: [Evidence.Candidate] = [], width: Int? = nil) -> Evidence {
            .init(ownerID: id, parentBoxIndex: index, provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                mapOriginX: 0, mapOriginY: 0, mapFullWidth: 100, mapFullHeight: 100, sourceWidth: width ?? size, sourceHeight: size,
                components: components, ownershipVersion: 2, completeCCScan: true, ambiguousComponents: ambiguous, candidateComponents: candidates)
        }
        let boxes = [CGRect(x: 0.1, y: 0.1, width: 0.02, height: 0.2),
                     CGRect(x: 0.14, y: 0.1, width: 0.02, height: 0.2),
                     CGRect(x: 0.11, y: 0.08, width: 0.09, height: 0.2)]
        func input(secondColumn: Bool = true, reciprocal: Bool = true, correctFrame: Bool = true,
                   peerText: String = "独立した列", jointFirst: Bool = false, sourceSupport: Bool = true,
                   completeJoint: Bool = true, reading: Bool = false, invalidReading: Bool = false) -> [ReaderTranslationRegion] {
            let shared = completeJoint ? c0 : Evidence.Component(seed: 1210, pixelCount: 12, meanProbability: 0.95,
                runs: [.init(y: 12, x: 10, count: 12)])
            let own = Evidence.Component(seed: 2014, pixelCount: 2, meanProbability: 0.95,
                runs: [.init(y: 20, x: 14, count: 2)])
            let seeds = [evidence("left", 0, components: [], ambiguous: jointFirst ? [shared] : [], candidates: jointFirst ? [] : [
                .init(component: shared, competingOwnerIDs: ["peer"], outsideCompetingCells: [1])]),
                evidence("right", 1, components: secondColumn ? (jointFirst && sourceSupport ? [own] : []) : [c1], candidates: secondColumn ? [
                    .init(component: c1, competingOwnerIDs: ["peer"], outsideCompetingCells: [1])] : []),
                evidence("peer", 2, components: [independent], ambiguous: reciprocal ? [shared, c1] : [],
                    width: correctFrame ? size : size + 1)]
            let allSeedsValid = seeds.allSatisfy { $0.isValid }
            #expect(allSeedsValid)
            let words = ["左の列", "右の列", peerText, "補助"]
            let lines = (boxes + [boxes[2]]).enumerated().map { i, box -> NativeCoreMLOCRLine in
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95,
                    orientation: .vertical, detectorSeedEvidence: i < seeds.count ? [seeds[i]] : nil)
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: words[1] + words[0])
            body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
            body.acceptedSource = .union(bound.prefix(2).map(\.acceptedSource))
            var peer = ReaderTranslationRegion(id: "peer", rect: boxes[2], source: words[2])
            peer.sourceOrientation = .vertical; peer.sourceSingleVerticalColumn = true; peer.sourceImageAspectRatio = 1
            peer.acceptedSource = bound[2].acceptedSource
            if reading { peer.acceptedSource = peer.acceptedSource.retainingReading(bound[3].acceptedSource) }
            if invalidReading {
                let m = peer.acceptedSource.membership!
                peer.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [99], unknownDedup: [], hasUntrackedInputs: false))
            }
            return [body, peer]
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: .init(x: 0.09, y: 0.05, width: 0.08, height: 0.3), confidence: 0.95)
        for values in [input(), Array(input().reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count == 1 && result[0].source == "独立した列右の列左の列")
            #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            #expect(result[0].unitMemberRects.count == 2)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: []) == values)
        }
        for values in [input(secondColumn: false), input(reciprocal: false), input(correctFrame: false), input(peerText: "右の列")] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
        }
        for values in [input(jointFirst: true), input(jointFirst: true, reading: true),
                       Array(input(jointFirst: true, reading: true).reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count == 1 && result[0].source == "独立した列右の列左の列")
            #expect(!result[0].source.contains("補助"))
            #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            let readings = values.reduce(into: Set<Int>()) { $0.formUnion($1.acceptedSource.membership!.readings) }
            #expect(result[0].acceptedSource.membership?.readings == readings)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
        }
        for values in [input(jointFirst: true, sourceSupport: false), input(jointFirst: true, completeJoint: false),
                       input(reciprocal: false, jointFirst: true), input(correctFrame: false, jointFirst: true),
                       input(jointFirst: true, invalidReading: true)] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
        }
        for badScope in [NativeParagraphFragmentGrouping.TextScope(owner: 1, box: scope.box, confidence: 0.79),
                         .init(owner: 1, box: .null, confidence: 0.95)] {
            let values = input()
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [badScope]) == values)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func repeatedWholeColumnContactNeedsIndependentExteriorInk(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale), words = ["右側の長い文章", "左側の長い文章", "別の観測"]
        func input(contacts: Int = 2, parentExterior: Bool = true, peerExterior: Bool = true,
                   reciprocal: Bool = true, uniqueOwner: Bool = true, sameFrame: Bool = true,
                   verticalColumn: Bool = true) -> [ReaderTranslationRegion] {
            let boxes = [CGRect(x: 0.1, y: 0.1, width: 0.02, height: 0.2),
                         CGRect(x: 0.06, y: 0.1, width: 0.02, height: 0.2),
                         CGRect(x: parentExterior ? 0.105 : 0.05, y: 0.08, width: parentExterior ? 0.095 : 0.15, height: 0.22)]
            func component(_ x: Int, _ y: Int) -> Evidence.Component {
                .init(seed: y * 1000 + x, pixelCount: 2, meanProbability: 0.95, runs: [.init(y: y, x: x, count: 2)])
            }
            let shared = [120, 170, 230].prefix(contacts).map { component(110, $0) }
            let candidates = shared.map { Evidence.Candidate(component: $0,
                competingOwnerIDs: uniqueOwner ? ["peer"] : ["peer", "another"], outsideCompetingCells: uniqueOwner ? [1] : [1, 1]) }
            let seeds: [Evidence] = (0..<3).map { i -> Evidence in
                let owner = ["column", "left", "peer"][i]
                let ownX = i == 1 ? 70 : (peerExterior ? 180 : 115)
                let owned: [Evidence.Component] = i == 0 ? [] : [component(ownX, 150)]
                let ambiguous: [Evidence.Component] = i == 2 ? (reciprocal ? shared : Array(shared.dropLast())) : []
                let competing: [Evidence.Candidate] = i == 0 ? candidates : []
                let sourceWidth = i == 2 && !sameFrame ? size + 1 : size
                return .init(ownerID: owner, parentBoxIndex: i,
                    provenance: "db-complete-cc-candidates-v2", threshold: 0.9, mapOriginX: 0, mapOriginY: 0,
                    mapFullWidth: 1000, mapFullHeight: 1000, sourceWidth: sourceWidth, sourceHeight: size,
                    components: owned,
                    ownershipVersion: 2, completeCCScan: true,
                    ambiguousComponents: ambiguous, candidateComponents: competing)
            }
            let allSeedsValid = seeds.allSatisfy { $0.isValid }
            #expect(allSeedsValid)
            let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95,
                    orientation: i == 0 && !verticalColumn ? .horizontal : .vertical, detectorSeedEvidence: [seeds[i]])
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: words[0] + words[1])
            body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
            body.acceptedSource = .union(bound.prefix(2).map(\.acceptedSource))
            var peer = ReaderTranslationRegion(id: "peer", rect: boxes[2], source: words[2])
            peer.sourceOrientation = .vertical; peer.sourceSingleVerticalColumn = true; peer.sourceImageAspectRatio = 1
            peer.acceptedSource = bound[2].acceptedSource
            return [body, peer]
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
            box: .init(x: 0.04, y: 0.07, width: 0.17, height: 0.24), confidence: 0.95)
        for values in [input(), input(contacts: 3), Array(input().reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count == 1 && result[0].source == words[2] + words[0] + words[1])
            #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            #expect(result[0].unitMemberRects.count == 2)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
        }
        for values in [input(contacts: 1), input(parentExterior: false), input(peerExterior: false),
                       input(reciprocal: false), input(uniqueOwner: false), input(sameFrame: false), input(verticalColumn: false)] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func reciprocalColumnContactPreservesGlyphScaleAndReading(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale), rightText = "さしすせそたちつてと", leftText = "あいうえおかきくけこ"
        for horizontal in [false, true] {
            let boxes = [CGRect(x: 0.14, y: 0.1, width: 0.02, height: 0.3),
                         CGRect(x: 0.1, y: 0.12, width: 0.02, height: 0.2),
                         horizontal ? CGRect(x: 0.1, y: 0.31, width: 0.02, height: 0.02)
                             : CGRect(x: 0.102, y: 0.1, width: 0.012, height: 0.026)]
            let y = horizontal ? 31 : 11
            let shared = Evidence.Component(seed: y * 100 + 10, pixelCount: 2, meanProbability: 0.95,
                runs: [.init(y: y, x: 10, count: 1), .init(y: y + 1, x: 10, count: 1)])
            let other = Evidence.Component(seed: 2010, pixelCount: 1, meanProbability: 0.95, runs: [.init(y: 20, x: 10, count: 1)])
            func evidence(_ owner: Bool, reciprocal: Bool) -> Evidence {
                .init(ownerID: owner ? "column" : "mark", parentBoxIndex: owner ? 1 : 2,
                    provenance: "db-complete-cc-candidates-v2", threshold: 0.9, mapOriginX: 0, mapOriginY: 0,
                    mapFullWidth: 100, mapFullHeight: 100, sourceWidth: size, sourceHeight: size,
                    components: owner && !reciprocal ? [other] : [], ownershipVersion: 2, completeCCScan: true,
                    ambiguousComponents: owner && reciprocal ? [shared] : [], candidateComponents: owner ? [] : [
                        .init(component: shared, competingOwnerIDs: ["column"], outsideCompetingCells: [1])])
            }
            func input(reciprocal: Bool = true, markText: String = "印", tilted: Bool = false) -> [ReaderTranslationRegion] {
                let seeds = [evidence(true, reciprocal: reciprocal), evidence(false, reciprocal: reciprocal)]
                let allSeedsValid = seeds.allSatisfy { $0.isValid }
                #expect(allSeedsValid)
                let words = [rightText, leftText, markText]
                let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
                    let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    let polygon: [CGPoint] = i == 2 && tilted ? [
                        .init(x: b.minX, y: b.minY + b.height * 0.25), .init(x: b.minX + b.width * 0.75, y: b.minY),
                        .init(x: b.maxX, y: b.minY + b.height * 0.75), .init(x: b.minX + b.width * 0.25, y: b.maxY)] : [
                        .init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)]
                    return .init(polygon: polygon, text: words[i], score: 0.95,
                        orientation: i == 2 && horizontal ? .horizontal : .vertical,
                        detectorSeedEvidence: i == 0 ? nil : [seeds[i - 1]])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: rightText + leftText)
                body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
                body.acceptedSource = .union(bound.prefix(2).map(\.acceptedSource))
                var mark = ReaderTranslationRegion(id: "mark", rect: boxes[2], source: markText)
                mark.sourceOrientation = horizontal ? .horizontal : .vertical; mark.sourceImageAspectRatio = 1
                mark.acceptedSource = bound[2].acceptedSource
                return [body, mark]
            }
            let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: boxes[0].union(boxes[1]).union(boxes[2]), confidence: 0.6)
            for values in [input(), Array(input().reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
                let expected = horizontal ? rightText + leftText + "印" : rightText + "印" + leftText
                #expect(result.count == 1 && result[0].source == expected)
                #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
            let missing = input(reciprocal: false)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(missing, scopes: [scope]) == missing)
            if !horizontal {
                let differentScale = input(markText: "abc")
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(differentScale, scopes: [scope]) == differentScale)
            } else {
                let tilted = input(tilted: true)
                let joined = NativeParagraphFragmentGrouping.reconcilingObservations(tilted, scopes: [scope])
                #expect(joined.count == 1 && joined[0].source == rightText + leftText + "印")
                #expect(joined[0].acceptedSource.membership?.body == Set([0, 1, 2]))
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(joined, scopes: [scope]) == joined)
                let unsupported = input(reciprocal: false, tilted: true)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(unsupported, scopes: [scope]) == unsupported)
            }
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func compactHorizontalGlyphContactRequiresReciprocalOwnership(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale), right = "あいうえおかきくけこ"
        func input(reciprocal: Bool = true, sameFrame: Bool = true, wideWord: Bool = false,
                   verticalPeer: Bool = false, uncertain: Bool = false, outsideContact: Bool = false) -> [ReaderTranslationRegion] {
            let boxes = [CGRect(x: 0.16, y: 0.1, width: 0.02, height: 0.2),
                         CGRect(x: 0.1, y: 0.125, width: 0.025, height: 0.035),
                         CGRect(x: 0.1, y: 0.1, width: wideWord ? 0.12 : 0.03, height: 0.032)]
            let sharedX = outsideContact ? 135 : 110
            let shared = Evidence.Component(seed: 127000 + sharedX, pixelCount: 2, meanProbability: 0.95,
                runs: [.init(y: 127, x: sharedX, count: 2)])
            let own = Evidence.Component(seed: 110120, pixelCount: 2, meanProbability: 0.95,
                runs: [.init(y: 110, x: 120, count: 2)])
            func evidence(_ head: Bool) -> Evidence {
                .init(ownerID: head ? "head" : "lower", parentBoxIndex: head ? 2 : 1,
                    provenance: "db-complete-cc-candidates-v2", threshold: 0.9, mapOriginX: 0, mapOriginY: 0,
                    mapFullWidth: 1000, mapFullHeight: 1000, sourceWidth: head && !sameFrame ? size + 1 : size, sourceHeight: size,
                    components: head ? [own] : [], ownershipVersion: 2, completeCCScan: true,
                    ambiguousComponents: head && reciprocal ? [shared] : [],
                    candidateComponents: head ? [] : [.init(component: shared, competingOwnerIDs: ["head"], outsideCompetingCells: [1])])
            }
            let words = [right, "乙", "甲"]
            let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                let tilt = CGFloat(size) * 0.008
                let polygon: [CGPoint] = i == 2 ? [
                    .init(x: b.minX, y: b.minY + tilt), .init(x: b.maxX - tilt, y: b.minY),
                    .init(x: b.maxX, y: b.maxY - tilt), .init(x: b.minX + tilt, y: b.maxY)] : [
                    .init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)]
                let seeds = i == 0 ? nil : [evidence(i == 2)]
                #expect(seeds?.allSatisfy(\.isValid) ?? true)
                return .init(polygon: polygon, text: words[i], score: 0.95,
                    orientation: i == 0 || (i == 1 && verticalPeer) ? .vertical : .horizontal, detectorSeedEvidence: seeds)
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: right + "乙")
            body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
            body.acceptedSource = .union(bound.prefix(2).map(\.acceptedSource))
            var head = ReaderTranslationRegion(id: "head", rect: boxes[2], source: "甲")
            head.sourceOrientation = .horizontal; head.sourceSingleVerticalColumn = false; head.sourceImageAspectRatio = 1
            head.acceptedSource = bound[2].acceptedSource
            if uncertain {
                let m = head.acceptedSource.membership!
                head.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [], unknownDedup: m.body, hasUntrackedInputs: false))
            }
            return [body, head]
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
            box: .init(x: 0.09, y: 0.09, width: 0.15, height: 0.22), confidence: 0.95)
        for values in [input(), Array(input().reversed()), input(verticalPeer: true), Array(input(verticalPeer: true).reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count == 1 && result[0].source == right + "甲乙")
            #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            #expect(result[0].unitMemberRects.count == 2)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
        }
        for values in [input(reciprocal: false), input(sameFrame: false), input(wideWord: true),
                       input(reciprocal: false, verticalPeer: true), input(verticalPeer: true, outsideContact: true),
                       input(sameFrame: false, verticalPeer: true), input(uncertain: true)] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func jointComponentContactPreservesNestedDuplicateAndOriginalOrder(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale), rightText = "さしすせそたちつてと", leftText = "あいうえおかきくけこ"
        let boxes = [CGRect(x: 0.14, y: 0.1, width: 0.02, height: 0.3),
                     CGRect(x: 0.1, y: 0.12, width: 0.02, height: 0.2),
                     CGRect(x: 0.102, y: 0.1, width: 0.012, height: 0.026)]
        func input(complete: Bool = true, independent: Bool = true, sameFrame: Bool = true,
                   duplicate: Bool = false, uncertainDuplicate: Bool = false) -> [ReaderTranslationRegion] {
            let count = complete ? 2 : 21
            let shared = Evidence.Component(seed: 121105, pixelCount: count, meanProbability: 0.95,
                runs: [.init(y: 121, x: 105, count: count)])
            func evidence(_ peer: Bool) -> Evidence {
                let y = peer ? 105 : 200
                let own = Evidence.Component(seed: y * 1000 + 105, pixelCount: 2, meanProbability: 0.95,
                    runs: [.init(y: y, x: 105, count: 2)])
                return .init(ownerID: peer ? "head" : "column", parentBoxIndex: peer ? 2 : 1,
                    provenance: "db-complete-cc-candidates-v2", threshold: 0.9, mapOriginX: 0, mapOriginY: 0,
                    mapFullWidth: 1000, mapFullHeight: peer && !sameFrame ? 1001 : 1000, sourceWidth: size, sourceHeight: size,
                    components: peer && !independent ? [] : [own], ownershipVersion: 2, completeCCScan: true,
                    ambiguousComponents: [shared], candidateComponents: [])
            }
            let seeds = [evidence(false), evidence(true)]
            let allSeedsValid = seeds.allSatisfy { $0.isValid }
            #expect(allSeedsValid)
            let words = [rightText, leftText, "印", leftText]
            let support = boxes + [boxes[1]]
            let lines = support.enumerated().map { i, box -> NativeCoreMLOCRLine in
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95,
                    orientation: .vertical, detectorSeedEvidence: i == 1 ? [seeds[0]] : i == 2 ? [seeds[1]] : nil)
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: rightText + leftText)
            body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
            body.acceptedSource = .union(bound.prefix(2).map(\.acceptedSource))
            var head = ReaderTranslationRegion(id: "head", rect: boxes[2], source: "印")
            head.sourceOrientation = .vertical; head.sourceSingleVerticalColumn = true; head.sourceImageAspectRatio = 1
            head.acceptedSource = bound[2].acceptedSource
            var copy = ReaderTranslationRegion(id: "duplicate", rect: boxes[1], source: leftText)
            copy.sourceOrientation = .vertical; copy.sourceSingleVerticalColumn = true; copy.sourceImageAspectRatio = 1
            copy.acceptedSource = bound[3].acceptedSource
            if uncertainDuplicate {
                let m = copy.acceptedSource.membership!
                copy.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [], unknownDedup: [3], hasUntrackedInputs: false))
            }
            return duplicate ? [body, head, copy] : [body, head]
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: boxes[0].union(boxes[1]), confidence: 0.95)
        for duplicate in [false, true] {
            for values in [input(duplicate: duplicate), Array(input(duplicate: duplicate).reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
                #expect(result.count == 1 && result[0].source == rightText + "印" + leftText)
                #expect(result[0].acceptedSource.membership?.body == Set(duplicate ? [0, 1, 2, 3] : [0, 1, 2]))
                #expect(result[0].unitMemberRects.count == (duplicate ? 3 : 2))
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
        }
        for values in [input(complete: false), input(independent: false), input(sameFrame: false)] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
        }
        let uncertain = input(duplicate: true, uncertainDuplicate: true)
        let retained = NativeParagraphFragmentGrouping.reconcilingObservations(uncertain, scopes: [scope])
        #expect(retained.count == 2)
        #expect(retained.first(where: { $0.id == "body" })?.source == rightText + leftText)
        #expect(retained.first(where: { $0.id == "body" })?.unitMemberRects.count == 2)
        #expect(retained.first(where: { $0.id == "head" }) == uncertain[1])
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func uncertainInteriorAllowsOnlyUniqueKnownOuterExtensions(scale: CGFloat) {
        let size = Int(1000 * scale), rightText = "さしすせそたちつてと", leftText = "あいうえおかきくけこ"
        for prefix in [true, false] {
            let boxes = [CGRect(x: 0.14, y: 0.12, width: 0.02, height: 0.3),
                         CGRect(x: 0.1, y: 0.1, width: 0.02, height: 0.2),
                         CGRect(x: 0.1, y: 0.2, width: 0.02, height: 0.03),
                         prefix ? CGRect(x: 0.14, y: 0.08, width: 0.02, height: 0.05)
                             : CGRect(x: 0.1, y: 0.29, width: 0.02, height: 0.06)]
            let extensionText = prefix ? "前置き" : "後置き"
            func input(uncertainTip: Bool = false, untracked: Bool = false, ambiguous: Bool = false) -> [ReaderTranslationRegion] {
                let words = [rightText, leftText, "あ", extensionText, "別の列"]
                let support = boxes + [boxes[3]]
                let lines = support.enumerated().map { i, box -> NativeCoreMLOCRLine in
                    let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95, orientation: .vertical)
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: rightText + leftText)
                body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
                let m = bound[0].acceptedSource.membership!
                let unknown: Set<Int> = uncertainTip ? [2, prefix ? 0 : 1] : [2]
                body.acceptedSource = .init(.init(table: m.table, body: [0, 1, 2], readings: [], unknownDedup: unknown,
                    hasUntrackedInputs: untracked))
                var fragment = ReaderTranslationRegion(id: "fragment", rect: boxes[3], source: extensionText)
                fragment.sourceOrientation = .vertical; fragment.sourceSingleVerticalColumn = true; fragment.sourceImageAspectRatio = 1
                fragment.acceptedSource = bound[3].acceptedSource
                var other = ReaderTranslationRegion(id: "alternative", rect: boxes[3], source: words[4])
                other.sourceOrientation = .vertical; other.sourceSingleVerticalColumn = true; other.sourceImageAspectRatio = 1
                other.acceptedSource = bound[4].acceptedSource
                return ambiguous ? [body, fragment, other] : [body, fragment]
            }
            let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: boxes[0].union(boxes[1]).union(boxes[3]), confidence: 0.95)
            for values in [input(), Array(input().reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
                let expected = prefix ? extensionText + rightText + leftText : rightText + leftText + extensionText
                #expect(result.count == 1 && result[0].source == expected)
                #expect(result[0].source.contains(rightText + leftText))
                #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2, 3]))
                #expect(result[0].acceptedSource.membership?.unknownDedup == Set([2]))
                #expect(result[0].unitMemberRects.count == 2)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
            for values in [input(uncertainTip: true), input(untracked: true), input(ambiguous: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
            }
            for index in [0, 1] {
                var values = input(); values[index].sourceOrientation = .horizontal
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
            }
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func originalColumnProofSurvivesAggregationWithoutParagraphBootstrapping(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        let words = ["あいうえお", "かきくけこ", "さしすせそたちつてと", "なにぬねのはひふへほ"]
        func input(expanded: Bool = false, block: Bool = false, unfragmented: Bool = false,
                   missingEvidence: Bool = false, separateColumns: Bool = false, reversed: Bool = false,
                   uncertain: Bool = false, competing: Bool = false) -> [ReaderTranslationRegion] {
            let boxes = [CGRect(x: 0.18, y: 0.1, width: 0.02, height: unfragmented ? 0.3 : 0.15),
                         CGRect(x: separateColumns ? 0.205 : 0.18, y: 0.24, width: 0.02, height: 0.16),
                         CGRect(x: 0.15, y: 0.1, width: 0.02, height: 0.28),
                         CGRect(x: 0.12, y: 0.1, width: 0.02, height: 0.28)]
            let support = boxes + [boxes[2]]
            let source = [unfragmented ? words[0] + words[1] : words[0], words[1], words[2], words[3], words[2]]
            let lines = support.enumerated().map { i, box -> NativeCoreMLOCRLine in
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                let x = Int((box.minX * 1000).rounded()) + 5
                let y = i == 1 ? 250 : 110
                let height = i == 0 ? (unfragmented ? 280 : 130) : i == 1 ? 140 : 260
                let component = Evidence.Component(seed: y * 1000 + x, pixelCount: height * 5, meanProbability: 0.95,
                    runs: (y..<(y + height)).map { .init(y: $0, x: x, count: 5) })
                let evidence = Evidence(ownerID: "owner-\(i)", parentBoxIndex: i, provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                    mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000, sourceWidth: size, sourceHeight: size,
                    components: [component], ownershipVersion: 2, completeCCScan: true, ambiguousComponents: [], candidateComponents: [])
                #expect(evidence.isValid)
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: source[i], score: 0.95,
                    orientation: .vertical, detectorSeedEvidence: i == 1 && missingEvidence ? nil : [evidence])
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            func region(_ name: String, _ indices: [Int]) -> ReaderTranslationRegion {
                let box = indices.map { support[$0] }.reduce(CGRect.null) { $0.union($1) }
                var r = ReaderTranslationRegion(id: name, rect: box, source: indices.map { source[$0] }.joined())
                r.sourceOrientation = .vertical; r.sourceImageAspectRatio = 1; r.sourceSingleVerticalColumn = name != "child" || !block
                r.acceptedSource = .union(indices.map { bound[$0].acceptedSource })
                return r
            }
            var root = region("root", unfragmented ? [0] : reversed ? [1, 0] : [0, 1])
            if uncertain {
                let m = root.acceptedSource.membership!
                root.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [], unknownDedup: m.body, hasUntrackedInputs: false))
            }
            var result = expanded ? [region("top", [0]), region("continuation", [1])] : [root]
            result.append(region("child", block ? [2, 3] : [2]))
            if competing { result.append(region("alternative", [4])) }
            return result
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
            box: .init(x: 0.11, y: 0.09, width: 0.13, height: 0.32), confidence: 0.95)
        for block in [false, true] {
            for expanded in [false, true] {
                let values = input(expanded: expanded, block: block)
                for ordered in [values, Array(values.reversed())] {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
                    #expect(result.count == 1 && result[0].source == words[0] + words[1] + words[2] + (block ? words[3] : ""))
                    #expect(result[0].acceptedSource.membership?.body == Set(block ? [0, 1, 2, 3] : [0, 1, 2]))
                    #expect(values.allSatisfy { result[0].rect.insetBy(dx: -1e-12, dy: -1e-12).contains($0.rect) })
                    #expect(result[0].unitMemberRects.count == values.count)
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
                }
            }
            for values in [input(block: block, unfragmented: true), input(block: block, missingEvidence: true),
                           input(block: block, separateColumns: true), input(block: block, reversed: true), input(block: block, uncertain: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
            }
        }
        let ambiguous = input(competing: true)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(ambiguous, scopes: [scope]) == ambiguous)
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func proofConnectedColumnExtensionPreservesOriginalTextAndPackets(scale: CGFloat) {
        let size = Int(1000 * scale)
        let boxes = [CGRect(x: 0.1, y: 0.1, width: 0.08, height: 0.2),
                     CGRect(x: 0.12, y: 0.12, width: 0.02, height: 0.04),
                     CGRect(x: 0.076, y: 0.1, width: 0.02, height: 0.18)]
        let words = ["本文の複数列", "複数", "隣の列"]
        let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
            let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
            return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95, orientation: .vertical)
        }
        let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
        let values = boxes.enumerated().map { i, box -> ReaderTranslationRegion in
            var r = ReaderTranslationRegion(id: "unit-\(i)", rect: box, source: words[i])
            r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = i != 0; r.sourceImageAspectRatio = 1
            r.acceptedSource = bound[i].acceptedSource
            return r
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
            box: .init(x: 0.07, y: 0.09, width: 0.12, height: 0.23), confidence: 0.95)
        for input in [values, Array(values.reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [scope])
            #expect(result.count == 1 && result[0].source == words[0] + words[2])
            #expect(result[0].unitMemberRects.count == 3)
            #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
        }
        let unproven = [values[0], values[2]]
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(unproven, scopes: [scope]) == unproven)
        let fragments = [CGRect(x: 0.14, y: 0.1, width: 0.02, height: 0.1),
                         CGRect(x: 0.14, y: 0.21, width: 0.02, height: 0.1),
                         CGRect(x: 0.116, y: 0.1, width: 0.02, height: 0.21)].enumerated().map { i, box -> ReaderTranslationRegion in
            var r = ReaderTranslationRegion(id: "fragment-\(i)", rect: box, source: ["上の列", "続き", "左列"][i])
            r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = true; r.sourceImageAspectRatio = 1
            return r
        }
        let fragmentScope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
            box: .init(x: 0.11, y: 0.09, width: 0.06, height: 0.23), confidence: 0.95)
        for input in [fragments, Array(fragments.reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(input, scopes: [fragmentScope])
            #expect(result.count == 1 && result[0].source == "上の列続き左列")
            #expect(result[0].unitMemberRects.count == 3)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func completeInkBoundaryDoesNotShrinkOriginalSourceOrMaskSupport(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale), words = ["本文の列", "文", "新列", "尾"]
        let boxes = [CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.2),
                     CGRect(x: 0.11, y: 0.12, width: 0.02, height: 0.04),
                     CGRect(x: 0.134, y: 0.1, width: 0.02, height: 0.18),
                     CGRect(x: 0.16, y: 0.15, width: 0.02, height: 0.1)]
        func input(partial: Bool = false, foreignCells: Bool = false) -> [ReaderTranslationRegion] {
            let top = foreignCells ? 350 : 110
            let component = Evidence.Component(seed: top * 1000 + 110, pixelCount: 3600, meanProbability: 0.95,
                runs: (top..<(top + 180)).map { .init(y: $0, x: 110, count: 20) })
            let evidence = Evidence(ownerID: "body", parentBoxIndex: 0, provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000, sourceWidth: size, sourceHeight: size,
                components: [component], ownershipVersion: 2, completeCCScan: true, ambiguousComponents: [], candidateComponents: [])
            #expect(evidence.isValid)
            let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95,
                    orientation: .vertical, detectorSeedEvidence: i == 0 ? [evidence] : nil)
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            return (0..<3).map { i in
                var r = ReaderTranslationRegion(id: "unit-\(i)", rect: boxes[i], source: words[i] + (i == 0 && partial ? words[3] : ""))
                r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = i != 0; r.sourceImageAspectRatio = 1
                r.acceptedSource = i == 0 && partial ? .union([bound[0].acceptedSource, bound[3].acceptedSource]) : bound[i].acceptedSource
                return r
            }
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
            box: .init(x: 0.09, y: 0.09, width: 0.12, height: 0.22), confidence: 0.95)
        for values in [input(), Array(input().reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count == 1 && result[0].source == words[2] + words[0])
            #expect(result[0].rect == boxes[0] && result[0].unitMemberRects.count == 3)
            #expect(result[0].unitMemberRects.contains(boxes[0]))
            #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
        }
        for values in [input(partial: true), input(foreignCells: true)] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count == 2 && result.first(where: { $0.id == "unit-0" })?.source == values[0].source)
            #expect(result.first(where: { $0.id == "unit-2" }) == values[2])
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func independentInkAxisRepairsPaddingWithoutBorrowingCandidateOwnership(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        let words = ["あいうえおかきくけこさしすせそ", "たちつてとなに", "ぬねのはひふへ"]
        func input(observed: Bool = true, candidateOnly: Bool = false, foreign: Bool = false,
                   uncertain: Bool = false, displaced: Bool = false, overlapping: Bool = false) -> [ReaderTranslationRegion] {
            let boxes = [CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.6),
                         CGRect(x: 0.17, y: 0.1, width: 0.035, height: 0.21),
                         CGRect(x: 0.155, y: overlapping ? 0.29 : 0.34, width: 0.07, height: 0.21)]
            let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                let x = i == 0 ? 120 : (i == 2 && displaced ? 210 : 183)
                let y = i == 2 ? (foreign ? 600 : overlapping ? 300 : 350) : 110
                let height = i == 0 ? 580 : 180
                let component = Evidence.Component(seed: y * 1000 + x, pixelCount: 10 * height, meanProbability: 0.95,
                    runs: (y..<(y + height)).map { .init(y: $0, x: x, count: 10) })
                let borrowed = i == 2 && candidateOnly
                let evidence = Evidence(ownerID: "owner-\(i)", parentBoxIndex: i, provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                    mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000, sourceWidth: size, sourceHeight: size,
                    components: borrowed ? [] : [component], ownershipVersion: 2, completeCCScan: true, ambiguousComponents: [],
                    candidateComponents: borrowed ? [.init(component: component, competingOwnerIDs: ["another-owner"], outsideCompetingCells: [1])] : [])
                #expect(evidence.isValid)
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[i], score: 0.95,
                    orientation: .vertical, detectorSeedEvidence: observed ? [evidence] : nil)
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: words[1] + words[0])
            body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
            body.acceptedSource = .union([bound[0].acceptedSource, bound[1].acceptedSource])
            var tail = ReaderTranslationRegion(id: "tail", rect: boxes[2], source: words[2])
            tail.sourceOrientation = .vertical; tail.sourceSingleVerticalColumn = true; tail.sourceImageAspectRatio = 1
            tail.acceptedSource = bound[2].acceptedSource
            if uncertain {
                let m = tail.acceptedSource.membership!
                tail.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [], unknownDedup: [2], hasUntrackedInputs: false))
            }
            return [body, tail]
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
            box: .init(x: 0.09, y: 0.09, width: 0.15, height: 0.62), confidence: 0.95)
        for values in [input(), Array(input().reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count == 1 && result[0].source == words[1] + words[2] + words[0])
            #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            #expect(values.allSatisfy { result[0].rect.insetBy(dx: -1e-12, dy: -1e-12).contains($0.rect) })
            #expect(result[0].unitMemberRects.count == 2)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
        }
        for values in [input(observed: false), input(candidateOnly: true), input(foreign: true),
                       input(uncertain: true), input(displaced: true)] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope]) == values)
        }
        let unowned = input()
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(unowned, scopes: []) == unowned)
        let inkScope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
            box: .init(x: 0.115, y: 0.105, width: 0.085, height: 0.585), confidence: 0.6)
        for values in [input(), Array(input().reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [inkScope])
            #expect(result.count == 1 && result[0].source == words[1] + words[2] + words[0])
            #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            #expect(values.allSatisfy { result[0].rect.insetBy(dx: -1e-12, dy: -1e-12).contains($0.rect) })
        }
        let competing = NativeParagraphFragmentGrouping.TextScope(owner: 2, box: inkScope.box, confidence: 0.55)
        let observed = input()
        for proposals in [[inkScope, competing], [competing, inkScope]] {
            let ranked = NativeParagraphFragmentGrouping.reconcilingObservations(observed, scopes: proposals)
            #expect(ranked.count == 1 && ranked[0].source == words[1] + words[2] + words[0])
            #expect(ranked[0].acceptedSource.membership?.body == Set([0, 1, 2]))
        }
        let tied = NativeParagraphFragmentGrouping.TextScope(owner: 2, box: inkScope.box, confidence: inkScope.confidence)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(observed, scopes: [inkScope, tied]) == observed)
        for values in [input(observed: false), input(candidateOnly: true), input(foreign: true),
                       input(uncertain: true), input(displaced: true), input(overlapping: true)] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [inkScope]) == values)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func horizontalWordTailRequiresCompleteColumnSupportAndKeepsAtomicText(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        let left = "なにぬねのはひふへほ", middle = "あいうえおかきくけこ", right = "さしすせそたちつてと", word = "甲乙"
        func input(observed: Bool = true, completeParent: Bool = false, partialParent: Bool = false,
                   singleSide: Bool = false, stray: Bool = false, tilted: Bool = false, spanning: Bool = false,
                   uncertain: Bool = false, ambiguous: Bool = false, narrowWord: Bool = false,
                   oneColumnParent: Bool = false) -> [ReaderTranslationRegion] {
            let boxes = [CGRect(x: 0.08, y: 0.1, width: 0.02, height: 0.3),
                         CGRect(x: 0.11, y: 0.1, width: 0.02, height: spanning ? 0.3 : 0.2),
                         CGRect(x: 0.14, y: 0.1, width: 0.02, height: 0.2),
                         CGRect(x: 0.11, y: 0.29, width: narrowWord ? 0.02 : 0.05, height: 0.03),
                         CGRect(x: 0.112, y: 0.11, width: 0.012, height: 0.025)]
            let support = boxes + [boxes[0], boxes[1], boxes[2], boxes[4]]
            let alternatives = ["がぎぐげござじずぜぞ", "まみむめもやゆよらり", "らりるれろわをんゃゅ"]
            let words = [left, middle, right, narrowWord ? "甲" : word, "あ"] + alternatives + ["ま"]
            func component(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> Evidence.Component {
                .init(seed: y * 1000 + x, pixelCount: width * height, meanProbability: 0.95,
                    runs: (y..<(y + height)).map { .init(y: $0, x: x, count: width) })
            }
            var components = [component(115, 305, 10, 10)]
            if !singleSide && !narrowWord { components.append(component(145, 305, 10, 10)) }
            if stray { components.append(component(133, 305, 3, 3)) }
            func evidence(_ id: Int, _ owned: [Evidence.Component]) -> Evidence {
                .init(ownerID: "owner-\(id)", parentBoxIndex: id, provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                    mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000, sourceWidth: size, sourceHeight: size,
                    components: owned, ownershipVersion: 2, completeCCScan: true, ambiguousComponents: [], candidateComponents: [])
            }
            let lines = support.enumerated().map { i, box -> NativeCoreMLOCRLine in
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                let polygon: [CGPoint] = i == 3 && tilted ? [
                    .init(x: b.minX, y: b.minY + b.height * 0.25), .init(x: b.minX + b.width * 0.75, y: b.minY),
                    .init(x: b.maxX, y: b.minY + b.height * 0.75), .init(x: b.minX + b.width * 0.25, y: b.maxY)] : [
                    .init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)]
                var seeds: [Evidence]? = nil
                if i == 3 { seeds = [evidence(i, components)] }
                if completeParent && i < 3 && !(partialParent && i == 1) {
                    seeds = [evidence(i, [component([85, 125, 155][i], 110, 5, i == 0 ? 280 : 180)])]
                }
                #expect(seeds?.allSatisfy(\.isValid) ?? true)
                return .init(polygon: polygon, text: words[i], score: 0.95, orientation: i == 3 ? .horizontal : .vertical,
                    detectorSeedEvidence: seeds)
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            func region(_ id: String, _ box: CGRect, _ source: String, _ indices: [Int], _ horizontal: Bool = false) -> ReaderTranslationRegion {
                var r = ReaderTranslationRegion(id: id, rect: box, source: source)
                r.sourceOrientation = horizontal ? .horizontal : .vertical; r.sourceImageAspectRatio = 1
                r.sourceSingleVerticalColumn = indices.count == 1 && !horizontal
                r.acceptedSource = .union(indices.map { bound[$0].acceptedSource })
                return r
            }
            let envelope = boxes[0].union(boxes[1]).union(boxes[2])
            let body = region("body", oneColumnParent ? boxes[1] : envelope, oneColumnParent ? middle : right + middle + left,
                oneColumnParent ? [1] : [0, 1, 2])
            let witness = region("witness", boxes[4], "あ", [4])
            var tail = region("word", boxes[3], words[3], [3], true)
            if uncertain {
                let m = tail.acceptedSource.membership!
                tail.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [], unknownDedup: [3], hasUntrackedInputs: false))
            }
            var result = observed ? [body, witness, tail] : [body, tail]
            if ambiguous {
                result += [region("alternative-body", envelope, alternatives[2] + alternatives[1] + alternatives[0], [5, 6, 7]),
                           region("alternative-witness", boxes[4], "ま", [8])]
            }
            return result
        }
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
            box: .init(x: 0.07, y: 0.09, width: 0.1, height: 0.32), confidence: 0.95)
        let positives: [([ReaderTranslationRegion], String)] = [
            (input(), right + middle + word + left), (Array(input().reversed()), right + middle + word + left),
            (input(observed: false, completeParent: true), right + middle + word + left),
            (input(narrowWord: true), right + middle + "甲" + left),
            (input(observed: false, completeParent: true, narrowWord: true, oneColumnParent: true), middle + "甲")]
        for (values, expected) in positives {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count == 1 && result[0].source == expected)
            #expect(result[0].source.contains(values.first(where: { $0.id == "word" })!.source)) // Never split or reverse the atomic read.
            #expect(result[0].unitMemberRects.count == values.count)
            let packets = values.reduce(into: Set<Int>()) { $0.formUnion($1.acceptedSource.membership!.body) }
            #expect(result[0].acceptedSource.membership?.body == packets)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
        }
        for values in [input(singleSide: true), input(stray: true), input(tilted: true), input(spanning: true),
                       input(uncertain: true), input(observed: false), input(observed: false, completeParent: true, partialParent: true),
                       input(ambiguous: true)] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope])
            #expect(result.count > 1)
            #expect(result.first(where: { $0.id == "word" }) == values.first(where: { $0.id == "word" }))
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func compoundHorizontalHeadsPreserveOriginalWords(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        for headCount in [1, 2, 4] {
            let count = headCount + 2
            func input(singleSide: Bool = false, wideGap: Bool = false, shared: Bool = false,
                       orphan: Bool = false, foreign: Bool = false, hidden: Int = 0,
                       missing: Int? = nil, outside: Bool = false, cycle: Bool = false,
                       otherTable: Bool = false, unknown: Bool = false) -> [ReaderTranslationRegion] {
                let parents = (0..<count).map { i in CGRect(x: 0.1 + CGFloat(i) * 0.03 + (wideGap && i == 1 ? 0.01 : 0),
                    y: i == count - 1 ? 0.2 : 0.22, width: 0.02, height: i == count - 1 ? 0.18 : 0.16) }
                let heads = (0..<headCount).map { i -> CGRect in
                    if i == 0 { return .init(x: 0.1, y: 0.2, width: wideGap ? 0.06 : 0.05, height: 0.02) }
                    let x: CGFloat = shared && i == 1 ? 0.148 : 0.1 + CGFloat(i + 1) * 0.03
                    return .init(x: x, y: 0.2, width: 0.12 + CGFloat(i + 1) * 0.03 - x, height: 0.02)
                }
                let extra = CGRect(x: hidden == 1 ? 0.123 : 0.8, y: hidden == 1 ? 0.24 : 0.8, width: 0.005, height: 0.03)
                let boxes = parents + heads + (hidden != 0 || foreign ? [extra] : [])
                let sharedCC = Evidence.Component(seed: 205149, pixelCount: 2, meanProbability: 0.95,
                    runs: [.init(y: 205, x: 149, count: 2)])
                let lines = boxes.enumerated().map { i, box -> NativeCoreMLOCRLine in
                    let isHead = i >= count && i < count + headCount
                    let isExtra = i >= count + headCount
                    let x = outside && i == count ? 90 : isHead && i > count ?
                        Int((parents[i - count + 1].minX * 1000).rounded()) + 5 : Int((box.minX * 1000).rounded()) + (isExtra ? 1 : 5)
                    let y = Int((box.minY * 1000).rounded()) + 2
                    let width = isExtra ? 3 : i == count && !singleSide ? Int((box.width * 1000).rounded()) - 10 : 10
                    let height = Int((box.height * 1000).rounded()) - 4
                    let component = Evidence.Component(seed: y * 1000 + x, pixelCount: width * height, meanProbability: 0.95,
                        runs: (y..<(y + height)).map { .init(y: $0, x: x, count: width) })
                    let isForeign = i >= count + headCount && foreign
                    let e = Evidence(ownerID: "source-\(i)", parentBoxIndex: i,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                        mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                        sourceWidth: size, sourceHeight: size, components: isForeign ? [] : [component], ownershipVersion: 2,
                        completeCCScan: true, ambiguousComponents: isForeign ||
                            (shared && (i == count || (i == count + 1 && !orphan))) ? [sharedCC] : [], candidateComponents: [])
                    #expect(e.isValid)
                    let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)],
                        text: isHead ? (i == count ? "甲乙" : "印\(i)") : "列\(i)あいうえおか", score: 0.95,
                        orientation: isHead ? .horizontal : .vertical, detectorSeedEvidence: missing == i ? nil : [e])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                let bodyIDs = cycle ? Array(0..<count) : Array((0..<count).reversed())
                var body = ReaderTranslationRegion(id: "body", rect: parents.reduce(CGRect.null) { $0.union($1) },
                    source: bodyIDs.map { lines[$0].text }.joined())
                body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
                body.acceptedSource = .union(bodyIDs.map { bound[$0].acceptedSource })
                let headIDs = Array(count..<(count + headCount))
                var head = ReaderTranslationRegion(id: "head", rect: heads.reduce(CGRect.null) { $0.union($1) },
                    source: headIDs.map { lines[$0].text }.joined())
                head.sourceOrientation = .horizontal; head.sourceSingleVerticalColumn = false; head.sourceImageAspectRatio = 1
                if !unknown {
                    let headerTable = otherTable ? NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size) : bound
                    head.acceptedSource = .union(headIDs.map { headerTable[$0].acceptedSource })
                }
                return [body, head]
            }
            func scope(_ values: [ReaderTranslationRegion], confidence: Double = 0.95) -> NativeParagraphFragmentGrouping.TextScope {
                .init(owner: 1, box: values[0].rect.union(values[1].rect), confidence: confidence)
            }
            let positives = [input(), input(hidden: 2)] + (headCount > 1 ? [input(shared: true)] : [])
            for values in positives {
                for ordered in [values, Array(values.reversed())] {
                    let merged = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope(values)])
                    let table = values[0].acceptedSource.membership!.table
                    let expected = table.packets[count - 1].text + values[1].source +
                        (0..<(count - 1)).reversed().map { table.packets[$0].text }.joined()
                    #expect(merged.count == 1 && merged[0].source == expected)
                    #expect(merged[0].acceptedSource.membership?.body == Set(0..<(count + headCount)))
                    #expect(merged[0].acceptedSource.membership?.table === table)
                    #expect(merged[0].source.contains(values[1].source))
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(merged, scopes: [scope(values)]) == merged)
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(ordered,
                        scopes: [scope(values, confidence: 0.79)]) == ordered)
                }
            }
            for negative in [input(singleSide: true), input(wideGap: true), input(shared: true, orphan: true),
                             input(shared: true, foreign: true), input(hidden: 1), input(missing: 0), input(missing: count),
                             input(outside: true), input(cycle: true), input(otherTable: true), input(unknown: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [scope(negative)]) == negative)
            }
            var crowded = input()
            var unknown = ReaderTranslationRegion(id: "unknown", rect: .init(x: 0.123, y: 0.24, width: 0.005, height: 0.03), source: "未知")
            unknown.sourceOrientation = .vertical; unknown.sourceSingleVerticalColumn = true; unknown.sourceImageAspectRatio = 1
            crowded.append(unknown)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(crowded, scopes: [scope(crowded)]) == crowded)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func horizontalRowsRequireCompleteScopeAndOriginalOwnership(scale: CGFloat) {
        for count in [2, 3, 5] {
            func input(gap: CGFloat = 0.01) -> [ReaderTranslationRegion] {
                let boxes = (0..<count).map { index in
                    CGRect(x: 0.1, y: 0.1 + CGFloat(index) * (0.025 + gap),
                           width: index == count - 1 ? 0.17 : 0.2, height: 0.025)
                        .applying(.init(scaleX: scale, y: scale))
                }
                let lines = boxes.enumerated().map { index, rect -> NativeCoreMLOCRLine in
                    let box = rect.applying(.init(scaleX: 1000, y: 1000))
                    return .init(polygon: [.init(x: box.minX, y: box.minY), .init(x: box.maxX, y: box.minY),
                        .init(x: box.maxX, y: box.maxY), .init(x: box.minX, y: box.maxY)],
                        text: "row\(index)", score: 0.95, orientation: .horizontal)
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: 1000, height: 1000)
                return boxes.enumerated().map { index, box in
                    var region = ReaderTranslationRegion(id: "r\(index)", rect: box, source: lines[index].text)
                    region.sourceOrientation = .horizontal; region.sourceImageAspectRatio = 1
                    region.acceptedSource = bound[index].acceptedSource
                    return region
                }
            }
            func scope(_ values: [ReaderTranslationRegion]) -> NativeParagraphFragmentGrouping.TextScope {
                .init(owner: 8, box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.5)
            }
            let values = input(), textScope = scope(values)
            for ordered in [values, Array(values.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [textScope])
                #expect(result.count == 1 && result[0].source == values.map(\.source).joined())
                #expect(result[0].sourceOrientation == .horizontal)
                #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [textScope]) == result)
            }
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: []).count == 1)
            var lowConfidence = values
            for index in lowConfidence.indices { lowConfidence[index].confidence = 0.8 }
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(lowConfidence, scopes: []) == lowConfidence)
            let distinct = values.enumerated().map {
                NativeParagraphFragmentGrouping.TextScope(owner: $0.offset, box: $0.element.rect, confidence: 0.95)
            }
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: distinct) == values)
            let broad = NativeParagraphFragmentGrouping.TextScope(owner: 8,
                box: textScope.box.insetBy(dx: -0.2 * scale, dy: -0.2 * scale), confidence: 0.95)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [broad]) == values)
            let interrupted = input(gap: 0.04)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(interrupted, scopes: [scope(interrupted)]) == interrupted)
            var unknown = values; unknown[0].acceptedSource = .init()
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(unknown, scopes: [textScope]) == unknown)
            var separate = values
            separate[0].balloonInterior = .init(rect: values[0].rect,
                center: .init(x: values[0].rect.midX, y: values[0].rect.midY), spans: [], contourVerified: true)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(separate, scopes: [textScope]) == separate)
        }
    }

    @Test func independentTextBlocksRequireExactOriginalLineage() {
        let parts = [CGRect(x: 0.1, y: 0.1, width: 0.08, height: 0.08),
                     CGRect(x: 0.1, y: 0.3, width: 0.08, height: 0.08)]
        let scopes = parts.enumerated().map { NativeParagraphFragmentGrouping.TextScope(owner: $0.offset, box: $0.element, confidence: 0.95) }
        func merged(_ words: [String]) -> ReaderTranslationRegion {
            let lines = parts.enumerated().map { index, box -> NativeCoreMLOCRLine in
                let box = box.applying(.init(scaleX: 1000, y: 1000))
                return .init(polygon: [.init(x: box.minX, y: box.minY), .init(x: box.maxX, y: box.minY),
                    .init(x: box.maxX, y: box.maxY), .init(x: box.minX, y: box.maxY)], text: words[index], score: 0.95, orientation: .vertical)
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: 1000, height: 1000)
            var r = ReaderTranslationRegion(id: "unit", rect: parts[0].union(parts[1]), source: words.joined())
            r.sourceOrientation = .vertical; r.sourceImageAspectRatio = 1
            r.unitMemberRects = parts; r.acceptedSource = .union(bound.map(\.acceptedSource))
            return r
        }
        let original = merged(["上の文章", "下の文章"])
        let result = NativeParagraphFragmentGrouping.reconcilingObservations([original], scopes: scopes)
        #expect(result.map(\.source) == ["上の文章", "下の文章"])
        #expect(result.map(\.rect) == parts)
        #expect(result.map { $0.acceptedSource.membership?.body.count } == [1, 1])
        #expect(result.allSatisfy { $0.acceptedSource.membership?.table === original.acceptedSource.membership?.table })
        var unknown = original; unknown.acceptedSource = .init()
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([unknown], scopes: scopes) == [unknown])
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([original], scopes: scopes + [
            .init(owner: 3, box: original.rect, confidence: 0.95)]) == [original])
        let request = merged(["せめて安全な場所に", "ちゃんと移動してください"])
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([request], scopes: scopes).map(\.source) ==
            ["せめて安全な場所に", "ちゃんと移動してください"])
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func partiallyDetectedOriginalBlocksRequireDisconnectedOwnedInk(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale), words = ["甲乙", "丙丁戊己", "庚辛壬癸"]
        func original(crossLink: Bool = false, missing: Bool = false, ambiguous: Bool = false,
                      disconnectedBody: Bool = false, leadingBox: CGRect? = nil) -> ReaderTranslationRegion {
            let boxes = [leadingBox ?? CGRect(x: crossLink ? 0.385 : 0.4, y: crossLink ? 0.118 : 0.1, width: 0.03, height: 0.06),
                         CGRect(x: 0.34, y: 0.13, width: 0.03, height: 0.12),
                         CGRect(x: disconnectedBody ? 0.25 : 0.3, y: 0.13, width: 0.03, height: 0.12)]
            let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                let x = Int((box.minX * 1000).rounded()) + 1, y = Int((box.minY * 1000).rounded()) + 1
                let height = Int((box.height * 1000).rounded()) - 2
                let component = Evidence.Component(seed: y * 1000 + x, pixelCount: height * 28, meanProbability: 0.95,
                    runs: (y..<(y + height)).map { .init(y: $0, x: x, count: 28) })
                let evidence = Evidence(ownerID: "column-\(index)", parentBoxIndex: index,
                    provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                    mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                    sourceWidth: size, sourceHeight: size, components: [component], ownershipVersion: 2,
                    completeCCScan: true, ambiguousComponents: ambiguous && index == 0 ? [component] : [], candidateComponents: [])
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[index], score: 0.95,
                    orientation: .vertical, detectorSeedEvidence: missing && index == 0 ? nil : [evidence])
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            let parts = [boxes[0], boxes[1].union(boxes[2])]
            var r = ReaderTranslationRegion(id: "unit", rect: parts[0].union(parts[1]), source: words.joined())
            r.sourceOrientation = .vertical; r.sourceImageAspectRatio = 1
            r.unitMemberRects = parts; r.acceptedSource = .union(bound.map(\.acceptedSource))
            return r
        }
        let value = original(), scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
            box: value.unitMemberRects[1], confidence: 0.95)
        let split = NativeParagraphFragmentGrouping.reconcilingObservations([value], scopes: [scope])
        #expect(split.map(\.source) == [words[0], words[1] + words[2]])
        #expect(split.map(\.rect) == value.unitMemberRects)
        #expect(split.map { $0.acceptedSource.membership?.body.count } == [1, 2])
        #expect(split.allSatisfy { $0.acceptedSource.membership?.table === value.acceptedSource.membership?.table })
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(split, scopes: [scope]) == split)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([value], scopes: []) == [value])
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([value], scopes: [scope,
            .init(owner: 2, box: value.rect, confidence: 0.3)]) == [value])
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([value], scopes: [
            .init(owner: 1, box: scope.box, confidence: 0.79)]) == [value])
        for negative in [original(crossLink: true), original(missing: true), original(ambiguous: true),
                         original(disconnectedBody: true)] {
            let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: negative.unitMemberRects[1], confidence: 0.95)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations([negative], scopes: [scope]) == [negative])
        }
        var untracked = value; untracked.acceptedSource = .init()
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([untracked], scopes: [scope]) == [untracked])
        let unknownParts = value.unitMemberRects + [CGRect(x: 0.6, y: 0.1, width: 0.03, height: 0.1)]
        // The additional rectangle has no accepted source packet. Retain
        // that uncertainty explicitly; a rectangle alone cannot certify a split.
        var unknownMembers = value
        unknownMembers.unitMemberRects = unknownParts
        let membership = value.acceptedSource.membership!
        unknownMembers.acceptedSource = .init(.init(table: membership.table, body: membership.body,
            readings: membership.readings, unknownDedup: membership.unknownDedup, hasUntrackedInputs: true))
        let unknownResult = NativeParagraphFragmentGrouping.reconcilingObservations([unknownMembers], scopes: [scope])
        #expect(unknownResult == [unknownMembers])
        #expect(unknownResult[0].acceptedSource.membership?.hasUntrackedInputs == true)
        #expect(unknownResult[0].unitMemberRects == unknownParts)
        let shortLead = CGRect(x: 0.4, y: 0.1, width: 0.03, height: 0.04)
        let short = original(leadingBox: shortLead)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations([short], scopes: [scope]) == [short])
        let ownLead = NativeParagraphFragmentGrouping.TextScope(owner: 2, box: shortLead, confidence: 0.95)
        for owners in [[scope, ownLead], [ownLead, scope]] {
            let separated = NativeParagraphFragmentGrouping.reconcilingObservations([short], scopes: owners)
            #expect(separated.map(\.source) == [words[0], words[1] + words[2]])
            #expect(separated.map(\.rect) == [shortLead, scope.box])
            #expect(separated.map { $0.acceptedSource.membership?.body } == [Set([0]), Set([1, 2])])
            #expect(separated.allSatisfy { $0.acceptedSource.membership?.table === short.acceptedSource.membership?.table })
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(separated, scopes: owners) == separated)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func unprofiledGraphPartitionsRequireCompleteOriginalSources(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        for columns in [2, 4] {
            func input(missing: Int? = nil, ambiguous: Bool = false, disconnected: Bool = false,
                       unanchoredPair: Bool = false, nested: Bool = false) -> [ReaderTranslationRegion] {
                let count = columns + (unanchoredPair ? 3 : 2)
                let boxes = (0..<count).map { index in
                    CGRect(x: nested && index == columns ? 0.1125 : 0.1 + Double(index) * 0.025 + (index > columns ? 0.08 : 0),
                        y: disconnected && index == 0 ? 0.4 : 0.1, width: 0.02, height: 0.16)
                }
                let words = (0..<count).map { "列\($0)本文" }
                let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                    let x = Int((box.minX * 1000).rounded()) + 2, y = Int((box.minY * 1000).rounded()) + 2
                    let component = Evidence.Component(seed: y * 1000 + x, pixelCount: 1560, meanProbability: 0.95,
                        runs: (y..<(y + 156)).map { .init(y: $0, x: x, count: 10) })
                    let evidence = Evidence(ownerID: "column-\(index)", parentBoxIndex: index,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                        mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                        sourceWidth: size, sourceHeight: size, components: [component], ownershipVersion: 2,
                        completeCCScan: true, ambiguousComponents: ambiguous && index == columns + 1 ? [component] : [], candidateComponents: [])
                    let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[index], score: 0.95,
                        orientation: .vertical, detectorSeedEvidence: missing == index ? nil : [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                let groups = [Array(0..<columns)] + (columns..<count).map { [$0] }
                return groups.enumerated().map { index, ids in
                    var r = ReaderTranslationRegion(id: "source-\(index)",
                        rect: ids.map { boxes[$0] }.reduce(CGRect.null) { $0.union($1) },
                        source: ids.reversed().map { words[$0] }.joined())
                    r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = ids.count == 1; r.sourceImageAspectRatio = 1
                    r.acceptedSource = .union(ids.map { bound[$0].acceptedSource })
                    return r
                }
            }
            func scope(_ values: [ReaderTranslationRegion], confidence: Double = 0.65) -> NativeParagraphFragmentGrouping.TextScope {
                .init(owner: 1, box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: confidence)
            }
            let values = input(), coarse = scope(values)
            for ordered in [values, Array(values.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [coarse])
                #expect(result.count == 2)
                #expect(Set(result.map { $0.acceptedSource.membership!.body }) == [Set(0...columns), Set([columns + 1])])
                #expect(result.contains { $0.source == values[1].source + values[0].source })
                #expect(result.contains { $0 == values[2] })
                #expect(result.allSatisfy { $0.acceptedSource.membership?.table === values[0].acceptedSource.membership?.table })
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [coarse]) == result)
            }
            let connected = Array(values.prefix(2)), local = scope(connected)
            let joined = NativeParagraphFragmentGrouping.reconcilingObservations(connected, scopes: [local])
            #expect(joined.count == 1 && joined[0].source == connected[1].source + connected[0].source)
            #expect(joined[0].acceptedSource.membership?.body == Set(0...columns))
            // Removing a disconnected source is safe only with a corresponding
            // complete scope; retaining its broad query leaves a coverage hole.
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(connected, scopes: [coarse]) == connected)
            // Another connected component of independently owned original
            // columns does not need an unrelated preaggregated block as an
            // anchor. Every original source still stays intact and accounted.
            let independent = input(unanchoredPair: true)
            for ordered in [independent, Array(independent.reversed())] {
                let joined = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope(independent)])
                #expect(joined.count == 2)
                #expect(Set(joined.map { $0.acceptedSource.membership!.body }) ==
                    [Set(0...columns), Set([columns + 1, columns + 2])])
                #expect(joined.contains { $0.source == independent[1].source + independent[0].source })
                #expect(joined.contains { $0.source == independent[3].source + independent[2].source })
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(joined, scopes: [scope(independent)]) == joined)
            }
            let nestedSeparate = input(unanchoredPair: true, nested: true)
            let isolated = NativeParagraphFragmentGrouping.reconcilingObservations(nestedSeparate, scopes: [scope(nestedSeparate)])
            #expect(isolated.count == 3)
            #expect(isolated.contains(nestedSeparate[0]) && isolated.contains(nestedSeparate[1]))
            #expect(isolated.contains { $0.acceptedSource.membership!.body == Set([columns + 1, columns + 2]) &&
                $0.source == nestedSeparate[3].source + nestedSeparate[2].source })
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(isolated, scopes: [scope(nestedSeparate)]) == isolated)
            for (variant, negative) in [input(missing: 0), input(missing: columns + 1), input(ambiguous: true),
                             input(disconnected: true), input(nested: true),
                             input(missing: columns + 2, unanchoredPair: true)].enumerated() {
                let actual = NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [scope(negative)])
                #expect(actual == negative, "partition negative \(variant) columns=\(columns) scale=\(scale)")
            }
            var unknown = values; unknown[2].acceptedSource = .init()
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(unknown, scopes: [coarse]) == unknown)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope(values, confidence: 0.2)]) == values)
            let broad = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: coarse.box.insetBy(dx: -0.05, dy: -0.05), confidence: 0.95)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [broad]) == values)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func nativeOriginalGridExtendsWithoutRFQuery(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        for count in [2, 3, 5] {
            func input(offset: CGFloat = 0, rightSide: Bool = false, irregular: Bool = false, hidden: Int = 0, missing: Int? = nil,
                       ambiguous: Bool = false, outsideInk: Bool = false, clippedBand: Bool = false,
                       native: Bool = true, competing: Bool = false, unknown: Bool = false,
                       differentGrid: Bool = false, wrongAspect: Bool = false, above: Bool = false) -> [ReaderTranslationRegion] {
                let boxes = (0..<(count + 1 + (hidden == 0 ? 0 : 1))).map { index -> CGRect in
                    if index == count {
                        let x: CGFloat = rightSide ? 0.335 + CGFloat(count - 1) * 0.03 : 0.275
                        return .init(x: x + offset, y: above ? 0.17 : 0.22, width: 0.01, height: 0.07)
                    }
                    if index > count {
                        return hidden == 2 ? .init(x: 0.8, y: 0.8, width: 0.01, height: 0.05) :
                            .init(x: 0.29, y: 0.24, width: 0.005, height: 0.05)
                    }
                    return .init(x: 0.3 + CGFloat(index) * 0.03 + (irregular && index == count - 1 ? 0.008 : 0),
                                 y: 0.2, width: 0.02, height: 0.16)
                }
                let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                    let x = Int((box.midX * 1000).rounded()) - 2, y = Int((box.minY * 1000).rounded()) + 2
                    let height = Int((box.height * 1000).rounded()) - 4
                    let gridWidth = differentGrid && index == count ? 1002 : 1000
                    let component = Evidence.Component(seed: y * gridWidth + (outsideInk && index == count ? 260 : x),
                        pixelCount: height * 4, meanProbability: 0.95,
                        runs: (y..<(y + height)).map { .init(y: $0, x: outsideInk && index == count ? 260 : x, count: 4) })
                    let disputed = Evidence.Component(seed: (y - 1) * gridWidth + x + 1, pixelCount: 2, meanProbability: 0.95,
                        runs: [.init(y: y - 1, x: x + 1, count: 2)])
                    let e = Evidence(ownerID: "column-\(index)", parentBoxIndex: index,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                        mapOriginX: 0, mapOriginY: 0, mapFullWidth: gridWidth, mapFullHeight: 1000,
                        sourceWidth: size, sourceHeight: size, components: [component], ownershipVersion: 2,
                        completeCCScan: true, ambiguousComponents: ambiguous && index == count ? [disputed] : [], candidateComponents: [])
                    #expect(e.isValid)
                    let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    return .init(polygon: hidden == 3 && index > count ? [] : [
                        .init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: "列\(index)本文", score: 0.95,
                        orientation: .vertical, detectorSeedEvidence: missing == index ? nil : [e])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                let bodyIDs = Array((0..<count).reversed())
                var body = ReaderTranslationRegion(id: "body", rect: boxes.prefix(count).reduce(CGRect.null) { $0.union($1) },
                    source: bodyIDs.map { lines[$0].text }.joined())
                body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
                body.acceptedSource = .union(bodyIDs.map { bound[$0].acceptedSource })
                let right = Double(body.rect.maxX + 0.03)
                body.balloonInterior = .init(rect: .init(x: 0.24, y: 0.15, width: right - 0.24, height: 0.25),
                    center: .init(x: 0.3, y: 0.27), spans: Array(repeating: [clippedBand ? 0.295 : 0.24, right], count: 16).flatMap { $0 },
                    contourVerified: native, modelEstimated: !native)
                var peer = ReaderTranslationRegion(id: "peer", rect: boxes[count], source: lines[count].text)
                peer.sourceOrientation = .vertical; peer.sourceSingleVerticalColumn = true
                peer.sourceImageAspectRatio = wrongAspect ? 1.25 : 1
                if !unknown { peer.acceptedSource = bound[count].acceptedSource }
                if competing {
                    peer.balloonInterior = .init(rect: .init(x: 0.25, y: 0.15, width: 0.04, height: 0.2),
                        center: .init(x: 0.28, y: 0.25), spans: Array(repeating: [0.25, 0.29], count: 8).flatMap { $0 },
                        contourVerified: true)
                }
                return [body, peer]
            }
            for values in [input(), input(offset: 0.0005), input(hidden: 2), input(rightSide: true)] {
                for ordered in [values, Array(values.reversed())] {
                    let joined = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [])
                    let expected = values[0].rect.midX < values[1].rect.midX ?
                        values[1].source + values[0].source : values[0].source + values[1].source
                    #expect(joined.count == 1 && joined[0].source == expected)
                    #expect(joined[0].acceptedSource.membership?.body == Set(0...count))
                    #expect(joined[0].acceptedSource.membership?.table === values[0].acceptedSource.membership?.table)
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(joined, scopes: []) == joined)
                }
            }
            for negative in [input(offset: 0.004), input(offset: 0.004, rightSide: true), input(irregular: true),
                             input(hidden: 1), input(hidden: 3), input(missing: 0), input(missing: count),
                             input(ambiguous: true), input(outsideInk: true), input(clippedBand: true), input(native: false),
                             input(competing: true), input(unknown: true), input(differentGrid: true), input(wrongAspect: true), input(above: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: []) == negative)
            }
            var withUnknown = input()
            var unknownSource = ReaderTranslationRegion(id: "unknown", rect: withUnknown[1].rect, source: "未知")
            unknownSource.sourceOrientation = .vertical; unknownSource.sourceSingleVerticalColumn = true; unknownSource.sourceImageAspectRatio = 1
            withUnknown.append(unknownSource)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(withUnknown, scopes: []) == withUnknown)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func nativeAnchorRequiresCompleteStrongSourceCohort(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale), boxes = [CGRect(x: 0.1, y: 0.1, width: 0.04, height: 0.18),
                                               CGRect(x: 0.15, y: 0.1, width: 0.02, height: 0.18)]
        let words = ["左の本文列", "右列"]
        func input(peerMode: Int, missing: Int? = nil, ambiguous: Bool = false, outsideOriginal: Bool = false,
                   clippedBand: Bool = false, clippedHull: Bool = false, verified: Bool = true,
                   otherTable: Bool = false, extraUnknown: Bool = false) -> [ReaderTranslationRegion] {
            let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                let x = outsideOriginal && index == 1 ? 82 : Int((box.minX * 1000).rounded()) + 2
                let component = Evidence.Component(seed: 102000 + x, pixelCount: 1760, meanProbability: 0.95,
                    runs: (102..<278).map { .init(y: $0, x: x, count: 10) })
                let evidence = Evidence(ownerID: "column-\(index)", parentBoxIndex: index,
                    provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                    mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                    sourceWidth: size, sourceHeight: size, components: [component], ownershipVersion: 2,
                    completeCCScan: true, ambiguousComponents: ambiguous && index == 1 ? [component] : [], candidateComponents: [])
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[index], score: 0.95,
                    orientation: .vertical, detectorSeedEvidence: missing == index ? nil : [evidence])
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            var values = boxes.enumerated().map { index, box -> ReaderTranslationRegion in
                var r = ReaderTranslationRegion(id: "column-\(index)", rect: box, source: words[index])
                r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = true; r.sourceImageAspectRatio = 1
                r.acceptedSource = bound[index].acceptedSource
                if index == 0 || peerMode != 0 {
                    r.balloonInterior = .init(rect: .init(x: 0.08, y: 0.08,
                        width: index == 0 && clippedHull ? 0.065 : 0.12, height: 0.24),
                        center: .init(x: 0.12, y: 0.19),
                        spans: Array(repeating: [0.08, index == 0 && clippedBand ? 0.145 : 0.2], count: 12).flatMap { $0 },
                        contourVerified: index == 0 ? verified : peerMode == 2 ? false : nil,
                        modelEstimated: index == 1 && peerMode == 2 ? true : nil)
                }
                return r
            }
            if otherTable {
                values[1].acceptedSource = NativeOCRAcceptedSource.bindingPrimary([lines[1]], width: size, height: size)[0].acceptedSource
            }
            if extraUnknown {
                var extra = ReaderTranslationRegion(id: "unknown", rect: .init(x: 0.18, y: 0.1, width: 0.01, height: 0.18), source: "別列")
                extra.sourceOrientation = .vertical; extra.sourceSingleVerticalColumn = true; extra.sourceImageAspectRatio = 1
                values.append(extra)
            }
            return values
        }
        func scope(_ values: [ReaderTranslationRegion], confidence: Double = 0.95) -> NativeParagraphFragmentGrouping.TextScope {
            .init(owner: 3, box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: confidence)
        }
        for mode in [0, 1, 2] {
            let values = input(peerMode: mode), common = scope(values)
            for ordered in [values, Array(values.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [common])
                #expect(result.count == 1 && result[0].source == words[1] + words[0])
                #expect(result[0].acceptedSource.membership?.body == Set([0, 1]))
                #expect(result[0].acceptedSource.membership?.table === values[0].acceptedSource.membership?.table)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [common]) == result)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope(values, confidence: 0.79)]) == ordered)
            }
            for negative in [input(peerMode: mode, missing: 0), input(peerMode: mode, missing: 1),
                             input(peerMode: mode, ambiguous: true), input(peerMode: mode, outsideOriginal: true),
                             input(peerMode: mode, clippedBand: true), input(peerMode: mode, clippedHull: true),
                             input(peerMode: mode, verified: false), input(peerMode: mode, otherTable: true),
                             input(peerMode: mode, extraUnknown: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [scope(negative)]) == negative)
            }
            let distinct = values.enumerated().map { NativeParagraphFragmentGrouping.TextScope(owner: $0.offset, box: $0.element.rect, confidence: 0.95) }
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: distinct) == values)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [common,
                .init(owner: 4, box: common.box, confidence: common.confidence)]) == values)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func closedCarrierKeepsUnclaimedComponentsAndCoveredReadings(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        func input(_ fault: Int = 0, extraDetectorOwner: Bool = false) -> [ReaderTranslationRegion] {
            func component(_ x: Int, _ y: Int) -> Evidence.Component {
                .init(seed: y * 1000 + x, pixelCount: 3, meanProbability: 0.95,
                    runs: [.init(y: y, x: x, count: 3)])
            }
            let shared = component(155, 130), alternate = component(112, 150), joined = component(175, 200)
            let local = component(120, 170), orphan = component(122, 180)
            let boxes = [CGRect(x: 0.10, y: 0.1, width: 0.08, height: 0.2),
                         CGRect(x: 0.17, y: 0.1, width: 0.04, height: 0.2),
                         CGRect(x: 0.11, y: 0.14, width: 0.005, height: 0.02),
                         CGRect(x: 0.15, y: 0.12, width: 0.02, height: 0.1),
                         fault == 9 ? CGRect(x: 0.22, y: 0.1, width: 0.01, height: 0.1) :
                         fault == 3 ? CGRect(x: 0.119, y: 0.169, width: 0.01, height: 0.03) :
                            CGRect(x: 0.6, y: 0.6, width: 0.02, height: 0.1)]
            let words = ["甲乙丙", "丁", "乙", "短列", "外部"]
            let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                let evidence = Evidence(ownerID: index == 4 && fault == 1 ? "discarded" : "owner-\(index)",
                    parentBoxIndex: index, provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                    mapOriginX: index == 4 && fault == 2 ? 1 : 0, mapOriginY: 0,
                    mapFullWidth: 1000, mapFullHeight: 1000, sourceWidth: size, sourceHeight: size,
                    components: index == 0 ? (fault == 6 ? [] : [component(110, 110)]) :
                        index == 1 ? (fault == 6 ? [] : [component(195, 110)]) : index == 4 ? [component(610, 610)] : [],
                    ownershipVersion: 2, completeCCScan: !(index == 0 && fault == 7),
                    ambiguousComponents: index == 0 ? [alternate, local, joined] + (fault == 5 ? [] : [shared]) :
                        index == 1 ? [joined] : index == 2 ? [alternate] : index == 4 && fault == 2 ? [local] : [],
                    candidateComponents: index == 0 ? [.init(component: orphan, competingOwnerIDs: ["discarded"], outsideCompetingCells: [1])] :
                        index == 3 ? [.init(component: shared, competingOwnerIDs:
                            ["owner-0"] + (extraDetectorOwner ? ["discarded"] : []),
                            outsideCompetingCells: extraDetectorOwner ? [1, 1] : [1])] : [])
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                let polygon = [CGPoint(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                               .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)]
                return .init(polygon: index == 4 && fault == 8 ? [] : polygon, text: words[index], score: 0.95,
                    orientation: index == 3 ? .horizontal : .vertical, detectorSeedEvidence: [evidence])
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            var body = ReaderTranslationRegion(id: "body", rect: boxes[0].union(boxes[1]), source: words[1] + words[0])
            body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = false; body.sourceImageAspectRatio = 1
            body.acceptedSource = .union(bound.prefix(3).map(\.acceptedSource))
            body.detectorSeedEvidence = Evidence.preservingUnion(lines.prefix(3).map(\.detectorSeedEvidence))
            var child = ReaderTranslationRegion(id: "child", rect: boxes[3], source: words[3])
            child.sourceOrientation = .horizontal; child.sourceSingleVerticalColumn = true; child.sourceImageAspectRatio = 1
            child.acceptedSource = bound[3].acceptedSource; child.detectorSeedEvidence = lines[3].detectorSeedEvidence
            if fault == 4 {
                child.acceptedSource = .init()
            }
            if fault == 10 {
                body.balloonInterior = .init(rect: body.rect, center: .init(x: body.rect.midX, y: body.rect.midY),
                    spans: [body.rect.minX, body.rect.maxX, body.rect.minX, body.rect.maxX],
                    contourVerified: false, modelEstimated: true)
            }
            return [body, child]
        }
        func scope(_ values: [ReaderTranslationRegion], confidence: Double = 0.95,
                   margin: CGFloat = 0) -> NativeParagraphFragmentGrouping.TextScope {
            .init(owner: 3, box: values[0].rect.insetBy(dx: -margin, dy: -margin), confidence: confidence)
        }
        for extraOwner in [false, true] {
            let values = input(extraDetectorOwner: extraOwner)
            for margin: CGFloat in [0, 0.02, 0.04] { for ordered in [values, Array(values.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope(values, margin: margin)])
                #expect(result.count == 1)
                #expect(result[0].source == "丁短列甲乙丙")
                #expect(result[0].acceptedSource.membership?.body == Set([0, 1, 3]))
                #expect(result[0].acceptedSource.membership?.readings == Set([2]))
                #expect(result[0].acceptedSource.membership?.table === values[0].acceptedSource.membership?.table)
                #expect(result[0].detectorSeedEvidence == Evidence.preservingUnion(values.map(\.detectorSeedEvidence)))
                let retained = result[0].detectorSeedEvidence?.first { $0.ownerID == "owner-0" }
                #expect(retained?.ambiguousComponents?.count == 4 && retained?.candidateComponents?.count == 1)
                let repeated = NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope(values)])
                #expect(repeated[0].acceptedSource.membership?.body == Set([0, 1, 3]))
                #expect(repeated[0].acceptedSource.membership?.readings == Set([2]))
            } }
        }
        for fault in 1...8 {
            let values = input(fault)
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope(values)])
            #expect(result.count == 2)
            #expect(result.map(\.source) == values.map(\.source))
            #expect(result.map(\.detectorSeedEvidence) == values.map(\.detectorSeedEvidence))
        }
        let weak = input()
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(weak,
            scopes: [scope(weak, confidence: 0.79)]).count == 2)
        let hidden = input(9)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(hidden,
            scopes: [scope(hidden, margin: 0.03)]).count == 2)
        let profiled = input(10)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(profiled,
            scopes: [scope(profiled, margin: 0.03)]).count == 2)
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func selectedCoveredReadingsKeepImmutableEvidence(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        func input(_ fault: Int = 0) -> ReaderTranslationRegion {
            let shared = Evidence.Component(seed: 150215, pixelCount: 3, meanProbability: 0.95,
                runs: [.init(y: 150, x: 215, count: 3)])
            let own = Evidence.Component(seed: 160225, pixelCount: 3, meanProbability: 0.95,
                runs: [.init(y: 160, x: 225, count: 3)])
            let boxes = [CGRect(x: 0.20, y: 0.1, width: 0.04, height: 0.15),
                         fault == 7 ? CGRect(x: 0.20, y: 0.1, width: 0.04, height: 0.15) :
                            CGRect(x: 0.25, y: 0.1, width: 0.04, height: 0.15),
                         fault == 4 ? CGRect(x: 0.18, y: 0.13, width: 0.04, height: 0.05) :
                            CGRect(x: 0.21, y: 0.13, width: 0.01, height: 0.05)]
            let words = ["甲乙丙", fault == 7 ? "丁乙戊" : "丁", "乙"]
            let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                let alternate = index == 2
                let evidence = Evidence(ownerID: "owner-\(index)", parentBoxIndex: index,
                    provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                    mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                    sourceWidth: size, sourceHeight: size,
                    components: alternate ? (fault == 1 ? [own] : []) : [own],
                    ownershipVersion: 2, completeCCScan: !(alternate && fault == 5),
                    ambiguousComponents: alternate && fault == 8 ? [] :
                        (alternate || index == 0 || fault == 7 ? [shared] : []),
                    candidateComponents: alternate && fault == 8 ? [.init(component: shared,
                        competingOwnerIDs: ["owner-0"], outsideCompetingCells: [1])] : [])
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                var quad = [CGPoint(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                            .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)]
                if alternate && fault == 11 { quad = Array(repeating: .init(x: b.minX, y: b.minY), count: 4) }
                if alternate && fault == 12 { quad[0].x = .nan }
                return .init(polygon: alternate && fault == 3 ? [] : quad,
                    text: words[index], score: 0.95, orientation: .vertical,
                    detectorSeedEvidence: alternate && fault == 2 ? nil : [evidence])
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            var region = ReaderTranslationRegion(id: "selected", rect: boxes[0].union(boxes[1]),
                source: words[0] + words[1] + (fault == 6 ? "未" : ""))
            region.sourceOrientation = .vertical; region.sourceSingleVerticalColumn = false; region.sourceImageAspectRatio = 1
            region.acceptedSource = .union(bound.map(\.acceptedSource))
            if fault == 9 || fault == 10 {
                let m = region.acceptedSource.membership!
                region.acceptedSource = .init(.init(table: m.table, body: m.body, readings: [],
                    unknownDedup: fault == 9 ? [2] : [], hasUntrackedInputs: fault == 10))
            }
            region.detectorSeedEvidence = lines.flatMap { $0.detectorSeedEvidence ?? [] }
            return region
        }
        let original = input()
        let result = NativeParagraphFragmentGrouping.reconcilingObservations([original], scopes: [])
        #expect(result.count == 1 && result[0].source == original.source && result[0].rect == original.rect)
        #expect(result[0].acceptedSource.membership?.body == Set([0, 1]))
        #expect(result[0].acceptedSource.membership?.readings == Set([2]))
        #expect(result[0].acceptedSource.membership?.unknownDedup.isEmpty == true)
        #expect(result[0].acceptedSource.membership?.hasUntrackedInputs == false)
        #expect(result[0].acceptedSource.membership?.table === original.acceptedSource.membership?.table)
        #expect(result[0].detectorSeedEvidence == original.detectorSeedEvidence)
        #expect(result[0].sourceOCRAlternatives == original.sourceOCRAlternatives)
        let repeated = NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [])
        #expect(repeated[0].acceptedSource.membership?.body == Set([0, 1]))
        #expect(repeated[0].acceptedSource.membership?.readings == Set([2]))
        for fault in 1...12 {
            let value = input(fault)
            let rejected = NativeParagraphFragmentGrouping.reconcilingObservations([value], scopes: [])
            #expect(rejected.count == 1 && rejected[0].source == value.source)
            #expect(rejected[0].acceptedSource.membership?.body == Set([0, 1, 2]))
            #expect(rejected[0].acceptedSource.membership?.readings.isEmpty == true)
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func ambiguousOnlyCarrierRequiresWholeTableClosure(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        for count in [1, 3, 4] {
            func input(reciprocal: Bool = true, anchor: Bool = true, outsideLast: Bool = false,
                       foreign: Int = 0, incomplete: Bool = false, duplicate: Bool = false,
                       horizontal: Bool = false, unknown: Bool = false) -> [ReaderTranslationRegion] {
                let boxes = [CGRect(x: 0.1, y: 0.1, width: 0.08, height: 0.2),
                             CGRect(x: 0.15, y: 0.12, width: 0.02, height: 0.1),
                             foreign == 2 ? CGRect(x: 0.15, y: 0.12, width: 0.02, height: 0.1) :
                                CGRect(x: 0.6, y: 0.6, width: 0.02, height: 0.1)]
                let words = duplicate ? ["甲乙丙", "乙", "外部"] : ["左の本文", "右列", "外部"]
                let shared = (0..<count).map { index -> Evidence.Component in
                    let x = outsideLast && index == count - 1 ? 185 : 155, y = 130 + index * 25
                    return .init(seed: y * 1000 + x, pixelCount: 8, meanProbability: 0.95, runs: [.init(y: y, x: x, count: 8)])
                }
                let own = Evidence.Component(seed: 110110, pixelCount: 720, meanProbability: 0.95,
                    runs: (110..<290).map { .init(y: $0, x: 110, count: 4) })
                let far = Evidence.Component(seed: 610610, pixelCount: 4, meanProbability: 0.95,
                    runs: [.init(y: 610, x: 610, count: 4)])
                let lines = (0..<(foreign == 0 ? 2 : 3)).map { index -> NativeCoreMLOCRLine in
                    let evidence = Evidence(ownerID: "owner-\(index)", parentBoxIndex: index,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                        mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                        sourceWidth: size, sourceHeight: size,
                        components: index == 0 && anchor ? [own] : index == 2 && foreign == 3 ? [far] : [],
                        ownershipVersion: 2, completeCCScan: !(incomplete && index == 0),
                        ambiguousComponents: index == 2 ? (foreign == 1 ? shared : []) :
                            index == 1 && !reciprocal ? Array(shared.dropLast()) : shared,
                        candidateComponents: [])
                    let box = boxes[index].applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    let polygon: [CGPoint] = foreign == 4 && index == 2 ? [] : [
                        .init(x: box.minX, y: box.minY), .init(x: box.maxX, y: box.minY),
                        .init(x: box.maxX, y: box.maxY), .init(x: box.minX, y: box.maxY)]
                    return .init(polygon: polygon, text: words[index], score: 0.95,
                        orientation: horizontal && index == 1 ? .horizontal : .vertical,
                        detectorSeedEvidence: index == 2 && foreign != 1 && foreign != 3 ? nil : [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                var values = (0..<2).map { index -> ReaderTranslationRegion in
                    var r = ReaderTranslationRegion(id: "source-\(index)", rect: boxes[index], source: words[index])
                    r.sourceOrientation = horizontal && index == 1 ? .horizontal : .vertical
                    r.sourceSingleVerticalColumn = true; r.sourceImageAspectRatio = 1
                    r.acceptedSource = bound[index].acceptedSource; r.detectorSeedEvidence = lines[index].detectorSeedEvidence
                    return r
                }
                if unknown {
                    var extra = ReaderTranslationRegion(id: "unknown", rect: .init(x: 0.12, y: 0.13, width: 0.01, height: 0.1), source: "未知")
                    extra.sourceOrientation = .vertical; extra.sourceSingleVerticalColumn = true; extra.sourceImageAspectRatio = 1
                    values.append(extra)
                }
                return values
            }
            func scope(_ values: [ReaderTranslationRegion], confidence: Double = 0.95) -> NativeParagraphFragmentGrouping.TextScope {
                .init(owner: 3, box: values[0].rect, confidence: confidence)
            }
            for values in [input(), input(foreign: 3), input(horizontal: true), input(foreign: 3, horizontal: true)] {
                for ordered in [values, Array(values.reversed())] {
                    let common = scope(values)
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [common])
                    #expect(result.count == 1 && result[0].source == values[1].source + values[0].source)
                    #expect(result[0].acceptedSource.membership?.body == Set([0, 1]))
                    #expect(result[0].acceptedSource.membership?.table === values[0].acceptedSource.membership?.table)
                    let child = result[0].detectorSeedEvidence?.first { $0.ownerID == "owner-1" }
                    #expect(child?.components.isEmpty == true && child?.candidateComponents?.isEmpty == true)
                    #expect(child?.ambiguousComponents?.count == count)
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [common]) == result)
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(ordered,
                        scopes: [scope(values, confidence: 0.79)]) == ordered)
                }
            }
            for negative in [input(reciprocal: false), input(anchor: false), input(outsideLast: true),
                             input(foreign: 1), input(foreign: 2), input(foreign: 4),
                             input(incomplete: true), input(unknown: true),
                             input(reciprocal: false, horizontal: true), input(anchor: false, horizontal: true),
                             input(outsideLast: true, horizontal: true), input(foreign: 1, horizontal: true),
                             input(foreign: 2, horizontal: true), input(foreign: 4, horizontal: true),
                             input(incomplete: true, horizontal: true), input(horizontal: true, unknown: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [scope(negative)]) == negative)
            }
            for duplicate in [input(duplicate: true), input(duplicate: true, horizontal: true)] {
                let deduplicated = NativeParagraphFragmentGrouping.reconcilingObservations(duplicate, scopes: [scope(duplicate)])
                #expect(deduplicated.count == 1 && deduplicated[0].source == duplicate[0].source)
            }
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func completeOwnedGridExplainsProposalMargins(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        for count in [2, 3, 5] {
            let boxes = (0..<count).map { CGRect(x: 0.2 + CGFloat($0) * 0.03, y: 0.2, width: 0.02, height: 0.12) }
            let envelope = boxes.reduce(CGRect.null) { $0.union($1) }
            let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1,
                box: envelope.insetBy(dx: -0.01, dy: -0.01), confidence: 0.95)
            func input(hidden: Int = 0, missing: Bool = false, ambiguous: Bool = false,
                       outlier: Bool = false) -> [ReaderTranslationRegion] {
                let lines = (0..<(count + (hidden == 0 ? 0 : 1))).map { index -> NativeCoreMLOCRLine in
                    let box = index < count ? boxes[index] : hidden == 2 ? CGRect(x: 0.7, y: 0.7, width: 0.02, height: 0.1) :
                        CGRect(x: 0.223, y: 0.24, width: 0.004, height: 0.02)
                    let x = Int((box.midX * 1000).rounded()) - 4, y = Int((box.minY * 1000).rounded()) + 2
                    let length = Int((box.height * 1000).rounded()) - 4
                    let component = Evidence.Component(seed: y * 1000 + x, pixelCount: length * 8, meanProbability: 0.95,
                        runs: (y..<(y + length)).map { .init(y: $0, x: x, count: 8) })
                    let extra = Evidence.Component(seed: 185210, pixelCount: 2, meanProbability: 0.95,
                        runs: [.init(y: 185, x: 210, count: 2)])
                    let e = Evidence(ownerID: "column-\(index)", parentBoxIndex: index,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                        mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                        sourceWidth: size, sourceHeight: size, components: [component] + (outlier && index == 0 ? [extra] : []),
                        ownershipVersion: 2, completeCCScan: true,
                        ambiguousComponents: ambiguous && index == 0 ? [extra] : [], candidateComponents: [])
                    let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    return .init(polygon: hidden == 3 && index == count ? [] : [
                        .init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)],
                        text: "列\(index)本文", score: 0.95, orientation: .vertical,
                        detectorSeedEvidence: missing && index == 0 ? nil : [e])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                let block = Array((0..<(count - 1)).reversed())
                var body = ReaderTranslationRegion(id: "body", rect: boxes.dropLast().reduce(CGRect.null) { $0.union($1) },
                    source: block.map { lines[$0].text }.joined())
                body.sourceOrientation = .vertical; body.sourceSingleVerticalColumn = count == 2; body.sourceImageAspectRatio = 1
                body.acceptedSource = .union(block.map { bound[$0].acceptedSource })
                body.detectorSeedEvidence = Evidence.preservingUnion(block.map { lines[$0].detectorSeedEvidence })
                var tail = ReaderTranslationRegion(id: "right", rect: boxes.last!, source: lines[count - 1].text)
                tail.sourceOrientation = .vertical; tail.sourceSingleVerticalColumn = true; tail.sourceImageAspectRatio = 1
                tail.acceptedSource = bound[count - 1].acceptedSource; tail.detectorSeedEvidence = lines[count - 1].detectorSeedEvidence
                return [body, tail]
            }
            for values in [input(), input(hidden: 2)] {
                for ordered in [values, Array(values.reversed())] {
                    let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
                    #expect(result.count == 1 && result[0].source == values[1].source + values[0].source)
                    #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(ordered,
                        scopes: [.init(owner: 1, box: scope.box, confidence: 0.79)]) == ordered)
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(ordered,
                        scopes: [.init(owner: 1, box: scope.box.insetBy(dx: -0.2, dy: -0.2), confidence: 0.95)]) == ordered)
                }
            }
            for negative in [input(hidden: 1), input(hidden: 3), input(missing: true), input(ambiguous: true), input(outlier: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [scope]) == negative)
            }
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func reciprocalOriginalColumnsDoNotDependOnStrongProposal(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        let boxes = [CGRect(x: 0.10, y: 0.10, width: 0.06, height: 0.20),
                     CGRect(x: 0.15, y: 0.12, width: 0.02, height: 0.10)]
        let commonBox = boxes[0].union(boxes[1])
        func input(missingAnchor: Bool = false, incomplete: Bool = false, foreign: Bool = false,
                   outside: Bool = false, block: Bool = false, ambiguousOnly: Bool = false,
                   unknown: Bool = false) -> [ReaderTranslationRegion] {
            let x = outside ? 200 : 155
            let shared = Evidence.Component(seed: 130000 + x, pixelCount: 120, meanProbability: 0.95,
                runs: (130..<140).map { .init(y: $0, x: x, count: 12) })
            let own = Evidence.Component(seed: 110110, pixelCount: 720, meanProbability: 0.95,
                runs: (110..<290).map { .init(y: $0, x: 110, count: 4) })
            let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                let evidence = Evidence(ownerID: "owner-\(index)", parentBoxIndex: index,
                    provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                    mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                    sourceWidth: size, sourceHeight: size, components: index == 0 && !missingAnchor ? [own] : [],
                    ownershipVersion: 2, completeCCScan: !(incomplete && index == 0),
                    ambiguousComponents: index == 0 || ambiguousOnly ? [shared] : [],
                    candidateComponents: index == 1 && !ambiguousOnly ? [.init(component: shared,
                        competingOwnerIDs: [foreign ? "foreign" : "owner-0"], outsideCompetingCells: [70])] : [])
                if !incomplete && !(missingAnchor && index == 0) { #expect(evidence.isValid) }
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)],
                    text: index == 0 ? "本文の続き" : "短い列", score: 0.95,
                    orientation: .vertical, detectorSeedEvidence: [evidence])
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            return boxes.indices.map { index in
                var r = ReaderTranslationRegion(id: "source-\(index)", rect: boxes[index], source: lines[index].text)
                r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = !(block && index == 0)
                r.sourceImageAspectRatio = 1
                if !(unknown && index == 1) { r.acceptedSource = bound[index].acceptedSource }
                r.detectorSeedEvidence = lines[index].detectorSeedEvidence
                return r
            }
        }
        let values = input()
        for confidence in [0.3, 0.5, 0.79, 0.95] {
            let scope = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: commonBox, confidence: confidence)
            for ordered in [values, Array(values.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
                #expect(result.count == 1 && result[0].source == values[1].source + values[0].source,
                        "reciprocal original confidence=\(confidence), scale=\(scale), result=\(result.map(\.source))")
                #expect(result[0].acceptedSource.membership?.body == Set([0, 1]))
                #expect(result[0].acceptedSource.membership?.table === values[0].acceptedSource.membership?.table)
                #expect(result[0].detectorSeedEvidence?.first { $0.ownerID == "owner-1" }?.components.isEmpty == true)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
            }
        }
        let weak = NativeParagraphFragmentGrouping.TextScope(owner: 1, box: commonBox, confidence: 0.5)
        for negative in [input(missingAnchor: true), input(incomplete: true), input(foreign: true),
                         input(outside: true), input(block: true), input(ambiguousOnly: true), input(unknown: true)] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [weak]) == negative)
        }
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values,
            scopes: [.init(owner: 1, box: commonBox, confidence: 0.24)]) == values)
        let competing = NativeParagraphFragmentGrouping.TextScope(owner: 2, box: boxes[1], confidence: 0.95)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [weak, competing]) == values)
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func closedCarrierConnectsIndependentOriginalColumns(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        for count in [1, 2, 4] {
            func input(missingAnchor: Bool = false, foreign: Bool = false, distant: Bool = false,
                       outside: Bool = false, incomplete: Bool = false, unknown: Bool = false,
                       candidateOutside: Bool = false) -> [ReaderTranslationRegion] {
                let boxes = [CGRect(x: 0.30, y: 0.10, width: 0.06, height: 0.20),
                             CGRect(x: 0.30, y: 0.11, width: 0.02, height: 0.10)] + (0..<count).map { index in
                    CGRect(x: (distant ? 0.20 : 0.28) - CGFloat(index) * 0.025, y: 0.10, width: 0.02, height: 0.20)
                }
                let sharedX = candidateOutside ? 500 : 305
                let shared = Evidence.Component(seed: 130000 + sharedX, pixelCount: 40, meanProbability: 0.95,
                    runs: (130..<140).map { .init(y: $0, x: sharedX, count: 4) })
                let lines = (0..<(boxes.count + (foreign ? 1 : 0))).map { index -> NativeCoreMLOCRLine in
                    let box = index < boxes.count ? boxes[index] : CGRect(x: 0.7, y: 0.7, width: 0.02, height: 0.1)
                    let x = Int((box.midX * 1000).rounded()) - 4
                    let own = Evidence.Component(seed: 110000 + x, pixelCount: 1440, meanProbability: 0.95,
                        runs: (110..<290).map { .init(y: $0, x: outside ? 900 : x, count: 8) })
                    let evidence = Evidence(ownerID: "owner-\(index)", parentBoxIndex: index,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                        mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                        sourceWidth: size, sourceHeight: size,
                        components: index < 2 || missingAnchor || index == boxes.count ? [] : [own],
                        ownershipVersion: 2, completeCCScan: !(incomplete && index == 2),
                        ambiguousComponents: index < 2 || index == boxes.count ?
                            (candidateOutside && index == 1 ? [] : [shared]) : [],
                        candidateComponents: candidateOutside && index == 1 ? [.init(component: shared,
                            competingOwnerIDs: ["owner-0"], outsideCompetingCells: [1])] : [])
                    let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: "列\(index)本文", score: 0.95,
                        orientation: .vertical, detectorSeedEvidence: [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                return boxes.indices.map { index in
                    var r = ReaderTranslationRegion(id: "source-\(index)", rect: boxes[index], source: lines[index].text)
                    r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = true; r.sourceImageAspectRatio = 1
                    if !(unknown && index == 2) { r.acceptedSource = bound[index].acceptedSource }
                    r.detectorSeedEvidence = lines[index].detectorSeedEvidence
                    return r
                }
            }
            func scope(_ values: [ReaderTranslationRegion], confidence: Double = 0.95) -> NativeParagraphFragmentGrouping.TextScope {
                .init(owner: 1, box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: confidence)
            }
            let values = input(), common = scope(values)
            for ordered in [values, Array(values.reversed())] {
                let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [common])
                #expect(result.count == 1)
                #expect(result[0].acceptedSource.membership?.body == Set(values.indices))
                #expect(result[0].acceptedSource.membership?.table === values[0].acceptedSource.membership?.table)
                #expect(result[0].source == values.map(\.source).joined())
                for id in ["owner-0", "owner-1"] {
                    let record = result[0].detectorSeedEvidence?.first { $0.ownerID == id }
                    #expect(record?.components.isEmpty == true && record?.ambiguousComponents?.count == 1)
                }
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [common]) == result)
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(ordered,
                    scopes: [scope(values, confidence: 0.79)]) == ordered)
            }
            for negative in [input(missingAnchor: true), input(foreign: true), input(distant: true),
                             input(outside: true), input(incomplete: true), input(unknown: true), input(candidateOutside: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [scope(negative)]) == negative)
            }
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func completeSingleColumnScopePreservesBlankSpacingAndOrder(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale)
        for count in [2, 3, 5] {
            func input(spacing: CGFloat = 0.12, hidden: Int = 0, missing: Bool = false,
                       ambiguous: Bool = false, outlier: Bool = false, drift: Bool = false,
                       block: Bool = false, extraStrong: Bool = false) -> [ReaderTranslationRegion] {
                let boxes = (0..<(count + (hidden == 0 ? 0 : 1))).map { index -> CGRect in
                    if index == count {
                        return hidden == 2 ? .init(x: 0.7, y: 0.2, width: 0.02, height: 0.06) :
                            .init(x: 0.295, y: 0.28, width: 0.01, height: 0.02)
                    }
                    let width: CGFloat = index.isMultiple(of: 2) ? 0.02 : 0.04
                    let center = 0.3 + (drift ? 0.012 : 0.001) * CGFloat(index) / CGFloat(count - 1)
                    return .init(x: center - width / 2, y: 0.2 + CGFloat(index) * spacing, width: width, height: 0.06)
                }
                let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                    let x = Int((box.midX * 1000).rounded()) - 4, y = Int((box.minY * 1000).rounded()) + 2
                    let length = Int((box.height * 1000).rounded()) - 4
                    let component = Evidence.Component(seed: y * 1000 + x, pixelCount: length * 8, meanProbability: 0.95,
                        runs: (y..<(y + length)).map { .init(y: $0, x: x, count: 8) })
                    let outside = Evidence.Component(seed: 212293, pixelCount: 1, meanProbability: 0.95,
                        runs: [.init(y: 212, x: 293, count: 1)])
                    let evidence = Evidence(ownerID: "column-\(index)", parentBoxIndex: index,
                        provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                        mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                        sourceWidth: size, sourceHeight: size,
                        components: ambiguous && index == 0 ? [] : [component] + (outlier && index == 0 ? [outside] : []),
                        ownershipVersion: 2, completeCCScan: true,
                        ambiguousComponents: ambiguous && index == 0 ? [component] : [], candidateComponents: [])
                    let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                    let polygon: [CGPoint] = hidden == 3 && index == count ? [] : [
                        .init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                        .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)]
                    return .init(polygon: polygon, text: "段\(index)文", score: 0.95, orientation: .vertical,
                        detectorSeedEvidence: missing && index == 0 ? nil : [evidence])
                }
                let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
                var values = (0..<count).map { index -> ReaderTranslationRegion in
                    var r = ReaderTranslationRegion(id: "part-\(index)", rect: boxes[index], source: lines[index].text)
                    r.sourceOrientation = .vertical; r.sourceSingleVerticalColumn = !(block && index == 0)
                    r.sourceImageAspectRatio = 1; r.confidence = 0.95; r.acceptedSource = bound[index].acceptedSource
                    return r
                }
                if extraStrong {
                    var extra = ReaderTranslationRegion(id: "competing", rect: .init(x: 0.295, y: 0.28, width: 0.01, height: 0.02), source: "別件")
                    extra.sourceOrientation = .vertical; extra.sourceSingleVerticalColumn = true; extra.sourceImageAspectRatio = 1
                    values.append(extra)
                }
                return values
            }
            func scope(_ values: [ReaderTranslationRegion], confidence: Double = 0.55) -> NativeParagraphFragmentGrouping.TextScope {
                .init(owner: 3, box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: confidence)
            }
            var positives = [input(), input(hidden: 2)]
            if count <= 3 { positives.append(input(spacing: 0.22)) }
            for values in positives {
                for ordered in [values, Array(values.reversed())] {
                    let common = scope(values), result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [common])
                    // Later observations deliberately drift RIGHT. Reading order
                    // must remain top-to-bottom, not rightmost-bbox first.
                    #expect(result.count == 1 && result[0].source == values.map(\.source).joined())
                    #expect(result[0].acceptedSource.membership?.body == Set(0..<count))
                    #expect(result[0].acceptedSource.membership?.table === values[0].acceptedSource.membership?.table)
                    #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [common]) == result)
                }
            }
            let values = input(), common = scope(values)
            for negative in [input(hidden: 1), input(hidden: 3), input(missing: true), input(ambiguous: true),
                             input(drift: true), input(block: true)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [scope(negative)]) == negative)
            }
            let outlier = input(outlier: true), full = scope(outlier).box
            let clipped = NativeParagraphFragmentGrouping.TextScope(owner: 3,
                box: .init(x: 0.294, y: full.minY, width: full.maxX - 0.294, height: full.height), confidence: 0.55)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(outlier, scopes: [clipped]) == outlier)
            let competitor = input(extraStrong: true), whole = scope(competitor)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(competitor, scopes: [whole,
                .init(owner: 9, box: competitor.last!.rect, confidence: 0.95)]) == competitor)
            let separate = values.enumerated().map { NativeParagraphFragmentGrouping.TextScope(owner: 10 + $0.offset,
                box: $0.element.rect, confidence: 0.95) }
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [common] + separate) == values)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [scope(values, confidence: 0.2)]) == values)
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [common,
                .init(owner: 4, box: common.box, confidence: common.confidence)]) == values)
            for box in [common.box.insetBy(dx: -common.box.width * 0.4, dy: 0),
                        common.box.insetBy(dx: 0, dy: -common.box.height * 0.4)] {
                #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [
                    .init(owner: 3, box: box, confidence: 0.55)]) == values)
            }
        }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func exteriorModelPeerRequiresIndependentInkAndNoTailConnection(scale: CGFloat) {
        typealias Evidence = NativeOCRDetectorSeedEvidence
        let size = Int(1000 * scale), words = ["縦書きの本文0", "縦書きの本文1", "注記"]
        func input(linked: Bool = false, missing: Bool = false, ambiguous: Bool = false,
                   displaced: Bool = false, unknown: Bool = false, otherTable: Bool = false,
                   wrongFrame: Bool = false) -> [ReaderTranslationRegion] {
            let boxes = [CGRect(x: 0.1, y: 0.1, width: 0.02, height: 0.2),
                         CGRect(x: 0.125, y: 0.1, width: 0.02, height: 0.2),
                         linked ? CGRect(x: 0.1, y: 0.31, width: 0.045, height: 0.02) :
                            CGRect(x: 0.3, y: 0.36, width: 0.04, height: 0.02)]
            let lines = boxes.enumerated().map { index, box -> NativeCoreMLOCRLine in
                let y = index == 2 ? (linked ? 315 : 365) : 110, end = index == 2 ? y + 10 : 290
                let xs = index == 2 ? (linked ? [105, 130] : [displaced ? 85 : 305]) : [index == 0 ? 105 : 130]
                let components = xs.map { x in Evidence.Component(seed: y * 1000 + x,
                    pixelCount: (end - y) * 5, meanProbability: 0.95,
                    runs: (y..<end).map { .init(y: $0, x: x, count: 5) }) }
                let evidence = Evidence(ownerID: "source-\(index)", parentBoxIndex: index,
                    provenance: "db-complete-cc-candidates-v2", threshold: 0.9,
                    mapOriginX: 0, mapOriginY: 0, mapFullWidth: 1000, mapFullHeight: 1000,
                    sourceWidth: size, sourceHeight: size,
                    components: index == 2 && ambiguous ? [] : components, ownershipVersion: 2, completeCCScan: true,
                    ambiguousComponents: index == 2 && ambiguous ? components : [], candidateComponents: [])
                let b = box.applying(.init(scaleX: CGFloat(size), y: CGFloat(size)))
                return .init(polygon: [.init(x: b.minX, y: b.minY), .init(x: b.maxX, y: b.minY),
                    .init(x: b.maxX, y: b.maxY), .init(x: b.minX, y: b.maxY)], text: words[index], score: 0.95,
                    orientation: index == 2 ? .horizontal : .vertical,
                    detectorSeedEvidence: index == 2 && missing ? nil : [evidence])
            }
            let bound = NativeOCRAcceptedSource.bindingPrimary(lines, width: size, height: size)
            var values = boxes.enumerated().map { index, box -> ReaderTranslationRegion in
                var r = ReaderTranslationRegion(id: "source-\(index)", rect: box, source: words[index])
                r.sourceOrientation = index == 2 ? .horizontal : .vertical; r.sourceSingleVerticalColumn = index != 2
                r.sourceImageAspectRatio = 1; r.confidence = 0.95; r.acceptedSource = bound[index].acceptedSource
                r.detectorSeedEvidence = lines[index].detectorSeedEvidence
                r.balloonInterior = .init(rect: .init(x: 0.08, y: 0.08, width: 0.32, height: 0.42),
                    center: .init(x: box.midX, y: box.midY), spans: Array(repeating: [0.08, 0.4], count: 20).flatMap { $0 },
                    contourVerified: false, modelEstimated: true)
                return r
            }
            if unknown { values[2].acceptedSource = .init() }
            if wrongFrame { values[2].sourceImageAspectRatio = 0.5 }
            if otherTable {
                values[2].acceptedSource = NativeOCRAcceptedSource.bindingPrimary([lines[2]], width: size, height: size)[0].acceptedSource
            }
            return values
        }
        let values = input()
        let scope = NativeParagraphFragmentGrouping.TextScope(owner: 3, box: values[0].rect.union(values[1].rect), confidence: 0.95)
        for ordered in [values, Array(values.reversed())] {
            let result = NativeParagraphFragmentGrouping.reconcilingObservations(ordered, scopes: [scope])
            #expect(result.count == 2 && result.contains { $0 == values[2] })
            #expect(result.contains { $0.source == words[1] + words[0] && $0.acceptedSource.membership?.body == Set([0, 1]) })
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(result, scopes: [scope]) == result)
        }
        for negative in [input(linked: true), input(missing: true), input(ambiguous: true),
                         input(displaced: true), input(unknown: true), input(otherTable: true), input(wrongFrame: true)] {
            #expect(NativeParagraphFragmentGrouping.reconcilingObservations(negative, scopes: [scope]) == negative)
        }
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [
            .init(owner: 3, box: scope.box, confidence: 0.79)]) == values)
        let coarse = NativeParagraphFragmentGrouping.TextScope(owner: 3,
            box: values.map(\.rect).reduce(CGRect.null) { $0.union($1) }, confidence: 0.95)
        #expect(NativeParagraphFragmentGrouping.reconcilingObservations(values, scopes: [coarse]) == values)
    }

    // Reconstruct expected membership only in tests; production consumes edges.
    private func partitions(_ input: [[Int]], edges: [NativeParagraphFragmentGrouping.Edge]) -> [[Int]] {
        var groups = input
        for edge in edges {
            guard let a = groups.firstIndex(where: { $0.contains(edge.first) }),
                  let b = groups.firstIndex(where: { $0.contains(edge.second) }) else {
                preconditionFailure("An edge references an unknown original member")
            }
            if a != b { groups[a] += groups[b]; groups.remove(at: b) }
        }
        #expect(groups.flatMap { $0 }.sorted() == input.flatMap { $0 }.sorted())
        return groups.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func shortEndpointDoesNotBridgeParagraphGutter(scale: CGFloat) {
        func atom(_ id: Int, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Atom {
            .init(index: id, source: "文章", box: .init(x: x * scale, y: y * scale, width: w * scale, height: h * scale),
                  orientation: .vertical, owner: nil)
        }
        let units = [atom(0, 696, 1472, 109, 580), atom(1, 744, 1466, 132, 477),
                     atom(2, 843, 1481, 81, 210), atom(3, 573, 1478, 88, 506)]
        for atoms in [units, Array(units.reversed())] {
            let result = NativeParagraphFragmentGrouping.infer(atoms: atoms, groups: [[0, 1], [2], [3]])
            let groups = partitions([[0, 1], [2], [3]], edges: result.edges)
            #expect(groups == [[0, 1, 2], [3]])
            #expect(result.edges.count == 1)
            #expect(NativeParagraphFragmentGrouping.infer(atoms: atoms, groups: groups).edges.isEmpty)
        }
        #expect(NativeParagraphFragmentGrouping.infer(atoms: units, groups: [[0, 1], [2], [3]],
                                                       separates: { _, _ in true }).edges.isEmpty)
        let far = atom(2, 990, 1481, 81, 210)
        #expect(NativeParagraphFragmentGrouping.infer(atoms: [units[0], units[1], far], groups: [[0, 1], [2]]).edges.isEmpty)
        let staggered = atom(2, 843, 1520, 81, 210)
        #expect(NativeParagraphFragmentGrouping.infer(atoms: [units[0], units[1], staggered], groups: [[0, 1], [2]]).edges.isEmpty)
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func overlappingGlyphRequiresOwnerAndIndependentInk(scale: CGFloat) {
        func atom(_ id: Int, _ owner: Int?, _ orientation: BrowserOCRSourceOrientation, _ source: String,
                  _ box: CGRect) -> Atom {
            .init(index: id, source: source, box: box.applying(.init(scaleX: scale, y: scale)), orientation: orientation, owner: owner)
        }
        let h = atom(11, 3, .horizontal, "ぱ", .init(x: 461, y: 399, width: 76, height: 87))
        let v = atom(18, 3, .vertical, "いを", .init(x: 453, y: 464, width: 86, height: 146))
        let good: (Atom) -> NativeParagraphFragmentGrouping.Ink? = { _ in .init(rgb: [1, 1, 1], samples: 72) }
        for atoms in [[h, v], [v, h]] {
            let result = NativeParagraphFragmentGrouping.infer(atoms: atoms, groups: [[11], [18]], ink: good)
            #expect(partitions([[11], [18]], edges: result.edges) == [[11, 18]])
            #expect(NativeParagraphFragmentGrouping.infer(atoms: atoms, groups: [[11], [18]]).edges.isEmpty)
            #expect(NativeParagraphFragmentGrouping.infer(atoms: atoms, groups: [[11], [18]],
                separates: { _, _ in true }, ink: good).edges.isEmpty)
        }
        for owner in [nil, 4] as [Int?] {
            let other = atom(18, owner, .vertical, "いを", .init(x: 453, y: 464, width: 86, height: 146))
            #expect(NativeParagraphFragmentGrouping.infer(atoms: [h, other], groups: [[11], [18]], ink: good).edges.isEmpty)
        }
        #expect(NativeParagraphFragmentGrouping.infer(atoms: [h, v], groups: [[11], [18]], ink: {
            .init(rgb: $0.index == 11 ? [0, 0, 0] : [100, 0, 0], samples: 72)
        }).edges.isEmpty)
        #expect(NativeParagraphFragmentGrouping.infer(atoms: [h, v], groups: [[11], [18]], ink: {
            _ in .init(rgb: [1, 1, 1], samples: 31)
        }).edges.isEmpty)
    }

    @Test func invalidPartitionsRemainUntouched() {
        let a = Atom(index: 0, source: "字", box: .init(x: 0, y: 0, width: 20, height: 20), orientation: .horizontal, owner: 0)
        #expect(NativeParagraphFragmentGrouping.infer(atoms: [a], groups: [[0], [0]]).edges.isEmpty)
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func equalPhysicalEndpointsAreNotContinuation(scale: CGFloat) {
        let whole = Atom(index: 0, source: "完全な観測", box: CGRect(x: 5, y: 7, width: 3, height: 27)
            .applying(.init(scaleX: scale / 97, y: scale / 97)), orientation: .vertical, owner: 1)
        let part = Atom(index: 1, source: "部分の観測", box: CGRect(x: 5, y: 13, width: 3, height: 21)
            .applying(.init(scaleX: scale / 97, y: scale / 97)), orientation: .vertical, owner: 1)
        #expect(NativeParagraphFragmentGrouping.columnRelations(atoms: [whole, part]).isEmpty)
        #expect(NativeParagraphFragmentGrouping.columnRelations(atoms: [part, whole]).isEmpty)
    }

    @Test func pipelinePreservesSourcesAndPhysicalMembers() {
        let width = 1200, height = 2400
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let boxes = [CGRect(x: 696, y: 1472, width: 109, height: 580),
                     CGRect(x: 744, y: 1466, width: 132, height: 477),
                     CGRect(x: 843, y: 1481, width: 81, height: 210)]
        let words = ["左の文章", "右の文章", "うう…"]
        func normalized(_ box: CGRect) -> CGRect {
            .init(x: box.minX / CGFloat(width), y: box.minY / CGFloat(height),
                  width: box.width / CGFloat(width), height: box.height / CGFloat(height))
        }
        func polygon(_ box: CGRect) -> [CGPoint] {
            [.init(x: box.minX, y: box.minY), .init(x: box.maxX, y: box.minY),
             .init(x: box.maxX, y: box.maxY), .init(x: box.minX, y: box.maxY)]
        }
        let lines = boxes.enumerated().map { NativeCoreMLOCRLine(polygon: polygon($0.element), text: words[$0.offset],
                                                               score: 0.9, orientation: .vertical) }
        var body = ReaderTranslationRegion(id: "body", rect: normalized(boxes[0].union(boxes[1])),
                                           source: words[1] + words[0])
        body.sourceOrientation = .vertical
        body.unitMemberRects = [normalized(boxes[0]), normalized(boxes[1])]
        var short = ReaderTranslationRegion(id: "short", rect: normalized(boxes[2]), source: words[2])
        short.sourceOrientation = .vertical
        let input = [body, short]
        let result = NativeParagraphFragmentGrouping.applying(input, lines: lines, ownerHints: input, image: image,
                                                              separates: { _, _, _ in false })
        #expect(result.count == 1)
        #expect(result.first?.source == words[2] + words[1] + words[0])
        #expect(result.first?.unitMemberRects.count == 3)
        #expect(result.first?.balloonInterior == nil)
        #expect(NativeParagraphFragmentGrouping.applying(input, lines: lines, ownerHints: input, image: image,
                                                         separates: { _, _, _ in true }) == input)
        var incomplete = body
        incomplete.unitMemberRects.append(normalized(CGRect(x: 730, y: 1390, width: 150, height: 650)))
        let partial = [incomplete, short]
        #expect(NativeParagraphFragmentGrouping.applying(partial, lines: lines, ownerHints: partial, image: image,
                                                         separates: { _, _, _ in false }) == partial)
    }

    @Test func pipelineSamplesOriginalInkAndInsertsGlyphAtItsColumn() {
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: 100); context.scaleBy(x: 1, y: -1)
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 12, y: 12, width: 8, height: 48))
        let image = context.makeImage()!
        let boxes = [CGRect(x: 10, y: 10, width: 20, height: 20), CGRect(x: 10, y: 25, width: 20, height: 40)]
        func evidence(_ i: Int) -> NativeOCRDetectorSeedEvidence {
            let box = boxes[i], y = i == 0 ? 12 : 32
            let probability = NativeOCRSourceROIProbabilityEvidence(
                version: 1, sourceWidth: 100, sourceHeight: 100, sourceDigest: String(repeating: "0", count: 64),
                roi: .init(x: Int(box.minX), y: Int(box.minY), width: Int(box.width), height: Int(box.height)),
                detector: .init(originX: 0, originY: 0, width: 100, height: 100, fullWidth: 100, fullHeight: 100),
                upperBounds: Data(repeating: 255, count: Int(box.width * box.height)))
            return .init(ownerID: "source-\(i)", parentBoxIndex: i, provenance: "db-4connected-original-cells-v1", threshold: 0.9,
                         mapOriginX: 0, mapOriginY: 0, mapFullWidth: 100, mapFullHeight: 100, sourceWidth: 100, sourceHeight: 100,
                         components: [.init(seed: y * 100 + 12, pixelCount: 1, meanProbability: 0.99,
                                            runs: [.init(y: y, x: 12, count: 1)])], sourceProbabilityROI: probability)
        }
        func polygon(_ box: CGRect) -> [CGPoint] {
            [.init(x: box.minX, y: box.minY), .init(x: box.maxX, y: box.minY),
             .init(x: box.maxX, y: box.maxY), .init(x: box.minX, y: box.maxY)]
        }
        let owners = [evidence(0), evidence(1)]
        #expect(owners.allSatisfy { $0.isValid })
        for owner in owners {
            let ink = NativeParagraphFragmentGrouping.sampleInk([owner], image: image)
            #expect(ink?.rgb == [0, 0, 0])
            #expect((ink?.samples ?? 0) >= 32)
        }
        let words = ["ぱ", "いを"], directions: [BrowserOCRSourceOrientation] = [.horizontal, .vertical]
        let lines = boxes.indices.map { i in
            NativeCoreMLOCRLine(polygon: polygon(boxes[i]), text: words[i], score: 0.9, orientation: directions[i],
                               detectorSeedEvidence: [owners[i]])
        }
        let regions = boxes.indices.map { i -> ReaderTranslationRegion in
            let box = boxes[i].applying(.init(scaleX: 0.01, y: 0.01))
            var r = ReaderTranslationRegion(id: "r\(i)", rect: box, source: words[i])
            r.sourceOrientation = directions[i]; r.detectorSeedEvidence = [owners[i]]
            return r
        }
        let hint = ReaderTranslationRegion(id: "hint", rect: regions[0].rect.union(regions[1].rect), source: words.joined())
        let output = NativeParagraphFragmentGrouping.applying(regions, lines: lines, ownerHints: [hint], image: image,
                                                              separates: { _, _, _ in false })
        #expect(output.count == 1)
        #expect(output.first?.source == "ぱいを")
        #expect(output.first?.detectorSeedEvidence?.count == 2)
        #expect(output.first?.unitMemberRects.count == 2)
        #expect(NativeParagraphFragmentGrouping.applying(regions, lines: lines, ownerHints: [hint, hint], image: image,
                                                         separates: { _, _, _ in false }) == regions)
    }
}
