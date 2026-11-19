import CoreGraphics
@preconcurrency import CoreML
import Foundation

// S3: PP-OCRv6 manga line recognition for the V2 pipeline.
//
// The legacy recognizer's text comes from exact-width batch-one predictions of
// the dynamic-width Core ML program. On every measured Apple runtime that
// program executes on the CPU (compute-unit choice, batching and reshape hints
// change nothing), and one `MLModel` handle serializes its predictions, so the
// legacy path was bounded by at most two handles, re-loaded a dropped replica
// after eight idle seconds, and gained nothing from same-width batching.
//
// V2 keeps every numeric step identical (same crop plan, sampling, tensor,
// model, compact top-k packing, n-gram corrected CTC decode and 0.30 gate)
// and only changes scheduling: a resident pool of independent handles
// predicts crops longest-first in parallel. No cache, task-local, audit
// recorder or environment switch is consulted.

/// Resident recognizer state. `V2Models` owns one instance for the process.
@available(iOS 18.0, *)
final class V2RecognitionEngine: @unchecked Sendable {
    static let modelResourceName = "PP-OCRv6-Manga-RecWidths"
    static let dictionaryResourceName = "ppocrv6_manga_rec_character_dict"
    static let languageModelResourceName = "manga_ngram_v03"
    static let expectedDictionaryCharacterCount = 19_054
    static let maximumWidth = IPhoneOCRSettings.mangaMaximumRecognizerWidth

    /// Independent handles predict concurrently; each resident handle costs
    /// about 180 MB on macOS (measured, widths up to 2400). A prediction keeps
    /// about 1.2 cores busy, so on macOS every core but four (left to the other
    /// stages of concurrent pages) gets a handle, at most ten (six below 16 GB):
    /// on a 14-core M4 Pro with three pages in flight, ten handles cut the S3
    /// median by about a quarter versus six without slowing other stages.
    /// iOS keeps the legacy two, three on >= 7 GB.
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
    let handleCount: Int
    private let pool: HandlePool

    /// `modelURL` is a compiled `.mlmodelc` (or an `.mlpackage`, compiled here).
    init(modelURL: URL, dictionaryURL: URL, languageModelURL: URL?) throws {
        let compiledURL = modelURL.pathExtension == "mlmodelc"
            ? modelURL : try MLModel.compileModel(at: modelURL)
        dictionary = try Self.parseDictionary(Data(contentsOf: dictionaryURL, options: .mappedIfSafe))
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
        // Separate loads are separate runtimes; one handle serializes work.
        let slots = LoadSlots(count: count)
        DispatchQueue.concurrentPerform(iterations: count) { index in
            slots.store(index, Result { try MLModel(contentsOf: compiledURL, configuration: configuration) })
        }
        pool = HandlePool(try slots.models())
        handleCount = count
    }

    static func load(bundle: Bundle = .main) throws -> V2RecognitionEngine {
        func find(_ name: String, _ extensions: [String]) -> URL? {
            extensions.lazy.compactMap { bundle.url(forResource: name, withExtension: $0) }.first
        }
        guard let model = find(modelResourceName, ["mlmodelc", "mlpackage"]) else {
            throw Failure.resourceMissing(modelResourceName)
        }
        guard let dictionary = find(dictionaryResourceName, ["txt"]) else {
            throw Failure.resourceMissing(dictionaryResourceName)
        }
        return try V2RecognitionEngine(modelURL: model, dictionaryURL: dictionary,
            languageModelURL: find(languageModelResourceName, ["bin"]))
    }

    func withHandle<T>(_ body: (MLModel) async throws -> T) async throws -> T {
        let model = await pool.acquire()
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

    private final class LoadSlots: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<MLModel, Error>?]
        init(count: Int) { results = Array(repeating: nil, count: count) }
        func store(_ index: Int, _ result: Result<MLModel, Error>) {
            lock.lock()
            results[index] = result
            lock.unlock()
        }
        func models() throws -> [MLModel] { try results.map { try $0!.get() } }
    }

    /// Exclusive handle checkout shared by concurrent pages.
    private actor HandlePool {
        private var free: [MLModel]
        private var waiters: [CheckedContinuation<MLModel, Never>] = []
        init(_ models: [MLModel]) { free = models }
        func acquire() async -> MLModel {
            if let model = free.popLast() { return model }
            return await withCheckedContinuation { waiters.append($0) }
        }
        func release(_ model: MLModel) {
            if waiters.isEmpty { free.append(model) } else { waiters.removeFirst().resume(returning: model) }
        }
    }
}

@available(iOS 18.0, *)
enum V2Recognition {
    /// The legacy manga acceptance gate (`IPhoneOCRSettings.mangaConfidenceThreshold`).
    static let minimumConfidence = IPhoneOCRSettings.mangaConfidenceThreshold

    struct Read: Sendable, Equatable {
        var text: String
        var confidence: Double
    }

