import CoreGraphics
@preconcurrency import CoreML
import Foundation

// S3: PP-OCRv6 manga line recognition. One `MLModel` handle serializes predictions, so a
// resident pool of handles predicts exact-width crops longest-first in parallel. Every step
// after the padded crop (tensor, compact top-k, n-gram CTC decode, 0.30 gate) matches legacy.

/// Resident recognizer state. `PipelineModels` owns one instance for the process.
@available(iOS 18.0, *)
final class PipelineRecognitionEngine: @unchecked Sendable {
    static let modelResourceName = "PP-OCRv6-Manga-RecWidths"
    static let dictionaryResourceName = "ppocrv6_manga_rec_character_dict"
    static let languageModelResourceName = "manga_ngram_v03"
    static let expectedDictionaryCharacterCount = 19_054

    /// About 180 MB and 1.2 busy cores per handle: on macOS every core but four (left to other
    /// stages) gets one, at most ten (six below 16 GB); iOS keeps the legacy two, three on >= 7 GB.
    static var defaultHandleCount: Int {
#if os(macOS)
        min(ProcessInfo.processInfo.physicalMemory >= 16 * 1_024 * 1_024 * 1_024 ? 10 : 6,
            max(2, ProcessInfo.processInfo.activeProcessorCount - 4))
#else
        ProcessInfo.processInfo.physicalMemory >= 7 * 1_024 * 1_024 * 1_024
            ? min(3, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) : 2
#endif
    }

    enum Failure: Error, Equatable {
        case resourceMissing(String)
        case dictionaryMalformed(line: Int)
        case dictionaryCharacterCount(expected: Int, actual: Int)
        case imageConversionFailed
        case modelOutputMissing
    }

    let dictionary: [String]
    let languageModel: NativeMangaNGram?
    /// The normal (full) handle count; idle time and memory warnings shrink the pool below it.
    let handleCount: Int
    /// Resident handles, checked out per crop. Holds the only strong references, so a shed
    /// handle is freed once it is free (never while a crop is using it).
    let pool: PipelineHandlePool<MLModel>
    /// iOS sheds to one handle after this much time without page work; the Mac host keeps its count.
#if os(macOS)
    static let idleSeconds: Double? = nil
#else
    static let idleSeconds: Double? = 45
#endif

