import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Repair row contact without changing font, colors, panels or row ownership.
// Bitmap and PDF-snapped alpha are runtime guards; actual serialized-PDF
// equivalence is validated offline, not claimed as a universal certificate.
extension NativeTranslationRenderer {
    // Conservative output-raster test: each complete shaped row must form one
    // alpha band, separated from its neighbor by a fully transparent pixel row.
    // Ambiguous split glyph bands abstain rather than pretending to be clearance.
    static func rasterRowClearance(_ card: Card, bounds: CGRect, pixels: CGSize,
        availableWork: Int, pixelSnapScale: CGFloat? = nil) -> (gap: Int, charged: Int)? {
        let ink = cardInkRect(card)
        guard valid(ink), card.typography.lineCount > 1 else { return nil }
        let sx = pixels.width / bounds.width, sy = pixels.height / bounds.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { return nil }
        let width = Int(ceil(ink.width * sx)) + 8, height = Int(ceil(ink.height * sy)) + 8
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width <= availableWork / height else { return nil }
        let startX = floor((ink.minX - bounds.minX) * sx) - 4
        let startY = floor((ink.minY - bounds.minY) * sy) - 4
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = false
        let bitmap = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
            format: format).image { renderer in
            renderer.cgContext.scaleBy(x: sx, y: sy)
            renderer.cgContext.translateBy(x: -bounds.minX - startX / sx,
                y: -bounds.minY - startY / sy)
            draw(card, context: renderer.cgContext, opacity: 1,
                paintsBackground: false, paintsText: true, paintsSourcePanels: false,
                pixelSnapScale: pixelSnapScale)
        }
        guard let image = bitmap.cgImage else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        let rendered = alpha.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        var bands: [ClosedRange<Int>] = []
        for y in 0..<height {
            let occupied = alpha[(y * width)..<((y + 1) * width)].contains { $0 > 0 }
            if occupied {
                if let last = bands.last, last.upperBound == y - 1 {
                    bands[bands.count - 1] = last.lowerBound...y
                } else { bands.append(y...y) }
            }
        }
        guard bands.count == card.typography.lineCount else { return (0, width * height) }
        let gap = zip(bands, bands.dropFirst()).map { $1.lowerBound - $0.upperBound - 1 }.min() ?? 0
        return (gap, width * height)
    }

    static func repairIntraRowClearance(cards: inout [Card], bounds: CGRect,
        pixels: CGSize, sourceRect: CGRect, pixelScale: CGSize,
        pdfDeviceScale: CGFloat) throws -> [[String: Any]] {
        guard bounds.width > 0, bounds.height > 0, pixels.width > 0, pixels.height > 0 else { return [] }
        let outputPixel = max(bounds.width / pixels.width, bounds.height / pixels.height)
        guard outputPixel.isFinite, outputPixel > 0 else { return [] }
        var receipts: [[String: Any]] = []
        // Per-page limits include all cards, not eight independent attempts per card.
        let pageAttemptLimit = 24
        let pageRawAlphaPixelLimit = 8_000_000
        var pageAttempts = 0
        var pageRawAlphaPixels = 0
        var pagePeerChecks = 0
        for index in cards.indices {
            try Task.checkCancellation()
            let base = cards[index]
            let paint = base.item.typesettingText ?? base.item.text
            guard base.drawsPanel, base.effectiveTextRotation == 0, !base.item.vertical,
                base.unitTextParts.isEmpty, base.heavyStrokeWidth == 0,
                let oldGap = NativeTranslationTypography.minimumPaintedRowGap(layout: base.typography),
                oldGap.isFinite, oldGap < outputPixel else { continue }
            var receipt: [String: Any] = ["id": base.item.id,
                "baselinePaintedGap": Double(oldGap), "requiredGap": Double(outputPixel),
                "candidateBudget": 8, "fontUnchanged": true, "panelUnchanged": true]
            guard let oldRows = NativeTranslationTypography.horizontalRowMetrics(
                    layout: base.typography, originalText: base.item.text),
                oldRows.count == base.typography.lineCount, oldRows.count > 1,
                oldRows.allSatisfy({ $0["sourceUTF16Range"] is [Int] && $0["shapedUTF16Range"] is [Int]
                    && $0["tokenCutAfterRowProxy"] is Bool }),
                NativeTranslationTypography.committedParagraphRawComplete(base.typography, original: paint),
                NativeTranslationTypography.sourceOwnershipCoverage(base.typography,
                    originalText: base.item.text)?.whole == true else {
                receipt["reason"] = "baseline-row-ledger-or-ownership-unmeasured"
                receipts.append(receipt); continue
            }
            let oldInk = cardInkRect(base)
            let allowed = base.textPaintDomain?.rect ?? base.sourcePlateRect
            guard valid(oldInk), valid(allowed), allowed.contains(oldInk) else {
                receipt["reason"] = "baseline-ink-not-within-existing-own-opaque-or-certified-domain"
                receipts.append(receipt); continue
            }
            let deficit = outputPixel - oldGap
            var rejections: [String: Int] = [:]
            var evaluated = 0
            var alphaAudits = 0
            var admitted: (card: Card, gap: CGFloat, pixelGap: Int, snappedGap: Int, delta: CGFloat)?
            for step in 0..<8 {
                guard pageAttempts < pageAttemptLimit,
                      pageRawAlphaPixels < pageRawAlphaPixelLimit else {
                    rejections["page-work-budget-exhausted", default: 0] += 1
                    break
                }
                pageAttempts += 1
                evaluated += 1
                let delta = deficit * (1 + CGFloat(step) * 0.25)
                guard delta.isFinite, delta > 0,
                    delta <= max(8 * outputPixel, 3 * deficit) else {
                    rejections["bounded-leading-budget", default: 0] += 1; continue
                }
                var trial = base
                trial.style.lineHeight = base.style.lineHeight + delta
                trial.item.lineHeight = trial.style.lineHeight
                trial.typography = NativeTranslationTypography.layout(text: paint,
                    in: base.textLayoutSize, style: trial.style)
                guard trial.typography.lineRanges == base.typography.lineRanges,
                    trial.typography.visibleUTF16Range == base.typography.visibleUTF16Range,
                    trial.typography.shapedText == base.typography.shapedText,
                    (!base.typography.fits || trial.typography.fits),
                    NativeTranslationTypography.committedParagraphRawComplete(trial.typography, original: paint),
                    NativeTranslationTypography.sourceOwnershipCoverage(trial.typography,
                        originalText: base.item.text)?.whole == true,
                    let rows = NativeTranslationTypography.horizontalRowMetrics(
                        layout: trial.typography, originalText: base.item.text), rows.count == oldRows.count,
                    zip(oldRows, rows).allSatisfy({ before, after in
                        String(describing: before["sourceUTF16Range"] ?? NSNull()) ==
                            String(describing: after["sourceUTF16Range"] ?? NSNull()) &&
                        String(describing: before["shapedUTF16Range"] ?? NSNull()) ==
                            String(describing: after["shapedUTF16Range"] ?? NSNull()) &&
                        (before["tokenCutAfterRowProxy"] as? Bool) == (after["tokenCutAfterRowProxy"] as? Bool)
                    }) else {
                    rejections["row-identity-or-completeness-changed", default: 0] += 1; continue
                }
                let unshifted = cardInkRect(trial)
                guard valid(unshifted) else { rejections["ink-unmeasured", default: 0] += 1; continue }
                trial.textShift.y += oldInk.minY - unshifted.minY
                let ink = cardInkRect(trial)
                guard valid(ink), abs(ink.minY - oldInk.minY) <= outputPixel / 2,
                    allowed.contains(ink) else {
                    rejections["first-ink-top-or-existing-domain", default: 0] += 1; continue
                }
                guard let gap = NativeTranslationTypography.minimumPaintedRowGap(layout: trial.typography),
                    gap.isFinite, gap + 0.001 >= outputPixel else {
                    rejections["painted-row-clearance", default: 0] += 1; continue
                }
                guard let raster = rasterRowClearance(trial, bounds: bounds, pixels: pixels,
                    availableWork: pageRawAlphaPixelLimit - pageRawAlphaPixels) else {
                    rejections["pixel-row-unmeasured-or-page-budget", default: 0] += 1; continue
                }
                pageRawAlphaPixels += raster.charged
                guard raster.gap >= 1 else {
                    rejections["pixel-row-clearance", default: 0] += 1; continue
                }
                guard let snapped = rasterRowClearance(trial, bounds: bounds, pixels: pixels,
                    availableWork: pageRawAlphaPixelLimit - pageRawAlphaPixels,
                    pixelSnapScale: pdfDeviceScale) else {
                    rejections["pdf-snapped-pixel-row-unmeasured-or-page-budget", default: 0] += 1; continue
                }
                pageRawAlphaPixels += snapped.charged
                guard snapped.gap >= 1 else {
                    rejections["pdf-snapped-pixel-row-clearance", default: 0] += 1; continue
                }
                let allocation = min(2_000_000, pageRawAlphaPixelLimit - pageRawAlphaPixels)
                var auditBudget = allocation
                alphaAudits += 1
                let audit = finalTextClipAudit(trial, pixelScale: pixelScale,
                    pdfDeviceScale: pdfDeviceScale, remainingPixels: &auditBudget,
                    forceMeasurement: true, auditEveryFinalCard: true)
                pageRawAlphaPixels += allocation - auditBudget
                let modes = audit?["modes"] as? [[String: Any]]
                guard audit?["status"] as? String == "measured-within-allocation", modes?.count == 2,
                    modes?.allSatisfy({ ($0["rawOccupiedPixels"] as? Int ?? 0) > 0 &&
                        ($0["clipLossPixels"] as? Int) == 0 }) == true else {
                    rejections["raw-alpha-clip-or-unmeasured", default: 0] += 1; continue
                }
                var proposed = cards
                proposed[index] = trial
                pagePeerChecks += 1
                let rejected = try rejectNewReadabilityPeerInk(cards: &proposed, baseline: cards,
                    changed: [base.item.id], bounds: bounds, pixels: pixels,
                    sourceRect: sourceRect, pdfDeviceScale: pdfDeviceScale)
                guard rejected.isEmpty else {
                    rejections["peer-alpha-or-collision", default: 0] += 1; continue
                }
                admitted = (proposed[index], gap, raster.gap, snapped.gap, delta)
                break
            }
            receipt["rejectionCounts"] = rejections
            receipt["candidateEvaluations"] = evaluated
            receipt["alphaAuditCalls"] = alphaAudits
            receipt["pageAttemptsUsed"] = pageAttempts
            receipt["pageRawAlphaPixelsCharged"] = pageRawAlphaPixels
            receipt["pagePeerChecks"] = pagePeerChecks
            if let admitted {
                cards[index] = admitted.card
                receipt["accepted"] = true
                receipt["leadingDelta"] = Double(admitted.delta)
                receipt["finalPaintedGap"] = Double(admitted.gap)
                receipt["finalPixelRowGap"] = admitted.pixelGap
                receipt["finalPDFSnappedPixelRowGap"] = admitted.snappedGap
                receipt["firstInkTop"] = Double(oldInk.minY)
                receipt["originalLineHeight"] = Double(base.style.lineHeight)
                receipt["finalLineHeight"] = Double(admitted.card.style.lineHeight)
            } else {
                receipt["accepted"] = false
                receipt["reason"] = "bounded-leading-frontier-no-certified-candidate"
            }
            receipts.append(receipt)
        }
        receipts.append(["scope": "page-budget", "attemptLimit": pageAttemptLimit,
            "rawAlphaPixelLimit": pageRawAlphaPixelLimit, "attemptsUsed": pageAttempts,
            "rawAlphaPixelsCharged": pageRawAlphaPixels, "peerChecks": pagePeerChecks])
        return receipts
    }
}
