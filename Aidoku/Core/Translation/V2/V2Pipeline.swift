import CoreGraphics
import Foundation

// V2 orchestrator for one page:
//   decode -> S1 layout || S2 detect -> S2b assemble -> S3 recognize -> S4 group + roles
//   -> S5 translate || (S8 style -> S6 mask -> S7 inpaint) -> S9 layout -> S10 paint
// S8/S6/S7 do not read translations, so they run during the LLM call (S8 on every S4 block,
// S6/S7 on the predicted paint set); S6/S7 are recomputed when S5 paints a different set,
// S8 when S5 changed a field it reads. A failed stage keeps the original pixels of the blocks
// it affects and is reported in `V2PageResult.failure`.

/// Fills `translation` (and may refine `role`): live `V2Translation.translate` or a replay.
typealias V2Translator = @Sendable (_ page: V2Page, _ blocks: [V2Block]) async throws -> [V2Block]

/// Admission hooks around the non-LLM compute phases; the defaults admit everything.
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
    /// The page's current scheduling rank (lower first) for shared S3 recognizer handles.
    var recognitionRank: @Sendable () -> Int = { 0 }
    /// Whether the page is visible now: its tail skips the back slot when S5 changed nothing
    /// S6-S8 read (S9/S10 only, ~5 ms, on buffers it already holds).
    var isForeground: @Sendable () -> Bool = { false }
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

    static func run(_ source: V2Page, models: V2Models, translate: V2Translator,
                    hooks: V2PipelineHooks = V2PipelineHooks()) async -> V2PageResult {
        let started = DispatchTime.now().uptimeNanoseconds
        // Every stage uses the capped page; the reader shows the output aspect-fit, so a
        // smaller same-aspect bitmap displays the same.
        guard let page = cappedPage(source) else {
            return V2PageResult(pageID: source.id, blocks: [], placed: [], output: source.image,
                                timings: V2Timings(), failure: "decode: page exceeds the pixel cap and could not be downscaled")
        }
        var timings = V2Timings()
        var failures: [String] = []
        let pageSize = CGSize(width: page.width, height: page.height)

        // S1 || S2 (after one shared pixel decode).
        var front = await timings.record(Stage.parallel) { await runFront(page, models: models) }
        timings.stages.merge(front.stages) { $0 + $1 }
        failures += front.failures
        // A page cancelled during S1 || S2 (result discarded) skips S3/S4 and the rest.
        if Task.isCancelled {
            return V2PageResult(pageID: page.id, blocks: [], placed: [], output: page.image, timings: timings,
                                failure: (failures + ["cancelled"]).joined(separator: "; "))
        }
        let layout = front.layout
        let lines = await timings.record(Stage.assemble) { V2LineAssembly.assemble(front.lines, layout: layout) }

        // S3
        var read: [V2Line] = []
        do {
            read = try await timings.record(Stage.recognize) {
                if let frame = front.frame {
                    return try await V2Recognition.recognize(frame: frame, lines: lines, engine: models.recognition,
                                                             rank: hooks.recognitionRank)
                }
                return try await V2Recognition.recognize(page, lines: lines, engine: models.recognition,
                                                         rank: hooks.recognitionRank)
            }
        } catch { failures.append("s3: \(error)") }

        // S4
        let classified = await timings.record(Stage.group) {
            let grouped = V2Grouping.group(read, layout: layout, pageSize: pageSize, raster: front.gray,
                                           direction: page.readingDirection)
            return V2RoleFilter.classify(grouped, layout: layout)
        }
        // S5 (LLM or replay) reads only the S4 text, bounds and roles: it starts before S4b, whose
        // fields are put back on its result below.
        async let translated: (result: Result<[V2Block], Error>, ms: Double) = {
            let start = DispatchTime.now().uptimeNanoseconds
            do { return (.success(try await translate(page, classified)), milliseconds(since: start)) } catch {
                return (.failure(error), milliseconds(since: start))
            }
        }()
        var blocks = await timings.record(Stage.group) {
            V2Interior.apply(classified, raster: front.gray, pageSize: pageSize, layout: layout)
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
        async let overlapped = { [front] in
            await runBack(page, blocks: candidates, predicted: predicted, front: front, models: models, hooks: hooks,
                          stop: translateFailed)
        }()
        // Only the back branch reads the page raster: it is freed when that ends, not held across
        // the provider wait; a speculation miss decodes the same bytes again.
        front.raster = nil
        let (translation, translateMilliseconds) = await translated
        switch translation {
        case .success(let output):
            let interior = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            blocks = V2RoleFilter.rescuingSpeech(output, layout: layout).map { block in
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
        timings.stages.merge(back.stages) { $0 + $1 }
        if let failure = back.failure { failures.append(failure) }

        let tailStart = DispatchTime.now().uptimeNanoseconds
        var admitted = false
        // S8 and S6/S7 results stay valid when S5 changed nothing they read (style is read by neither check).
        let styleReused = back.styled.map { styled in
            styled.count == blocks.count && zip(styled, blocks).allSatisfy { styleInput($0) == styleInput($1) }
        } ?? false
        let paintableBlocks = blocks.filter(V2Layout.isPaintable)
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
            return V2PageResult(pageID: page.id, blocks: blocks, placed: [], output: page.image,
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
            blocks = await timings.record(Stage.style) { V2Style.estimate(page, blocks: unstyled) }
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
            if speculationHit, let speculative = back.erased {
                erased = speculative
            } else {
                timings.stages[Stage.speculationMiss] = 1
                // Free the stale speculative background and mask before recomputing them.
                back.erased = nil
                let recomputed = await erase(page, paintable: paintable, layout: layout, raster: decodePixels(page.image).raster,
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
            output = await timings.record(Stage.paint) { V2Painter.paint(background: background, blocks: finalBlocks, placed: placed) }
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
                            timings: timings,
                            failure: failures.isEmpty ? nil : failures.joined(separator: "; "))
    }

    /// The same page within `maxPixels`, else downscaled with its aspect kept; nil when
    /// the smaller raster cannot be allocated.
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

    /// The block fields S6/S7 read for a paintable (non-background) block: all but the translation,
    /// S8's style and the dialogue/sfx distinction.
    static func eraseInput(_ block: V2Block) -> V2Block {
        var block = block
        block.translation = nil
        block.style = nil
        if block.role != .background { block.role = .dialogue }
        return block
    }

    private static func runBack(_ page: V2Page, blocks: [V2Block], predicted: Set<Int>?, front: Front,
                                models: V2Models, hooks: V2PipelineHooks, stop: Flag) async -> Back {
        let start = DispatchTime.now().uptimeNanoseconds
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
        var timings = V2Timings()
        // S6/S7 do not read S8's style, so S8 runs alongside them instead of before.
        let paintable = blocks.filter { $0.role != .background && (predicted?.contains($0.id) ?? true) }
        back.paintable = paintable
        // Skipped when the page was cancelled or S5 already failed (the result would be discarded).
        async let erased: Erased? = paintable.isEmpty || Task.isCancelled || stop.isRaised ? nil
            : erase(page, paintable: paintable, layout: front.layout, raster: front.raster, models: models)
        back.styled = await timings.record(Stage.style) { V2Style.estimate(page, blocks: blocks, raster: front.raster) }
        back.erased = await erased
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
        let removal = await timings.record(Stage.mask) {
            // The shared raster holds exactly the bytes V2RemovalMask would convert itself.
            if let raster {
                return V2RemovalMask.build(rgba: raster.rgba, width: raster.width, height: raster.height,
                                           blocks: paintable, layout: layout, net: models.removalMask)
            }
            return V2RemovalMask.build(page, blocks: paintable, layout: layout, net: models.removalMask)
        }
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
                let lines = if let frame {
                    try await V2Detection.detect(frame: frame, models: models)
                } else {
                    try await V2Detection.detect(page, models: models)
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

    /// Decodes the page once: for an opaque sRGB page the detector frame and the canonical
    /// raster are the same bytes, so one buffer serves S1-S7; others pay a second conversion.
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