    /// `modelURL` is a compiled `.mlmodelc` (or an `.mlpackage`, compiled here).
    init(modelURL: URL, dictionaryURL: URL, languageModelURL: URL?) throws {
        let compiledURL = modelURL.pathExtension == "mlmodelc"
            ? modelURL : try MLModel.compileModel(at: modelURL)
        // Raw DEFLATE (NSData .zlib); keeps the 19k-line table out of text diffs.
        dictionary = try Self.parseDictionary(
            (Data(contentsOf: dictionaryURL, options: .mappedIfSafe) as NSData).decompressed(using: .zlib) as Data)
        guard dictionary.count == Self.expectedDictionaryCharacterCount else {
            throw Failure.dictionaryCharacterCount(expected: Self.expectedDictionaryCharacterCount,
                                                   actual: dictionary.count)
        }
        languageModel = try languageModelURL.map {
            try NativeMangaNGram(data: Data(contentsOf: $0, options: .mappedIfSafe))
        }
        let count = Self.defaultHandleCount
        // The legacy configuration: every compute unit, frequent reshapes.
        let configuration = MLModelConfiguration()
#if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
#else
        configuration.computeUnits = .all
#endif
        configuration.optimizationHints.reshapeFrequency = .frequent
        configuration.optimizationHints.specializationStrategy = .fastPrediction
        configuration.modelDisplayName = "PP-OCRv6 Dynamic Width V2"
        // Separate loads are separate runtimes; one handle serializes work. All start at once; the
        // engine is ready after the first `readyCount` (the rest join the pool as they finish).
        let arrivals = Arrivals(ready: Self.readyHandleCount(count))
        for _ in 0..<count {
            DispatchQueue.global(qos: .userInitiated).async {
                arrivals.arrive(Result {
                    let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
                    // Its cold first prediction right away, overlapping the other handles' loads.
                    try? PipelineRecognition.warmUpSync(model)
                    return model
                })
            }
        }
        let initial = try arrivals.waitForReady()
        pool = PipelineHandlePool(initial, capacity: count, idleSeconds: Self.idleSeconds) {
            // Same URL and configuration as the initial handles, so a regrown handle reads identically.
            let model: MLModel? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: try? MLModel(contentsOf: compiledURL, configuration: configuration))
                }
            }
            guard let model else { return nil }
            try? await PipelineRecognition.warmUp(model)
            return model
        }
        handleCount = count
        arrivals.forward(to: pool)
    }

    /// Handles the engine waits for before it is ready: all of them on iOS (two or three); on macOS
    /// at most four of the ten, as the concurrent loads finish one after another.
    static func readyHandleCount(_ count: Int) -> Int {
#if os(macOS)
        min(count, 4)
#else
        count
#endif
    }

    static func load(bundle: Bundle = .main) throws -> PipelineRecognitionEngine {
        func find(_ name: String, _ extensions: [String]) -> URL? {
            extensions.lazy.compactMap { bundle.url(forResource: name, withExtension: $0) }.first
        }
        guard let model = find(modelResourceName, ["mlmodelc", "mlpackage"]) else {
            throw Failure.resourceMissing(modelResourceName)
        }
        guard let dictionary = find(dictionaryResourceName, ["deflate"]) else {
            throw Failure.resourceMissing(dictionaryResourceName)
        }
        return try PipelineRecognitionEngine(modelURL: model, dictionaryURL: dictionary,
            languageModelURL: find(languageModelResourceName, ["bin"]))
    }

    /// Memory warning: drop to one handle now and do not regrow for a while.
    func shed() { Task { await pool.shrink(cooldownSeconds: 60) } }

    /// `rank` (lower first, read when a handle frees) orders pages that wait for a handle.
    func withHandle<T>(rank: @escaping @Sendable () -> Int = { 0 }, _ body: (MLModel) async throws -> T) async throws -> T {
        let model = await pool.acquire(rank: rank)
        do {
            let value = try await body(model)
            await pool.release(model)
            return value
        } catch {
            await pool.release(model)
            throw error
        }
    }

    /// Same format and rules as the legacy dictionary resource parser: one
    /// JSON string literal per line, optional BOM, trailing newline.
    static func parseDictionary(_ data: Data) throws -> [String] {
        guard var text = String(data: data, encoding: .utf8) else { throw Failure.dictionaryMalformed(line: 1) }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var characters: [String] = []
        characters.reserveCapacity(rawLines.count)
        let decoder = JSONDecoder()
        for (offset, rawLine) in rawLines.enumerated() {
            if offset == rawLines.count - 1, rawLine.isEmpty { continue }
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let bytes = line.utf8
            if bytes.count >= 2, bytes.first == UInt8(ascii: "\""), bytes.last == UInt8(ascii: "\"") {
                let token = bytes.dropFirst().dropLast()
                if token.allSatisfy({ $0 >= 0x20 && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "\\") }) {
                    characters.append(String(decoding: token, as: UTF8.self))
                    continue
                }
            }
            guard let value = try? decoder.decode(String.self, from: Data(line.utf8)) else {
                throw Failure.dictionaryMalformed(line: offset + 1)
            }
            characters.append(value)
        }
        return characters
    }

    /// The initial handle loads: `waitForReady` returns the handles finished once `ready` have
    /// (throwing the first error among them); each later one joins the pool `forward` names.
    private final class Arrivals: @unchecked Sendable {
        private let condition = NSCondition()
        private let ready: Int
        private var models: [MLModel] = []
        private var error: Error?
        private var finished = 0
        private var handedOut = false
        private var late: [MLModel?] = []
        private var pool: PipelineHandlePool<MLModel>?

        init(ready: Int) { self.ready = ready }

        func arrive(_ result: Result<MLModel, Error>) {
            condition.lock()
            guard handedOut else {
                finished += 1
                switch result {
                case .success(let model): models.append(model)
                case .failure(let failure): if error == nil { error = failure }
                }
                condition.broadcast()
                condition.unlock()
                return
            }
            let model = try? result.get()
            guard let pool else {
                late.append(model)
                condition.unlock()
                return
            }
            condition.unlock()
            Task { await pool.deliver(model) }
        }

        func waitForReady() throws -> [MLModel] {
            condition.lock()
            defer { condition.unlock() }
            while finished < ready { condition.wait() }
            if let error { throw error }
            handedOut = true
            defer { models = [] }
            return models
        }

        func forward(to pool: PipelineHandlePool<MLModel>) {
            condition.lock()
            self.pool = pool
            let early = late
            late = []
            condition.unlock()
            for model in early { Task { await pool.deliver(model) } }
        }
    }
}

