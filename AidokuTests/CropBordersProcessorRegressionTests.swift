import AidokuRunner
import Nuke
import Testing
import UIKit
@testable import Aidoku

struct CropBordersProcessorRegressionTests {
    @Test @MainActor func downsamplePanoramaKeepsAtLeastOnePixel() throws {
        let source = UIImage(cgImage: try image(width: 1000, height: 1, fill: nil))
        let output = try #require(DownsampleProcessor(width: 10).process(source)?.cgImage)
        #expect(output.width == Int(10 * UIScreen.main.scale))
        #expect(output.height == 1)
    }

    @Test @MainActor func invalidDownsampleSizePreservesSource() throws {
        let source = UIImage(cgImage: try image(fill: nil))
        #expect(DownsampleProcessor(size: .zero).process(source) === source)
    }

    private func image(width: Int = 10, height: Int = 10, fill: CGRect?) throws -> CGImage {
        let context = try #require(CropBordersProcessor().createARGBBitmapContext(width: width, height: height))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let fill {
            context.setFillColor(UIColor.gray.cgColor)
            context.fill(fill)
        }
        return try #require(context.makeImage())
    }

    @Test func includesLastRetainedPixel() throws {
        let source = try image(fill: CGRect(x: 2, y: 2, width: 6, height: 6))
        #expect(CropBordersProcessor().createCropRect(source) == CGRect(x: 2, y: 2, width: 6, height: 6))
    }

    @Test func stripsPreserveBoundaryAndFinalPartialRow() throws {
        for y in [0, 1, 127, 128, 129, 255, 256] {
            let source = try image(width: 20, height: 257, fill: CGRect(x: 7, y: y, width: 1, height: 1))
            #expect(CropBordersProcessor().createCropRect(source) == CGRect(x: 7, y: 256 - y, width: 1, height: 1))
        }
    }

    @Test func singlePixelHasArea() throws {
        let source = try image(width: 1, height: 1, fill: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(CropBordersProcessor().createCropRect(source) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func emptyContentAndInvalidScaleReturnEmptyBounds() throws {
        let source = try image(fill: nil)
        #expect(CropBordersProcessor().createCropRect(source) == .zero)
        #expect(CropBordersProcessor().createCropRect(source, scale: 0) == .zero)
        #expect(CropBordersProcessor().createCropRect(source, scale: .nan) == .zero)
    }

    @Test func preservesPixelScaleAndOrientation() throws {
        let pixels = try image(width: 100, height: 100, fill: CGRect(x: 0, y: 0, width: 100, height: 100))
        let source = UIImage(cgImage: pixels, scale: 2, orientation: .right)
        let result = try #require(CropBordersProcessor().process(source))
        #expect(result.cgImage?.width == 100)
        #expect(result.cgImage?.height == 100)
        #expect(result.scale == 2)
        #expect(result.imageOrientation == .right)
    }

    @Test func rotatedAsymmetricBordersRetainCompleteContent() throws {
        let pixels = try image(width: 100, height: 80, fill: CGRect(x: 20, y: 10, width: 60, height: 40))
        let source = UIImage(cgImage: pixels, scale: 2, orientation: .right)
        let result = try #require(CropBordersProcessor().process(source))
        #expect(result.cgImage?.width == 60)
        #expect(result.cgImage?.height == 40)
        #expect(result.scale == 2)
        #expect(result.imageOrientation == .right)
        let output = try #require(result.cgImage)
        #expect(CropBordersProcessor().createCropRect(output) == CGRect(x: 0, y: 0, width: 60, height: 40))
    }

    @Test func failedCoverProcessingReleasesSourceHandle() async throws {
        let runner = TestableSourceRunner(failsProcessing: true, processesCovers: true)
        let source = AidokuRunner.Source.test(runner: runner)
        let request = ImageRequest(urlRequest: URLRequest(url: URL(string: "https://test.invalid/cover")!))
        let container = ImageContainer(image: .mangaPlaceholder)
        do {
            _ = try await CoverInterceptorProcessor(source: source).processAsync(container,
                context: .init(request: request, response: .init(container: container, request: request), isCompleted: true))
            Issue.record("Expected cancellation from source")
        } catch is CancellationError { }
        #expect(await runner.storage.liveCount() == 0)
    }
}
