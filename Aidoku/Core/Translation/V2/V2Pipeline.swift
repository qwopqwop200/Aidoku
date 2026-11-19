import CoreGraphics
import Foundation

// V2 orchestrator for one page (see Docs/translation-v2.md):
//   S1 layout || S2 detect (+ page decodes) -> S2b line assembly -> S3 recognize
//   -> S4 group + role filter -> S5 translate -> S8 style
//   -> (S6 mask -> S7 inpaint) || S9 layout -> S10 paint
// Every stage is timed in `V2Timings`. A page is never thrown away: a failed
// stage degrades to "keep the original pixels" for the blocks it affects and
// the failure is reported in `V2PageResult.failure`.

/// Fills `translation` (and may refine `role`) on blocks. Live mode wraps
/// `V2Translation.translate`; evaluation replays saved legacy translations.
typealias V2Translator = @Sendable (_ page: V2Page, _ blocks: [V2Block]) async throws -> [V2Block]

@available(iOS 18.0, macOS 15.0, *)
enum V2Pipeline {
    enum Stage {
        static let decode = "decode"
        static let layout = "s1_layout"
        static let detect = "s2_detect"
        static let assemble = "s2_assemble"
        static let parallel = "s1_s2_wall"
        static let recognize = "s3_recognize"
        static let group = "s4_group"
        static let translate = "s5_translate"
        static let style = "s8_style"
        static let mask = "s6_mask"
        static let inpaint = "s7_inpaint"
        static let place = "s9_layout"
        static let paint = "s10_paint"
        static let total = "total"
        static let nonLLM = "total_non_llm"
    }

    private struct Front: Sendable {
        var layout: [V2LayoutRegion] = []
        var lines: [V2Line] = []
        var raster: V2PageRaster?
        var frame: NativeOCRRGBAFrame?
        var gray: V2GrayRaster?
        var stages: [String: Double] = [:]
        var failures: [String] = []
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func run(_ page: V2Page, models: V2Models, translate: V2Translator) async -> V2PageResult {
        let started = DispatchTime.now().uptimeNanoseconds
        var timings = V2Timings()
        var failures: [String] = []
        let pageSize = CGSize(width: page.width, height: page.height)

        // S1 || S2 (and the shared pixel decodes) run concurrently.
        let front = await timings.record(Stage.parallel) { await runFront(page, models: models) }
        timings.stages.merge(front.stages) { $0 + $1 }
        failures += front.failures
        let layout = front.layout
        let lines = timings.record(Stage.assemble) { V2LineAssembly.assemble(front.lines, layout: layout) }

        // S3
        var read: [V2Line] = []
        do {
            read = try await timings.record(Stage.recognize) {
                if let frame = front.frame {
                    return try await V2Recognition.recognize(frame: frame, lines: lines, engine: models.recognition)
                }
                return try await V2Recognition.recognize(page, lines: lines, engine: models.recognition)
            }
        } catch { failures.append("s3: \(error)") }

        // S4
        var blocks = timings.record(Stage.group) {
            let grouped = V2Grouping.group(read, layout: layout, pageSize: pageSize, raster: front.gray)
            return V2RoleFilter.classify(grouped, layout: layout)
        }

        // S5 (LLM or replay). Excluded from the non-LLM wall time.
        let translateStart = DispatchTime.now().uptimeNanoseconds
        do {
            let candidate = blocks
            blocks = try await timings.record(Stage.translate) { try await translate(page, candidate) }
        } catch { failures.append("s5: \(error)") }
        let translateMilliseconds = milliseconds(since: translateStart)

        // S8
        blocks = timings.record(Stage.style) { V2Style.estimate(page, blocks: blocks) }

        // (S6 -> S7) || S9
        let paintable = blocks.filter(V2Layout.isPaintable)
        let finalBlocks = blocks
        async let placement: (placed: [V2PlacedText], ms: Double) = {
            let start = DispatchTime.now().uptimeNanoseconds
            let placed = paintable.isEmpty ? [] : V2Layout.place(paintable, pageSize: pageSize)
            return (placed, milliseconds(since: start))
        }()
        var removal: [UInt8]?
        var background: CGImage?
        if !paintable.isEmpty {
            removal = timings.record(Stage.mask) {
                V2RemovalMask.build(page, blocks: paintable, layout: layout)
            }
            do {
                background = try await timings.record(Stage.inpaint) { () async throws -> CGImage in
                    guard let removal, removal.count == page.width * page.height else {
                        throw V2PipelineFailure.maskSize
                    }
                    if let raster = front.raster {
                        return try await V2Inpaint.restore(raster, mask: removal, models: models).image()
                    }
                    return try await V2Inpaint.restore(page, mask: removal, models: models)
                }
            } catch { failures.append("s7: \(error)") }
        }
        let (placed, placeMilliseconds) = await placement
        timings.stages[Stage.place, default: 0] += placeMilliseconds

        // S10. Without a restored background the source pixels stay untouched.
        var output = page.image
        var painted: [V2PlacedText] = []
        if let background {
            painted = placed
            output = timings.record(Stage.paint) { V2Painter.paint(background: background, blocks: finalBlocks, placed: placed) }
            let placedIDs = Set(placed.map(\.blockID))
            let unplaced = paintable.filter { !placedIDs.contains($0.id) }.count
            if unplaced > 0 { failures.append("s9: \(unplaced) erased block(s) not placed") }
        }
        let total = milliseconds(since: started)
        timings.stages[Stage.total] = total
        timings.stages[Stage.nonLLM] = total - translateMilliseconds
        return V2PageResult(pageID: page.id, blocks: finalBlocks, placed: painted, output: output,
                            removalMask: removal, timings: timings,
                            failure: failures.isEmpty ? nil : failures.joined(separator: "; "))
    }

