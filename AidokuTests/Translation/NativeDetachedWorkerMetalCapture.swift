import Foundation
import QuartzCore
@preconcurrency import Metal

/// Public, detached CARenderer diagnostic. No window, view snapshot, or private API.
/// A successful capture proves completeness only; its pixels need independent comparison.
nonisolated enum NativeDetachedWorkerMetalCapture {
    struct Result {
        let image: CGImage
        /// Metal texture row order, premultiplied sRGB RGBA8. Orientation is a diagnostic observation.
        let canonicalRGBA: Data
        let width: Int
        let height: Int
        let metadata: [String: Any]
    }

    enum Failure: Error { case invalidGeometry, attachedRoot, unavailableMetal, allocation, command(String), image }

    static func capture(root: CALayer, size: CGSize, scale: CGFloat, checkCancellation: () throws -> Void = { if Thread.current.isCancelled { throw CancellationError() } }) throws -> Result {
        try checkCancellation()
        guard !Thread.isMainThread else { throw Failure.command("Worker capture must not block main thread") }
        guard root.superlayer == nil else { throw Failure.attachedRoot }
        let wp = size.width * scale, hp = size.height * scale
        guard size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0,
              wp > 0, hp > 0, wp <= 16_384, hp <= 16_384,
              wp.rounded() == wp, hp.rounded() == hp, wp * hp <= 12_000_000 else { throw Failure.invalidGeometry }
        let width = Int(wp), height = Int(hp)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.unavailableMetal
        }
        queue.label = "NativeDetachedWorkerMetalCapture"
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
            height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor),
              let clear = queue.makeCommandBuffer() else { throw Failure.allocation }
        texture.label = "Detached CARenderer diagnostic target"
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = clear.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocation }
        encoder.endEncoding()
        clear.label = "Detached CARenderer target clear"
        try commitAndComplete(clear)
        try checkCancellation()

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererColorSpace: colorSpace,
            kCARendererMetalCommandQueue: queue
        ])
        let oldPosition = root.position, oldAnchor = root.anchorPoint, oldTransform = root.transform
        let original: [String: Any] = ["bounds": rect(root.bounds), "position": point(oldPosition),
            "anchorPoint": point(oldAnchor), "transform": matrix(oldTransform), "contentsScale": root.contentsScale]
        let container = CALayer()
        container.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        container.anchorPoint = .zero; container.position = .zero
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.anchorPoint = .zero; root.position = .zero
        root.transform = CATransform3DConcat(oldTransform, CATransform3DMakeScale(scale, scale, 1))
        container.addSublayer(root)
        CATransaction.commit()
        renderer.layer = container
        renderer.bounds = container.bounds
        defer {
            renderer.layer = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            root.removeFromSuperlayer()
            root.anchorPoint = oldAnchor; root.position = oldPosition; root.transform = oldTransform
            CATransaction.commit()
        }
        try checkCancellation()
        root.displayIfNeeded(); container.displayIfNeeded()
        // layer assignment follows the earlier explicit transaction. Commit its
        // implicit render-tree update before manually rendering in this same turn.
        CATransaction.flush()
        let time = CACurrentMediaTime()
        renderer.beginFrame(atTime: time, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        // The public header requires client synchronization when supplying this queue.
        // Encode a real read dependency on the rendered target, not an empty marker.
        // CPU reads only the shared buffer after this texture-copy command completes.
        let readbackRowBytes = (width * 4 + 255) / 256 * 256
        guard let buffer = device.makeBuffer(length: readbackRowBytes * height, options: .storageModeShared),
              let copy = queue.makeCommandBuffer(), let blit = copy.makeBlitCommandEncoder() else { throw Failure.allocation }
        buffer.label = "Detached CARenderer shared readback"
        copy.label = "Detached CARenderer target texture readback"
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: readbackRowBytes, destinationBytesPerImage: readbackRowBytes * height)
        blit.endEncoding()
        try commitAndComplete(copy)
        try checkCancellation()
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        try bgra.withUnsafeMutableBytes { destination in
            for y in 0..<height {
                if y % 64 == 0 { try checkCancellation() }
                destination.baseAddress!.advanced(by: y * width * 4).copyMemory(
                    from: buffer.contents().advanced(by: y * readbackRowBytes), byteCount: width * 4)
            }
        }
        for offset in stride(from: 0, to: bgra.count, by: 4) {
            if offset % 16_384 == 0 { try checkCancellation() }
            bgra.swapAt(offset, offset + 2)
        }
        let bytes = Data(bgra)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.image }
        try checkCancellation()
        return Result(image: image, canonicalRGBA: bytes, width: width, height: height, metadata: [
            "route": "public CARenderer(mtlTexture:options:), detached CALayer tree",
            "windowAttachment": false, "actualThreadIsMain": Thread.isMainThread,
            "waitPolicy": "synchronous waitUntilCompleted on caller-owned background thread only", "sizeCSS": [size.width, size.height], "scale": scale,
            "pixelSize": [width, height], "pixelBudget": 12_000_000,
            "device": device.name, "texturePixelFormat": "bgra8Unorm", "storageMode": "shared",
            "outputColorSpace": colorSpace.name as String? ?? "nil",
            "synchronization": "await target-clear completion; public supplied Metal queue; await actual target-texture to shared-buffer blit completion before CPU buffer read",
            "clearCommandStatus": clear.status.rawValue, "clearCommandError": clear.error?.localizedDescription ?? "nil",
            "readbackCommandStatus": copy.status.rawValue, "readbackCommandError": copy.error?.localizedDescription ?? "nil",
            "readbackRowBytes": readbackRowBytes, "readbackBufferLength": buffer.length,
            "readbackStorageMode": "shared", "readbackOperation": "MTLBlitCommandEncoder.copy texture to buffer",
            "CARendererInternalCommandStatus": "not exposed by public CARenderer API",
            "rendererBounds": rect(renderer.bounds), "frameTime": time, "originalRoot": original,
            "renderTreeCommit": "public CATransaction.flush after layer assignment/display and before beginFrame",
            "renderRootTransform": matrix(root.transform), "rawOrientation": "texture row order, no postcapture flipping",
            "canonicalTransport": "BGRA8 to premultiplied sRGB RGBA8 channel exchange only",
            "pixelParityAsserted": false
        ])
    }

    private static func commitAndComplete(_ command: any MTLCommandBuffer) throws {
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw Failure.command("\(command.label ?? "Metal command") status \(command.status.rawValue): " +
                (command.error?.localizedDescription ?? "no public Metal error"))
        }
    }

    private static func rect(_ v: CGRect) -> [CGFloat] { [v.minX, v.minY, v.width, v.height] }
    private static func point(_ v: CGPoint) -> [CGFloat] { [v.x, v.y] }
    private static func matrix(_ v: CATransform3D) -> [CGFloat] {
        [v.m11,v.m12,v.m13,v.m14,v.m21,v.m22,v.m23,v.m24,v.m31,v.m32,v.m33,v.m34,v.m41,v.m42,v.m43,v.m44]
    }
}

