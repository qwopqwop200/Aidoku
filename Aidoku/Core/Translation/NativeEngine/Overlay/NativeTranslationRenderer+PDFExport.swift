import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension NativeTranslationRenderer {
    /// Vector export owns no full-page raster. The caller composites this PDF
    /// and the exact native repair patches once, at its final output resolution.
    struct PDFResult: @unchecked Sendable {
        let layoutData: Data
        let renderedItemCount: Int
        let limitations: [String]
        let renderBounds: CGRect
        let diagnosticData: Data?
        let exportPDFData: Data
        let sourceRestorationRects: [CGRect]
        let paintBounds: [CGRect]
        let sourcePatches: [SourcePatch]
        let stagesMilliseconds: [String: Double]
        var ensembleRestored: CGImage? = nil
        var ensembleRemovalMask: CGImage? = nil
        var includesSourcePage = false
    }

    static func renderPDFSynchronously(layout: NativeTranslationLayout, image: UIImage?,
                                       settings: IPhoneOverlaySettings, scale: CGFloat = 1,
                                       dark: Bool = false, renderBounds: CGRect? = nil,
                                       outputPixelSize: CGSize? = nil, collectDiagnostics: Bool = false,
                                       pdfDeviceScale: CGFloat = 1, auditCardObserver: AuditCardObserver? = nil,
                                       preparedDB:NativeMainEnsemblePreparedDB? = nil) throws -> PDFResult {
        if #available(iOS 18.0, macOS 15.0, *), NativeMainEnsembleRenderer.enabled, settings.visible,
           let image, let source = ensembleSourceImage(image).cgImage {
            return try NativeMainEnsembleRenderer.renderPDF(layout: layout, source: source, scale: scale,
                renderBounds: renderBounds, outputPixelSize: outputPixelSize, pdfDeviceScale: pdfDeviceScale,preparedDB:preparedDB)
        }
        let profileStages = ProcessInfo.processInfo.environment["AIDOKU_PROFILE_RENDER_STAGES"] == "1"
        var stagesMilliseconds: [String: Double] = [:]
        var stageStarted = profileStages ? ProcessInfo.processInfo.systemUptime : 0
        let recordStage: ((String) -> Void)? = profileStages ? { name in
            let now = ProcessInfo.processInfo.systemUptime
            stagesMilliseconds[name] = (now - stageStarted) * 1000
            stageStarted = now
        } : nil
        let plan = try prepareRenderSynchronously(layout: layout, image: image, settings: settings,
            scale: scale, dark: dark, renderBounds: renderBounds, composeSource: false,
            outputPixelSize: outputPixelSize, collectDiagnostics: collectDiagnostics,
            capturePDF: true, pdfDeviceScale: pdfDeviceScale, recordStage: recordStage, auditCardObserver: auditCardObserver)
        recordStage?("native.prepareFinalize")
        return try autoreleasepool {
            var cancelled = false
            let capture: NativeTranslationPDFCapture.Document
            if let retained = plan.retainedWidthArtifact {
                try Task.checkCancellation()
                guard let data = retained.data else { throw RenderError.invalidGeometry }
                capture = NativeTranslationPDFCapture.Document(data: data, mediaBox: retained.mediaBox)
            } else {
                guard !plan.cards.contains(where: { $0.harmonyRecord["widthRequiresRetainedArtifact"] as? Bool == true }) else {
                    throw RenderError.invalidGeometry
                }
                capture = try NativeTranslationPDFCapture.captureDocument(bounds: plan.bounds,
                    pixels: plan.pixels, deviceScale: plan.pdfDeviceScale, alignsToLogicalBounds: true) { context in
                    cancelled = paintPrepared(plan, context: context, canvasBacking: nil, canvasSession: nil)
                }
            }
            if cancelled { throw CancellationError() }
            try Task.checkCancellation()
            recordStage?("native.pdfDrawing")
            let layoutData = try JSONEncoder().encode(plan.inputLayout)
            recordStage?("native.layoutJSONEncode")
            return PDFResult(layoutData: layoutData,
                renderedItemCount: plan.cards.count - plan.gloss.hiddenIDs.count,
                limitations: Array(Set(plan.limitations)).sorted(), renderBounds: plan.bounds,
                diagnosticData: plan.diagnosticData, exportPDFData: capture.data,
                sourceRestorationRects: plan.sourcePieces,
                paintBounds: finalPaintBounds(cards: plan.cards, glossCards: plan.glossCards,
                    gloss: plan.gloss, settings: plan.settings), sourcePatches: plan.sourcePatches,
                stagesMilliseconds: stagesMilliseconds)
        }
    }
}
