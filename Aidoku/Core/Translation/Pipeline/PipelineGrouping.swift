import CoreGraphics
import Foundation

// S4: recognized lines -> paragraph/balloon blocks (PipelineParagraphGrouping) in reading order
// (ReaderTranslationPanelOrder, mirrored for left-to-right; strips use bands only).

/// Downsampled 8-bit gray page for panel-gutter ordering (<= 768 px side).
struct PipelineGrayRaster: Sendable {
    let pixels: [UInt8]
    let width: Int
    let height: Int

    /// The same 768-px medium-quality gray rendering the legacy reader uses.
    init?(image: CGImage) {
        let scale = min(1, 768 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(pixels: pixels, width: width, height: height)
    }

    init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    /// The horizontally mirrored raster (left-to-right panel order).
    func mirrored() -> PipelineGrayRaster {
        guard width > 1, pixels.count == width * height else { return self }
        var flipped = pixels
        for row in 0..<height {
            let start = row * width
            for column in 0..<width { flipped[start + column] = pixels[start + width - 1 - column] }
        }
        return PipelineGrayRaster(pixels: flipped, width: width, height: height)
    }

    /// Pixel-free stand-in: layout frames painted dark on white, so frame
    /// gutters become the bright bands the panel splitter cuts at.
    init?(frames: [CGRect], pageSize: CGSize) {
        guard !frames.isEmpty, pageSize.width > 0, pageSize.height > 0 else { return nil }
        let scale = min(1, 768 / max(pageSize.width, pageSize.height))
        width = max(1, Int(pageSize.width * scale))
        height = max(1, Int(pageSize.height * scale))
        var pixels = [UInt8](repeating: 255, count: width * height)
        for frame in frames where !frame.isNull && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy({
            $0.isFinite && abs($0) < 1e9
        }) {
            let x0 = max(0, Int((frame.minX * scale).rounded(.down))), x1 = min(width, Int((frame.maxX * scale).rounded(.up)))
            let y0 = max(0, Int((frame.minY * scale).rounded(.down))), y1 = min(height, Int((frame.maxY * scale).rounded(.up)))
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 { for x in x0..<x1 { pixels[y * width + x] = 0 } }
        }
        self.pixels = pixels
    }
}

enum PipelineGrouping {
    /// Groups lines into blocks (`id` == 0-based `readingOrder`); without `raster` the
    /// layout frames stand in for panel borders.
    static func group(
        _ lines: [PipelineLine],
        layout: [PipelineLayoutRegion],
        pageSize: CGSize,
        raster: PipelineGrayRaster? = nil,
        direction: PipelineReadingDirection = .rightToLeft
    ) -> [PipelineBlock] {
        let usable = lines.filter { line in
            line.polygon.count >= 3 && line.polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        }
        guard !usable.isEmpty else { return [] }
        func scopes(_ kind: PipelineLayoutKind) -> [PipelineParagraphGrouping.Scope] {
            layout.enumerated().compactMap { index, region in
                region.kind == kind && region.bounds.isFinite
                    ? .init(owner: index, box: region.bounds, confidence: Double(region.score)) : nil
            }
        }
        let inputs = usable.map { line in
            PipelineParagraphGrouping.Input(polygon: line.polygon, vertical: line.vertical,
                confidence: Double(line.confidence), source: line.text)
        }
        let units = PipelineBalloonUnits(lines: usable, raster: raster, pageSize: pageSize)
        let groups = PipelineParagraphGrouping.group(inputs, textScopes: scopes(.text), balloons: scopes(.balloon), joins: units.gap)
            // Invalid scope geometry: keep every line as its own block.
            ?? usable.indices.map { index in
                PipelineParagraphGrouping.Group(members: [index], readingOrder: [index], polygon: usable[index].polygon,
                                          vertical: usable[index].vertical)
            }
        let balloons = layout.filter { $0.kind == .balloon && $0.bounds.isFinite && !$0.bounds.isEmpty }
        var blocks = groups.map { group -> PipelineBlock in
            let members = group.readingOrder.map { usable[$0] }
            let bounds = members.reduce(CGRect.null) { $0.union(polygonBounds($1.polygon)) }
            // Ruby readings are erased with the block (S6 uses its lines) but are not part of its text or bounds.
            return PipelineBlock(id: 0, lines: members + group.readings.map { usable[$0] }, bounds: bounds, polygon: group.polygon,
                vertical: group.vertical, readingOrder: 0,
                sourceText: joinedText(members.map(\.text)), balloon: enclosingBalloon(bounds, balloons))
        }
        let order = readingOrder(blocks, layout: layout, pageSize: pageSize, raster: raster, direction: direction)
        blocks = order.enumerated().map { rank, index in
            var block = blocks[index]
            block.id = rank
            block.readingOrder = rank
            return block
        }
        return blocks
    }