    private static func runFront(_ page: V2Page, models: V2Models) async -> Front {
        async let raster: (V2PageRaster?, Double) = {
            let start = DispatchTime.now().uptimeNanoseconds
            return (try? V2PageRaster(page.image), milliseconds(since: start))
        }()
        async let gray: V2GrayRaster? = V2GrayRaster(image: page.image)
        // One RGBA frame feeds both the detector and the recognizer (S3 reuses it).
        async let detected: (Result<[V2Line], Error>, Double, NativeOCRRGBAFrame?) = {
            let start = DispatchTime.now().uptimeNanoseconds
            let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: page.image)
            do {
                let lines: [V2Line]
                if let frame {
                    let result = try await models.detectors.with { detector in
                        try await detector.detect(frame: frame, requestID: page.id, configuration: V2Detection.configuration)
                    }
                    lines = result.boxes.compactMap { V2Detection.line(polygon: $0.polygon, score: $0.score) }
                } else {
                    lines = try await V2Detection.detect(page, models: models)
                }
                return (.success(lines), milliseconds(since: start), frame)
            } catch { return (.failure(error), milliseconds(since: start), frame) }
        }()
        var front = Front()
        let (decoded, decodeMilliseconds) = await raster
        front.raster = decoded
        front.stages[Stage.decode] = decodeMilliseconds
        if let decoded {
            let start = DispatchTime.now().uptimeNanoseconds
            do { front.layout = try await V2LayoutDetection.detect(decoded, models: models) }
            catch { front.failures.append("s1: \(error)") }
            front.stages[Stage.layout] = milliseconds(since: start)
        } else { front.failures.append("decode: page raster unavailable") }
        let (lines, detectMilliseconds, frame) = await detected
        front.stages[Stage.detect] = detectMilliseconds
        switch lines {
        case .success(let value): front.lines = value
        case .failure(let error): front.failures.append("s2: \(error)")
        }
        front.frame = frame
        front.gray = await gray
        return front
    }
}

enum V2PipelineFailure: Error { case maskSize }
