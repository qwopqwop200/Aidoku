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
        private struct Entry { let image: CGImage; let texture: MTLTexture?; let isOpaque: Bool; let pixels: Int }
        private let lock = NSLock()
        private var entries: [ObjectIdentifier: Entry] = [:]
        private var pixels = 0
        private var closed = false
        func close() { lock.lock(); defer { lock.unlock() }; closed = true; entries.removeAll(); pixels = 0 }
        private func cached(_ image: CGImage) -> Entry? {
            lock.lock(); defer { lock.unlock() }; return closed ? nil : entries[ObjectIdentifier(image)]
        }
        private func store(_ source: SourceValue, image: CGImage) {
            lock.lock(); defer { lock.unlock() }
            let count = image.width * image.height, key = ObjectIdentifier(image), prior = entries[key]
            guard !closed, prior != nil || count <= maximumPixels - pixels else { return }
            entries[key] = Entry(image: image, texture: source.texture ?? prior?.texture, isOpaque: source.isOpaque, pixels: count)
            if prior == nil { pixels += count }
        }
        private func checkOpen() throws {
            lock.lock(); let isClosed = closed; lock.unlock()
            guard !isClosed else { throw Failure.closedSession }
        }
        fileprivate func source(_ image: CGImage, resources: Resources) throws -> MTLTexture {
            try checkOpen()
            if let texture = cached(image)?.texture { return texture }
            let prepared = try resources.source(image)
            guard let texture = prepared.texture else { throw Failure.allocation }
            store(prepared, image: image); return texture
        }
        fileprivate func opacity(_ image: CGImage, resources: Resources) throws -> Bool {
            try checkOpen()
            if let entry = cached(image) { return entry.isOpaque }
            let prepared = try resources.source(image, uploadOnlyIfOpaque: true)
            store(prepared, image: image); return prepared.isOpaque
        }
    }
    fileprivate struct SourceValue { let texture: MTLTexture?; let isOpaque: Bool }

    /// Reads actual alpha from the same normalized PMA8 source used for filtering.
    /// An opaque first call uploads and retains that texture in the render Session;
    /// a translucent first call caches only its bounded image identity/opacity and
    /// returns before GPU upload. No second decoded-byte cache is retained.
    static func isOpaqueSource(image: CGImage, session: Session) throws -> Bool {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0, image.width <= maximumDimension, image.height <= maximumDimension,
              image.width <= maximumPixels / image.height else { throw Failure.invalidGeometry }
        guard let resources = Resources.shared else { throw Failure.unavailable }
        resources.lock.lock(); defer { resources.lock.unlock() }
        try Task.checkCancellation()
        let opaque = try session.opacity(image, resources: resources)
        try Task.checkCancellation()
        return opaque
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
        try filteredCanvasImage(image: image, destinationPixels: destinationPixels, cropPixels: cropPixels, backgroundRGBA: nil, session: session)
    }

    /// Bounded Float filtering and source-over in one dispatch. Destination bytes must be encoded
    /// sRGB premultiplied RGBA8 in top-row-first order, exactly the crop extent.
    /// Caller must copy the already-composited result without a second blend.
    static func compositeCanvasImage(image: CGImage, destinationPixels: CGSize, cropPixels: CGRect,
                                     backgroundRGBA: Data, session: Session? = nil) throws -> CGImage {
        try filteredCanvasImage(image: image, destinationPixels: destinationPixels, cropPixels: cropPixels,
                                backgroundRGBA: backgroundRGBA, session: session)
    }

    private static func filteredCanvasImage(image: CGImage, destinationPixels: CGSize, cropPixels: CGRect,
                                           backgroundRGBA: Data?, session: Session?) throws -> CGImage {
        try Task.checkCancellation()
        guard validSize(destinationPixels), validSize(cropPixels.size),
              [cropPixels.origin.x, cropPixels.origin.y].allSatisfy({ $0.isFinite && $0 >= 0 && $0.rounded(.towardZero) == $0 }),
              cropPixels.maxX <= destinationPixels.width, cropPixels.maxY <= destinationPixels.height,
              Double(cropPixels.size.width) * Double(cropPixels.size.height) <= Double(maximumPixels),
              image.width > 0, image.height > 0, image.width <= maximumDimension, image.height <= maximumDimension,
              image.width <= maximumPixels / image.height else { throw Failure.invalidGeometry }
        let width = Int(cropPixels.size.width), height = Int(cropPixels.size.height)
        guard backgroundRGBA == nil || backgroundRGBA!.count == width * height * 4 else { throw Failure.invalidGeometry }
        guard let resources = Resources.shared else { throw Failure.unavailable }
        resources.lock.lock(); defer { resources.lock.unlock() }
        try Task.checkCancellation()
        let source = try session?.source(image, resources: resources) ?? resources.uploadedSource(image)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
        guard let output = resources.device.makeTexture(descriptor: descriptor),
              let command = resources.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw Failure.allocation }
        if let backgroundRGBA {
            backgroundRGBA.withUnsafeBytes {
                output.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                               withBytes: $0.baseAddress!, bytesPerRow: width * 4)
            }
        }
        var geometry = Geometry(fullSize: SIMD2(Float(destinationPixels.width), Float(destinationPixels.height)),
                                cropOrigin: SIMD2(UInt32(cropPixels.origin.x), UInt32(cropPixels.origin.y)))
        encoder.setComputePipelineState(backgroundRGBA == nil ? resources.pipeline : resources.overPipeline); encoder.setTexture(source, index: 0); encoder.setTexture(output, index: 1)
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
    struct CanvasAffineGeometry {
        let localFrame: CGRect
        /// Projected Float coordinates used by the Metal vertex path. This quad is not a clip capability.
        let pixelQuad: [CGPoint]
        var pixelBounds: CGRect {
            let xs = pixelQuad.map(\.x), ys = pixelQuad.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        /// A conservative integer sampling window. Its bounding box never establishes clip/backing ownership.
        func samplingCrop(viewportPixelSize: CGSize) -> CGRect? {
            guard NativeCanvasTextureResampler.validSize(viewportPixelSize) else { return nil }
            let bound = pixelBounds
            let left = max(0, floor(bound.minX) - 1), top = max(0, floor(bound.minY) - 1)
            let right = min(viewportPixelSize.width, ceil(bound.maxX) + 1)
            let bottom = min(viewportPixelSize.height, ceil(bound.maxY) + 1)
            guard left < right, top < bottom else { return nil }
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }
    static func affineCanvasGeometry(domRect: CGRect, userToPixelTransform transform: CGAffineTransform) throws -> CanvasAffineGeometry {
        let input = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty,
                     domRect.origin.x, domRect.origin.y, domRect.size.width, domRect.size.height]
        guard input.allSatisfy(\.isFinite), domRect.size.width > 0, domRect.size.height > 0 else { throw Failure.invalidGeometry }
        let sx = hypot(Double(transform.a), Double(transform.b)), sy = hypot(Double(transform.c), Double(transform.d))
        let determinant = Double(transform.a) * Double(transform.d) - Double(transform.b) * Double(transform.c)
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0, determinant.isFinite, determinant != 0 else { throw Failure.invalidGeometry }
        // HTMLCanvasElement snappedIntRect, followed by literal CGUtilities
        // cgRoundToDevicePixelsNonIdentity. Translation does not enter rounding.
        let initial = [domRect.origin.x, domRect.origin.y,
                       domRect.origin.x + domRect.size.width, domRect.origin.y + domRect.size.height].map { Float(floor($0 + 0.5)) }
        guard initial.allSatisfy(\.isFinite) else { throw Failure.invalidGeometry }
        let dx = Float(Double(initial[0]) * sx).rounded(.toNearestOrAwayFromZero)
        let dy = Float(Double(initial[1]) * sy).rounded(.toNearestOrAwayFromZero)
        var dr = Float(Double(initial[2]) * sx).rounded(.toNearestOrAwayFromZero)
        var db = Float(Double(initial[3]) * sy).rounded(.toNearestOrAwayFromZero)
        guard [dx, dy, dr, db].allSatisfy(\.isFinite) else { throw Failure.invalidGeometry }
        if dr == dx && initial[2] != initial[0] { dr += 1 }
        if db == dy && initial[3] != initial[1] { db += 1 }
        let x = Float(Double(dx) / sx), y = Float(Double(dy) / sy)
        let w = Float(Double(dr) / sx) - x, h = Float(Double(db) / sy) - y
        guard [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { throw Failure.invalidGeometry }
        let r = x + w, b = y + h
        let matrix = SIMD4(Float(transform.a), Float(transform.b), Float(transform.c), Float(transform.d))
        let translation = SIMD2(Float(transform.tx), Float(transform.ty))
        guard [matrix.x, matrix.y, matrix.z, matrix.w, translation.x, translation.y].allSatisfy(\.isFinite) else { throw Failure.invalidGeometry }
        let corners = [SIMD2(x, y), SIMD2(r, y), SIMD2(r, b), SIMD2(x, b)]
        let quad = try corners.map { point -> CGPoint in
            let px = matrix.x * point.x + matrix.z * point.y + translation.x
            let py = matrix.y * point.x + matrix.w * point.y + translation.y
            guard px.isFinite, py.isFinite else { throw Failure.invalidGeometry }
            return CGPoint(x: CGFloat(px), y: CGFloat(py))
        }
        return CanvasAffineGeometry(localFrame: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h)), pixelQuad: quad)
    }

    /// Rasterizes a canvas through an affine transform into a top-row-first
    /// device-pixel crop. This crop is a sampling window, not a clipping proof.
    /// Nil backing returns filtered PMA8 source; nonnil backing is composited
    /// once in Float and must be copied by a caller with trusted clip/backing.
    static func affineCanvasImage(image: CGImage, domRect: CGRect,
                                  userToPixelTransform transform: CGAffineTransform,
                                  viewportPixelSize: CGSize, cropPixels: CGRect,
                                  backgroundRGBA: Data? = nil, session: Session? = nil) throws -> CGImage {
        try Task.checkCancellation()
        let components = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty,
                          domRect.origin.x, domRect.origin.y, domRect.size.width, domRect.size.height]
        guard components.allSatisfy(\.isFinite), domRect.size.width > 0, domRect.size.height > 0,
              validSize(viewportPixelSize), validSize(cropPixels.size),
              [cropPixels.origin.x, cropPixels.origin.y].allSatisfy({ $0.isFinite && $0 >= 0 && $0.rounded(.towardZero) == $0 }),
              cropPixels.maxX <= viewportPixelSize.width, cropPixels.maxY <= viewportPixelSize.height,
              Double(cropPixels.size.width) * Double(cropPixels.size.height) <= Double(maximumPixels),
              image.width > 0, image.height > 0, image.width <= maximumDimension, image.height <= maximumDimension,
              image.width <= maximumPixels / image.height else { throw Failure.invalidGeometry }
        let width = Int(cropPixels.size.width), height = Int(cropPixels.size.height)
        guard backgroundRGBA == nil || backgroundRGBA!.count == width * height * 4 else { throw Failure.invalidGeometry }
        let resolved = try affineCanvasGeometry(domRect: domRect, userToPixelTransform: transform)
        let x = Float(resolved.localFrame.origin.x), y = Float(resolved.localFrame.origin.y)
        let r = x + Float(resolved.localFrame.size.width), b = y + Float(resolved.localFrame.size.height)
        let vertices: [SIMD4<Float>] = [SIMD4(x,y,0,0), SIMD4(r,y,1,0), SIMD4(x,b,0,1),
                                      SIMD4(r,y,1,0), SIMD4(r,b,1,1), SIMD4(x,b,0,1)]
        var geometry = AffineGeometry(matrix: SIMD4(Float(transform.a), Float(transform.b), Float(transform.c), Float(transform.d)),
                                      translation: SIMD2(Float(transform.tx), Float(transform.ty)),
                                      viewport: SIMD2(Float(viewportPixelSize.width), Float(viewportPixelSize.height)))
        guard [geometry.matrix.x, geometry.matrix.y, geometry.matrix.z, geometry.matrix.w,
               geometry.translation.x, geometry.translation.y].allSatisfy(\.isFinite) else { throw Failure.invalidGeometry }
        // Reject finite input whose GPU arithmetic would produce nonfinite clip vertices.
        for vertex in vertices {
            let px = geometry.matrix.x * vertex.x + geometry.matrix.z * vertex.y + geometry.translation.x
            let py = geometry.matrix.y * vertex.x + geometry.matrix.w * vertex.y + geometry.translation.y
            guard px.isFinite, py.isFinite else { throw Failure.invalidGeometry }
        }
        guard let resources = Resources.shared else { throw Failure.unavailable }
        resources.lock.lock(); defer { resources.lock.unlock() }
        try Task.checkCancellation()
        let source = try session?.source(image, resources: resources) ?? resources.uploadedSource(image)
        // Anchor tiles to the full device plane, never to a caller's crop.
        // Raster interpolation then remains identical across distinct crop requests.
        let tileEdge = 256
        let floatDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: tileEdge, height: tileEdge, mipmapped: false)
        floatDescriptor.storageMode = .shared; floatDescriptor.usage = [.renderTarget, .shaderRead]
        let byteDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: tileEdge, height: tileEdge, mipmapped: false)
        byteDescriptor.storageMode = .shared; byteDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let filtered = resources.device.makeTexture(descriptor: floatDescriptor),
              let output = resources.device.makeTexture(descriptor: byteDescriptor) else { throw Failure.allocation }
        var resultBytes = Data(count: width * height * 4)
        let cropX = Int(cropPixels.origin.x), cropY = Int(cropPixels.origin.y)
        let firstX = cropX / tileEdge * tileEdge, firstY = cropY / tileEdge * tileEdge
        for tileY in stride(from: firstY, to: cropY + height, by: tileEdge) {
            for tileX in stride(from: firstX, to: cropX + width, by: tileEdge) {
                try Task.checkCancellation()
                let visibleX = max(cropX, tileX), visibleY = max(cropY, tileY)
                let tileWidth = min(cropX + width, tileX + tileEdge) - visibleX
                let tileHeight = min(cropY + height, tileY + tileEdge) - visibleY
                let localX = visibleX - tileX, localY = visibleY - tileY
                let resultX = visibleX - cropX, resultY = visibleY - cropY
                if let backgroundRGBA {
                    var tile = Data(count: tileEdge * tileEdge * 4)
                    for row in 0..<tileHeight {
                        let sourceOffset = ((resultY + row) * width + resultX) * 4
                        let targetOffset = ((localY + row) * tileEdge + localX) * 4
                        tile.replaceSubrange(targetOffset..<(targetOffset + tileWidth * 4),
                            with: backgroundRGBA[sourceOffset..<(sourceOffset + tileWidth * 4)])
                    }
                    tile.withUnsafeBytes { output.replace(region: MTLRegionMake2D(0, 0, tileEdge, tileEdge),
                        mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: tileEdge * 4) }
                }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = filtered; pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
                guard let command = resources.queue.makeCommandBuffer(),
                      let render = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocation }
                render.setRenderPipelineState(resources.affinePipeline)
                render.setViewport(MTLViewport(originX: -Double(tileX), originY: -Double(tileY),
                    width: Double(viewportPixelSize.width), height: Double(viewportPixelSize.height), znear: 0, zfar: 1))
                vertices.withUnsafeBytes { render.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
                render.setVertexBytes(&geometry, length: MemoryLayout<AffineGeometry>.stride, index: 1)
                render.setFragmentTexture(source, index: 0)
                render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6); render.endEncoding()
                guard let compute = command.makeComputeCommandEncoder() else { throw Failure.allocation }
                compute.setComputePipelineState(backgroundRGBA == nil ? resources.affineCopyPipeline : resources.affineOverPipeline)
                compute.setTexture(filtered, index: 0); compute.setTexture(output, index: 1)
                compute.dispatchThreads(MTLSize(width: tileEdge, height: tileEdge, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)); compute.endEncoding()
                try Task.checkCancellation()
                command.commit(); command.waitUntilCompleted()
                guard command.error == nil, command.status == .completed else { throw Failure.execution }
                try Task.checkCancellation()
                var bytes = Data(count: tileWidth * tileHeight * 4)
                bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: tileWidth * 4,
                    from: MTLRegionMake2D(localX, localY, tileWidth, tileHeight), mipmapLevel: 0) }
                for row in 0..<tileHeight {
                    let destination = ((resultY + row) * width + resultX) * 4
                    resultBytes.replaceSubrange(destination..<(destination + tileWidth * 4),
                        with: bytes[(row * tileWidth * 4)..<((row + 1) * tileWidth * 4)])
                }
            }
        }
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data: resultBytes as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.allocation }
        return result
    }
    private struct AffineGeometry { var matrix: SIMD4<Float>; var translation: SIMD2<Float>; var viewport: SIMD2<Float> }

    private static func validSize(_ size: CGSize) -> Bool {
        [size.width, size.height].allSatisfy { $0.isFinite && $0 >= 1 && $0 <= CGFloat(maximumDimension) && $0.rounded(.towardZero) == $0 }
    }
    private struct Geometry { var fullSize: SIMD2<Float>; var cropOrigin: SIMD2<UInt32> }

    fileprivate final class Resources: @unchecked Sendable {
        static let shared = try? Resources()
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let overPipeline: MTLComputePipelineState
        let affinePipeline: MTLRenderPipelineState
        let affineCopyPipeline: MTLComputePipelineState
        let affineOverPipeline: MTLComputePipelineState
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
            kernel void canvasOver(texture2d<float,access::sample> source [[texture(0)]],
                                   texture2d<float,access::read_write> target [[texture(1)]],
                                   constant Geometry &geometry [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
                if(p.x>=target.get_width()||p.y>=target.get_height())return;
                constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
                float2 uv=(float2(p+geometry.cropOrigin)+0.5f)/geometry.fullSize;
                float4 value=source.sample(linear,uv);
                target.write(value+target.read(p)*(1.0f-value.a),p);
            }
            struct AffineGeometry { float4 matrix; float2 translation; float2 viewport; };
            struct AffineVarying { float4 position [[position]]; float2 uv; };
            vertex AffineVarying affineVertex(uint id [[vertex_id]], constant float4 *vertices [[buffer(0)]], constant AffineGeometry &g [[buffer(1)]]) {
                float4 v=vertices[id];
                float2 p=float2(g.matrix.x*v.x+g.matrix.z*v.y,g.matrix.y*v.x+g.matrix.w*v.y)+g.translation;
                AffineVarying o;o.position=float4(p.x*2.0f/g.viewport.x-1.0f,1.0f-p.y*2.0f/g.viewport.y,0,1);o.uv=v.zw;return o;
            }
            fragment float4 affineFragment(AffineVarying v [[stage_in]], texture2d<float> source [[texture(0)]]) {
                constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
                return source.sample(linear,v.uv);
            }
            kernel void affineCopy(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::write> target [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
                if(p.x>=target.get_width()||p.y>=target.get_height())return;
                target.write(source.read(p),p);
            }
            kernel void affineOver(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::read_write> target [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
                if(p.x>=target.get_width()||p.y>=target.get_height())return;
                float4 value=source.read(p);target.write(value+target.read(p)*(1.0f-value.a),p);
            }
            """#
            let library = try device.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(name: "canvasLinear"),
                  let over = library.makeFunction(name: "canvasOver") else { throw Failure.encoding }
            self.device = device; self.queue = queue; self.pipeline = try device.makeComputePipelineState(function: function)
            self.overPipeline = try device.makeComputePipelineState(function: over)
            guard let vertex=library.makeFunction(name:"affineVertex"),let fragment=library.makeFunction(name:"affineFragment"),
                  let copy=library.makeFunction(name:"affineCopy"),let composite=library.makeFunction(name:"affineOver") else {throw Failure.encoding}
            let descriptor=MTLRenderPipelineDescriptor();descriptor.vertexFunction=vertex;descriptor.fragmentFunction=fragment
            descriptor.colorAttachments[0].pixelFormat = .rgba32Float
            self.affinePipeline=try device.makeRenderPipelineState(descriptor:descriptor)
            self.affineCopyPipeline=try device.makeComputePipelineState(function:copy)
            self.affineOverPipeline=try device.makeComputePipelineState(function:composite)
        }
        func uploadedSource(_ image: CGImage) throws -> MTLTexture {
            guard let texture = try source(image).texture else { throw Failure.allocation }
            return texture
        }
        func source(_ image: CGImage, uploadOnlyIfOpaque: Bool = false) throws -> SourceValue {
            try Task.checkCancellation()
            let width = image.width, height = image.height
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                  let pixels = context.data else { throw Failure.allocation }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            try Task.checkCancellation()
            let sourceBytes = pixels.assumingMemoryBound(to: UInt8.self)
            var opaque = true
            rows: for row in 0..<height {
                try Task.checkCancellation()
                for column in 0..<width where sourceBytes[(row * width + column) * 4 + 3] != 255 {
                    opaque = false; break rows
                }
            }
            if uploadOnlyIfOpaque && !opaque {
                try Task.checkCancellation()
                return SourceValue(texture: nil, isOpaque: false)
            }
            try Task.checkCancellation()
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.allocation }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
            try Task.checkCancellation()
            return SourceValue(texture: texture, isOpaque: opaque)
        }
    }
}
