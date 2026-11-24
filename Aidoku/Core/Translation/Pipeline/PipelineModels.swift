import CoreGraphics
@preconcurrency import CoreML
import Foundation

// Resident pipeline model set: loaded once per process and shared by all pages.

/// Canonical page raster of the pixel stages (RF-DETR, AOT): sRGB RGBA8
/// premultipliedLast on a white matte, top-left row order.
struct PipelinePageRaster: Sendable {
    let width: Int
    let height: Int
    var rgba: [UInt8]

    enum Failure: Error { case invalidImage, tooLarge }

    init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    init(_ image: CGImage) throws {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { throw Failure.tooLarge }
        guard let bytes = PipelineRemovalMask.rgbaBytes(image) else { throw Failure.invalidImage }
        self.init(width: width, height: height, rgba: bytes)
    }

    func image() throws -> CGImage { try Self.image(Data(rgba), width: width, height: height) }

    /// Canonical-format image over `data` (no copy of the bytes).
    static func image(_ data: Data, width: Int, height: Int) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw Failure.invalidImage }
        return image
    }
}

/// Runs blocking Core ML work on a serial queue, off Swift's cooperative pool.
final class PipelineSerialExecutor: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

/// FIFO pool of resident instances that serve one page at a time (a second concurrent
/// legacy `NativeCoreMLDetector.detect` cancels the first).
final class PipelineInstancePool<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var free: [Element]
    private var waiters: [CheckedContinuation<Element, Never>] = []

    init(_ elements: [Element]) {
        precondition(!elements.isEmpty)
        free = elements
    }

    func acquire() async -> Element {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let element = free.popLast() {
                lock.unlock()
                continuation.resume(returning: element)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release(_ element: Element) {
        lock.lock()
        if waiters.isEmpty {
            free.append(element)
            lock.unlock()
        } else {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: element)
        }
    }

    func with<T: Sendable>(_ body: (Element) async throws -> T) async rethrows -> T {
        let element = await acquire()
        defer { release(element) }
        return try await body(element)
    }
}

