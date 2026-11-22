import CoreGraphics
@preconcurrency import CoreML
import Foundation

// Resident V2 model set: loaded once per process and shared by all pages.

/// Canonical page raster of the pixel stages (RF-DETR, AOT): sRGB RGBA8
/// premultipliedLast on a white matte, top-left row order.
struct V2PageRaster: Sendable {
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
        guard let bytes = V2RemovalMask.rgbaBytes(image) else { throw Failure.invalidImage }
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
final class V2SerialExecutor: @unchecked Sendable {
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
final class V2InstancePool<Element: Sendable>: @unchecked Sendable {
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
final class V2Models: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case resourceMissing(String)

        var description: String {
            switch self {
            case .resourceMissing(let name): "V2 model resource missing: \(name)"
            }
        }
    }

    static let detectorResourceName = "PP-OCRv6-Manga-DetShapes"

    /// S2 PP-OCRv6 manga DB detectors; use `detectors.with { ... }`.
    let detectors: V2InstancePool<NativeCoreMLDetector>
    let recognition: V2RecognitionEngine
    let layout: V2RFDETRModel
    let inpainters: V2InstancePool<V2AOTModel>
    /// Wall-clock milliseconds spent loading each model, for the run summary.
    let loadMilliseconds: [String: Double]

    init(detectors: [NativeCoreMLDetector], recognition: V2RecognitionEngine, layout: V2RFDETRModel,
         inpainters: [V2AOTModel], loadMilliseconds: [String: Double]) {
        self.detectors = V2InstancePool(detectors)
        self.recognition = recognition
        self.layout = layout
        self.inpainters = V2InstancePool(inpainters)
        self.loadMilliseconds = loadMilliseconds
    }

    /// Loads all models from compiled `.mlmodelc` resources; the detector program loads
    /// lazily, so call `warmUp()` before the first page.
    static func load(bundle: Bundle = .main, detectorInstances: Int = 2, inpainterInstances: Int = 2) throws -> V2Models {
        var timings: [String: Double] = [:]
        func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            defer { timings[name] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
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
        let recognition = try timed("recognizer") { try V2RecognitionEngine.load(bundle: bundle) }
        let layout = try timed("layout") { try V2RFDETRModel(compiledURL: compiled(V2RFDETRModel.resourceName)) }
        let inpainters = try timed("inpainter") {
            try (0..<max(1, inpainterInstances)).map { _ in try V2AOTModel(compiledURL: compiled(V2AOTModel.resourceName)) }
        }
        return V2Models(detectors: detectors, recognition: recognition, layout: layout, inpainters: inpainters,
                        loadMilliseconds: timings)
    }

    /// One throwaway prediction per model instance on a blank page, so the first real
    /// page does not pay Core ML's first-prediction compilation.
    func warmUp() async throws {
        let side = 512
        let raster = V2PageRaster(width: side, height: side, rgba: [UInt8](repeating: 255, count: side * side * 4))
        let page = V2Page(id: "v2-warm-up", image: try raster.image())
        let mask = (0..<(side * side)).map { (200..<240).contains($0 / side) && (200..<300).contains($0 % side) ? UInt8(255) : 0 }
        async let layoutWarm = V2LayoutDetection.detect(raster, models: self)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for detector in detectors.all {
                group.addTask { _ = try await V2Detection.detect(page, detector: detector) }
            }
            for model in inpainters.all {
                group.addTask { _ = try await model.executor.run { try model.restoreImage(raster, removal: mask) } }
            }
            try await group.waitForAll()
        }
        let line = V2Line(polygon: [CGPoint(x: 240, y: 100), CGPoint(x: 272, y: 100), CGPoint(x: 272, y: 400),
                                    CGPoint(x: 240, y: 400)],
                          bounds: CGRect(x: 240, y: 100, width: 32, height: 300), vertical: true, detectionScore: 1)
        _ = try await V2Recognition.recognize(page, lines: [line], engine: recognition)
        _ = try await layoutWarm
    }
}
