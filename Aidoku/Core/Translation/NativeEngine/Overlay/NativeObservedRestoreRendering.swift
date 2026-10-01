import CoreGraphics
import Foundation

extension NativeObservedRestoreState {
    typealias Helpers = NativeObservedRestorationHelpers

    /// Shared ownership decision before preserved-pixel qualifications. Keeping
    /// body ownership separate from complete erasure prevents frame-connected
    /// drawing from becoming permission to release the entire OCR rectangle.
    var ownershipCertificate: (glyphs: Bool, erasure: Bool) {
        let glyphs = unresolved == 0 && !auxiliary.contains {
            Helpers.rectHasInk(protectedInk, frameInk: frameInk, w: pixels.width, rect: $0)
        }
        return (glyphs, glyphs && frameInterior == 0)
    }

    var followHalo: Bool {
        measuredHalo && options.outlineFringe && palette.stroke.map {
            $0.distance(background) >= 40 || $0.minimum >= 230 && palette.strokeConfidence >= 0.7 && $0.distance(foreground) >= 80
        } == true
    }
    var outlinedDark: Bool {
        let confidence = palette.metadata["confidence"] as? [String: Any]
        return legacyDark && (palette.stroke?.minimum ?? 0) >= 230 && palette.foregroundConfidence >= 0.6 &&
            palette.strokeConfidence >= 0.6 && confidence?["reason"] as? String == "repeated dark glyph interiors enclosed by white source outlines"
    }

