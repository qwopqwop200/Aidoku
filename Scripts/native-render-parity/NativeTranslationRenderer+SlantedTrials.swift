import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// One render's source proofs and speculative layouts. Admissions commit only
    /// a proven final candidate; failed queries never update source patches.
    final class SlantedContext {
        typealias Trial = NativeSlantedTypographyTrial
        enum Raster {
            case rectified(NativeSlantedRestoration.ProofRaster, CGFloat)
            case page(NativeSpatialSourceCrop.Prepared, NativeRestorationPixels)
        }
        let originalLayout: NativeTranslationLayout
        let source: CGImage?
        let settings: IPhoneOverlaySettings
        var entries: [String: Trial.Entry] = [:]
        var results: [String: Trial.Result] = [:]
        var appearances: [String: NativeTranslationRestoration.Appearance] = [:]
        var rasters: [String: Raster] = [:]
        var proposals: [String: NativeSpatialSourceCrop.SlantedPrepared] = [:]
        var preparations: [String: NativeSlantedPreparation] = [:]
        var liftedIDs: Set<String> = []
        var nextSurface = 0
        var liftBudget = 600
        var lockedIDs: Set<String> { Set(results.filter { $0.value.accepted }.map(\.key)) }

        init(layout: NativeTranslationLayout, source: CGImage?, settings: IPhoneOverlaySettings) {
            originalLayout = layout; self.source = source; self.settings = settings
        }
        func style(item: NativeTranslationLayoutItem, appearance: NativeTranslationRestoration.Appearance,
                   candidate: Trial.Candidate) -> NativeTranslationTypography.Style {
            let background = settings.preserveSourceBackgroundColor ? appearance.background : nil
            let panelInk = background.map { NativeTranslationRenderer.panelForeground($0, opacity: CGFloat(settings.renderedBackgroundOpacity)) }
            let light = panelInk.map { ($0.components?.first ?? 1) < 1 } ?? item.lightSurface
            var style = NativeTranslationTypography.Style(
                fontName: settings.preserveSourceColors && item.fontScript == "korean" ? appearance.fontName : nil,
                fontScript: item.fontScript, fontSize: candidate.font, vertical: item.vertical,
                foreground: (settings.preserveSourceTextColor ? appearance.foreground : nil) ?? panelInk ??
                    NativeTranslationRenderer.color(light ? [17, 18, 23] : [255, 255, 255]),
                tracking: -candidate.font * 0.012, lineHeight: candidate.pitch, alignsToTop: item.balancedColumn,
                horizontalScale: candidate.condense)
            style.optimizesKoreanWrapping = false
            // The frozen slanted card changes CSS size, never reinserts Korean lines during a trial.
            style.balancesHorizontalLines = false
            return style
        }
        func shape(item: NativeTranslationLayoutItem, appearance: NativeTranslationRestoration.Appearance,
                   candidate: Trial.Candidate, guardPixels: CGFloat) -> (Trial.Measurement, NativeTranslationTypography.Layout, NativeTranslationTypography.Style)? {
            guard !Task.isCancelled, candidate.padding.count == 4,
                  candidate.rect.size.width > 0, candidate.rect.size.height > 0 else { return nil }
            let contentWidth = candidate.rect.width - candidate.padding[1] - candidate.padding[3]
            let contentHeight = candidate.rect.height - candidate.padding[0] - candidate.padding[2]
            guard contentWidth > 0, contentHeight > 0 else { return nil }
            let style = style(item: item, appearance: appearance, candidate: candidate)
            // Typography accepts physical width and expands it once for condensed shaping.
            let measured = NativeTranslationTypography.layout(text: item.typesettingText ?? item.text,
                in: CGSize(width: contentWidth * candidate.condense, height: contentHeight), style: style)
            let padX = candidate.padding[3] * candidate.condense, padY = candidate.padding[0]
            let glyphs = NativeTranslationTypography.slantedGlyphRects(layout: measured, style: style, guardPixels: guardPixels).map { r in
                [Double(r.minX) + padX, Double(r.minY) + padY, Double(r.maxX) + padX, Double(r.maxY) + padY]
            }
            let ranges = measured.rangeBounds.map { $0.offsetBy(dx: padX, dy: padY) }
            let lines = NativeTranslationTypography.captionLineMetrics(layout: measured).map { metric in
                CGRect(x: metric.rect.minX / candidate.condense + candidate.padding[3], y: metric.rect.minY + padY,
                       width: metric.rect.width / candidate.condense, height: metric.rect.height)
            }
            let rows = max(0, measured.lineCount)
            let broken = NativeTranslationTypography.slantedWordBroken(layout: measured, originalText: item.typesettingText ?? item.text)
            let measurement = Trial.Measurement(glyphs: glyphs, lines: lines, lineCount: rows, contentFits: measured.fits,
                                               wordBroken: broken, rangeRects: ranges)
            return (measurement, measured, style)
        }
        func sourceRect(_ item: NativeTranslationLayoutItem) -> CGRect? {
            guard item.sourceBounds.count == 4, item.sourceBounds.allSatisfy(\.isFinite) else { return nil }
            let frame = originalLayout.sourceRect, b = item.sourceBounds
            return CGRect(x: frame.minX + b[0] * frame.width, y: frame.minY + b[1] * frame.height,
                          width: b[2] * frame.width, height: b[3] * frame.height)
        }
        func entry(item: NativeTranslationLayoutItem, appearance: NativeTranslationRestoration.Appearance) -> Trial.Entry {
            let c = Trial.Candidate(rect: item.rect, font: item.fontSize, pitch: item.lineHeight,
                padding: [item.paddingTop, item.paddingRight, item.paddingBottom, item.paddingLeft].map(Double.init), angle: item.rotation)
            let style = style(item: item, appearance: appearance, candidate: c)
            let sampled = appearance.sourceSample
            let initialInk = NativeTranslationRenderer.rgb(style.foreground) ?? [17, 18, 23]
            let foreground = NativeTranslationSourceStylePostPolish.captionPalette(sample: sampled ?? [:], ink: initialInk,
                preserveText: settings.preserveSourceTextColor, displayInk: NativeObservedSourcePalette.sourceDisplayInk(sample: sampled)).foreground
            let peers = originalLayout.items.filter { $0.id != item.id && !$0.keptLettering }.map { other -> Trial.Peer in
                let card = NativeSlantedGeometry.rotatedCard(cx: other.rect.midX, cy: other.rect.midY,
                    width: other.width, height: other.height, angle: other.rotation)
                return Trial.Peer(text: other.text, plannedFont: other.fontSize, source: sourceRect(other),
                                  sourceFont: other.sourceFontSize.map(Double.init), card: card)
            }
            let obstacles = peers.flatMap { p -> [Trial.Polygon] in
                var q = [p.card]
                if let r = p.source { q.append(NativeSlantedGeometry.rotatedCard(cx: r.midX, cy: r.midY, width: r.width, height: r.height, angle: 0)) }
                return q
            }
            let upright = item.uprightQuadText && !item.vertical && source.map {
                (try? NativeSlantedQuadOutsideBox.read(item: item, image: $0, sample: sampled)).map { Double($0.ink) <= max(2, Double($0.area) * 0.005) } == true
            } == true
            return Trial.Entry(quad: item.rect, initial: c, plannedFont: item.rotationPlannedFontSize.map(Double.init),
                minimumFont: BrowserOverlayLayoutPlanner.minimumRenderedFontSize, text: item.text, sourceText: item.text,
                sourceFont: item.sourceFontSize.map(Double.init), sourceBounds: sourceRect(item), sourceVertical: item.sourceVertical,
                vertical: item.vertical, wrappingKorean: item.wrappingScript == "korean", sourceForeground: foreground,
                observedForeground: NativeSourceColorSampler.rgb(sampled?["foreground"] ?? sampled?["displayForeground"]),
                frame: originalLayout.sourceRect, uprightQuad: upright, peers: peers, bodyObstacles: obstacles)
        }
        func surface(id: String, raster: Raster, method: String = "") -> Trial.Surface {
            switch raster {
            case .rectified(let proof, _):
                return .init(id: id, method: method, width: proof.width, height: proof.height, safe: proof.safe, luminance: proof.luminance)
            case .page(let descriptor, let pixels):
                let bytes = NativeSlantedPixels.compositeLuminance(pixels.rgba, local: descriptor.pixels.rgba, n: pixels.width * pixels.height)
                return .init(id: id, method: pixels.method ?? method, isPage: true, width: pixels.width, height: pixels.height,
                             safe: pixels.layoutSafe ?? [], luminance: bytes)
            }
        }
        func fits(item: NativeTranslationLayoutItem, entry: Trial.Entry, surface: Trial.Surface, candidate: Trial.Candidate,
                  glyphs: [[Double]], color: [Double], audit: inout NativeSlantedInkSafety.Audit) -> Bool {
            guard let raster = rasters[surface.id] else { return false }
            switch raster {
            case .rectified(var proof, let scale):
                if surface.expandedPaper { proof.safe = surface.safe }
                let local: [[Double]]
                if candidate.angle == 0 && item.rotation != 0 {
                    let physicalLeft = Double(candidate.rect.midX) - Double(candidate.rect.width) * candidate.condense / 2
                    let page = glyphs.map { [$0[0] + physicalLeft, $0[1] + Double(candidate.rect.minY),
                                              $0[2] + physicalLeft, $0[3] + Double(candidate.rect.minY)] }
                    local = NativeSlantedGeometry.localRects(page, box: NativeSlantedGeometry.array(entry.quad), angle: item.rotation)
                } else {
                    let physicalLeft = Double(candidate.rect.midX) - Double(candidate.rect.width) * candidate.condense / 2
                    local = glyphs.map { [$0[0] + physicalLeft - Double(entry.quad.minX), $0[1] + Double(candidate.rect.minY - entry.quad.minY),
                                           $0[2] + physicalLeft - Double(entry.quad.minX), $0[3] + Double(candidate.rect.minY - entry.quad.minY)] }
                }
                return NativeSlantedInkSafety.inkFits(proof: proof, rects: local, scale: Double(scale), foreground: color, audit: &audit)
            case .page(let descriptor, let pixels):
                guard let source else { return false }
                return NativeSlantedInkSafety.rotatedPageInkFits(width: surface.width, height: surface.height,
                    safe: pixels.layoutSafe, luminance: surface.luminance, sx: descriptor.sx, sy: descriptor.sy,
                    ox: descriptor.crop.minX, oy: descriptor.crop.minY, rects: glyphs,
                    node: [Double(candidate.rect.midX) - Double(candidate.rect.width) * candidate.condense / 2, Double(candidate.rect.minY), Double(candidate.rect.width) * candidate.condense, Double(candidate.rect.height)],
                    angle: candidate.angle, toImage: { x, y in
                        [(x - Double(originalLayout.sourceRect.minX)) / Double(originalLayout.sourceRect.width) * Double(source.width),
                         (y - Double(originalLayout.sourceRect.minY)) / Double(originalLayout.sourceRect.height) * Double(source.height)]
                    }, foreground: color, audit: &audit)
            }
        }
        func hooks(item: NativeTranslationLayoutItem, appearance: NativeTranslationRestoration.Appearance, entry: Trial.Entry,
                   sourceSurface: Trial.Surface) -> Trial.Hooks {
            Trial.Hooks(measure: { candidate in
                self.shape(item: item, appearance: appearance, candidate: candidate,
                    guardPixels: sourceSurface.method == "rectified-narrow-paper-glyphs" ? 0.25 : 1)?.0
            }, longestWord: { font in
                var c = entry.initial; c.font = font
                return Double(NativeTranslationTypography.widestWord(text: item.text, style: self.style(item: item, appearance: appearance, candidate: c)))
            }, fits: { surface, candidate, glyphs, color, audit in
                self.fits(item: item, entry: entry, surface: surface, candidate: candidate, glyphs: glyphs, color: color, audit: &audit)
            }, prepareWide: { rect in
                guard let preparation = self.preparations[item.id], let proposed = preparation.prepareUpright(rect),
                      self.ownsWide(proposed, item: item) else { return nil }
                self.nextSurface += 1; let id = "\(item.id)-wide-\(self.nextSurface)"
                self.rasters[id] = .rectified(proposed.result.proof, proposed.scale); self.proposals[id] = proposed
                return self.surface(id: id, raster: self.rasters[id]!, method: proposed.result.pixels.method ?? "")
            }, leftover: { surface in
                let palette = appearance.sourceSample.flatMap(NativeRestorationPixels.palette)
                switch self.rasters[surface.id] {
                case .rectified(let proof, _):
                    return NativeSlantedInkSafety.plateLeftoverInk(luminance: proof.luminance, n: proof.width * proof.height, inside: { i in
                        let x = Double(i % proof.width) + 0.5, y = Double(i / proof.width) + 0.5, b = proof.box
                        return x >= b[0] + 1 && x <= b[0] + b[2] - 1 && y >= b[1] + 1 && y <= b[1] + b[3] - 1
                    }, palette: palette)
                case .page(let descriptor, let pixels):
                    guard let source = self.source else { return nil }
                    let f = self.originalLayout.sourceRect, kx = Double(source.width) / Double(f.width), ky = Double(source.height) / Double(f.height)
                    let cx = Double(entry.quad.midX - f.minX) * kx, cy = Double(entry.quad.midY - f.minY) * ky
                    let qw = Double(entry.quad.width) * kx, qh = Double(entry.quad.height) * ky, cs = cos(Double(item.rotation)), sn = sin(Double(item.rotation))
                    return NativeSlantedInkSafety.plateLeftoverInk(luminance: surface.luminance, n: pixels.width * pixels.height, inside: { i in
                        let dx = (Double(i % pixels.width) + 0.5) / Double(descriptor.sx) + Double(descriptor.crop.minX) - cx
                        let dy = (Double(i / pixels.width) + 0.5) / Double(descriptor.sy) + Double(descriptor.crop.minY) - cy
                        return max(abs(dx * cs + dy * sn) - qw / 2, abs(-dx * sn + dy * cs) - qh / 2) <= -1
                    }, palette: palette)
                case nil: return nil
                }
            })
        }
        func ownsWide(_ proposal: NativeSpatialSourceCrop.SlantedPrepared, item: NativeTranslationLayoutItem) -> Bool {
            guard let source, item.sourceFrame.count == 4, item.sourceFrame[2] > 0, item.sourceFrame[3] > 0 else { return false }
            let f = item.sourceFrame, iw = Double(source.width), ih = Double(source.height)
            let quad = [(Double(item.x) - Double(f[0])) * iw / Double(f[2]), (Double(item.y) - Double(f[1])) * ih / Double(f[3]),
                        Double(item.width) * iw / Double(f[2]), Double(item.height) * ih / Double(f[3])]
            let auxiliary = item.auxiliaryInkRects.filter { $0.count == 4 && $0.allSatisfy(\.isFinite) }.map {
                [Double($0[0]) * iw, Double($0[1]) * ih, Double($0[2]) * iw, Double($0[3]) * ih]
            }
            let p = proposal.prepared, pixels = proposal.result.pixels
            let spill = NativeSlantedProof.erasureOffQuad(rgba: pixels.rgba, width: pixels.width, height: pixels.height,
                ox: p.crop.minX, oy: p.crop.minY, scale: p.sx, quad: quad, angle: item.rotation, auxiliary: auxiliary)
            return spill.erased > 0 && Double(spill.off) <= max(2, Double(spill.erased) * 0.01)
        }
        func admit(item: NativeTranslationLayoutItem, appearance: NativeTranslationRestoration.Appearance,
                   proof: NativeSlantedRestoration.ProofRaster, scale: CGFloat) -> Bool {
            let id = "\(item.id)-original"; rasters[id] = .rectified(proof, scale)
            appearances[item.id] = appearance; preparations[item.id] = proof.preparation
            return evaluate(item: item, appearance: appearance, sourceSurface: surface(id: id, raster: rasters[id]!, method: proof.method ?? ""))
        }
        func admitPage(item: NativeTranslationLayoutItem, appearance: NativeTranslationRestoration.Appearance,
                       prepared: NativeSpatialSourceCrop.Prepared, pixels: NativeRestorationPixels) -> Bool {
            let id = "\(item.id)-page"; rasters[id] = .page(prepared, pixels); appearances[item.id] = appearance
            return evaluate(item: item, appearance: appearance, sourceSurface: surface(id: id, raster: rasters[id]!))
        }
        func evaluate(item: NativeTranslationLayoutItem, appearance: NativeTranslationRestoration.Appearance, sourceSurface: Trial.Surface) -> Bool {
            var e = entry(item: item, appearance: appearance)
            e.wideObstacles = originalLayout.items.filter { $0.id != item.id }.flatMap { other -> [Trial.Polygon] in
                if let accepted = results[other.id], let m = accepted.measurement {
                    return Trial.polygons(m, accepted.candidate, margin: 6)
                }
                var q = [NativeSlantedGeometry.rotatedCard(cx: other.rect.midX, cy: other.rect.midY,
                    width: other.width, height: other.height, angle: other.rotation, margin: 6)]
                if results[other.id] == nil, let u = other.uprightAlternative {
                    q.append(NativeSlantedGeometry.rotatedCard(cx: u.rect.midX, cy: u.rect.midY, width: u.width, height: u.height, angle: 0, margin: 6))
                }
                return q
            }
            var h = hooks(item: item, appearance: appearance, entry: e, sourceSurface: sourceSurface)
            if let alternative = item.uprightAlternative, !item.vertical, settings.preserveSourceBackgroundColor,
               let preparation = preparations[item.id], let proposed = preparation.prepareUpright(alternative.rect) {
                nextSurface += 1; let id = "\(item.id)-upright-\(nextSurface)"
                rasters[id] = .rectified(proposed.result.proof, proposed.scale); proposals[id] = proposed
                let u = Trial.Upright(rect: alternative.rect, content: alternative.rect.inset(by: alternative.contentInsets),
                                      font: alternative.fontSize, pitch: alternative.lineHeight)
                let obstacles = originalLayout.items.filter { $0.id != item.id }.map { $0.rect.insetBy(dx: -8, dy: -8) }
                if let accepted = Trial.upright(e, alternative: u, surface: surface(id: id, raster: rasters[id]!, method: proposed.result.pixels.method ?? ""),
                                               obstacles: obstacles, hooks: h) {
                    entries[item.id] = e; results[item.id] = accepted; return true
                }
            }
            e = Trial.preparedEntry(e, measure: h.measure); h = hooks(item: item, appearance: appearance, entry: e, sourceSurface: sourceSurface)
            entries[item.id] = e; results[item.id] = Trial.run(e, surface: sourceSurface, hooks: h)
            return results[item.id]?.accepted == true
        }
        func applying(_ result: Trial.Result, to item: NativeTranslationLayoutItem) -> NativeTranslationLayoutItem {
            var output = item; let c = result.candidate
            output.x = c.rect.minX; output.y = c.rect.minY; output.width = c.rect.width; output.height = c.rect.height
            output.fontSize = c.font; output.lineHeight = c.pitch
            output.paddingTop = c.padding[0]; output.paddingRight = c.padding[1]; output.paddingBottom = c.padding[2]; output.paddingLeft = c.padding[3]
            output.drawsUprightQuadText = c.angle == 0 && item.rotation != 0
            output.typesettingWidthScale = c.condense; output.typesettingForeground = result.foreground
            output.smallTextReference = nil; output.smallTextReferenceResolved = true
            return output
        }
        func applyInitial(to layout: NativeTranslationLayout) -> NativeTranslationLayout {
            NativeTranslationLayout(imageSize: layout.imageSize, sourceRect: layout.sourceRect, viewport: layout.viewport,
                items: layout.items.map { item in results[item.id].flatMap { $0.accepted ? applying($0, to: item) : nil } ?? item })
        }
    }

    static func applySlantedTrials(cards: inout [Card], restoration: inout NativeTranslationRestoration.Result,
                                   layout: NativeTranslationLayout, source: CGImage?, settings: IPhoneOverlaySettings,
                                   context: SlantedContext) {
        func expandedProofPatch(_ patch: NativeTranslationRestoration.Patch, surface: NativeSlantedTypographyTrial.Surface) -> NativeTranslationRestoration.Patch {
            guard surface.expandedPaper, var proof = patch.slantedProof,
                  proof.width == surface.width, proof.height == surface.height else { return patch }
            proof.safe = surface.safe
            return .init(image: patch.image, rect: patch.rect, itemID: patch.itemID, layoutSafe: patch.layoutSafe,
                surfaceLuminance: patch.surfaceLuminance, surfaceQuality: patch.surfaceQuality,
                finalForcedErasure: patch.finalForcedErasure, slantedProof: proof, slantedScale: patch.slantedScale,
                candidate: patch.candidate, rasterGeometry: patch.rasterGeometry)
        }
        func polygon(_ r: CGRect) -> [[Double]] { [[r.minX,r.minY],[r.maxX,r.minY],[r.maxX,r.maxY],[r.minX,r.maxY]] }
        func obstacles(excluding id: String) -> [[[Double]]] {
            var output: [[[Double]]] = []
            for other in cards where other.item.id != id {
                if let trial = context.results[other.item.id], trial.accepted, let m = trial.measurement {
                    output += NativeSlantedTypographyTrial.polygons(m, trial.candidate); continue
                }
                output += NativeTranslationRenderer.cardPageLineRects(other).map(polygon)
                if other.rotatesSourcePanels {
                    output.append(NativeSlantedGeometry.rotatedCard(cx: other.item.rect.midX, cy: other.item.rect.midY,
                        width: other.item.width * other.style.horizontalScale, height: other.item.height, angle: other.item.rotation))
                } else if other.drawsPanel { output.append(polygon(other.item.rect)) }
                output += other.sourcePanels.map { panel in
                    polygon(other.rotatesSourcePanels ? NativeTranslationRenderer.rotatedBounds(panel.rect, about: other.item.rect, angle: other.item.rotation) : panel.rect)
                }
                output += other.backings.map { polygon($0.frame) }
            }
            for kept in context.originalLayout.items where kept.keptLettering {
                output.append(NativeSlantedGeometry.rotatedCard(cx: kept.rect.midX, cy: kept.rect.midY,
                    width: kept.width, height: kept.height, angle: kept.rotation))
            }
            return output
        }
        for index in cards.indices {
            let id = cards[index].item.id
            guard let originalItem = context.originalLayout.items.first(where: { $0.id == id }),
                  var result = context.results[id], result.accepted,
                  let entry = context.entries[id], let appearance = context.appearances[id], let surface = result.surface else { continue }
            let hooks = context.hooks(item: originalItem, appearance: appearance, entry: entry, sourceSurface: surface)
            if result.pendingReadableLift {
                result = NativeSlantedTypographyTrial.lift(entry, result: result, obstacles: obstacles(excluding: id), budget: &context.liftBudget, hooks: hooks)
                if result.metadata["readableLift"] != nil { context.liftedIDs.insert(id) }
            }
            guard let shaped = context.shape(item: originalItem, appearance: appearance, candidate: result.candidate,
                guardPixels: surface.method == "rectified-narrow-paper-glyphs" ? 0.25 : 1) else { continue }
            context.results[id] = result
            cards[index].slantedTrial = result
            cards[index].sourceBackgroundKind = result.metadata["sourceBackgroundColor"]
            let item = context.applying(result, to: originalItem), c = result.candidate
            cards[index].item = item; cards[index].typography = shaped.1; cards[index].style = shaped.2
            cards[index].style.foreground = NativeTranslationRenderer.color(result.foreground.map { CGFloat($0) })
            cards[index].finalFontSize = CGFloat(c.font)
            let physicalLeft = c.rect.midX - c.rect.width * c.condense / 2
            cards[index].textShift = CGPoint(x: physicalLeft + c.padding[3] * c.condense - item.contentRect.minX, y: 0)
            cards[index].typographyWidth = item.contentRect.width * c.condense
            cards[index].lineOffsets = []
            cards[index].drawsPanel = false; cards[index].sourcePanels = []; cards[index].backings = []
            cards[index].rotatesSourcePanels = false; cards[index].finalUprightText = c.angle == 0
            if let selected = result.surface, let proposal = context.proposals[selected.id],
               var patch = context.preparations[id]?.patch(proposal) {
                patch = expandedProofPatch(patch, surface: selected)
                restoration.patches.removeAll { $0.itemID == id }; restoration.patches.append(patch)
            } else if let selected = result.surface, selected.expandedPaper,
                      let pi = restoration.patches.firstIndex(where: { $0.itemID == id }) {
                restoration.patches[pi] = expandedProofPatch(restoration.patches[pi], surface: selected)
            }
            if let old = restoration.appearances[id] {
                restoration.appearances[id] = .init(foreground: cards[index].style.foreground, background: old.background, restored: true,
                    stroke: old.stroke, strokeWidth: old.strokeWidth, erasureComplete: true, letteringStyle: old.letteringStyle,
                    fontName: old.fontName, sourceStrokeWeight: old.sourceStrokeWeight, sourceSample: old.sourceSample,
                    restorationMethod: "slanted-glyph-restored", sourceGlyphsVerified: true, finalForcedErasure: old.finalForcedErasure, provisional: false)
            }
        }
        // Source restoration and opaque fallback share the terminal image clip,
        // but only the fallback needs the original grown quad's Range fitting.
        for index in cards.indices where cards[index].item.rotation != 0 {
            let id = cards[index].item.id
            guard let original = context.originalLayout.items.first(where: { $0.id == id }) else { continue }
            let appearance = restoration.appearances[id] ?? .init(foreground: nil, background: nil, restored: false)
            var entry = context.entries[id] ?? context.entry(item: original, appearance: appearance)
            var result = context.results[id] ?? NativeSlantedTypographyTrial.Result(candidate: entry.initial,
                foreground: NativeTranslationRenderer.rgb(cards[index].style.foreground) ?? entry.sourceForeground)
            if !result.accepted {
                let current = cards[index].item
                result.candidate = .init(rect: current.rect, font: Double(cards[index].style.fontSize),
                    pitch: Double(cards[index].style.lineHeight),
                    padding: [current.paddingTop,current.paddingRight,current.paddingBottom,current.paddingLeft].map(Double.init),
                    condense: Double(cards[index].style.horizontalScale), angle: Double(cards[index].effectiveTextRotation))
            } else { entry.quad.size.height = result.candidate.rect.height }
            let clipped = NativeSlantedTypographyTrial.finalClip(entry, result: result, measure: { c in
                context.shape(item: original, appearance: appearance, candidate: c, guardPixels: 1)?.0
            })
            cards[index].slantedClip = clipped.polygon
            if clipped.result.candidate.font != result.candidate.font,
               let shaped = context.shape(item: original, appearance: appearance, candidate: clipped.result.candidate, guardPixels: 1) {
                cards[index].item = context.applying(clipped.result, to: original)
                cards[index].typography = shaped.1; cards[index].style = shaped.2
                cards[index].finalFontSize = CGFloat(clipped.result.candidate.font)
            }
            if result.accepted { cards[index].slantedTrial = clipped.result; context.results[id] = clipped.result }
        }
    }

    /// Called after the text rotation, before glyph painting, in the card's axes.
    static func drawSlantedClip(_ card: Card, context: CGContext) {
        guard let polygon = card.slantedClip, polygon.count >= 3 else { return }
        let item = card.item, scale = card.style.horizontalScale
        let path = CGMutablePath()
        for (index, p) in polygon.enumerated() where p.count == 2 {
            let point = CGPoint(x: item.rect.midX + (CGFloat(p[0]) - item.rect.width / 2) * scale,
                                y: item.rect.minY + CGFloat(p[1]))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath(); context.addPath(path); context.clip()
    }
}
