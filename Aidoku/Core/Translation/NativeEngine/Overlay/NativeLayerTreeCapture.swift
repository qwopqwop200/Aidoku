import Foundation
import CoreGraphics
import QuartzCore
@preconcurrency import Metal

/// Captures a fresh, caller-owned layer graph on the calling render worker.
/// No UIKit/window dependency. makeRoot must return a fresh, unshared graph,
/// commit its model transaction, prepare leaf contents and retain any weak delegates
/// through this synchronous call. Graph factories must not recursively capture.
nonisolated enum NativeLayerTreeCapture {
    static let maximumPixelCount = 12_000_000
    static let maximumDimension = 16_384
    // Serializes transient core-owned graph/Metal surfaces across callers.
    // Returned image-provider memory is subsequently owned by the caller/cache.
    private static let admission = NSLock()

    struct Result: Sendable {
        let image: CGImage
        let pixelSize: CGSize
    }

    enum Failure: Error {
        case mainThread, invalidGeometry, invalidRoot, metalUnavailable, allocationFailed, gpuFailure(String)
    }

    /// Call inside a background Swift Task, or supply its cancellation token.
    /// Cancellation is cooperative: submitted GPU work drains before resources/graph are released.
    static func capture(size: CGSize, scale: CGFloat,
                        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
                        makeRoot: () throws -> CALayer) throws -> Result {
        try checkCancellation()
        guard !Thread.isMainThread else { throw Failure.mainThread }
        admission.lock()
        defer { admission.unlock() }
        try checkCancellation()
        // Drain each capture's autoreleased CA/Metal intermediates while still
        // owning admission. The returned CGImage independently retains its provider.
        let result = try autoreleasepool {
            try captureOwned(size: size, scale: scale, checkCancellation: checkCancellation, makeRoot: makeRoot)
        }
        try checkCancellation()
        return result
    }

    private static func captureOwned(size: CGSize, scale: CGFloat,
                                     checkCancellation: () throws -> Void,
                                     makeRoot: () throws -> CALayer) throws -> Result {
        let wp = size.width * scale, hp = size.height * scale
        guard size.width.isFinite, size.height.isFinite, scale.isFinite, size.width > 0, size.height > 0, scale > 0,
              wp.isFinite, hp.isFinite, wp > 0, hp > 0,
              wp <= CGFloat(maximumDimension), hp <= CGFloat(maximumDimension),
              abs(wp - wp.rounded()) <= 2 * wp.ulp, abs(hp - hp.rounded()) <= 2 * hp.ulp else {
            throw Failure.invalidGeometry
        }
        let width = Int(wp.rounded()), height = Int(hp.rounded())
        guard width > 0, height > 0, width * height <= maximumPixelCount else { throw Failure.invalidGeometry }
        let page = CGRect(origin: .zero, size: size)
        let root = try makeRoot()
        guard root.superlayer == nil, root.bounds == page, root.frame == page,
              CATransform3DIsIdentity(root.transform), root.position.x.isFinite, root.position.y.isFinite,
              root.anchorPoint.x.isFinite, root.anchorPoint.y.isFinite else { throw Failure.invalidRoot }
        try checkCancellation()

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure.metalUnavailable }
        let rowBytes = (width * 4 + 255) / 256 * 256
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let clear = queue.makeCommandBuffer(), let copy = queue.makeCommandBuffer() else { throw Failure.allocationFailed }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let clearEncoder = clear.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocationFailed }
        clearEncoder.endEncoding()
        guard let readbackEncoder = copy.makeBlitCommandEncoder() else { throw Failure.allocationFailed }
        readbackEncoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
        readbackEncoder.endEncoding()
        // All allocations/encoders that can fail are prepared before CARenderer submits work.
        // After render there is no cancellation point until the actual target readback drains.
        var clearSubmitted = false, copySubmitted = false
        defer {
            if clearSubmitted { drain(clear) }
            if copySubmitted { drain(copy) }
        }
        clearSubmitted = true
        try submitAndComplete(clear)
        try checkCancellation()

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: space, kCARendererMetalCommandQueue: queue])
        let position = root.position, anchor = root.anchorPoint
        let container = CALayer()
        container.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        container.anchorPoint = .zero; container.position = .zero
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.anchorPoint = .zero; root.position = .zero; root.transform = CATransform3DMakeScale(scale, scale, 1)
        container.addSublayer(root)
        CATransaction.commit()
        renderer.layer = container; renderer.bounds = container.bounds
        var graphRestored = false
        func restoreGraph() {
            guard !graphRestored else { return }
            // Target copy has either completed/failed or was never submitted before render.
            // Restore caller model only after all submitted target users have drained.
            if copySubmitted { drain(copy) }
            renderer.layer = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            root.removeFromSuperlayer(); root.anchorPoint = anchor; root.position = position; root.transform = CATransform3DIdentity
            CATransaction.commit(); CATransaction.flush()
            graphRestored = true
        }
        defer { restoreGraph() }
        try checkCancellation()
        root.displayIfNeeded(); container.displayIfNeeded(); CATransaction.flush()
        try checkCancellation()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds); renderer.render(); renderer.endFrame()
        copySubmitted = true
        try submitAndComplete(copy)
        try checkCancellation()

        // One immutable RGBA provider allocation. Metal bytes are not exposed or retained by Result.
        var rgba = Data(count: width * height * 4)
        try rgba.withUnsafeMutableBytes { destination in
            let pixels = destination.bindMemory(to: UInt8.self)
            let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                try checkCancellation()
                for x in 0..<width {
                    if x % 4096 == 0 { try checkCancellation() }
                    let src = y * rowBytes + x * 4, dst = (y * width + x) * 4
                    pixels[dst] = source[src + 2]; pixels[dst + 1] = source[src + 1]
                    pixels[dst + 2] = source[src]; pixels[dst + 3] = source[src + 3]
                }
            }
        }
        try checkCancellation()
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.allocationFailed }
        let result = Result(image: image, pixelSize: CGSize(width: width, height: height))
        restoreGraph()
        try checkCancellation()
        return result
    }

    private static func submitAndComplete(_ command: any MTLCommandBuffer) throws {
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else {
            throw Failure.gpuFailure(command.error?.localizedDescription ?? "Metal status \(command.status.rawValue)")
        }
    }
    private static func drain(_ command: any MTLCommandBuffer) {
        if command.status != .completed && command.status != .error { command.waitUntilCompleted() }
    }
}