/// The same two integer, opaque source controls. Every layer is created on the caller's worker.
nonisolated enum NativeDetachedGradientWorkerScene {
    static func capture(rgb: [Double], scale: CGFloat = 3,
                        checkCancellation: () throws -> Void = { if Thread.current.isCancelled { throw CancellationError() } })
        throws -> NativeDetachedWorkerMetalCapture.Result {
        let page = CGRect(x: 0, y: 0, width: 320, height: 160)
        let root = CALayer(); root.frame = page; root.contentsScale = scale
        func color(_ values: [Double]) -> CGColor {
            CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: values.map { CGFloat(Float($0 / 255)) } + [1])!
        }
        root.backgroundColor = color([41,65,87])
        let gradient = CAGradientLayer(); gradient.frame = CGRect(x: 20, y: 20, width: 96, height: 96)
        gradient.contentsScale = scale; gradient.type = .axial
        gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.locations = [0,1]; gradient.colors = [color(rgb),color(rgb)]
        root.addSublayer(gradient)
        let anchor = root.anchorPoint, position = root.position
        defer { gradient.removeFromSuperlayer(); CATransaction.flush() }
        let result = try NativeDetachedWorkerMetalCapture.capture(root: root, size: page.size, scale: scale,
            checkCancellation: checkCancellation)
        var metadata = result.metadata
        metadata["rootModelRestored"] = root.superlayer == nil && root.bounds == page && root.anchorPoint == anchor &&
            root.position == position && CATransform3DIsIdentity(root.transform)
        metadata["privateTreeCreatedOnMainThread"] = Thread.isMainThread
        metadata["sourceRGB"] = rgb; metadata["sourceFrameCSS"] = [20,20,96,96]
        metadata["declaredSRGBComponents"] = color(rgb).components ?? []
        try checkCancellation()
        return .init(image: result.image, canonicalRGBA: result.canonicalRGBA, width: result.width, height: result.height,
            metadata: metadata)
    }
}