    /// Top-to-bottom bands of overlapping rows, ordered inside by the reading direction
    /// (left-to-right for strips); paged directions then apply panel ranks from gutters.
    static func readingOrder(_ blocks: [PipelineBlock], layout: [PipelineLayoutRegion], pageSize: CGSize,
                             raster: PipelineGrayRaster?, direction: PipelineReadingDirection = .rightToLeft) -> [Int] {
        guard blocks.count > 1 else { return Array(blocks.indices) }
        let byTop = blocks.indices.sorted { blocks[$0].bounds.minY < blocks[$1].bounds.minY }
        var bands: [[Int]] = []
        var bottom = -CGFloat.infinity
        for index in byTop {
            let box = blocks[index].bounds
            // A new band starts strictly below every block of the current one.
            if bands.isEmpty || box.minY > bottom {
                bands.append([index])
                bottom = box.maxY
            } else {
                bands[bands.count - 1].append(index)
                bottom = max(bottom, box.maxY)
            }
        }
        let rightToLeft = direction == .rightToLeft
        let base = bands.flatMap { band in
            band.sorted { first, second in
                let a = blocks[first].bounds, b = blocks[second].bounds
                if rightToLeft { return a.maxX == b.maxX ? first < second : a.maxX > b.maxX }
                return a.minX == b.minX ? first < second : a.minX < b.minX
            }
        }
        guard direction != .topToBottom else { return base }
        let frames = layout.filter { $0.kind == .frame && $0.score >= 0.5 }.map(\.bounds)
        guard let source = raster ?? PipelineGrayRaster(frames: frames, pageSize: pageSize),
              pageSize.width > 0, pageSize.height > 0 else { return base }
        // Left-to-right panels are right-to-left panels of the mirrored page.
        let gray = rightToLeft ? source : source.mirrored()
        let page = CGRect(origin: .zero, size: pageSize)
        let inputs = base.map { index -> ReaderTranslationPanelOrder.Input in
            let box = blocks[index].bounds.intersection(page)
            let rect = box.isNull ? CGRect(x: 0, y: 0, width: 1 / pageSize.width, height: 1 / pageSize.height) : box
            var normalized = CGRect(x: rect.minX / pageSize.width, y: rect.minY / pageSize.height,
                                    width: max(rect.width, 1) / pageSize.width, height: max(rect.height, 1) / pageSize.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if !rightToLeft { normalized.origin.x = 1 - normalized.maxX }
            return .init(rect: normalized, isVertical: blocks[index].vertical)
        }
        let ranks = ReaderTranslationPanelOrder.rightToLeftRanks(pixels: gray.pixels, width: gray.width,
                                                                 height: gray.height, inputs: inputs)
        guard ranks.sorted() == Array(base.indices) else { return base }
        var ordered = Array(repeating: 0, count: base.count)
        for (slot, rank) in ranks.enumerated() { ordered[rank] = base[slot] }
        return ordered
    }

    /// The smallest balloon holding at least half of the block.
    static func enclosingBalloon(_ bounds: CGRect, _ balloons: [PipelineLayoutRegion]) -> CGRect? {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        let area = bounds.width * bounds.height
        return balloons.filter { $0.score >= PipelineLayoutRegion.balloonFloor }.map(\.bounds).filter { balloon in
            let overlap = balloon.intersection(bounds)
            return !overlap.isNull && overlap.width * overlap.height >= area / 2
        }.min { $0.width * $0.height < $1.width * $1.height }
    }

    /// CJK runs join directly; anything else joins with one space.
    static func joinedText(_ parts: [String]) -> String {
        parts.reduce(into: "") { result, part in
            guard !part.isEmpty else { return }
            if let last = result.unicodeScalars.last, let first = part.unicodeScalars.first,
               !(isCJK(last) && isCJK(first)) {
                result += " "
            }
            result += part
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0xA4CF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x323AF, 0x2000...0x206F: true
        default: false
        }
    }

    static func polygonBounds(_ points: [CGPoint]) -> CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }
}

private extension CGRect {
    var isFinite: Bool {
        !isNull && [minX, minY, maxX, maxY].allSatisfy(\.isFinite)
    }
}
