import CoreGraphics
import Foundation

// Pipeline orchestrator for one page:
//   decode -> S1 layout || S2 detect -> S2b assemble -> S3 recognize -> S4 group + roles
//   -> S5 translate || (S8 style -> S6 mask -> S7 inpaint) -> S9 layout -> S10 paint
// S8/S6/S7 do not read translations, so they run during the LLM call (S8 on every S4 block,
// S6/S7 on the predicted paint set); S6/S7 are recomputed when S5 paints a different set,
// S8 when S5 changed a field it reads. A failed stage keeps the original pixels of the blocks
// it affects and is reported in `PipelinePageResult.failure`.

/// Fills `translation` (and may refine `role`): live `PipelineTranslation.translate` or a replay.
typealias PipelineTranslator = @Sendable (_ page: PipelinePage, _ blocks: [PipelineBlock]) async throws -> [PipelineBlock]

/// Admission hooks around the non-LLM compute phases; the defaults admit everything.
struct PipelineHooks: Sendable {
    /// S1-S4 are done; called once, before S5 and the overlapped back work start.
    var frontFinished: @Sendable () -> Void = {}
    /// Brackets each back compute phase: the overlapped S8/S6/S7 (during S5)
    /// and the post-S5 tail (S9/S10 plus any recompute). Never held across S5.
    var acquireBack: @Sendable () async throws -> Void = {}
    var releaseBack: @Sendable () -> Void = {}
    /// Ids S5 is expected to translate (S6/S7 speculate on them minus background
    /// blocks); nil predicts every non-background block.
    var predictTranslated: (@Sendable (_ blocks: [PipelineBlock]) -> Set<Int>)?
    /// The page's current scheduling rank (lower first) for shared S3 recognizer handles.
    var recognitionRank: @Sendable () -> Int = { 0 }
    /// Whether the page is visible now: its tail skips the back slot when S5 changed nothing
    /// S6-S8 read (S9/S10 only, ~5 ms, on buffers it already holds).
    var isForeground: @Sendable () -> Bool = { false }
}

