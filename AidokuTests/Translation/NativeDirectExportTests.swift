import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct NativeDirectExportTests {
    @Test(arguments: [0, 1, 2, 3, 4, 5, 65_535, 65_536, 65_537, 65_540, 131_072])
    func artifactAlphaChannelKeepsOriginalStrideAndTail(count: Int) throws {
        let rgba = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ ($0 >> 2)) }
        let expected = stride(from: 3, to: count, by: 4).map { rgba[$0] }
        let actual = try NativeWidthFinalArtifactAdmission.alphaBytes(rgba)
        #expect(actual == expected)
        #expect(actual.count == count / 4)
    }

    @Test func artifactAlphaChannelNonemptyHonorsCancellation() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try NativeWidthFinalArtifactAdmission.alphaBytes([UInt8](repeating: 17, count: 65_536))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await task.value)
    }

    @Test(arguments: [false, true])
    func artifactAlphaChannelActualAdmissionRetainsOrderedConsumer(pdf: Bool) throws {
        let payload: [String: Any] = [
            "id": "alpha-neutral", "text": "가나다라", "x": 14, "y": 24, "width": 90, "height": 42,
            "sourceBounds": [14.0 / 120, 24.0 / 160, 90.0 / 120, 42.0 / 160], "sourceFrame": [0, 0, 120, 160],
            "fontSize": 12, "lineHeight": 15,
            "paddingTop": 8, "paddingBottom": 8, "paddingLeft": 8, "paddingRight": 8,
            "sourceTextOnly": false, "allowsAutomaticFontRecovery": false,
            "sourceColorEligible": false, "fontScript": "korean", "wrappingScript": "korean"
        ]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: payload))
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: bounds, viewport: size, items: [item])
        let source = bitmap { c in UIColor(red: 0.32, green: 0.47, blue: 0.63, alpha: 1).setFill(); c.fill(bounds) }
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: source,
            settings: observerSettings, composeSource: true, capturePDF: pdf, pdfDeviceScale: 1)
        let ordinary = try NativeTranslationRenderer.finishPreparedSynchronously(plan)
        let card = try #require(plan.cards.first)
        #expect(NativeWidthFinalArtifactAdmission.support(card) == nil)
        #expect(card.typography.fits && !card.item.sourceTextOnly)
        #expect(NativeTranslationTypography.sourceOwnershipCoverage(card.typography,
            originalText: card.item.typesettingText ?? card.item.text)?.whole == true)
        let session = NativeWidthFinalArtifactAdmission(plan: plan, keptOwners: [CGRect(x: 0, y: 0, width: 5, height: 160)])
        #expect(session.admission(before: plan.cards, after: plan.cards, ids: [item.id]) == true)
        let receipt = try #require(session.accepted)
        #expect(session.backingCaptureReuseCount == (pdf ? 3 : 0))
        #expect(session.documentReceipts.count == (pdf ? 27 : 10))
        #expect(NativeWidthFinalArtifactAdmission.backingProgramsIdentical(plan.cards, plan.cards))
        var textOnly = plan.cards
        textOnly[0].textShift.x += 0.125
        #expect(NativeWidthFinalArtifactAdmission.backingProgramsIdentical(plan.cards, textOnly))
        var changedFillFrame = textOnly
        let fillFrame = card.straightenedPanelRect ?? card.sourcePlateRect
        changedFillFrame[0].straightenedPanelRect = fillFrame.offsetBy(dx: 0.125, dy: 0)
        #expect(!NativeWidthFinalArtifactAdmission.backingProgramsIdentical(plan.cards, changedFillFrame))
        var changedColour = textOnly
        changedColour[0].background = CGColor(gray: 0.12345, alpha: 1)
        #expect(!NativeWidthFinalArtifactAdmission.backingProgramsIdentical(plan.cards, changedColour))
        let rgba = try NativeWidthFinalArtifactAdmission.rgba(receipt.image)
        let alpha = try NativeWidthFinalArtifactAdmission.alphaBytes(rgba)
        #expect(alpha == stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] })
        let finalized = try session.finalized(cards: plan.cards, diagnosticData: nil)
        let sealed = try #require(finalized)
        let retained = try #require(sealed.retainedWidthArtifact)
        #expect(retained.image === receipt.image && retained.data == receipt.data)
        let consumed = try NativeTranslationRenderer.finishPreparedSynchronously(sealed)
        let consumedOverlay = try pixels(consumed.overlayImage)
        let ordinaryOverlay = try pixels(ordinary.overlayImage)
        let consumedImage = try pixels(consumed.image)
        let ordinaryImage = try pixels(ordinary.image)
        #expect(consumedOverlay == ordinaryOverlay)
        #expect(consumedImage == ordinaryImage)
        #expect(consumed.exportPDFData == receipt.data)
        #expect(sealed.cards.map(\.item) == plan.cards.map(\.item))
        #expect(sealed.cards[0].background == card.background)
        #expect(sealed.cards[0].style.outline == card.style.outline)
        #expect(sealed.cards[0].sourcePlateRect == card.sourcePlateRect)
    }

    @Test(arguments: [1, 3, 17, 255])
    func artifactOwnedRGBABankKeepsTransparentOddWidthAndP3(width: Int) throws {
        for space in [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpace(name: CGColorSpace.displayP3)!] {
            for transparent in [true, false] {
                let imageContext = try #require(CGContext(data: nil, width: width, height: 37,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                if !transparent {
                    imageContext.setFillColor(CGColor(red: 0.13, green: 0.67, blue: 0.29, alpha: 0.43))
                    imageContext.fill(CGRect(x: 0.375, y: 1.25, width: CGFloat(width) - 0.5, height: 30.125))
                }
                let image = try #require(imageContext.makeImage())
                let old = try #require(CGContext(data: nil, width: width, height: 37,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                old.draw(image, in: CGRect(x: 0, y: 0, width: width, height: 37))
                let oldData = try #require(old.data)
                let expected = Array(UnsafeBufferPointer(start: oldData.assumingMemoryBound(to: UInt8.self), count: width * 37 * 4))
                let actual = try NativeWidthFinalArtifactAdmission.rgba(image)
                let actualAlpha = try NativeWidthFinalArtifactAdmission.alphaBytes(actual)
                let expectedAlpha = try NativeWidthFinalArtifactAdmission.alphaBytes(expected)
                #expect(actual == expected)
                #expect(actualAlpha == expectedAlpha)
                #expect(NativeWidthFinalArtifactAdmission.hash(actual) == NativeWidthFinalArtifactAdmission.hash(Data(expected)))
                var alias = actual
                alias[0] ^= 1
                #expect(actual == expected && alias != actual)
            }
        }
    }

    @Test(arguments: [0, 1, 65_535, 65_536, 65_537, 131_073])
    func artifactByteComparisonChecksEveryChunkAndTail(count: Int) throws {
        let original = [UInt8](repeating: 7, count: count)
        let identical = try NativeWidthFinalArtifactAdmission.equalBytes(original, original)
        #expect(identical)
        #expect(NativeWidthFinalArtifactAdmission.hash(original) == NativeWidthFinalArtifactAdmission.hash(Data(original)))
        let differentLength = try NativeWidthFinalArtifactAdmission.equalBytes(original, original + [7])
        #expect(!differentLength)
        for offset in Set([0, 65_535, 65_536, count - 1]).filter({ $0 >= 0 && $0 < count }) {
            var changed = original
            changed[offset] ^= 1
            let equal = try NativeWidthFinalArtifactAdmission.equalBytes(original, changed)
            #expect(!equal)
        }
    }

    @Test
    func artifactNonemptyByteComparisonHonorsCancellation() async {
        let comparison = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try NativeWidthFinalArtifactAdmission.equalBytes([1], [1])
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        #expect(await comparison.value)
    }

    @Test
    func independentDomainCertificateDoesNotMasqueradeAsMeasuredClip() throws {
        let metadata = NativeTranslationRenderer.independentTextDomainAuditMetadata()
        #expect(metadata.clipAudit["status"] as? String == "allocation-unsupported")
        #expect(metadata.clipAudit["unsupportedReason"] as? String == "independent-text-paint-domain")
        #expect(metadata.clipAudit["ordinaryClipMeasured"] as? Bool == false)
        #expect(metadata.clipAudit["serializedPDFMeasured"] as? Bool == false)
        #expect(metadata.clipAudit["modes"] == nil)
        #expect(metadata.certificate["status"] as? String == "independent-domain-tiled-certificate")
        #expect(metadata.certificate["serializedPDFMeasured"] as? Bool == false)
        #expect(JSONSerialization.isValidJSONObject(metadata.clipAudit))
        #expect(JSONSerialization.isValidJSONObject(metadata.certificate))
    }

    private let size = CGSize(width: 120, height: 160)
    private var bounds: CGRect { CGRect(origin: .zero, size: size) }

    private func bitmap(_ paint: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: paint)
    }

    private func pixels(_ image: UIImage) throws -> Data {
        let image = try #require(image.cgImage)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }

    @Test(arguments: [false, true])
    func directBitmapKeepsFullSettledCoverageAndLogicalScale(stretched: Bool) throws {
        let source = bitmap { context in
            UIColor.white.setFill(); context.fill(bounds)
            UIColor.green.setFill(); context.fill(CGRect(x: 4, y: 80, width: 20, height: 30))
        }
        let overlay = bitmap { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 8, y: 12, width: 28, height: 32))
            UIColor.blue.withAlphaComponent(0.5).setFill(); context.fill(CGRect(x: 60, y: 55, width: 20, height: 20))
        }
        // Native images carry a logical scale even when their CGImage already
        // has the exact output density. Direct composition must preserve it.
        let scaledOverlay = UIImage(cgImage: try #require(overlay.cgImage), scale: 2, orientation: .up)
        let outputSize = stretched ? CGSize(width: 180, height: 80) : size
        let layers = ReaderTranslationImageExporter.ExportLayers(masks: [], surfaces: [], paintBounds: [[60, 55, 20, 20]])
        let direct = try ReaderTranslationImageExporter.composite(image: source, typography: .bitmap(scaledOverlay),
            layers: layers, displayRect: bounds, size: outputSize, nativeBitmap: true)
        let encoded = try ReaderTranslationImageExporter.composite(image: source, typography: #require(overlay.pngData()),
            layers: layers, displayRect: bounds, size: outputSize, nativeBitmap: true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let destination = CGRect(origin: .zero, size: outputSize)
        let expected = UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            source.draw(in: destination)
            overlay.draw(in: destination)
        }
        #expect(try pixels(direct) == pixels(expected), "Source repairs outside text bounds and translucent lettering must survive")
        #expect(try pixels(direct) == pixels(encoded), "Cold pixels and serialized native asset replay must agree")
    }


    @Test(arguments: [CGFloat(1), CGFloat(2), CGFloat(3)])
    func backingExportSupportIgnoresTextEnvelope(deviceScale: CGFloat) throws {
        let panel = CGRect(x: 8, y: 16, width: 16, height: 8)
        let envelope = CGRect(x: 8, y: 16, width: 16, height: 8.5)
        let source = bitmap { context in
            UIColor(white: 0.25, alpha: 1).setFill(); context.fill(bounds)
        }
        func values(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
        for height in [CGFloat(32), CGFloat(32.5)] {
            let display = CGRect(x: 0, y: 0, width: 32, height: height)
            let output = CGSize(width: 128, height: height * 4)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.preferredRange = .standard
            let expected = UIGraphicsImageRenderer(size: output, format: format).image { context in
                source.draw(in: CGRect(origin: .zero, size: output))
                context.cgContext.scaleBy(x: 4, y: 4)
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fill(panel)
            }
            for normalized in [false, true] {
                let document = try NativeTranslationPDFCapture.captureDocument(bounds: display, pixels: output,
                    deviceScale: deviceScale, alignsToLogicalBounds: normalized) { context in
                    context.clip(to: panel)
                    context.setFillColor(UIColor.white.cgColor); context.fill(panel)
                }
                func exported(wide: Bool) throws -> UIImage {
                    let clips = [values(panel)] + (wide ? [values(envelope)] : [])
                    return try ReaderTranslationImageExporter.composite(image: source, typography: document.data,
                        layers: .init(masks: [], surfaces: [], paintBounds: clips), displayRect: display, size: output)
                }
                let wide = try pixels(exported(wide: true)), tight = try pixels(exported(wide: false))
                if normalized || height == 32 {
                    #expect(wide == tight)
                    #expect(tight == (try pixels(expected)))
                } else {
                    #expect(wide != tight)
                }
            }
        }
    }

    @Test func nativeInputsRetainGeometryValidation() throws {
        let source = bitmap { context in UIColor.white.setFill(); context.fill(bounds) }
        let layers = ReaderTranslationImageExporter.ExportLayers(masks: [], surfaces: [], paintBounds: [])
        let invalid = NativeTranslationRenderer.SourcePatch(image: try #require(source.cgImage),
            rect: CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20))
        #expect(throws: ReaderTranslationImageExporter.ExportError.self) {
            try ReaderTranslationImageExporter.composite(image: source, typography: .bitmap(source),
                layers: layers, sourcePatches: [invalid], displayRect: bounds, size: size, nativeBitmap: true)
        }
        #expect(throws: ReaderTranslationImageExporter.ExportError.self) {
            try ReaderTranslationImageExporter.composite(image: source, typography: .bitmap(UIImage()),
                layers: layers, displayRect: bounds, size: size, nativeBitmap: true)
        }
    }

    @Test func cancelledDirectCompositeDoesNotReturnPixels() async throws {
        let source = bitmap { context in UIColor.white.setFill(); context.fill(bounds) }
        let layers = ReaderTranslationImageExporter.ExportLayers(masks: [], surfaces: [], paintBounds: [])
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ReaderTranslationImageExporter.composite(image: source, typography: .bitmap(source),
                layers: layers, displayRect: bounds, size: size, nativeBitmap: true)
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }
}

