import Testing
import Foundation
import CoreGraphics
import QuartzCore
@testable import Aidoku

@MainActor
struct NativeLayerTreeCaptureTests {
    @Test
    func privateWorkerOutputRetainsPixelsAfterGPUAndGraphRelease() async throws {
        let result = try await Task.detached {
            try NativeLayerTreeCapture.capture(size: CGSize(width: 64, height: 40), scale: 2) {
                CaptureCoreTestGraph.make()
            }
        }.value
        #expect(result.pixelSize == CGSize(width: 128, height: 80))
        let data = try #require(result.image.dataProvider?.data) as Data
        #expect(data.count == 128 * 80 * 4)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(data[(y * 128 + x) * 4..<(y * 128 + x + 1) * 4]) }
        // Independent asymmetric source rectangle at [6,4,11,9] CSS; exact opaque colors.
        #expect(pixel(0, 0) == [255,255,255,255])
        #expect(pixel(12, 8) == [255,0,0,255])
        #expect(pixel(33, 25) == [255,0,0,255])
        #expect(pixel(34, 26) == [255,255,255,255])
        #expect(pixel(12, 72) == [255,255,255,255])
    }

    @Test
    func invalidRasterAndPrivateRootAreRejectedBeforePublication() async {
        let checks = await Task.detached { () -> [Bool] in
            var result: [Bool] = []
            for size in [CGSize(width: CGFloat.nan, height: 40), CGSize(width: 4000, height: 4000), CGSize(width: 64.125, height: 40)] {
                var graphMade = false
                do {
                    _ = try NativeLayerTreeCapture.capture(size: size, scale: 1) {
                        graphMade = true; return CaptureCoreTestGraph.make()
                    }
                    result.append(false)
                } catch NativeLayerTreeCapture.Failure.invalidGeometry { result.append(!graphMade) }
                catch { result.append(false) }
            }
            do {
                _ = try NativeLayerTreeCapture.capture(size: CGSize(width: 64, height: 40), scale: 2) {
                    let root = CaptureCoreTestGraph.make(); root.bounds.origin.x = 1; return root
                }
                result.append(false)
            } catch NativeLayerTreeCapture.Failure.invalidRoot { result.append(true) }
            catch { result.append(false) }
            return result
        }.value
        #expect(checks == [true,true,true,true])
    }

    @Test
    func actualSwiftTaskCancellationAfterCleanupPreventsPublication() async {
        let checkpoint = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let job = Task.detached { () -> Bool in
            defer { checkpoint.continuation.finish() }
            var owned: CALayer?, sawAttached = false
            do {
                _ = try NativeLayerTreeCapture.capture(size: CGSize(width: 64, height: 40), scale: 2,
                    checkCancellation: {
                        if owned?.superlayer != nil { sawAttached = true }
                        // The private graph was attached during rendering, then actually restored.
                        if sawAttached && owned?.superlayer == nil {
                            checkpoint.continuation.yield(()); release.wait()
                        }
                        try Task.checkCancellation()
                    }, makeRoot: {
                        let root = CaptureCoreTestGraph.make(); owned = root; return root
                    })
                return false
            } catch is CancellationError {
                guard let root = owned else { return false }
                return root.superlayer == nil && root.frame == CGRect(x: 0, y: 0, width: 64, height: 40) &&
                    CATransform3DIsIdentity(root.transform)
            } catch { return false }
        }
        var reached = false
        for await _ in checkpoint.stream {
            reached = true; job.cancel(); release.signal(); break
        }
        #expect(reached)
        #expect(await job.value)
    }
}

nonisolated private enum CaptureCoreTestGraph {
    static func make() -> CALayer {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let root = CALayer(); root.frame = CGRect(x: 0, y: 0, width: 64, height: 40)
        root.backgroundColor = CGColor(colorSpace: space, components: [1,1,1,1])!
        let child = CALayer(); child.frame = CGRect(x: 6, y: 4, width: 11, height: 9)
        child.backgroundColor = CGColor(colorSpace: space, components: [1,0,0,1])!
        root.addSublayer(child)
        return root
    }
}