/// Exclusive handle checkout shared by concurrent pages: a freed handle goes to the best-ranked
/// waiter, FIFO within a rank. `shrink` (idle or memory pressure) keeps one handle: free extras
/// go at once, checked-out ones when they come back. The next checkout regrows the pool to its
/// capacity in the background (one load per missing handle) while pages run on what stayed.
actor PipelineHandlePool<Element: AnyObject> {
    let capacity: Int
    private var free: [Element]
    private var waiters: [(rank: @Sendable () -> Int, continuation: CheckedContinuation<Element, Never>)] = []
    /// Handles alive (free or checked out), loads in flight, and the current allowed count.
    private(set) var resident: Int
    private(set) var loading = 0
    private var limit: Int
    /// Checkouts held or awaited; idle means zero.
    private var busy = 0
    private var idleSince = DispatchTime.now().uptimeNanoseconds
    private var growAfter: UInt64 = 0
    private var idleTask: Task<Void, Never>?
    private let idleNanoseconds: UInt64?
    private let load: @Sendable () async -> Element?

    /// `capacity` above `elements.count`: that many loads are already in flight, each ending in `deliver`.
    init(_ elements: [Element], capacity: Int? = nil, idleSeconds: Double?, load: @escaping @Sendable () async -> Element?) {
        precondition(!elements.isEmpty)
        free = elements
        self.capacity = max(elements.count, capacity ?? elements.count)
        resident = elements.count
        loading = self.capacity - elements.count
        limit = self.capacity
        idleNanoseconds = idleSeconds.map { UInt64($0 * 1_000_000_000) }
        self.load = load
    }

    func acquire(rank: @escaping @Sendable () -> Int) async -> Element {
        busy += 1
        grow()
        if let element = free.popLast() { return element }
        return await withCheckedContinuation { waiters.append((rank, $0)) }
    }

    func release(_ element: Element) {
        busy -= 1
        if resident > limit {
            // Shed: dropping it frees the handle; the others serve any waiter.
            resident -= 1
        } else {
            give(element)
        }
        if busy == 0 { becameIdle() }
    }

    /// Down to one handle; `cooldownSeconds` keeps checkouts from regrowing it that long.
    func shrink(cooldownSeconds: Double = 0) {
        limit = 1
        let drop = min(free.count, resident - limit)
        if drop > 0 {
            free.removeLast(drop)
            resident -= drop
        }
        growAfter = max(growAfter, now() + UInt64(cooldownSeconds * 1_000_000_000))
    }

    private func grow() {
        if limit < capacity, now() >= growAfter { limit = capacity }
        let missing = limit - resident - loading
        guard missing > 0 else { return }
        loading += missing
        for _ in 0..<missing {
            Task.detached(priority: .userInitiated) { [load] in
                let element = await load()
                await self.loaded(element)
            }
        }
    }

    /// A load started outside the pool (see `init`) finished; nil when it failed.
    func deliver(_ element: Element?) { loaded(element) }

    private func loaded(_ element: Element?) {
        loading -= 1
        guard let element else {
            // A failed load waits a minute instead of retrying on every crop.
            growAfter = now() + 60_000_000_000
            return
        }
        guard resident < limit else { return }
        resident += 1
        give(element)
    }

    private func give(_ element: Element) {
        guard !waiters.isEmpty else { free.append(element); return }
        let ranks = waiters.map { $0.rank() }
        let best = ranks.indices.min { ranks[$0] == ranks[$1] ? $0 < $1 : ranks[$0] < ranks[$1] } ?? 0
        waiters.remove(at: best).continuation.resume(returning: element)
    }

    private func becameIdle() {
        idleSince = now()
        guard let idle = idleNanoseconds, idleTask == nil, resident > 1 else { return }
        idleTask = Task { [weak self] in
            var wait = idle
            while true {
                try? await Task.sleep(nanoseconds: wait)
                guard let self, let next = await self.idleCheck(idle) else { return }
                wait = next
            }
        }
    }

    /// Nil ends the timer (shrunk, or busy again: the next idle restarts it); else the time left.
    private func idleCheck(_ idle: UInt64) -> UInt64? {
        let elapsed = now() - idleSince
        guard busy == 0, elapsed < idle else {
            if busy == 0 { shrink() }
            idleTask = nil
            return nil
        }
        return idle - elapsed
    }

    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

@available(iOS 18.0, *)
enum PipelineRecognition {
    /// The legacy manga acceptance gate (`IPhoneOCRSettings.mangaConfidenceThreshold`).
    static let minimumConfidence = IPhoneOCRSettings.mangaConfidenceThreshold

    struct Read: Sendable, Equatable {
        var text: String
        var confidence: Double
    }

    /// The accepted lines (non-empty text, confidence >= `minimumConfidence`) in input order.
    static func recognize(_ page: PipelinePage, lines: [PipelineLine], engine: PipelineRecognitionEngine,
                          rank: @escaping @Sendable () -> Int = { 0 }) async throws -> [PipelineLine] {
        guard !lines.isEmpty else { return [] }
        guard let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: page.image) else {
            throw PipelineRecognitionEngine.Failure.imageConversionFailed
        }
        return try await recognize(frame: frame, lines: lines, engine: engine, rank: rank)
    }

    /// Frame overload so the orchestrator can share the detector's RGBA frame. Handles are
    /// checked out per crop, so a better-ranked page (the visible one) takes every handle
    /// within one crop instead of sharing them with a look-ahead page for the whole stage.
    static func recognize(frame: NativeOCRRGBAFrame, lines: [PipelineLine], engine: PipelineRecognitionEngine,
                          rank: @escaping @Sendable () -> Int = { 0 }) async throws -> [PipelineLine] {
        let plans = lines.map { plan($0.polygon) }
        // Longest crops first: cost is linear in width, so this balances the lanes (LPT).
        let order = plans.indices.filter { plans[$0] != nil }
            .sorted { (plans[$0]!.bucket.width, $1) > (plans[$1]!.bucket.width, $0) }
        guard !order.isEmpty else { return [] }
        let queue = WorkQueue(order)
        let lanes = min(engine.handleCount, order.count)
        var reads = [Read?](repeating: nil, count: lines.count)
        try await withThrowingTaskGroup(of: [(Int, Read?)].self) { group in
            for _ in 0..<lanes {
                group.addTask(priority: .userInitiated) {
                    var results: [(Int, Read?)] = []
                    while true {
                        let read = try await engine.withHandle(rank: rank) { model -> (Int, Read?)? in
                            guard let index = queue.next() else { return nil }
                            try Task.checkCancellation()
                            return (index, try await predict(plans[index]!, frame: frame, model: model, engine: engine))
                        }
                        guard let read else { return results }
                        results.append(read)
                    }
                }
            }
            for try await results in group {
                for (index, read) in results { reads[index] = read }
            }
        }
        return zip(lines, reads).compactMap { line, read in
            guard let read, !read.text.isEmpty, read.confidence >= minimumConfidence else { return nil }
            var output = line
            output.text = read.text
            output.confidence = Float(read.confidence)
            return output
        }
    }

    /// Legacy crop plan for the full-frame manga policy (dynamic width, publisher width rule,
    /// reading-order quad) on the padded line polygon.
    static func plan(_ polygon: [CGPoint]) -> NativeCoreMLRecognitionPreprocessor.Plan? {
        // A text line (long side >= 1.5 x short) is padded 5% of its short side: tight boxes
        // clip edge strokes. Squarish boxes keep the exact crop (padding lets SFX pass the gate).
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        let short = min(x1 - x0, y1 - y0)
        let pad = max(x1 - x0, y1 - y0) >= 1.5 * short ? short / 20 : 0
        let polygon = polygon.map {
            CGPoint(x: $0.x + ($0.x < (x0 + x1) / 2 ? -pad : pad), y: $0.y + ($0.y < (y0 + y1) / 2 ? -pad : pad))
        }
        let ordered = polygon.count == 4 ? NativeOCRDirectionGeometry.readingQuad(polygon) : nil
        if polygon.count == 4, ordered == nil { return nil }
        return NativeCoreMLRecognitionPreprocessor.plan(polygon: ordered ?? polygon)
    }

    private static func predict(_ plan: NativeCoreMLRecognitionPreprocessor.Plan, frame: NativeOCRRGBAFrame,
                                model: MLModel, engine: PipelineRecognitionEngine) async throws -> Read? {
        guard let tensor = NativeCoreMLRecognitionPreprocessor.prepare(frame: frame, plan: plan) else { return nil }
        let width = tensor.bucket.width
        let input = try MLMultiArray(shape: [1, 3, 48, NSNumber(value: width)], dataType: .float32)
        guard input.strides.map(\.intValue) == [3 * 48 * width, 48 * width, width, 1],
              tensor.values.count == 3 * 48 * width else { throw PipelineRecognitionEngine.Failure.modelOutputMissing }
        tensor.values.withUnsafeBufferPointer { source in
            input.dataPointer.copyMemory(from: source.baseAddress!, byteCount: source.count * MemoryLayout<Float>.stride)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
        let output = try await model.prediction(from: provider)
        let compact = try pack(output, timeSteps: tensor.bucket.timeSteps)
        let decoded = try NativeCoreMLCTCDecoder.decode(
            output: compact, dictionary: engine.dictionary, expectedShape: [1, tensor.bucket.timeSteps],
            languageModel: engine.languageModel)
        return Read(text: decoded.text, confidence: decoded.confidence)
    }

    /// A regrown handle's first (cold, about 0.3 s) prediction, on a blank 32 x 300 vertical line.
    static func warmUp(_ model: MLModel) async throws {
        let polygon = [CGPoint(x: 16, y: 50), CGPoint(x: 48, y: 50), CGPoint(x: 48, y: 350), CGPoint(x: 16, y: 350)]
        guard let plan = plan(polygon) else { return }
        let input = try MLMultiArray(shape: [1, 3, 48, NSNumber(value: plan.bucket.width)], dataType: .float32)
        _ = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)]))
    }

    /// `warmUp(_:)` for a handle not yet shared (synchronous; on its loading thread).
    static func warmUpSync(_ model: MLModel) throws {
        let polygon = [CGPoint(x: 16, y: 50), CGPoint(x: 48, y: 50), CGPoint(x: 48, y: 350), CGPoint(x: 16, y: 350)]
        guard let plan = plan(polygon) else { return }
        let input = try MLMultiArray(shape: [1, 3, 48, NSNumber(value: plan.bucket.width)], dataType: .float32)
        _ = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)]))
    }

    /// Legacy compact layout: row 0 indices, row 1 scores, then four
    /// (index, score) top-k row pairs consumed by the n-gram arbiter.
    static func pack(_ output: MLFeatureProvider, timeSteps: Int) throws -> MLMultiArray {
        guard let indices = output.featureValue(for: "ctc_indices")?.multiArrayValue,
              let scores = output.featureValue(for: "ctc_scores")?.multiArrayValue,
              indices.shape.map(\.intValue) == [1, timeSteps], scores.shape.map(\.intValue) == [1, timeSteps],
              indices.dataType == .int32, scores.dataType == .float32 else {
            throw PipelineRecognitionEngine.Failure.modelOutputMissing
        }
        let topIndices = output.featureValue(for: "ctc_topk_indices")?.multiArrayValue
        let topScores = output.featureValue(for: "ctc_topk_scores")?.multiArrayValue
        let alternatives = topIndices != nil && topScores != nil ? 4 : 0
        if let topIndices, let topScores {
            let shape = [1, timeSteps, alternatives]
            guard topIndices.shape.map(\.intValue) == shape, topScores.shape.map(\.intValue) == shape,
                  topIndices.dataType == .int32, topScores.dataType == .float32 else {
                throw PipelineRecognitionEngine.Failure.modelOutputMissing
            }
        }
        let compact = try MLMultiArray(shape: [NSNumber(value: 2 + alternatives * 2), NSNumber(value: timeSteps)],
                                       dataType: .float32)
        let destination = compact.dataPointer.assumingMemoryBound(to: Float.self)
        let row = compact.strides[0].intValue, column = compact.strides[1].intValue
        // Copied under the array's lock: a GPU-backed output is only coherent inside withUnsafeBufferPointer.
        let index = indices.withUnsafeBufferPointer(ofType: Int32.self) { Array($0) }
        let score = scores.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        let indexStride = indices.strides[1].intValue, scoreStride = scores.strides[1].intValue
        for step in 0..<timeSteps {
            destination[step * column] = Float(index[step * indexStride])
            destination[row + step * column] = score[step * scoreStride]
        }
        if let topIndices, let topScores {
            let ti = topIndices.withUnsafeBufferPointer(ofType: Int32.self) { Array($0) }
            let ts = topScores.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
            let iStrides = topIndices.strides.map(\.intValue), sStrides = topScores.strides.map(\.intValue)
            for rank in 0..<alternatives {
                let indexRow = destination + (2 + rank * 2) * row, scoreRow = indexRow + row
                for step in 0..<timeSteps {
                    indexRow[step * column] = Float(ti[rank * iStrides[2] + step * iStrides[1]])
                    scoreRow[step * column] = ts[rank * sStrides[2] + step * sStrides[1]]
                }
            }
        }
        return compact
    }

    private final class WorkQueue: @unchecked Sendable {
        private let lock = NSLock()
        private let items: [Int]
        private var cursor = 0
        init(_ items: [Int]) { self.items = items }
        func next() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard cursor < items.count else { return nil }
            cursor += 1
            return items[cursor - 1]
        }
    }
}