@available(iOS 18.0, macOS 15.0, *)
final class PipelineModels: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case resourceMissing(String)

        var description: String {
            switch self {
            case .resourceMissing(let name): "Pipeline model resource missing: \(name)"
            }
        }
    }

    static let detectorResourceName = "PP-OCRv6-Manga-DetShapes"

    /// S2 PP-OCRv6 manga DB detectors; use `detectors.with { ... }`.
    let detectors: PipelineInstancePool<NativeCoreMLDetector>
    let recognition: PipelineRecognitionEngine
    let layout: PipelineRFDETRModel
    let inpainters: PipelineInstancePool<PipelineAOTModel>
    /// S6 glyph classifier.
    let removalMask: PipelineMaskNet
    /// Wall-clock milliseconds spent loading (and warming) each model, for the run summary.
    var loadMilliseconds: [String: Double] { timings.value }
    private let timings: Timings
    /// Warm-up started by `load` (the detectors, whose program loads lazily); `warmUp()` awaits it.
    private let pendingWarmUp: Task<Void, Error>?
    /// First warm-up failure inside `load`, rethrown by `warmUp()`.
    private let warmUpError: Error?

    private init(detectors: [NativeCoreMLDetector], recognition: PipelineRecognitionEngine, layout: PipelineRFDETRModel,
         inpainters: [PipelineAOTModel], removalMask: PipelineMaskNet, timings: Timings,
         pendingWarmUp: Task<Void, Error>?, warmUpError: Error?) {
        self.detectors = PipelineInstancePool(detectors)
        self.removalMask = removalMask
        self.recognition = recognition
        self.layout = layout
        self.inpainters = PipelineInstancePool(inpainters)
        self.timings = timings
        self.pendingWarmUp = pendingWarmUp
        self.warmUpError = warmUpError
    }

    /// The blank warm-up page: one 512 x 512 white raster, a 40 x 100 erase rectangle and one vertical line.
    private static let warmSide = 512
    private static func warmRaster() -> PipelinePageRaster {
        PipelinePageRaster(width: warmSide, height: warmSide, rgba: [UInt8](repeating: 255, count: warmSide * warmSide * 4))
    }

    /// Loads all models concurrently, warming each instance as soon as it is loaded. The detectors
    /// load lazily and finish in `warmUp()`: call it before the first page.
    static func load(bundle: Bundle = .main, detectorInstances: Int = 2, inpainterInstances: Int = 2) throws -> PipelineModels {
        let lock = NSLock()
        let timings = Timings()
        var warmError: Error?
        func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            defer { timings.record(name, since: start) }
            return try body()
        }
        /// A failed warm-up never fails the load (`warmUp()` rethrows it).
        func warm(_ body: () throws -> Void) {
            do { try body() } catch { lock.withLock { if warmError == nil { warmError = error } } }
        }
        func compiled(_ name: String) throws -> URL {
            guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
                throw Failure.resourceMissing(name)
            }
            return url
        }
        let detectors = (0..<max(1, detectorInstances)).map { _ in NativeCoreMLDetector(bundle: bundle) }
        // The detectors' lazy program load + first prediction runs beside the other loads.
        let detectorStart = DispatchTime.now().uptimeNanoseconds
        let detectorWarm: Task<Void, Error>? = {
            guard let page = try? PipelinePage(id: "pipeline-warm-up", image: warmRaster().image()) else { return nil }
            return Task.detached(priority: .userInitiated) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for detector in detectors {
                        group.addTask { _ = try await PipelineDetection.detect(page, detector: detector) }
                    }
                    try await group.waitForAll()
                }
                timings.record("detector", since: detectorStart)
            }
        }()
        // Independent loads overlap: the set is resident after the slowest one, not their sum.
        var recognition: Result<PipelineRecognitionEngine, Error>?
        var layout: Result<PipelineRFDETRModel, Error>?
        var inpainters: Result<[PipelineAOTModel], Error>?
        var removalMask: Result<PipelineMaskNet, Error>?
        DispatchQueue.concurrentPerform(iterations: 4) { index in
            switch index {
            case 0:
                // Each handle is warmed right after its own load (PipelineRecognitionEngine.init).
                let result = Result { try timed("recognizer") { try PipelineRecognitionEngine.load(bundle: bundle) } }
                lock.withLock { recognition = result }
            case 1:
                let result = Result { try timed("layout") {
                    let model = try PipelineRFDETRModel(compiledURL: compiled(PipelineRFDETRModel.resourceName))
                    let raster = warmRaster()
                    warm { _ = try PipelineLayoutDetection.decode(model.predict(raster), width: raster.width, height: raster.height) }
                    return model
                } }
                lock.withLock { layout = result }
            case 2:
                let result = Result { try timed("mask") { try PipelineMaskNet(compiledURL: compiled(PipelineMaskNet.resourceName)) } }
                lock.withLock { removalMask = result }
            default:
                let result = Result { try timed("inpainter") {
                    let models = try (0..<max(1, inpainterInstances)).map { _ in
                        try PipelineAOTModel(compiledURL: compiled(PipelineAOTModel.resourceName))
                    }
                    let side = warmSide
                    let raster = warmRaster()
                    let mask = (0..<(side * side)).map {
                        (200..<240).contains($0 / side) && (200..<300).contains($0 % side) ? UInt8(255) : 0
                    }
                    // Instances warm concurrently (no page can reach them yet, so off their executors).
                    DispatchQueue.concurrentPerform(iterations: models.count) { index in
                        warm { _ = try models[index].restoreImage(raster, removal: mask) }
                    }
                    return models
                } }
                lock.withLock { inpainters = result }
            }
        }
        do {
            return try PipelineModels(detectors: detectors, recognition: recognition!.get(), layout: layout!.get(),
                                      inpainters: inpainters!.get(), removalMask: removalMask!.get(),
                                      timings: timings, pendingWarmUp: detectorWarm,
                                      warmUpError: lock.withLock { warmError })
        } catch {
            detectorWarm?.cancel()
            throw error
        }
    }

    /// Finishes the warm-up `load` started (every instance's cold first prediction), so the first
    /// real page does not pay Core ML's first-prediction compilation.
    func warmUp() async throws {
        try await pendingWarmUp?.value
        if let warmUpError { throw warmUpError }
    }

    /// Per-model load milliseconds, filled while loads (and the detectors' deferred one) finish.
    private final class Timings: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Double] = [:]
        var value: [String: Double] { lock.withLock { values } }
        func record(_ name: String, since start: UInt64) {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            lock.withLock { values[name] = elapsed }
        }
    }
}
