from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[3]
staged=Path(__file__).parent/'staged'
overlay=root/'Aidoku/Core/Translation/NativeEngine/Overlay'
main=(overlay/'NativeTranslationRenderer.swift').read_text()
paint=(overlay/'NativeTranslationRenderer+PaintOrder.swift').read_text()
start=main.index('    /// Callers outside the async entrypoint')
end=main.index('\n    static func initialSlantedTypography',start)
original=main[start:end]
header_end=original.index('        return try autoreleasepool {')
preparation_end=original.index('            let format = UIGraphicsImageRendererFormat()')
suffix_start=original.index('            let overlay = UIImage(cgImage: overlayCGImage')
finish_end=original.rindex('\n        }\n    }')
prefix=original[:header_end]
prepare_body=original[header_end:preparation_end]
prepare_body=prepare_body.replace('            let initialPatchCapture = collectDiagnostics ? NativeRestorationDiagnosticCapture.capture(restoration) : nil','            let initialPatchCapture = collectDiagnostics ? NativeRestorationDiagnosticCapture.capture(restoration) : nil')
shared_declarations='''            let pixels = outputPixelSize.map { pixelSize(viewport: $0, scale: 1) } ?? pixelSize(viewport: bounds.size, scale: scale)
            let sourcePatches = snapshotSourcePatches(restoration: restoration, cards: cards, gloss: gloss, visible: settings.visible)
            let sourcePieces = settings.visible && settings.renderedBackgroundOpacity == 1 && image != nil
                ? sourceRestorationRects(cards: cards, glossCards: glossCards, gloss: gloss, layout: layout, restoration: restoration, recovered: recovered, settings: settings) : []
            let diagnosticData = collectDiagnostics ? diagnostics(cards: cards, glossCards: glossCards, gloss: gloss,
                restoration: restoration, growthSession: growthSession, initialPatchCapture: initialPatchCapture) : nil
            return PreparedRender(inputLayout: inputLayout, layout: layout, image: image, source: source,
                restoration: restoration, cards: cards, glossCards: glossCards, gloss: gloss, settings: settings,
                bounds: bounds, pixels: pixels, scale: scale, composeSource: composeSource,
                capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale,
                sourcePatches: sourcePatches, sourcePieces: sourcePieces,
                limitations: limitations, diagnosticData: diagnosticData)
        }
    }
'''
prepared='''    /// Private worker value. CoreText/layout/context values never cross to UIKit's actor.
    struct PreparedRender {
        let inputLayout: NativeTranslationLayout
        let layout: NativeTranslationLayout
        let image: UIImage?
        let source: CGImage?
        let restoration: NativeTranslationRestoration.Result
        let cards: [Card]
        let glossCards: [GlossCard]
        let gloss: NativeTranslationEffectGloss.Refinement
        let settings: IPhoneOverlaySettings
        let bounds: CGRect
        let pixels: CGSize
        let scale: CGFloat
        let composeSource: Bool
        let capturePDF: Bool
        let pdfDeviceScale: CGFloat
        let sourcePatches: [SourcePatch]
        let sourcePieces: [CGRect]
        let limitations: [String]
        let diagnosticData: Data?
    }
'''
bindings='''            let inputLayout = plan.inputLayout, layout = plan.layout, image = plan.image, source = plan.source
            let restoration = plan.restoration, cards = plan.cards, glossCards = plan.glossCards, gloss = plan.gloss
            let settings = plan.settings, bounds = plan.bounds, pixels = plan.pixels, scale = plan.scale
            let composeSource = plan.composeSource, capturePDF = plan.capturePDF, pdfDeviceScale = plan.pdfDeviceScale
            let sourcePatches = plan.sourcePatches, sourcePieces = plan.sourcePieces
'''
paint_sync=original[preparation_end:suffix_start]
paint_sync=paint_sync.replace('            let pixels = outputPixelSize.map { pixelSize(viewport: $0, scale: 1) } ?? pixelSize(viewport: bounds.size, scale: scale)\n','')
patchstart=paint_sync.index('            let sourcePatches = snapshotSourcePatches')
patchend=paint_sync.index('            let canvasSession:',patchstart)
paint_sync=paint_sync[:patchstart]+paint_sync[patchend:]
paint_sync+='''            if cancelled { throw CancellationError() }
            try Task.checkCancellation()
            return try finishPreparedResult(plan, overlayCGImage: overlayCGImage, exportPDFData: exportPDFData)
        }
    }
'''
result_body=original[suffix_start:finish_end]
result_body=result_body.replace('            if cancelled { throw CancellationError() }\n','')
result_body=result_body.replace('limitations: Array(Set(limitations)).sorted()','limitations: Array(Set(plan.limitations)).sorted()')
result_body=result_body.replace('diagnosticData: collectDiagnostics ? diagnostics(cards: cards, glossCards: glossCards, gloss: gloss, restoration: restoration, growthSession: growthSession, initialPatchCapture: initialPatchCapture) : nil','diagnosticData: plan.diagnosticData')
result_body=result_body.replace('            _ = dark // Native glyph/panel palettes are determined by overlay settings, not the view\'s trait appearance.\n','')
wrapper=prefix[:prefix.index('        try Task.checkCancellation()')]+'''        let plan = try prepareRenderSynchronously(layout: layout, image: image, settings: settings,
            scale: scale, dark: dark, renderBounds: renderBounds, composeSource: composeSource,
            outputPixelSize: outputPixelSize, collectDiagnostics: collectDiagnostics, capturePDF: capturePDF,
            pdfDeviceScale: pdfDeviceScale)
        return try finishPreparedSynchronously(plan)
    }

'''
prepare_header=prefix.replace('static func renderSynchronously','static func prepareRenderSynchronously').replace('throws -> Result {','throws -> PreparedRender {')
replacement=wrapper+prepared+prepare_header+prepare_body+shared_declarations+'''
    static func finishPreparedSynchronously(_ plan: PreparedRender) throws -> Result {
        try autoreleasepool {
'''+bindings.replace('let inputLayout = plan.inputLayout, layout = plan.layout, image = plan.image, source = plan.source','let layout = plan.layout, image = plan.image, source = plan.source').replace('let settings = plan.settings, bounds = plan.bounds, pixels = plan.pixels, scale = plan.scale','let settings = plan.settings, bounds = plan.bounds, pixels = plan.pixels').replace('let composeSource = plan.composeSource, capturePDF = plan.capturePDF, pdfDeviceScale = plan.pdfDeviceScale','let capturePDF = plan.capturePDF, pdfDeviceScale = plan.pdfDeviceScale')+paint_sync+'''
    static func finishPreparedResult(_ plan: PreparedRender, overlayCGImage: CGImage, exportPDFData: Data?) throws -> Result {
        try autoreleasepool {
'''+bindings.replace('let inputLayout = plan.inputLayout, layout = plan.layout, image = plan.image, source = plan.source','let inputLayout = plan.inputLayout, layout = plan.layout, image = plan.image').replace('let restoration = plan.restoration, cards = plan.cards, glossCards = plan.glossCards, gloss = plan.gloss','let cards = plan.cards, glossCards = plan.glossCards, gloss = plan.gloss').replace('let composeSource = plan.composeSource, capturePDF = plan.capturePDF, pdfDeviceScale = plan.pdfDeviceScale','let composeSource = plan.composeSource, capturePDF = plan.capturePDF')+'''            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.preferredRange = .standard; format.opaque = false
            let contextScaleX = pixels.width / bounds.width, contextScaleY = pixels.height / bounds.height
'''+result_body+'''
        }
    }
'''
main=main[:start]+replacement+main[end:]
worker_start=main.index('private actor NativeTranslationRenderWorker')
worker_end=main.index('\n}\n',worker_start)+2
worker='''private actor NativeTranslationRenderWorker {
    static let shared = NativeTranslationRenderWorker()
    private let admission = NativeTranslationRenderAdmission()

    func render(layout: NativeTranslationLayout, image: UIImage?, settings: IPhoneOverlaySettings,
                scale: CGFloat, dark: Bool, renderBounds: CGRect?, composeSource: Bool, outputPixelSize: CGSize?, collectDiagnostics: Bool, capturePDF: Bool, pdfDeviceScale: CGFloat) async throws -> NativeTranslationRenderer.Result {
        let lease = try await admission.acquire()
        let result: NativeTranslationRenderer.Result
        do {
            // The helper unwinds its mutable plan/context/session before this lease is released.
            result = try await NativeTranslationRenderer.renderOnWorker(layout: layout, image: image,
                settings: settings, scale: scale, dark: dark, renderBounds: renderBounds,
                composeSource: composeSource, outputPixelSize: outputPixelSize,
                collectDiagnostics: collectDiagnostics, capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale)
        } catch {
            await lease.release()
            throw error
        }
        await lease.release()
        try Task.checkCancellation()
        return result
    }
}'''
main=main[:worker_start]+worker+main[worker_end:]
# Keep synchronous and asynchronous painters on the exact same command inventory/switch.
draw_start=paint.index('    static func drawPaintScene(')
scene_start=paint.index('        let scene=paintScene',draw_start)
loop_start=paint.index('        for command in ordered',scene_start)
switch_start=paint.index('            switch command.operation',loop_start)
switch_end=paint.index('\n            }\n        }\n    }',switch_start)+len('\n            }')
header=paint[draw_start:scene_start]
order_body=paint[scene_start:loop_start]
order_body=order_body.replace('        let ordered=','        return ')
switch=paint[switch_start:switch_end]
switch='\n'.join(line[4:] if line.startswith('    ') else line for line in switch.splitlines())
newpaint=header+'''        let ordered = orderedPaintCommands(cards: cards, gloss: gloss, settings: settings, latePatches: latePatches)
        for command in ordered {
            if Task.isCancelled { return }
            drawPaintCommand(command, cards: cards, gloss: gloss, settings: settings, context: context,
                pixelSnapScale: pixelSnapScale, latePatches: latePatches, usesLiveTextureSampling: usesLiveTextureSampling,
                canvasSession: canvasSession, canvasBacking: canvasBacking, allowsOpaqueAffineSampling: allowsOpaqueAffineSampling)
        }
    }
    static func orderedPaintCommands(cards: [Card], gloss: NativeTranslationEffectGloss.Refinement,
                                     settings: IPhoneOverlaySettings, latePatches: [SourcePatch]) -> [PaintCommand] {
'''+order_body+'''    }
    static func drawPaintCommand(_ command: PaintCommand, cards: [Card], gloss: NativeTranslationEffectGloss.Refinement,
        settings: IPhoneOverlaySettings, context: CGContext, pixelSnapScale: CGFloat?, latePatches: [SourcePatch],
        usesLiveTextureSampling: Bool, canvasSession: NativeCanvasTextureResampler.Session?, canvasBacking: NativeCanvasBacking?,
        allowsOpaqueAffineSampling: Bool) {
'''+switch+'''
    }
'''
paint=paint[:draw_start]+newpaint+'}\n'
# Methods below are added to the same staged Main file, not a public source yet.
async_methods=(Path(__file__).parent/'async_methods.swift.txt').read_text()
main=main.rstrip()[:-1]+async_methods+'\n}\n'
staged.mkdir(exist_ok=True)
(staged/'NativeTranslationRenderer.swift').write_text(main)
(staged/'NativeTranslationRenderer+PaintOrder.swift').write_text(paint)
(Path(__file__).parent/'manifest.json').write_text(json.dumps({'productionBaseline':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [overlay/'NativeTranslationRenderer.swift',overlay/'NativeTranslationRenderer+PaintOrder.swift']},'staged':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in staged.glob('*.swift')},'scope':'External staged worker preparation/ordered paint bridge only; no app publication or runtime claim'},indent=2))
