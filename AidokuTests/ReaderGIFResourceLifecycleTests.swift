import AsyncDisplayKit
import Gifu
import ImageIO
import Testing
import UIKit
@testable import Aidoku

@MainActor struct ReaderGIFResourceLifecycleTests {
    @Test func releasedPagedImageDropsFramesAndCanAnimateAgain() async throws {
        let store = ReaderTemporaryPageStore()
        let view = ReaderPageView(temporaryPageStore: store)
        // Exercise the same presentation method as a successful Nuke GIF load.
        let data = try makeGIF()
        let image = try #require(UIImage(data: data))
        view.setPageImage(image, gifData: data)
        #expect(view.imageView.frameCount == 2)
        #expect(view.imageView.isAnimatingGIF)

        view.releasePageResources()
        #expect(view.imageView.frameCount == 0)
        #expect(!view.imageView.isAnimatingGIF)
        #expect(view.imageView.image == nil)

        view.setPageImage(image, gifData: data)
        #expect(view.imageView.frameCount == 2)
        #expect(view.imageView.isAnimatingGIF)
        #expect(view.imageView.image === image)
        view.releasePageResources()
        await store.removeAll()
    }

    @Test func resetWebtoonNodeDropsFramesAndCanAnimateAgain() async throws {
        let node = GIFImageNode()
        _ = node.view
        let imageView = try #require(node.imageView)
        let data = try makeGIF()
        let image = try #require(UIImage(data: data))
        node.image = image
        node.animatedData = data
        #expect(node.commitImage())
        #expect(imageView.frameCount == 2)
        #expect(imageView.isAnimatingGIF)

        node.reset()
        // Texture-backed resource release is deliberately deferred to MainActor.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while imageView.frameCount != 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(imageView.frameCount == 0)
        #expect(!imageView.isAnimatingGIF)
        #expect(imageView.image == nil)

        node.image = image
        node.animatedData = data
        #expect(node.commitImage())
        #expect(imageView.frameCount == 2)
        #expect(imageView.isAnimatingGIF)
        #expect(imageView.image === image)
        imageView.prepareForReuse()
    }

    private func makeGIF() throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for color in [UIColor.red, .blue] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            CGImageDestinationAddImage(destination, try #require(image.cgImage),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