@available(iOS 18.0, macOS 15.0, *)
enum TranslationPipeline {
    /// Host-only observer of each page's S6 removal mask (page id, width, height, mask, erased block
    /// ids), for mask scoring when knobs are re-fitted; nil in the app. Set before any page runs.
    nonisolated(unsafe) static var removalObserver: (@Sendable (String, Int, Int, [UInt8], [Int]) -> Void)?

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
        var layout: [PipelineLayoutRegion] = []
        var lines: [PipelineLine] = []
        var raster: PipelinePageRaster?
        var frame: NativeOCRRGBAFrame?
        var gray: PipelineGrayRaster?
        var stages: [String: Double] = [:]
        var failures: [String] = []
    }

    /// Restored background for one paint set (S6 + S7).
    private struct Erased: Sendable {
        /// The restored page, whose bytes S10 takes and paints over in place (the async let result
        /// that carries this value keeps a copy, so the bytes stay unshared only behind a reference).
        var restored: PipelineRasterHandoff?
        /// The restored page when no shared raster was decoded.
        var background: CGImage?
        var failure: String?
        var stages: [String: Double] = [:]
    }

    /// The overlapped back branch: S8 on the S4 blocks, then S6/S7 on the predicted paint set.
    private struct Back: Sendable {
        var styled: [PipelineBlock]?
        var paintable: [PipelineBlock] = []
        var erased: Erased?
        var failure: String?
        var stages: [String: Double] = [:]
    }

    /// What the back branch reads from S1 || S2. A reference holds the page raster so its lifetime
    /// never rests on an `async let` capture: the optimized build borrowed `[front]` there, and
    /// `front.raster = nil` freed the bytes while S8 still read them (heap-use-after-free).
    private final class BackInput: @unchecked Sendable {
        let layout: [PipelineLayoutRegion]
        private let lock = NSLock()
        private var raster: PipelinePageRaster?
        init(layout: [PipelineLayoutRegion], raster: PipelinePageRaster?) {
            self.layout = layout
            self.raster = raster
        }
        /// Hands the raster to the caller (the back branch), which then frees it when it ends.
        func takeRaster() -> PipelinePageRaster? { lock.withLock { defer { raster = nil }; return raster } }
    }

    /// Raised when S5 throws: its blocks then paint nothing, so the speculative S6/S7 is skipped.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func run(_ source: PipelinePage, models: PipelineModels, translate: PipelineTranslator,
                    hooks: PipelineHooks = PipelineHooks()) async -> PipelinePageResult {
        let started = DispatchTime.now().uptimeNanoseconds
        // Every stage uses the capped page; the reader shows the output aspect-fit, so a
        // smaller same-aspect bitmap displays the same.
        guard let page = cappedPage(source) else {
            return PipelinePageResult(pageID: source.id, blocks: [], placed: [], output: source.image,
                                timings: PipelineTimings(), failure: "decode: page exceeds the pixel cap and could not be downscaled")
        }
        var timings = PipelineTimings()
        var failures: [String] = []
        let pageSize = CGSize(width: page.width, height: page.height)

        // S1 || S2 (after one shared pixel decode).
        var front = await timings.record(Stage.parallel) { await runFront(page, models: models) }
        timings.stages.merge(front.stages) { $0 + $1 }
        failures += front.failures
        // A page cancelled during S1 || S2 (result discarded) skips S3/S4 and the rest.
        if Task.isCancelled {
            return PipelinePageResult(pageID: page.id, blocks: [], placed: [], output: page.image, timings: timings,
                                failure: (failures + ["cancelled"]).joined(separator: "; "))
        }
        let layout = front.layout
        let lines = await timings.record(Stage.assemble) { PipelineLineAssembly.assemble(front.lines, layout: layout) }

        // S3
        var read: [PipelineLine] = []
        do {
            read = try await timings.record(Stage.recognize) {
                if let frame = front.frame {
                    return try await PipelineRecognition.recognize(frame: frame, lines: lines, engine: models.recognition,
                                                             rank: hooks.recognitionRank)
                }
                return try await PipelineRecognition.recognize(page, lines: lines, engine: models.recognition,
                                                         rank: hooks.recognitionRank)
            }
        } catch { failures.append("s3: \(error)") }

        // S4
        let classified = await timings.record(Stage.group) {
            let grouped = PipelineGrouping.group(read, layout: layout, pageSize: pageSize, raster: front.gray,
                                           direction: page.readingDirection)
            return PipelineRoleFilter.classify(grouped, layout: layout)
        }
        // S5 (LLM or replay) reads only the S4 text, bounds and roles: it starts before S4b, whose
        // fields are put back on its result below.
        async let translated: (result: Result<[PipelineBlock], Error>, ms: Double) = {
            let start = DispatchTime.now().uptimeNanoseconds
            do { return (.success(try await translate(page, classified)), milliseconds(since: start)) } catch {
                return (.failure(error), milliseconds(since: start))
            }
        }()
        var blocks = await timings.record(Stage.group) {
            PipelineInterior.apply(classified, raster: front.gray, pageSize: pageSize, layout: layout)
        }
        timings.stages[Stage.front] = milliseconds(since: started)
        hooks.frontFinished()
        // Only S2-S4 read the frame and gray raster; free them before the provider wait.
        front.frame = nil
        front.gray = nil

        // S5 (LLM or replay) || S8 -> S6 -> S7 (S6/S7 on the predicted paint set).
        let candidates = blocks
        let predicted = hooks.predictTranslated?(candidates)
        let translateFailed = Flag()
        // Only the back branch reads the page raster: it is freed when that ends, not held across
        // the provider wait; a speculation miss decodes the same bytes again.
        let backInput = BackInput(layout: front.layout, raster: front.raster)
        front.raster = nil
        async let overlapped = runBack(page, blocks: candidates, predicted: predicted, input: backInput, models: models,
                                       hooks: hooks, stop: translateFailed)
        let (translation, translateMilliseconds) = await translated
        switch translation {
        case .success(let output):
            let interior = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            blocks = PipelineRoleFilter.rescuingSpeech(output, layout: layout).map { block in
                guard let source = interior[block.id] else { return block }
                var block = block
                block.balloon = source.balloon
                block.rows = source.rows
                block.panel = source.panel
                return block
            }
        case .failure(let error):
            translateFailed.raise()
            failures.append("s5: \(error)")
        }
        timings.stages[Stage.translate] = translateMilliseconds
        var back = await overlapped
        withExtendedLifetime(backInput) {}
        timings.stages.merge(back.stages) { $0 + $1 }
        if let failure = back.failure { failures.append(failure) }

        let tailStart = DispatchTime.now().uptimeNanoseconds
        var admitted = false
        // S8 and S6/S7 results stay valid when S5 changed nothing they read (style is read by neither check).
        let styleReused = back.styled.map { styled in
            styled.count == blocks.count && zip(styled, blocks).allSatisfy { styleInput($0) == styleInput($1) }
        } ?? false
        let paintableBlocks = blocks.filter(PipelineLayout.isPaintable)
        let speculationHit = back.erased != nil && back.paintable.map(eraseInput) == paintableBlocks.map(eraseInput)
        // Nothing to erase or paint (no text, or S5 failed), or a visible page whose S6-S8 results
        // all stand: the cheap rest needs no back slot, so it never queues behind another page's S6/S7.
        if !paintableBlocks.isEmpty, !(styleReused && speculationHit && hooks.isForeground()) {
            do {
                try await hooks.acquireBack()
                admitted = true
            } catch { failures.append("back: \(error)") }
        }
        // A cancelled page (result discarded) skips the tail, which could run unadmitted.
        if Task.isCancelled {
            if admitted { hooks.releaseBack() }
            failures.append("cancelled")
            timings.stages[Stage.tail] = milliseconds(since: tailStart)
            return PipelinePageResult(pageID: page.id, blocks: blocks, placed: [], output: page.image,
                                timings: timings, failure: failures.joined(separator: "; "))
        }

        // S8 result: reused when S5 changed nothing S8 reads.
        if styleReused, let styled = back.styled {
            blocks = zip(blocks, styled).map { block, measured in
                var block = block
                block.style = measured.style
                return block
            }
        } else {
            let unstyled = blocks
            blocks = await timings.record(Stage.style) { PipelineStyle.estimate(page, blocks: unstyled) }
        }

        // (S6 -> S7, only when the prediction missed) || S9
        let paintable = blocks.filter(PipelineLayout.isPaintable)
        let finalBlocks = blocks
        async let placement: (placed: [PipelinePlacedText], ms: Double) = {
            let start = DispatchTime.now().uptimeNanoseconds
            let placed = paintable.isEmpty ? [] : PipelineLayout.place(paintable, pageSize: pageSize)
            return (placed, milliseconds(since: start))
        }()
        var erased: Erased?
        if !paintable.isEmpty {
            if speculationHit, let speculative = back.erased {
                erased = speculative
            } else {
                timings.stages[Stage.speculationMiss] = 1
                // Free the stale speculative background and mask before recomputing them.
                back.erased = nil
                let recomputed = await erase(page, paintable: paintable, layout: layout,
                                             raster: decodePixels(page.image).raster.map(PipelineRasterHandoff.init), models: models)
                timings.stages.merge(recomputed.stages) { $0 + $1 }
                erased = recomputed
            }
            if let failure = erased?.failure { failures.append(failure) }
        }
        let (placed, placeMilliseconds) = await placement
        timings.stages[Stage.place, default: 0] += placeMilliseconds

        // S10. Without a restored background the source pixels stay untouched.
        var output = page.image
        var painted: [PipelinePlacedText] = []
        var restored: CGImage?
        if var pixels = erased?.restored?.take()?.rgba {
            // The only reference to the restored bytes: S10 paints over them in place, no page copy.
            restored = await timings.record(Stage.paint) {
                PipelinePainter.paint(pixels: &pixels, width: page.width, height: page.height, blocks: finalBlocks, placed: placed)
            }
        } else if let background = erased?.background {
            restored = await timings.record(Stage.paint) { PipelinePainter.paint(background: background, blocks: finalBlocks, placed: placed) }
        }
        if let restored {
            painted = placed
            output = restored
            let placedIDs = Set(placed.map(\.blockID))
            let unplaced = paintable.filter { !placedIDs.contains($0.id) }.count
            if unplaced > 0 { failures.append("s9: \(unplaced) erased block(s) not placed") }
        }
        if admitted { hooks.releaseBack() }
        timings.stages[Stage.tail] = milliseconds(since: tailStart)
        let total = milliseconds(since: started)
        timings.stages[Stage.total] = total
        timings.stages[Stage.nonLLM] = total - translateMilliseconds
        return PipelinePageResult(pageID: page.id, blocks: finalBlocks, placed: painted, output: output,
                            timings: timings,
                            failure: failures.isEmpty ? nil : failures.joined(separator: "; "))
    }

    /// The same page within `maxPixels`, else downscaled with its aspect kept; nil when
    /// the smaller raster cannot be allocated.
    static func cappedPage(_ page: PipelinePage, maxPixels: Int = ImagePixelCap.maxPixels) -> PipelinePage? {
        guard ImagePixelCap.exceeds(width: page.width, height: page.height, maxPixels: maxPixels) else { return page }
        guard let image = ImagePixelCap.downscaled(page.image, maxPixels: maxPixels) else { return nil }
        return PipelinePage(id: page.id, image: image, readingDirection: page.readingDirection)
    }

    /// The block fields S8 reads: everything except S5's translation/role and S8's own output.
    static func styleInput(_ block: PipelineBlock) -> PipelineBlock {
        var block = block
        block.translation = nil
        block.role = .dialogue
        block.style = nil
        return block
    }

    /// The block fields S6/S7 read for a paintable (non-background) block: all but the translation,
    /// S8's style and the dialogue/sfx distinction.
    static func eraseInput(_ block: PipelineBlock) -> PipelineBlock {
        var block = block
        block.translation = nil
        block.style = nil
        if block.role != .background { block.role = .dialogue }
        return block
    }

    private static func runBack(_ page: PipelinePage, blocks: [PipelineBlock], predicted: Set<Int>?, input: BackInput,
                                models: PipelineModels, hooks: PipelineHooks, stop: Flag) async -> Back {
        let start = DispatchTime.now().uptimeNanoseconds
        // Owned here from now on: S8's reference is dropped when it ends, the handoff's by S7.
        var raster = input.takeRaster()
        let handoff = raster.map(PipelineRasterHandoff.init)
        let layout = input.layout
        var back = Back()
        // A page without text has nothing to measure or erase: no back slot wait.
        if blocks.isEmpty {
            back.styled = []
            back.stages[Stage.back] = milliseconds(since: start)
            return back
        }
        // Not admitted (the tail then recomputes everything after S5) or cancelled.
        let admitted = (try? await hooks.acquireBack()) != nil
        guard admitted, !Task.isCancelled else {
            if admitted { hooks.releaseBack() }
            back.stages[Stage.back] = milliseconds(since: start)
            return back
        }
        var timings = PipelineTimings()
        // S6/S7 do not read S8's style, so S8 runs alongside them instead of before.
        let paintable = blocks.filter { $0.role != .background && (predicted?.contains($0.id) ?? true) }
        back.paintable = paintable
        // Skipped when the page was cancelled or S5 already failed (the result would be discarded).
        async let erased: Erased? = paintable.isEmpty || Task.isCancelled || stop.isRaised ? nil
            : erase(page, paintable: paintable, layout: layout, raster: handoff, models: models)
        back.styled = await timings.record(Stage.style) { PipelineStyle.estimate(page, blocks: blocks, raster: raster) }
        // S7 then restores into the page bytes instead of a copy.
        raster = nil
        back.erased = await erased
        withExtendedLifetime(handoff) {}
        hooks.releaseBack()
        back.stages = timings.stages
        if let erased = back.erased { back.stages.merge(erased.stages) { $0 + $1 } }
        back.stages[Stage.back] = milliseconds(since: start)
        return back
    }

    private static func erase(_ page: PipelinePage, paintable: [PipelineBlock], layout: [PipelineLayoutRegion],
                              raster: PipelineRasterHandoff?, models: PipelineModels) async -> Erased {
        var timings = PipelineTimings()
        var erased = Erased()
        let removal = await timings.record(Stage.mask) {
            // The shared raster holds exactly the bytes PipelineRemovalMask would convert itself.
            if let raster = raster?.current {
                return PipelineRemovalMask.build(rgba: raster.rgba, width: raster.width, height: raster.height,
                                           blocks: paintable, layout: layout, net: models.removalMask)
            }
            return PipelineRemovalMask.build(page, blocks: paintable, layout: layout, net: models.removalMask)
        }
        removalObserver?(page.id, page.width, page.height, removal, paintable.map(\.id))
        do {
            (erased.restored, erased.background) = try await timings.record(Stage.inpaint) {
                () async throws -> (PipelineRasterHandoff?, CGImage?) in
                guard removal.count == page.width * page.height else { throw PipelineFailure.maskSize }
                if let raster {
                    let pixels = try await PipelineInpaint.restorePixels(raster, mask: removal, models: models)
                    return (PipelineRasterHandoff(PipelinePageRaster(width: page.width, height: page.height, rgba: pixels)), nil)
                }
                return (nil, try await PipelineInpaint.restore(page, mask: removal, models: models))
            }
        } catch { erased.failure = "s7: \(error)" }
        erased.stages = timings.stages
        return erased
    }

    private static func runFront(_ page: PipelinePage, models: PipelineModels) async -> Front {
        var front = Front()
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        let pixels = decodePixels(page.image)
        front.stages[Stage.decode] = milliseconds(since: decodeStart)
        // Started after the decode: a lazily decoded page then reuses ImageIO's decoded pixels instead of
        // parking a pool thread on the decode lock (same bytes either way).
        async let gray: PipelineGrayRaster? = PipelineGrayRaster(image: page.image)
        front.stages[Stage.conversions] = Double(pixels.conversions)
        let frame = pixels.frame
        // One RGBA frame feeds both the detector and the recognizer (S3 reuses it).
        async let detected: (Result<[PipelineLine], Error>, Double) = {
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                let lines = if let frame {
                    try await PipelineDetection.detect(frame: frame, models: models)
                } else {
                    try await PipelineDetection.detect(page, models: models)
                }
                return (.success(lines), milliseconds(since: start))
            } catch { return (.failure(error), milliseconds(since: start)) }
        }()
        front.raster = pixels.raster
        if let decoded = pixels.raster {
            let start = DispatchTime.now().uptimeNanoseconds
            do { front.layout = try await PipelineLayoutDetection.detect(decoded, models: models) }
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

    /// Decodes the page once: for an opaque sRGB page the detector frame and the canonical
    /// raster are the same bytes, so one buffer serves S1-S7; others pay a second conversion.
    static func decodePixels(_ image: CGImage)
        -> (raster: PipelinePageRaster?, frame: NativeOCRRGBAFrame?, conversions: Int) {
        let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: image)
        if let frame, canShare(image, frame: frame) {
            return (PipelinePageRaster(width: frame.width, height: frame.height, rgba: frame.bytes), frame, 1)
        }
        return (try? PipelinePageRaster(image), frame, frame == nil ? 1 : 2)
    }

    static func canShare(_ image: CGImage, frame: NativeOCRRGBAFrame) -> Bool {
        guard frame.width <= 16_384, frame.height <= 16_384, frame.bytesPerRow == frame.width * 4,
              image.colorSpace?.name == CGColorSpace.sRGB else { return false }
        // An alpha-free source draws fully opaque: no scan needed.
        if !image.isMask, [.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo) { return true }
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

enum PipelineFailure: Error { case maskSize }