    func establishMask() -> Bool {
        queue = [Int](repeating: 0, count: pixels.count)
        if options.readabilityGate && options.vertical && legacyDark && auxiliary.isEmpty {
            auxiliary.append(contentsOf: NativeSourceGlyphSegmentation.inferVerticalRuby(raw: raw, rgba: pixels.rgba,
                width: pixels.width, height: pixels.height, box: box, background: background.channels).filter { r in
                    !options.inferredRubyExclusions.contains { $0.intersects(r) }
                })
        }
        recruitFaintInk()
        guard classifyComponents() else { return false }
        if options.protectArtMargin || options.readabilityGate {
            drawingSurface = Helpers.growDrawingSupport(pixels.rgba, w: pixels.width, h: pixels.height,
                threshold: min(210, background.minimum - 40), frameInk: &frameInk, raw: raw, mask: &mask,
                seedRadius: &seedRadius, protectedInk: &protectedInk, queue: &queue)
        }
        if options.readabilityGate && !options.slantedOwnership {
            _ = Helpers.preserveFrameFringe(pixels.rgba, w: pixels.width, h: pixels.height, box: box,
                background: background.channels, raw: raw, mask: mask, protectedInk: protectedInk, frameInk: &frameInk)
        }
        codecIslands()
        coreCount = mask.reduce(0) { $0 + Int($1) }
        let substantial = acceptedObserved.reduce(0) { $0 + ($1 >= 2 ? $1 : 0) }
        let density = options.flatPalette ? 0.48 : (outlinedDark ? 0.42 :
            (connectedOutlineRuns > 0 && palette.stroke != nil && palette.strokeConfidence >= 0.6 ? 0.48 : 0.3))
        guard Double(substantial) <= box.width * box.height * density else { return false }
        unresolved = Helpers.countUnresolvedInk(protectedInk, frameInk: frameInk, w: pixels.width, box: box)
        guard options.slantedOwnership || options.segmentedSurfaceRecovery || unresolved <= max(8, Int(Double(coreCount) * 0.04)) else { return false }
        if options.excludedDonorPolicy == .observedSource && !options.excluded.isEmpty && separation >= 80 {
            // Broad OCR bounds may include source backing. Reuse the palette
            // classifier's bounded tolerance; unrelated ink, outline and art
            // retain their donor barrier and its full eight-pixel margin.
            var forbidden = protectedInk
            var foreignInk = [UInt8](repeating: 0, count: pixels.count)
            let tolerance = max(10, min(48, separation * 0.4))
            for i in 0..<pixels.count where frameInk[i] != 0 || drawingSurface[i] != 0 { forbidden[i] = 1 }
            for rect in options.excluded { for i in pixels.indices(rect) {
                let color = pixels.color(i)
                let outline = palette.stroke.map { $0.distance(background) >= 40 && color.distance($0) <= tolerance } == true
                if raw[i] != 0 || observedInk[i] != 0 || color.distance(background) > tolerance ||
                    color.distance(foreground) <= tolerance || outline {
                    forbidden[i] = 1; foreignInk[i] = 1
                }
            } }
            sourceDonorBlocked = Helpers.blockProtectedDonors(forbidden, w: pixels.width, h: pixels.height, queue: &queue).blocked
            // Exemplar patches use a nine-pixel footprint, not the diffusion
            // donor dilation. Explicitly keep the same foreign-ink margin in
            // its source footprint; default kernel inputs are unaffected.
            if foreignInk.contains(1) {
                let margin = Helpers.blockProtectedDonors(foreignInk, w: pixels.width, h: pixels.height, queue: &queue).blocked
                for i in 0..<pixels.count where margin[i] != 0 { forbidden[i] = 1 }
            }
            sourceDonorForbidden = forbidden
        }
        for rect in options.excluded { for i in pixels.indices(rect) { protectedInk[i] = 1; mask[i] = 0; seedRadius[i] = 0 } }
        let donors = Helpers.blockProtectedDonors(protectedInk, w: pixels.width, h: pixels.height, queue: &queue)
        donorBlocked = donors.blocked; donorDistance = donors.distance
        for i in 0..<pixels.count where drawingSurface[i] != 0 { donorBlocked[i] = 1 }
        if background.maximum < 225 {
            for rect in auxiliary { for i in pixels.indices(rect.insetBy(dx: -12, dy: -12)) where pixels.color(i).minimum > 240 { donorBlocked[i] = 1 } }
        }
        if var sourceDonors = sourceDonorBlocked {
            for i in 0..<pixels.count where drawingSurface[i] != 0 { sourceDonors[i] = 1 }
            if background.maximum < 225 {
                for rect in auxiliary { for i in pixels.indices(rect.insetBy(dx: -12, dy: -12)) where pixels.color(i).minimum > 240 {
                    sourceDonors[i] = 1
                } }
            }
            sourceDonorBlocked = sourceDonors
        }
        var tail = Helpers.maskQueue(mask, queue: &queue, n: pixels.count), flags: [UInt8] = [0]
        let extents = accepted.filter { $0.points.count >= 8 }.map { max($0.rect.width, $0.rect.height) }.sorted()
        let glyphSize = min(min(box.width, box.height), extents.isEmpty ? .infinity : extents[Int(Double(extents.count) * 0.75)])
        tail = Helpers.dilateOwnedMask(pixels.rgba, w: pixels.width, h: pixels.height, queue: &queue, tail: tail,
            mask: &mask, distance: &distance, seedRadius: &seedRadius, protectedInk: protectedInk, drawingSurface: drawingSurface,
            donorBlocked: &donorBlocked, donorDistance: donorDistance, protectArtMargin: options.protectArtMargin, followHalo: followHalo,
            preciseFringe: options.preciseFringe, radius: Double(radius), background: background.channels,
            strokeBackgroundBlend: Helpers.blend(end: background.channels, start: palette.stroke?.channels), flags: &flags,
            glyphMargin: max(3, Double(ceil(glyphSize * 0.3))), foreground: foreground.channels, owned: [box] + auxiliary + options.rowEndMarks)
        if flags[0] != 0 { extendedHalo = true }
        if (options.slantedOwnership || outlinedDark && (palette.stroke?.distance(background) ?? .infinity) < 40 ||
            options.readabilityGate && options.vertical && foreground.maximum - foreground.minimum >= 40) &&
            palette.stroke != nil && palette.strokeConfidence >= 0.6 && palette.stroke!.distance(background) >= 8 {
            tail = Helpers.fillEnclosedHoles(pixels.rgba, w: pixels.width, h: pixels.height, box: box, mask: &mask, queue: &queue,
                protectedInk: protectedInk, drawingSurface: drawingSurface, stroke: palette.stroke?.channels, background: background.channels,
                inkStrokeBlend: Helpers.blend(end: palette.stroke?.channels, start: foreground.channels),
                strokeBackgroundBlend: Helpers.blend(end: background.channels, start: palette.stroke?.channels))
        }
        queueTail = tail
        enclosedResidualIslands()
        let interior = Helpers.frameInterior(frameInk, w: pixels.width, box: box)
        frameInterior = interior.pixels; innerArea = interior.area
        if options.segmentedSurfaceRecovery && frameInterior > 0 && unresolved > max(8, Int(Double(coreCount) * 0.04)) { return false }
        sourceErasureVerified = ownershipCertificate.erasure
        if hasPeriodicTexture && !periodicInk && texturePoints.reduce(0, { $0 + Int(mask[$1]) }) > max(8, Int(Double(texturePoints.count) * 0.05)) {
            return false
        }
        return tail > 0
    }

