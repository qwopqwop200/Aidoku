import CoreGraphics
import Foundation

// V2 orchestrator for one page (see Docs/translation-v2.md):
//   decode (once) -> S1 layout || S2 detect -> S2b line assembly -> S3 recognize
//   -> S4 group + role filter -> S5 translate || (S8 style -> S6 mask -> S7 inpaint)
//   -> S9 layout -> S10 paint
// S8, S6 and S7 do not read the translation text, so they start right after S4
// and run during the LLM call; only S9/S10 wait for translations. S6/S7 run on
// the blocks predicted to be painted; when S5's result paints a different set
// they are recomputed after S5, so the output never depends on the overlap.
// Every stage is timed in `V2Timings`. A page is never thrown away: a failed
// stage degrades to "keep the original pixels" for the blocks it affects and
// the failure is reported in `V2PageResult.failure`.

/// Fills `translation` (and may refine `role`) on blocks. Live mode wraps
/// `V2Translation.translate`; evaluation replays saved legacy translations.
typealias V2Translator = @Sendable (_ page: V2Page, _ blocks: [V2Block]) async throws -> [V2Block]

/// Admission hooks around the non-LLM compute phases. The iOS service maps them
/// to its compute slots; the defaults admit everything immediately.
struct V2PipelineHooks: Sendable {
    /// S1-S4 are done; called once, before S5 and the overlapped back work start.
    var frontFinished: @Sendable () -> Void = {}
    /// Brackets each back compute phase: the overlapped S8/S6/S7 (during S5)
    /// and the post-S5 tail (S9/S10 plus any recompute). Never held across S5.
    var acquireBack: @Sendable () async throws -> Void = {}
    var releaseBack: @Sendable () -> Void = {}
    /// Ids S5 is expected to translate (S6/S7 speculate on them minus background
    /// blocks); nil predicts every non-background block.
    var predictTranslated: (@Sendable (_ blocks: [V2Block]) -> Set<Int>)?
}

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
        /// Decode through S4 (everything before the LLM call).
        static let front = "front_wall"
        /// The overlapped S8/S6/S7 branch, including its admission wait.
        static let back = "back_overlap_wall"
        /// From the later of S5 and the back branch to the finished page.
        static let tail = "tail_wall"
        /// 1 when S5 painted a different block set than predicted (S6/S7 recomputed).
        static let speculationMiss = "speculation_miss"
        /// Full-page pixel conversions of the source image (decode included).
        static let conversions = "decode_conversions"
        static let total = "total"
        /// `total` minus S5: the non-LLM work on the page's critical path.
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

    /// Restored background for one paint set (S6 + S7).
    private struct Erased: Sendable {
        var removal: [UInt8]?
        var background: CGImage?
        var failure: String?
        var stages: [String: Double] = [:]
    }

    /// The overlapped back branch: S8 on the S4 blocks, then S6/S7 on the predicted paint set.
    private struct Back: Sendable {
        var styled: [V2Block]?
        var paintable: [V2Block] = []
        var erased: Erased?
        var failure: String?
        var stages: [String: Double] = [:]
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func run(_ source: V2Page, models: V2Models, translate: V2Translator,
                    hooks: V2PipelineHooks = V2PipelineHooks()) async -> V2PageResult {
        let started = DispatchTime.now().uptimeNanoseconds
        // Every stage, the translator and the painted output use the capped page, so
        // coordinates stay consistent; the reader presents the output aspect-fit in
        // place of the source, so a smaller same-aspect bitmap displays the same.
        guard let page = cappedPage(source) else {
            return V2PageResult(pageID: source.id, blocks: [], placed: [], output: source.image, removalMask: nil,
                                timings: V2Timings(), failure: "decode: page exceeds the pixel cap and could not be downscaled")
        }
        var timings = V2Timings()
        var failures: [String] = []
        let pageSize = CGSize(width: page.width, height: page.height)

        // S1 || S2 (after one shared pixel decode).
        var front = await timings.record(Stage.parallel) { await runFront(page, models: models) }
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
            let grouped = V2Grouping.group(read, layout: layout, pageSize: pageSize, raster: front.gray,
                                           direction: page.readingDirection)
            return V2RoleFilter.classify(grouped, layout: layout)
        }
        timings.stages[Stage.front] = milliseconds(since: started)
        hooks.frontFinished()
        // Only S2/S3 read the detector frame and S4 the gray raster. Drop them before the
        // provider wait: for a non-shareable page the frame is a second full-page buffer.
        front.frame = nil
        front.gray = nil
        let shared = front

        // S5 (LLM or replay) || S8 -> S6 -> S7 on the predicted paint set.
        let candidates = blocks
        let predicted = hooks.predictTranslated?(candidates)
        async let overlapped = runBack(page, blocks: candidates, predicted: predicted, front: shared,
                                       models: models, hooks: hooks)
        let translateStart = DispatchTime.now().uptimeNanoseconds
        do {
            blocks = try await timings.record(Stage.translate) { try await translate(page, candidates) }
        } catch { failures.append("s5: \(error)") }
        let translateMilliseconds = milliseconds(since: translateStart)
        var back = await overlapped
        timings.stages.merge(back.stages) { $0 + $1 }
        if let failure = back.failure { failures.append(failure) }

        let tailStart = DispatchTime.now().uptimeNanoseconds
        var admitted = true
        do { try await hooks.acquireBack() } catch {
            admitted = false
            failures.append("back: \(error)")
        }
        // A cancelled page (its result is discarded) skips the tail: otherwise a cancelled
        // look-ahead, refused a back slot, would run S8/S6/S7/S10 outside back admission.
        if Task.isCancelled {
            if admitted { hooks.releaseBack() }
            failures.append("cancelled")
            timings.stages[Stage.tail] = milliseconds(since: tailStart)
            return V2PageResult(pageID: page.id, blocks: blocks, placed: [], output: page.image, removalMask: nil,
                                timings: timings, failure: failures.joined(separator: "; "))
        }

        // S8 result: reused when S5 changed nothing S8 reads.
        if let styled = back.styled, styled.count == blocks.count,
           zip(styled, blocks).allSatisfy({ styleInput($0) == styleInput($1) }) {
            blocks = zip(blocks, styled).map { block, measured in
                var block = block
                block.style = measured.style
                return block
            }
        } else {
            let unstyled = blocks
            blocks = timings.record(Stage.style) { V2Style.estimate(page, blocks: unstyled) }
        }

        // (S6 -> S7, only when the prediction missed) || S9
        let paintable = blocks.filter(V2Layout.isPaintable)
        let finalBlocks = blocks
        async let placement: (placed: [V2PlacedText], ms: Double) = {
            let start = DispatchTime.now().uptimeNanoseconds
            let placed = paintable.isEmpty ? [] : V2Layout.place(paintable, pageSize: pageSize)
            return (placed, milliseconds(since: start))
        }()
        var erased: Erased?
        if !paintable.isEmpty {
            if let speculative = back.erased, back.paintable.map(eraseInput) == paintable.map(eraseInput) {
                erased = speculative
            } else {
                timings.stages[Stage.speculationMiss] = 1
                // Free the stale speculative background and mask before recomputing them.
                back.erased = nil
                let recomputed = await erase(page, paintable: paintable, layout: layout, raster: shared.raster,
                                             models: models)
                timings.stages.merge(recomputed.stages) { $0 + $1 }
                erased = recomputed
            }
            if let failure = erased?.failure { failures.append(failure) }
        }
        let (placed, placeMilliseconds) = await placement
        timings.stages[Stage.place, default: 0] += placeMilliseconds

        // S10. Without a restored background the source pixels stay untouched.
        var output = page.image
        var painted: [V2PlacedText] = []
        if let background = erased?.background {
            painted = placed
            output = timings.record(Stage.paint) { V2Painter.paint(background: background, blocks: finalBlocks, placed: placed) }
            let placedIDs = Set(placed.map(\.blockID))
            let unplaced = paintable.filter { !placedIDs.contains($0.id) }.count
            if unplaced > 0 { failures.append("s9: \(unplaced) erased block(s) not placed") }
        }
        if admitted { hooks.releaseBack() }
        timings.stages[Stage.tail] = milliseconds(since: tailStart)
        let total = milliseconds(since: started)
        timings.stages[Stage.total] = total
        timings.stages[Stage.nonLLM] = total - translateMilliseconds
        return V2PageResult(pageID: page.id, blocks: finalBlocks, placed: painted, output: output,
                            removalMask: erased?.removal, timings: timings,
                            failure: failures.isEmpty ? nil : failures.joined(separator: "; "))
    }

    /// A page within `maxPixels` is returned unchanged (same image, so its output is
    /// byte-identical to an uncapped run); a larger one is downscaled with its aspect
    /// kept. Nil when the smaller raster cannot be allocated.
    static func cappedPage(_ page: V2Page, maxPixels: Int = ImagePixelCap.maxPixels) -> V2Page? {
        guard ImagePixelCap.exceeds(width: page.width, height: page.height, maxPixels: maxPixels) else { return page }
        guard let image = ImagePixelCap.downscaled(page.image, maxPixels: maxPixels) else { return nil }
        return V2Page(id: page.id, image: image, readingDirection: page.readingDirection)
    }

    /// The block fields S8 reads: everything except S5's translation/role and S8's own output.
    static func styleInput(_ block: V2Block) -> V2Block {
        var block = block
        block.translation = nil
        block.role = .dialogue
        block.style = nil
        return block
    }

    /// The block fields S6/S7 read for a paintable (non-background) block: all but the translation
    /// and the dialogue/sfx distinction.
    static func eraseInput(_ block: V2Block) -> V2Block {
        var block = block
        block.translation = nil
        if block.role != .background { block.role = .dialogue }
        return block
    }

    private static func runBack(_ page: V2Page, blocks: [V2Block], predicted: Set<Int>?, front: Front,
                                models: V2Models, hooks: V2PipelineHooks) async -> Back {
        let start = DispatchTime.now().uptimeNanoseconds
        var back = Back()
        do { try await hooks.acquireBack() } catch {
            // Not admitted: the tail recomputes everything after S5.
            back.stages[Stage.back] = milliseconds(since: start)
            return back
        }
        guard !Task.isCancelled else {
            hooks.releaseBack()
            back.stages[Stage.back] = milliseconds(since: start)
            return back
        }
        var timings = V2Timings()
        let styled = timings.record(Stage.style) { V2Style.estimate(page, blocks: blocks) }
        back.styled = styled
        back.paintable = styled.filter { $0.role != .background && (predicted?.contains($0.id) ?? true) }
        if !back.paintable.isEmpty {
            back.erased = await erase(page, paintable: back.paintable, layout: front.layout, raster: front.raster,
                                      models: models)
        }
        hooks.releaseBack()
        back.stages = timings.stages
        if let erased = back.erased { back.stages.merge(erased.stages) { $0 + $1 } }
        back.stages[Stage.back] = milliseconds(since: start)
        return back
    }

    private static func erase(_ page: V2Page, paintable: [V2Block], layout: [V2LayoutRegion],
                              raster: V2PageRaster?, models: V2Models) async -> Erased {
        var timings = V2Timings()
        var erased = Erased()
        let removal = timings.record(Stage.mask) {
            // The shared raster holds exactly the bytes V2RemovalMask would convert itself.
            if let raster {
                return V2RemovalMask.build(rgba: raster.rgba, width: raster.width, height: raster.height,
                                           blocks: paintable, layout: layout)
            }
            return V2RemovalMask.build(page, blocks: paintable, layout: layout)
        }
        erased.removal = removal
        do {
            erased.background = try await timings.record(Stage.inpaint) { () async throws -> CGImage in
                guard removal.count == page.width * page.height else { throw V2PipelineFailure.maskSize }
                if let raster {
                    return try await V2Inpaint.restoreImage(raster, mask: removal, models: models)
                }
                return try await V2Inpaint.restore(page, mask: removal, models: models)
            }
        } catch { erased.failure = "s7: \(error)" }
        erased.stages = timings.stages
        return erased
    }

    private static func runFront(_ page: V2Page, models: V2Models) async -> Front {
        async let gray: V2GrayRaster? = V2GrayRaster(image: page.image)
        var front = Front()
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        let pixels = decodePixels(page.image)
        front.stages[Stage.decode] = milliseconds(since: decodeStart)
        front.stages[Stage.conversions] = Double(pixels.conversions)
        let frame = pixels.frame
        // One RGBA frame feeds both the detector and the recognizer (S3 reuses it).
        async let detected: (Result<[V2Line], Error>, Double) = {
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                let lines: [V2Line]
                if let frame {
                    // Geometry-only detection: same polygons/scores, no legacy evidence (V2Detection.swift).
                    lines = try await V2Detection.detect(frame: frame, models: models)
                } else {
                    lines = try await V2Detection.detect(page, models: models)
                }
                return (.success(lines), milliseconds(since: start))
            } catch { return (.failure(error), milliseconds(since: start)) }
        }()
        front.raster = pixels.raster
        if let decoded = pixels.raster {
            let start = DispatchTime.now().uptimeNanoseconds
            do { front.layout = try await V2LayoutDetection.detect(decoded, models: models) }
            catch { front.failures.append("s1: \(error)") }
            front.stages[Stage.layout] = milliseconds(since: start)
        } else { front.failures.append("decode: page raster unavailable") }
        let (lines, detectMilliseconds) = await detected
        front.stages[Stage.detect] = detectMilliseconds
        switch lines {
        case .success(let value): front.lines = value
        case .failure(let error): front.failures.append("s2: \(error)")
        }
        front.frame = frame
        front.gray = await gray
        return front
    }

    // MARK: - Shared page pixels

    /// Decodes the page once. The detector/recognizer frame (DeviceRGB, `.copy`) and the
    /// canonical raster (sRGB on a white matte) are the same bytes for an opaque sRGB page, so
    /// one buffer serves both (and S6); any other page pays a second conversion.
    static func decodePixels(_ image: CGImage)
        -> (raster: V2PageRaster?, frame: NativeOCRRGBAFrame?, conversions: Int) {
        let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: image)
        if let frame, canShare(image, frame: frame) {
            return (V2PageRaster(width: frame.width, height: frame.height, rgba: frame.bytes), frame, 1)
        }
        return (try? V2PageRaster(image), frame, frame == nil ? 1 : 2)
    }

    static func canShare(_ image: CGImage, frame: NativeOCRRGBAFrame) -> Bool {
        guard frame.width <= 16_384, frame.height <= 16_384, frame.bytesPerRow == frame.width * 4,
              image.colorSpace?.name == CGColorSpace.sRGB else { return false }
        return isOpaque(frame.bytes)
    }

    /// True when every alpha byte (offset 3 of each RGBA pixel) is 255.
    static func isOpaque(_ rgba: [UInt8]) -> Bool {
        rgba.withUnsafeBytes { raw -> Bool in
            let words = raw.bindMemory(to: UInt32.self)
            let alpha = UInt32(0xFF) << 24
            var index = 0
            while index < words.count {
                let end = min(words.count, index + 65_536)
                var combined = UInt32.max
                for word in words[index..<end] { combined &= word }
                guard combined & alpha == alpha else { return false }
                index = end
            }
            return true
        }
    }
}

enum V2PipelineFailure: Error { case maskSize }
