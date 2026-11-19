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