    func flatSurfaceFringe(_ quality: Pixels.Surface) -> Bool {
        guard options.flatPalette && options.vertical && !options.slantedOwnership && quality.safe && quality.rmse <= 8 &&
            foreground.maximum - foreground.minimum >= 40 else { return false }
        var pending: [Int] = []
        for y in Int(ceil(box.minY))..<Int(floor(box.maxY)) { for x in Int(ceil(box.minX))..<Int(floor(box.maxX)) {
            let i = y * pixels.width + x
            if mask[i] != 0 || protectedInk[i] != 0 || drawingSurface[i] != 0 { continue }
            let bg = quality.coefficients.map { $0[0] + $0[1] * Double(x) / Double(pixels.width) + $0[2] * Double(y) / Double(pixels.height) }
            let color = pixels.color(i).channels, delta = zip(foreground.channels, bg).map(-)
            let length = delta.reduce(0) { $0 + $1 * $1 }
            guard length >= 1600, zip(color, bg).map({ abs($0 - $1) }).max()! >= 24 else { continue }
            let t = (0..<3).reduce(0) { $0 + (color[$1] - bg[$1]) * delta[$1] } / length
            guard t >= 0.1, t < 0.95, (0..<3).map({ abs(color[$0] - bg[$0] - t * delta[$0]) }).max()! <= 18 else { continue }
            let owned = pixels.neighbors(i).reduce(Int(mask[i])) { $0 + Int(mask[$1]) }
            if owned >= 3 { pending.append(i) }
        } }
        for i in pending { mask[i] = 1 }
        return !pending.isEmpty
    }

    func certified(_ candidate: Pixels, preservedCore: Int = 0, preservedPixels: Int = 0, quality: Pixels.Surface? = nil) -> Pixels {
        var output = candidate
        output.sourceRemainingInk = unresolved; output.sourceCorePixels = coreCount; output.sourceFramePixels = frameInterior
        output.preservedCore = preservedCore; output.preservedPixels = preservedPixels
        output.surfaceQuality = quality?.payload
        output.layoutSafe = Helpers.layoutSafe(protectedInk, drawingSurface: drawingSurface, n: pixels.count)
        output.glyphsVerified = ownershipCertificate.glyphs && preservedCore == 0 && preservedPixels == 0
        // establishMask can infer ruby after the caller's polygon proof was
        // built. Retain the existing ink/frame veto for these added regions;
        // body-contained explicit metadata is handled by the polygon proof.
        let inferredAuxiliaryHasInk = options.glyphOwnership != nil && auxiliary.contains { rect in
            !options.auxiliary.contains(rect) &&
                Helpers.rectHasInk(protectedInk, frameInk: frameInk, w: pixels.width, rect: rect)
        }
        output.polygonGlyphsVerified = options.glyphOwnership?.certifiesBodyGlyphs(protectedInk: protectedInk, frameInk: frameInk) == true &&
            !inferredAuxiliaryHasInk && preservedCore == 0 && preservedPixels == 0
        output.sourceErasureVerified = sourceErasureVerified && preservedCore == 0 && preservedPixels == 0
        output.erasureComplete = sourceErasureVerified && preservedCore == 0 && preservedPixels == 0
        return output
    }

    /// Reconstruction may use independently classified source backing, but
    /// strict geometry has already decided admission, growth and paint alpha.
    /// Failure to requalify a smooth source surface retains the strict donors.
    func reconstructionDonors(_ quality: Pixels.Surface?) -> (quality: Pixels.Surface?, blocked: [UInt8]?, forbidden: [UInt8]) {
        guard quality?.safe == true, quality?.reason == "smooth",
              let blocked = sourceDonorBlocked, let forbidden = sourceDonorForbidden,
              let measured = Pixels.surface(pixels, mask: mask, blocked: blocked, dense: options.denseDonorSampling),
              measured.safe && measured.reason == "smooth" else { return (quality, nil, protectedInk) }
        return (measured, blocked, forbidden)
    }