// The audit observer must not change the ordinary render or its unknown states.
extension NativeDirectExportTests {
    private var observerSettings: IPhoneOverlaySettings {
        .init(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
              textPlacement: .replace, subtitlePosition: .bottom,
              subtitleMaxLines: 3, subtitleContextSentences: 0)
    }

    private func observerLayout() throws -> NativeTranslationLayout {
        let items = try (0..<2).map { index -> NativeTranslationLayoutItem in
            let payload: [String: Any] = ["id": "observer-\(index)",
                "text": index == 0 ? "실제 행 관찰 검증" : "두 번째 문장 검증",
                "x": 10, "y": 12 + index * 65, "width": 100, "height": 54,
                "sourceBounds": [10.0 / 120, Double(12 + index * 65) / 160, 100.0 / 120, 54.0 / 160],
                "sourceFrame": [0, 0, 120, 160],
                "fontSize": 12, "lineHeight": 15,
                "paddingTop": 2, "paddingBottom": 2, "paddingLeft": 2, "paddingRight": 2,
                "allowsAutomaticFontRecovery": false,
                "sourceColorEligible": false, "fontScript": "korean", "wrappingScript": "korean"]
            return try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from: JSONSerialization.data(withJSONObject: payload))
        }
        return .init(imageSize: size, sourceRect: bounds, viewport: size, items: items)
    }

    @Test func auditObserverNilAndNoOpKeepActualPreparedCardsAndPixels() throws {
        let layout = try observerLayout()
        let implicit = try NativeTranslationRenderer.prepareRenderSynchronously(
            layout: layout, image: nil, settings: observerSettings, composeSource: false)
        let explicit = try NativeTranslationRenderer.prepareRenderSynchronously(
            layout: layout, image: nil, settings: observerSettings, composeSource: false,
            auditCardObserver: nil)
        let enabled = try NativeTranslationRenderer.prepareRenderSynchronously(
            layout: layout, image: nil, settings: observerSettings, composeSource: false,
            auditCardObserver: { _, _ in })
        #expect(implicit.cards.count == 2) // Never let an empty fixture certify identity.
        for plan in [explicit, enabled] {
            #expect(plan.cards.count == implicit.cards.count)
            for (old, new) in zip(implicit.cards, plan.cards) {
                #expect(old.item == new.item)
                #expect(old.finalFontSize == new.finalFontSize)
                #expect(old.typography.lineRanges == new.typography.lineRanges)
                #expect(old.typography.rangeBounds == new.typography.rangeBounds)
                #expect(old.style.horizontalAlignment == new.style.horizontalAlignment)
                #expect(old.style.tracking == new.style.tracking)
                #expect(old.textShift == new.textShift && old.authoredTextOrigin == new.authoredTextOrigin)
            }
            let oldResult = try NativeTranslationRenderer.finishPreparedSynchronously(implicit)
            let newResult = try NativeTranslationRenderer.finishPreparedSynchronously(plan)
            // JSONEncoder does not promise dictionary-key byte order. Compare
            // the complete decoded layout, without dropping fields or rows.
            let oldLayout = try JSONSerialization.jsonObject(with: oldResult.layoutData) as AnyObject
            let newLayout = try JSONSerialization.jsonObject(with: newResult.layoutData) as AnyObject
            #expect((oldLayout as? NSDictionary)?.isEqual(newLayout) == true)
            #expect(try pixels(oldResult.overlayImage) == pixels(newResult.overlayImage))
        }
    }

    @Test func auditObserverActualStagesOrderAndPDFForwarding() throws {
        let layout = try observerLayout()
        var events: [String] = []
        var finalItems: [NativeTranslationLayoutItem] = []
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(
            layout: layout, image: nil, settings: observerSettings, composeSource: false,
            recordStage: { events.append($0) }, auditCardObserver: { stage, card in
                events.append("\(stage.rawValue):\(card.item.id)")
                if stage == .finalCard { finalItems.append(card.item) }
            })
        let expected = ["preCohort:observer-0", "preCohort:observer-1",
                        "finalCard:observer-0", "finalCard:observer-1"]
        #expect(events.filter { $0.hasPrefix("preCohort:") || $0.hasPrefix("finalCard:") } == expected)
        #expect(finalItems == plan.cards.map(\.item))
        let finalIndex = try #require(events.firstIndex(of: "finalCard:observer-1"))
        let finalizeIndex = try #require(events.firstIndex(of: "native.solidTextBoxes"))
        #expect(finalIndex < finalizeIndex)
        var forwarded: [String] = []
        let pdf = try NativeTranslationRenderer.renderPDFSynchronously(
            layout: layout, image: nil, settings: observerSettings,
            auditCardObserver: { forwarded.append("\($0.rawValue):\($1.item.id)") })
        #expect(forwarded == expected)
        #expect(pdf.renderedItemCount == 2 && !pdf.exportPDFData.isEmpty)
    }

    @Test func auditObserverUnknownIsFiniteNullAndBudgetReasonDoesNotLeak() throws {
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(
            layout: observerLayout(), image: nil, settings: observerSettings, composeSource: false)
        let good = try #require(plan.cards.first)
        let work = ReadabilityAuditBudget()
        work.outputBytes = 0
        #expect(NativeParagraphReadabilityGuard.auditObservation(good, stage: "preCohort", work: work) == nil)
        #expect(work.reason == "budget-output")
        work.outputBytes = 1_048_576
        var invalid = good
        invalid.style.outlineGlow = .infinity
        let unknown = try #require(NativeParagraphReadabilityGuard.auditObservation(
            invalid, stage: "finalCard", work: work))
        #expect(unknown["status"] as? String == "unknown")
        #expect(unknown["reason"] as? String == "unknown-nonfinite-style")
        #expect(unknown["metrics"] is NSNull && unknown["originalGT"] is NSNull)
        #expect(unknown["authority"] as? String == "actual-native-currentstyle-not-original-GT")
        #expect(JSONSerialization.isValidJSONObject(unknown))
        _ = try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys])
        var vertical = good
        vertical.style.vertical = true
        let unsupported = try #require(NativeParagraphReadabilityGuard.auditObservation(
            vertical, stage: "finalCard", work: work))
        #expect(unsupported["status"] as? String == "unsupported")
        #expect(unsupported["reason"] as? String == "unsupported-vertical-horizontal-definition")
        #expect(unsupported["metrics"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject(unsupported))
    }
}

