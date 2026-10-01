import CoreGraphics
import Foundation
@preconcurrency import Metal

/// Live canvas filtering in encoded sRGB premultiplied RGBA8. PDF and saved
/// raw masks deliberately retain their independent Core Graphics contracts.
enum NativeCanvasTextureResampler {
    enum Failure: Error { case unavailable, invalidGeometry, allocation, encoding, execution, closedSession }
    static let maximumPixels = 12_000_000
    static let maximumDimension = 16_384

    /// Page-scoped immutable source texture reuse. It retains image identities
    /// while cached and releases them together; closed sessions cannot repopulate.
    final class Session: @unchecked Sendable {
        private struct Entry { let image: CGImage; let texture: MTLTexture; let pixels: Int }
        private let lock = NSLock()
        private var entries: [ObjectIdentifier: Entry] = [:]
        private var pixels = 0
        private var closed = false
        func close() { lock.lock(); defer { lock.unlock() }; closed = true; entries.removeAll(); pixels = 0 }
        private func cached(_ image: CGImage) -> MTLTexture? {
            lock.lock(); defer { lock.unlock() }; return closed ? nil : entries[ObjectIdentifier(image)]?.texture
        }
        private func store(_ texture: MTLTexture, image: CGImage) {
            lock.lock(); defer { lock.unlock() }
            let count = image.width * image.height
            guard !closed, entries[ObjectIdentifier(image)] == nil, count <= maximumPixels - pixels else { return }
            entries[ObjectIdentifier(image)] = Entry(image: image, texture: texture, pixels: count); pixels += count
        }
        fileprivate func source(_ image: CGImage, resources: Resources) throws -> MTLTexture {
            lock.lock(); let isClosed = closed; lock.unlock()
            guard !isClosed else { throw Failure.closedSession }
            if let texture = cached(image) { return texture }
            let texture = try resources.source(image); store(texture, image: image); return texture
        }
    }

    /// Output is an actual pixel rectangle, without CSS or capture snapping.
    static func resample(image: CGImage, outputPixelSize: CGSize, session: Session? = nil) throws -> CGImage {
        try canvasImage(image: image, destinationPixels: outputPixelSize,
                        cropPixels: CGRect(origin: .zero, size: outputPixelSize), session: session)
    }

    /// Only the visible destination crop is allocated. Sampling coordinates
    /// retain the complete destination extent, so offscreen clipping cannot
    /// shift or stretch source UVs. All dimensions/crop edges are integer pixels.
    static func canvasImage(image: CGImage, destinationPixels: CGSize, cropPixels: CGRect,
                            session: Session? = nil) throws -> CGImage {
        try Task.checkCancellation()
        guard let resources = Resources.shared else { throw Failure.unavailable }
        guard validSize(destinationPixels), validSize(cropPixels.size),
              [cropPixels.origin.x, cropPixels.origin.y].allSatisfy({ $0.isFinite && $0 >= 0 && $0.rounded(.towardZero) == $0 }),
              cropPixels.maxX <= destinationPixels.width, cropPixels.maxY <= destinationPixels.height,
              Double(cropPixels.size.width) * Double(cropPixels.size.height) <= Double(maximumPixels),
              image.width > 0, image.height > 0, image.width <= maximumDimension, image.height <= maximumDimension,
              image.width <= maximumPixels / image.height else { throw Failure.invalidGeometry }
        resources.lock.lock(); defer { resources.lock.unlock() }
        try Task.checkCancellation()
        let source = try session?.source(image, resources: resources) ?? resources.source(image)
        let width = Int(cropPixels.size.width), height = Int(cropPixels.size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
        guard let output = resources.device.makeTexture(descriptor: descriptor),
              let command = resources.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw Failure.allocation }
        var geometry = Geometry(fullSize: SIMD2(Float(destinationPixels.width), Float(destinationPixels.height)),
                                cropOrigin: SIMD2(UInt32(cropPixels.origin.x), UInt32(cropPixels.origin.y)))
        encoder.setComputePipelineState(resources.pipeline); encoder.setTexture(source, index: 0); encoder.setTexture(output, index: 1)
        encoder.setBytes(&geometry, length: MemoryLayout<Geometry>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        try Task.checkCancellation()
        command.commit(); command.waitUntilCompleted()
        guard command.error == nil, command.status == .completed else { throw Failure.execution }
        try Task.checkCancellation()
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: bytes as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.allocation }
        return result
    }
    private static func validSize(_ size: CGSize) -> Bool {
        [size.width, size.height].allSatisfy { $0.isFinite && $0 >= 1 && $0 <= CGFloat(maximumDimension) && $0.rounded(.towardZero) == $0 }
    }
    private struct Geometry { var fullSize: SIMD2<Float>; var cropOrigin: SIMD2<UInt32> }

    fileprivate final class Resources: @unchecked Sendable {
        static let shared = try? Resources()
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let lock = NSLock()
        init() throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure.unavailable }
            let source = #"""
            #include <metal_stdlib>
            using namespace metal;
            struct Geometry { float2 fullSize; uint2 cropOrigin; };
            kernel void canvasLinear(texture2d<float,access::sample> source [[texture(0)]],
                                     texture2d<float,access::write> target [[texture(1)]],
                                     constant Geometry &geometry [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
                if(p.x>=target.get_width()||p.y>=target.get_height())return;
                constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
                float2 uv=(float2(p+geometry.cropOrigin)+0.5f)/geometry.fullSize;
                target.write(source.sample(linear,uv),p);
            }
            """#
            let library = try device.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(name: "canvasLinear") else { throw Failure.encoding }
            self.device = device; self.queue = queue; self.pipeline = try device.makeComputePipelineState(function: function)
        }
        func source(_ image: CGImage) throws -> MTLTexture {
            let width = image.width, height = image.height
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                  let pixels = context.data else { throw Failure.allocation }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
            return texture
        }
    }
}