    func diffuse(_ quality: Pixels.Surface?, colorDonors: [UInt8]? = nil) -> Pixels? {
        let strictDonors = colorDonors == nil ? nil : donorBlocked
        if let colorDonors { donorBlocked = colorDonors }
        defer { if let strictDonors { donorBlocked = strictDonors } }
        var p = pixels.rgba, tail = queueTail, paint = mask
        let originalMask = mask
        let planarFront: [(Int, [UInt8])]? = quality.map { $0.safe && $0.reason == "smooth" } == true ?
            queue.prefix(tail).map { ($0, Array(p[($0 * 4)..<($0 * 4 + 3)])) } : nil
        Helpers.fillFromDonorFront(p: &p, w: pixels.width, n: pixels.count, queue: queue, tail: tail,
                                  mask: &mask, donorBlocked: donorBlocked, paintMask: paint)
        if !options.protectArtMargin && mask.contains(1) { return nil }
        let preserved = Helpers.countPreserved(mask, raw: raw, n: pixels.count)
        guard Double(preserved.core) <= min(64, Double(coreCount) * 0.02), Double(preserved.pixels) <= Double(tail) * 0.15 else { return nil }
        var painted = 0
        for k in 0..<tail {
            let i = queue[k]
            if mask[i] != 0 { paint[i] = 0; donorBlocked[i] = 1 }
            else { queue[painted] = i; painted += 1 }
        }
        tail = painted
        guard tail > 0 else { return nil }
        if let planarFront, let quality {
            let strokes = palette.stroke.map { $0.distance(background) >= 32 ? [$0.channels] : [] } ?? []
            let inks = [foreground, options.secondaryInk].compactMap { $0?.channels }
            let tainted = Helpers.contaminatedFrontDonors(p: p, w: pixels.width, h: pixels.height, queue: queue, tail: tail,
                donorBlocked: donorBlocked, paintMask: paint, coefficients: quality.coefficients, strokes: strokes, inks: inks)
            if !tainted.indices.isEmpty {
                let first = queue.prefix(tail).map { Array(p[($0 * 4)..<($0 * 4 + 3)]) }, start = tail
                for (i, rgb) in planarFront { for c in 0..<3 { p[i * 4 + c] = rgb[c] } }
                let specks = Set(tainted.specks), unlinked = tainted.indices.filter { !specks.contains($0) }
                let speckRGB = tainted.specks.map { Array(p[($0 * 4)..<($0 * 4 + 3)]) }
                for i in unlinked { donorBlocked[i] = 1 }
                for i in tainted.specks { paint[i] = 1; queue[tail] = i; tail += 1 }
                for i in queue.prefix(tail) { mask[i] = 1 }
                Helpers.fillFromDonorFront(p: &p, w: pixels.width, n: pixels.count, queue: queue, tail: tail,
                                          mask: &mask, donorBlocked: donorBlocked, paintMask: paint)
                if queue.prefix(tail).contains(where: { mask[$0] != 0 }) {
                    for i in queue.prefix(tail) { mask[i] = 0 }
                    for (k, i) in tainted.specks.enumerated() { paint[i] = 0; for c in 0..<3 { p[i * 4 + c] = speckRGB[k][c] } }
                    tail = start
                    for k in 0..<tail { let i = queue[k]; for c in 0..<3 { p[i * 4 + c] = first[k][c] } }
                    for i in unlinked { donorBlocked[i] = 0 }
                }
            }
        }
        var seed = pixels; seed.rgba = p
        let accelerated = quality?.reason == "smooth" && quality?.outliers == 0 && frameInterior == 0
        let output = Pixels.harmonicFill(pixels, mask: paint, blocked: donorBlocked, seed: seed, accelerated: accelerated,
                                        orderedQueue: Array(queue.prefix(tail)))
        mask = originalMask
        return certified(output, preservedCore: preserved.core, preservedPixels: preserved.pixels, quality: quality)
    }
}