    /// Recognizes every line; returns accepted lines (non-empty text and
    /// confidence >= `minimumConfidence`) in input order with text/confidence set.
    static func recognize(
        _ page: V2Page,
        lines: [V2Line],
        engine: V2RecognitionEngine
    ) async throws -> [V2Line] {
        guard !lines.isEmpty else { return [] }
        guard let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: page.image) else {
            throw V2RecognitionEngine.Failure.imageConversionFailed
        }
        return try await recognize(frame: frame, lines: lines, engine: engine)
    }

    /// Frame overload so the orchestrator can share the detector's RGBA frame.
    static func recognize(
        frame: NativeOCRRGBAFrame,
        lines: [V2Line],
        engine: V2RecognitionEngine
    ) async throws -> [V2Line] {
        let reads = try await read(frame: frame, polygons: lines.map(\.polygon), engine: engine)
        return zip(lines, reads).compactMap { line, read in
            guard let read, !read.text.isEmpty, read.confidence >= minimumConfidence else { return nil }
            var output = line
            output.text = read.text
            output.confidence = Float(read.confidence)
            return output
        }
    }

    /// Raw reads per polygon (nil = degenerate geometry), before the gate.
    static func read(
        frame: NativeOCRRGBAFrame,
        polygons: [[CGPoint]],
        engine: V2RecognitionEngine
    ) async throws -> [Read?] {
        let plans = polygons.map(plan)
        // Longest crops first: prediction cost is linear in width, so this
        // balances the parallel lanes (LPT scheduling).
        let order = plans.indices.filter { plans[$0] != nil }
            .sorted { (plans[$0]!.bucket.width, $1) > (plans[$1]!.bucket.width, $0) }
        guard !order.isEmpty else { return Array(repeating: nil, count: polygons.count) }
        let queue = WorkQueue(order)
        let lanes = min(engine.handleCount, order.count)
        var reads = [Read?](repeating: nil, count: polygons.count)
        try await withThrowingTaskGroup(of: [(Int, Read?)].self) { group in
            for _ in 0..<lanes {
                group.addTask(priority: .userInitiated) {
                    try await engine.withHandle { model in
                        var results: [(Int, Read?)] = []
                        while let index = queue.next() {
                            try Task.checkCancellation()
                            results.append((index, try await predict(plans[index]!, frame: frame,
                                                                     model: model, engine: engine)))
                        }
                        return results
                    }
                }
            }
            for try await results in group {
                for (index, read) in results { reads[index] = read }
            }
        }
        return reads
    }

    /// Exact legacy crop plan for the full-frame manga policy: dynamic width,
    /// publisher width rule (<= 640, natural > 2000 up to 2400) and the
    /// reading-order quad (the legacy main-manga `quad` direction path).
    static func plan(_ polygon: [CGPoint]) -> NativeCoreMLRecognitionPreprocessor.Plan? {
        let ordered = polygon.count == 4 ? NativeOCRDirectionGeometry.readingQuad(polygon) : nil
        if polygon.count == 4, ordered == nil { return nil }
        return NativeCoreMLRecognitionPreprocessor.plan(
            polygon: ordered ?? polygon, dynamicWidth: true, maximumWidth: V2RecognitionEngine.maximumWidth,
            mangaPublisherWidth: true, useProvidedOrder: ordered != nil)
    }

    private static func predict(
        _ plan: NativeCoreMLRecognitionPreprocessor.Plan,
        frame: NativeOCRRGBAFrame,
        model: MLModel,
        engine: V2RecognitionEngine
    ) async throws -> Read? {
        guard let tensor = NativeCoreMLRecognitionPreprocessor.prepare(frame: frame, plan: plan) else { return nil }
        let width = tensor.bucket.width
        let input = try MLMultiArray(shape: [1, 3, 48, NSNumber(value: width)], dataType: .float32)
        guard input.strides.map(\.intValue) == [3 * 48 * width, 48 * width, width, 1],
              tensor.values.count == 3 * 48 * width else { throw V2RecognitionEngine.Failure.modelOutputMissing }
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

    /// Legacy compact layout: row 0 indices, row 1 scores, then four
    /// (index, score) top-k row pairs consumed by the n-gram arbiter.
    static func pack(_ output: MLFeatureProvider, timeSteps: Int) throws -> MLMultiArray {
        guard let indices = output.featureValue(for: "ctc_indices")?.multiArrayValue,
              let scores = output.featureValue(for: "ctc_scores")?.multiArrayValue,
              indices.shape.map(\.intValue) == [1, timeSteps], scores.shape.map(\.intValue) == [1, timeSteps],
              indices.dataType == .int32, scores.dataType == .float32 else {
            throw V2RecognitionEngine.Failure.modelOutputMissing
        }
        let topIndices = output.featureValue(for: "ctc_topk_indices")?.multiArrayValue
        let topScores = output.featureValue(for: "ctc_topk_scores")?.multiArrayValue
        let alternatives = topIndices != nil && topScores != nil ? 4 : 0
        if let topIndices, let topScores {
            let shape = [1, timeSteps, alternatives]
            guard topIndices.shape.map(\.intValue) == shape, topScores.shape.map(\.intValue) == shape,
                  topIndices.dataType == .int32, topScores.dataType == .float32 else {
                throw V2RecognitionEngine.Failure.modelOutputMissing
            }
        }
        let compact = try MLMultiArray(shape: [NSNumber(value: 2 + alternatives * 2), NSNumber(value: timeSteps)],
                                       dataType: .float32)
        let destination = compact.dataPointer.assumingMemoryBound(to: Float.self)
        let row = compact.strides[0].intValue, column = compact.strides[1].intValue
        let index = indices.dataPointer.assumingMemoryBound(to: Int32.self)
        let score = scores.dataPointer.assumingMemoryBound(to: Float.self)
        let indexStride = indices.strides[1].intValue, scoreStride = scores.strides[1].intValue
        for step in 0..<timeSteps {
            destination[step * column] = Float(index[step * indexStride])
            destination[row + step * column] = score[step * scoreStride]
        }
        if let topIndices, let topScores {
            let ti = topIndices.dataPointer.assumingMemoryBound(to: Int32.self)
            let ts = topScores.dataPointer.assumingMemoryBound(to: Float.self)
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