extension NativeDirectExportTests {
    // Transport fixture only: the receipt is authored here, not a claim that
    // this test ran width admission or proved source-style/ten-axis quality.
    @Test(arguments: [CGFloat(1), CGFloat(1.75), CGFloat(3)])
    func boundedPDFSinkPreservesPreparedSourceAndRetainedConsumer(deviceScale: CGFloat) throws {
        let source = bitmap { renderer in
            UIColor(red: 0.32, green: 0.47, blue: 0.63, alpha: 1).setFill()
            renderer.fill(bounds)
            UIColor(red: 0.75, green: 0.36, blue: 0.21, alpha: 1).setFill()
            renderer.fill(CGRect(x: 2, y: 3, width: 5, height: 149))
        }
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(
            layout: observerLayout(), image: source, settings: observerSettings,
            composeSource: true, capturePDF: true, pdfDeviceScale: deviceScale)
        var paintCancelled = false
        func paint(_ context: CGContext) {
            paintCancelled = NativeTranslationRenderer.paintPrepared(
                plan, context: context, canvasBacking: nil, canvasSession: nil) || paintCancelled
        }
        let legacy = try NativeTranslationPDFCapture.captureDocument(
            bounds: plan.bounds, pixels: plan.pixels, deviceScale: deviceScale,
            alignsToLogicalBounds: true, maximumBytes: nil, paint: paint)
        let bounded = try NativeTranslationPDFCapture.captureDocument(
            bounds: plan.bounds, pixels: plan.pixels, deviceScale: deviceScale,
            alignsToLogicalBounds: true, maximumBytes: 16 * 1_024 * 1_024, paint: paint)
        #expect(!paintCancelled && legacy.mediaBox == bounded.mediaBox)
        for zoom in [CGFloat(1), CGFloat(2)] {
            let density = CGSize(width: plan.pixels.width * zoom, height: plan.pixels.height * zoom)
            let old = try NativeTranslationPDFCapture.rasterize(data: legacy.data, pixels: density)
            let new = try NativeTranslationPDFCapture.rasterize(data: bounded.data, pixels: density)
            #expect(try pixels(UIImage(cgImage: old)) == pixels(UIImage(cgImage: new)))
        }
        let oldImage = try NativeTranslationPDFCapture.rasterize(data: legacy.data, pixels: plan.pixels)
        let newImage = try NativeTranslationPDFCapture.rasterize(data: bounded.data, pixels: plan.pixels)
        let reference = try NativeTranslationRenderer.finishPreparedResult(
            plan, overlayCGImage: oldImage, exportPDFData: legacy.data)
        let receipt = NativeWidthFinalArtifactAdmission.Receipt(
            snapshot: plan, data: bounded.data, image: newImage, mediaBox: bounded.mediaBox,
            logicalBounds: plan.bounds, sourceRect: plan.layout.sourceRect,
            pixels: plan.pixels, deviceScale: deviceScale, cards: plan.cards)
        let sealed = NativeTranslationRenderer.retainedWidthPreparedRender(
            receipt, diagnosticData: plan.diagnosticData)
        let consumed = try NativeTranslationRenderer.finishPreparedSynchronously(sealed)
        #expect(try pixels(reference.overlayImage) == pixels(consumed.overlayImage))
        #expect(try pixels(reference.image) == pixels(consumed.image))
        #expect(consumed.exportPDFData == bounded.data)
        #expect(consumed.sourceRestorationRects == reference.sourceRestorationRects)
        let original = bounded.data
        var alias = bounded.data
        alias[0] ^= 1
        #expect(bounded.data == original && alias != original)
        // Budget failure must never hand a truncated document to the consumer.
        for quota in [1, 1_024] {
            var exhausted = false
            do {
                _ = try NativeTranslationPDFCapture.captureDocument(
                    bounds: plan.bounds, pixels: plan.pixels, deviceScale: deviceScale,
                    alignsToLogicalBounds: true, maximumBytes: quota, paint: paint)
            } catch NativeTranslationPDFCapture.DocumentBudgetError.exhausted {
                exhausted = true
            }
            #expect(exhausted)
        }
    }

