import CoreGraphics
import Foundation

/// Recover one source reading unit when adjacent vertical OCR envelopes overlap
/// inside each other's independently observed balloon face. Source owners remain
/// separate; this changes the translation request, not the erasure geometry.
enum NativeOverlappingSourceUnitGrouping {
    static func hasSentenceBody(_ source: String) -> Bool {
        let japaneseCount = source.unicodeScalars.reduce(into: 0) { count, scalar in
            let value = scalar.value
            if (0x3040...0x30FF).contains(value) || (0x3400...0x9FFF).contains(value) {
                count += 1
            }
        }
        return japaneseCount >= 2
    }

    static func apply(_ input: [ReaderTranslationRegion], image: CGImage,
                      separates: (CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool) throws -> [ReaderTranslationRegion] {
        guard (2...256).contains(input.count), image.width > 0, image.height > 0 else { return input }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        func pixels(_ region: ReaderTranslationRegion) -> CGRect {
            CGRect(x: region.rect.minX * width, y: region.rect.minY * height,
                width: region.rect.width * width, height: region.rect.height * height)
        }
        func eligible(_ region: ReaderTranslationRegion) -> Bool {
            region.translation == nil && region.sourceOrientation == .vertical &&
                region.source.count >= 3 && region.source.count <= 80 &&
                hasSentenceBody(region.source) && !region.isOccludedFinePrint &&
                region.rect.width > 0 && region.rect.height > 0 && page.contains(pixels(region))
        }
        let eligibleIndices = input.indices.filter { eligible(input[$0]) }
        var possible: [(Int, Int)] = []
        for (offset, i) in eligibleIndices.enumerated() {
            let a = pixels(input[i])
            for j in eligibleIndices.dropFirst(offset + 1) {
                let b = pixels(input[j]), shared = a.intersection(b)
                guard !shared.isNull, shared.width > 0, shared.height > 0,
                      shared.width * shared.height >= min(a.width * a.height, b.width * b.height) * 0.08,
                      shared.width * shared.height <= min(a.width * a.height, b.width * b.height) * 0.75,
                      shared.height >= min(a.height, b.height) * 0.45,
                      abs(a.midX - b.midX) >= min(a.width, b.width) * 0.45,
                      !separates(a, b, .vertical) else { continue }
                let first = input[i].source.trimmingCharacters(in: .whitespacesAndNewlines)
                let second = input[j].source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard first != second, !first.contains(second), !second.contains(first) else { continue }
                possible.append((i, j))
            }
        }
        guard !possible.isEmpty, possible.count <= 64 else { return input }
        let involved = Set(possible.flatMap { [$0.0, $0.1] })
        let reader = NativeSourcePixelReader(image: image, preservesSamplingGeometry: true)
        defer { reader.release() }
        var surfaces: [Int: NativeTextBoxContainment.Surface] = [:]
        var remainingPixels = 1_600_000
        for index in involved.sorted() {
            try Task.checkCancellation()
            let owner = pixels(input[index]), extent = max(owner.width, owner.height) * 2.4
            let roi = owner.insetBy(dx: -extent, dy: -extent).intersection(page)
            let sampleWidth = Int(min(320, ceil(roi.width)))
            let sampleHeight = Int(min(320, ceil(roi.height)))
            guard sampleWidth >= 8, sampleHeight >= 8,
                  sampleWidth <= remainingPixels / sampleHeight else { continue }
            remainingPixels -= sampleWidth * sampleHeight
            let rgba = try reader.read(x: Double(roi.minX), y: Double(roi.minY),
                sourceWidth: Double(roi.width), sourceHeight: Double(roi.height),
                width: sampleWidth, height: sampleHeight)
            if let surface = try NativeTextBoxContainment.measured(rgba: rgba, width: sampleWidth,
                height: sampleHeight, roi: roi, owner: owner), surface.certifiedSpans,
               surface.contains(owner) { surfaces[index] = surface }
        }
        var links: [(Int, Int)] = []
        for (i, j) in possible {
            guard let a = surfaces[i], let b = surfaces[j],
                  a.contains(pixels(input[j])), b.contains(pixels(input[i])) else { continue }
            links.append((i, j))
        }
        guard !links.isEmpty else { return input }
        var parent = Dictionary(uniqueKeysWithValues: involved.map { ($0, $0) })
        func root(_ index: Int) -> Int {
            var node = index
            while parent[node] != node { node = parent[node]! }
            return node
        }
        for (i, j) in links { parent[root(j)] = root(i) }
        var groups: [Int: [Int]] = [:]
        for index in involved { groups[root(index), default: []].append(index) }
        var replacements: [Int: ReaderTranslationRegion] = [:]
        var removed = Set<Int>()
        for members in groups.values where (2...3).contains(members.count) {
            let sorted = members.sorted { pixels(input[$0]).midX > pixels(input[$1]).midX }
            let anchor = members.min()!
            let union = members.dropFirst().reduce(input[members[0]].rect) { $0.union(input[$1].rect) }
            let unionPixels = pixels(input[members[0]]).union(members.dropFirst().reduce(CGRect.null) {
                $0.union(pixels(input[$1]))
            })
            guard !input.indices.contains(where: { index in
                guard !members.contains(index) else { return false }
                let other = pixels(input[index]), shared = other.intersection(unionPixels)
                return !shared.isNull && shared.width * shared.height >= other.width * other.height * 0.08
            }), sorted.allSatisfy({ index in surfaces[index]?.contains(unionPixels) == true }) else { continue }
            let originals = sorted.map { input[$0] }
            let sourceSeeds = NativeOCRDetectorSeedEvidence.preservingUnion(originals.map(\.detectorSeedEvidence))
            guard sourceSeeds != nil || originals.allSatisfy({ $0.detectorSeedEvidence?.isEmpty ?? true }) else { continue }
            var joined = ReaderTranslationRegion(id: input[anchor].id, rect: union,
                source: originals.map(\.source).joined(), confidence: originals.map(\.confidence).min() ?? 0,
                sourceImageAspectRatio: Double(width / height), sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false)
            joined.unitMemberRects = originals.flatMap { $0.unitMemberRects.isEmpty ? [$0.rect] : $0.unitMemberRects }
            joined.auxiliaryInkRects = originals.flatMap(\.auxiliaryInkRects)
            joined.auxiliaryInkPolygons = originals.flatMap(\.auxiliaryInkPolygons)
            joined.detectorSeedEvidence = sourceSeeds
            joined.acceptedSource = .union(originals.map(\.acceptedSource))
            joined.sourceOCRAlternatives = originals.flatMap(\.sourceOCRAlternatives)
            joined.isRecoveredLine = originals.contains { $0.isRecoveredLine }
            joined.polygon = [CGPoint(x: union.minX, y: union.minY), CGPoint(x: union.maxX, y: union.minY),
                CGPoint(x: union.maxX, y: union.maxY), CGPoint(x: union.minX, y: union.maxY)]
            replacements[anchor] = joined
            removed.formUnion(members.filter { $0 != anchor })
        }
        return input.indices.compactMap { replacements[$0] ?? (removed.contains($0) ? nil : input[$0]) }
    }
}
