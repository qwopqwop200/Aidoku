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
    let all: [Element]

    init(_ elements: [Element]) {
        precondition(!elements.isEmpty)
        free = elements
        all = elements
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
    /// Wall-clock milliseconds spent loading each model, for the run summary.
    let loadMilliseconds: [String: Double]

    init(detectors: [NativeCoreMLDetector], recognition: PipelineRecognitionEngine, layout: PipelineRFDETRModel,
         inpainters: [PipelineAOTModel], removalMask: PipelineMaskNet, loadMilliseconds: [String: Double]) {
        self.detectors = PipelineInstancePool(detectors)
        self.removalMask = removalMask
        self.recognition = recognition
        self.layout = layout
        self.inpainters = PipelineInstancePool(inpainters)
        self.loadMilliseconds = loadMilliseconds
    }

    /// Loads all models from compiled `.mlmodelc` resources, concurrently; the detector program
    /// loads lazily, so call `warmUp()` before the first page.
    static func load(bundle: Bundle = .main, detectorInstances: Int = 2, inpainterInstances: Int = 2) throws -> PipelineModels {
        let lock = NSLock()
        var timings: [String: Double] = [:]
        func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            defer {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                lock.withLock { timings[name] = elapsed }
            }
            return try body()
        }
        func compiled(_ name: String) throws -> URL {
            guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
                throw Failure.resourceMissing(name)
            }
            return url
        }
        let detectors = timed("detector") {
            (0..<max(1, detectorInstances)).map { _ in
                NativeCoreMLDetector(bundle: bundle)
            }
        }
        // Independent loads overlap: the set is resident after the slowest one, not their sum.
        var recognition: Result<PipelineRecognitionEngine, Error>?
        var layout: Result<PipelineRFDETRModel, Error>?
        var inpainters: Result<[PipelineAOTModel], Error>?
        var removalMask: Result<PipelineMaskNet, Error>?
        DispatchQueue.concurrentPerform(iterations: 4) { index in
            switch index {
            case 0:
                let result = Result { try timed("recognizer") { try PipelineRecognitionEngine.load(bundle: bundle) } }
                lock.withLock { recognition = result }
            case 1:
                let result = Result { try timed("layout") { try PipelineRFDETRModel(compiledURL: compiled(PipelineRFDETRModel.resourceName)) } }
                lock.withLock { layout = result }
            case 2:
                let result = Result { try timed("mask") { try PipelineMaskNet(compiledURL: compiled(PipelineMaskNet.resourceName)) } }
                lock.withLock { removalMask = result }
            default:
                let result = Result { try timed("inpainter") {
                    try (0..<max(1, inpainterInstances)).map { _ in try PipelineAOTModel(compiledURL: compiled(PipelineAOTModel.resourceName)) }
                } }
                lock.withLock { inpainters = result }
            }
        }
        return try PipelineModels(detectors: detectors, recognition: recognition!.get(), layout: layout!.get(),
                            inpainters: inpainters!.get(), removalMask: removalMask!.get(), loadMilliseconds: timings)
    }

    /// One throwaway prediction per model instance on a blank page, so the first real
    /// page does not pay Core ML's first-prediction compilation.
    func warmUp() async throws {
        let side = 512
        let raster = PipelinePageRaster(width: side, height: side, rgba: [UInt8](repeating: 255, count: side * side * 4))
        let page = PipelinePage(id: "pipeline-warm-up", image: try raster.image())
        let mask = (0..<(side * side)).map { (200..<240).contains($0 / side) && (200..<300).contains($0 % side) ? UInt8(255) : 0 }
        let line = PipelineLine(polygon: [CGPoint(x: 240, y: 100), CGPoint(x: 272, y: 100), CGPoint(x: 272, y: 400),
                                    CGPoint(x: 240, y: 400)],
                          bounds: CGRect(x: 240, y: 100, width: 32, height: 300), vertical: true, detectionScore: 1)
        async let layoutWarm = PipelineLayoutDetection.detect(raster, models: self)
        // Every model warms concurrently (the recognizer handles too), so the set is ready after the slowest.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await PipelineRecognition.warmUp(page, line: line, engine: self.recognition) }
            for detector in detectors.all {
                group.addTask { _ = try await PipelineDetection.detect(page, detector: detector) }
            }
            for model in inpainters.all {
                group.addTask { _ = try await model.executor.run { try model.restoreImage(raster, removal: mask) } }
            }
            try await group.waitForAll()
        }
        _ = try await layoutWarm
    }
}