    @Test func boundedPDFSinkPrecancelledTaskNeverPaints() async {
        let result = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            var painted = false
            do {
                _ = try NativeTranslationPDFCapture.captureDocument(
                    bounds: CGRect(x: 0, y: 0, width: 120, height: 160),
                    pixels: CGSize(width: 120, height: 160), maximumBytes: 1_024) { _ in
                        painted = true
                    }
                return false
            } catch is CancellationError {
                return !painted
            } catch {
                return false
            }
        }.value
        #expect(result)
    }
}

import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Test-only common body: compile against the candidate's exact production primaries.
enum Lane08PublicationFocusedCases {
    typealias R = NativeTranslationRenderer
    struct Fixture {
        let plan: R.PreparedRender
        let session: NativeWidthFinalArtifactAdmission
    }
    static func require(_ value: Bool, _ reason: String) throws {
        if !value { throw NSError(domain: "Lane08PublicationGate." + reason, code: 1) }
    }
    static func fixture(pdf: Bool) throws -> Fixture {
        let size = CGSize(width: 128, height: 128), bounds = CGRect(origin: .zero, size: size)
        func item(_ id: String, _ text: String, _ x: Int, _ y: Int, _ w: Int) throws -> NativeTranslationLayoutItem {
            try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: [
                "id": id, "text": text, "typesettingText": text, "x": x, "y": y, "width": w, "height": w,
                "fontSize": 12, "lineHeight": 16, "rotation": 0, "vertical": false, "clipsText": true,
                "sourceTextOnly": false, "sourceFrame": [0, 0, 128, 128],
                "sourceBounds": [Double(x)/128, Double(y)/128, Double(w)/128, Double(w)/128]]))
        }
        let owner = try item("owner", "회몸", 16, 16, 64), peer = try item("retained-peer", "점", 96, 96, 28)
        let style = NativeTranslationTypography.Style(fontName: "AppleSDGothicNeo-Bold", fontSize: 12,
            foreground: R.color([17, 31, 47]), outline: nil, outlineWidth: 0, tracking: 0,
            lineHeight: 16, optimizesKoreanWrapping: false)
        func card(_ item: NativeTranslationLayoutItem, panel: Bool) -> R.Card {
            R.Card(item: item, typography: NativeTranslationTypography.layout(text: item.text,
                in: item.contentRect.size, style: style), style: style, drawsPanel: panel,
                background: R.color([221, 231, 241]), usesFallbackVeil: false,
                lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 12)
        }
        var owned = card(owner, panel: true)
        owned.sourceBackgroundKind = "solid-text-box"
        owned.harmonyRecord["widthRequiresRetainedArtifact"] = true
        let cards = [owned, card(peer, panel: false)]
        let ctx = try makeContext()
        ctx.setFillColor(R.color([101, 137, 173])); ctx.fill(bounds)
        let source = ctx.makeImage()!
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: bounds, viewport: size, items: [owner, peer])
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        let plan = R.PreparedRender(inputLayout: layout, layout: layout, image: UIImage(cgImage: source), source: source,
            restoration: .init(), cards: cards, glossCards: [], gloss: .init(), settings: settings,
            bounds: bounds, pixels: size, scale: 1, composeSource: true, capturePDF: pdf, pdfDeviceScale: 1,
            sourcePatches: [], sourcePieces: [], limitations: [], diagnosticData: nil)
        let session = NativeWidthFinalArtifactAdmission(plan: plan, keptOwners: [CGRect(x: 2, y: 2, width: 4, height: 4)])
        try require(session.admission(before: cards, after: cards, ids: [owner.id]) == true, "physical-admission")
        return Fixture(plan: plan, session: session)
    }
    static func makeContext() throws -> CGContext {
        guard let c = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "Lane08PublicationGate.context", code: 1)
        }
        return c
    }
    static func golden(pdf: Bool) throws -> [String: Any] {
        let f = try fixture(pdf: pdf), receipt = f.session.accepted!
        let before = try f.session.finalized(cards: f.plan.cards, diagnosticData: nil)!
        let reference = try R.finishPreparedSynchronously(before)
        let captures = f.session.documentReceipts.count
        let published = try f.session.publishOwned(diagnosticData: nil)!
        try require(f.session.documentReceipts.count == captures, "new-publication-capture")
        try require(published.retainedWidthArtifact?.image === receipt.image, "image-not-owned")
        try require(published.retainedWidthArtifact?.data == receipt.data, "document-not-owned")
        let candidate = try R.finishPreparedSynchronously(published)
        func rgba(_ image: UIImage) throws -> [UInt8] {
            try NativeWidthFinalArtifactAdmission.rgba(image.cgImage!)
        }
        try require(try rgba(candidate.image) == rgba(reference.image), "native-source-over")
        try require(try rgba(candidate.overlayImage) == rgba(reference.overlayImage), "overlay")
        let overlay = try rgba(candidate.overlayImage)
        let partial = stride(from: 3, to: overlay.count, by: 4).filter { overlay[$0] > 0 && overlay[$0] < 255 }.count
        try require(partial > 0, "transparent-AA-control-inactive")
        // A wrong painter buffer must not pass the retained identity gate, even if PDF data matches.
        let dropped = try makeContext().makeImage()!
        var rejected = false
        do { _ = try R.finishPreparedResult(published, overlayCGImage: dropped, exportPDFData: receipt.data) }
        catch { rejected = true }
        try require(rejected, "substituted-overlay-published")
        // Reconstructing a world must drop ownership; an unchanged marker cannot bypass the gate.
        let reconstructed = R.PreparedRender(inputLayout: published.inputLayout, layout: published.layout,
            image: published.image, source: published.source, restoration: published.restoration, cards: published.cards,
            glossCards: published.glossCards, gloss: published.gloss, settings: published.settings,
            bounds: published.bounds, pixels: published.pixels, scale: published.scale, composeSource: true,
            capturePDF: pdf, pdfDeviceScale: 1, sourcePatches: [], sourcePieces: [], limitations: [], diagnosticData: nil)
        rejected = false
        do { _ = try R.finishPreparedSynchronously(reconstructed) } catch { rejected = true }
        try require(rejected, "reconstructed-world-published")
        return ["pdf": pdf, "nativeCompositeExact": true, "ownedImageIdentity": true,
            "ownedDocumentExact": true, "partialAlphaPixels": partial, "substitutedOverlayRejected": true,
            "reconstructionRejected": true, "publicationNewCaptures": 0]
    }
    // Invoke inside a child Swift Task so the enclosing test itself is not cancelled.
    static func taskCancellation(afterPublication: Bool) throws -> Bool {
        let f = try fixture(pdf: true)
        do {
            let p = try f.session.publishOwned(diagnosticData: nil, reserveWork: { _ in
                if !afterPublication { withUnsafeCurrentTask { $0?.cancel() } }
                return true
            })
            if afterPublication {
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try R.finishPreparedSynchronously(p!)
            }
            return false
        } catch is CancellationError {
            return afterPublication || f.session.accepted == nil
        }
    }
}

// Main-only addition to NativeDirectExportTests.swift after integrating publication v2.
// Append PublicationFocusedCases.swift's test-only body (or include that file in AidokuTests).
extension NativeDirectExportTests {
    @Test(arguments: [false, true])
    func ownedPublicationKeepsNativeSourceOverAndRejectsSubstitutedWorld(pdf: Bool) throws {
        _ = try Lane08PublicationFocusedCases.golden(pdf: pdf)
    }

    @Test(arguments: [false, true])
    func ownedPublicationAndConsumerHonorActualTaskCancellation(afterPublication: Bool) async throws {
        let task = Task { @MainActor in
            try Lane08PublicationFocusedCases.taskCancellation(afterPublication: afterPublication)
        }
        #expect(try await task.value)
    }
}
