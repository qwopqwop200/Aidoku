import Nuke
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderRawImageProcessingTests {
    @Test func synchronousProcessorCanReturnToMainActorWithoutBlockingReader() async throws {
        let image = makeImage()
        let result = try await ReaderPageView.processRawImage(image, processors: [MainActorRoundTripProcessor()])
        #expect(result === image)
    }

    @Test func rawProcessingPreservesProcessorOrderAndExactPixels() async throws {
        let image = makeImage()
        let processors: [ImageProcessing] = [CropBordersProcessor(), DownsampleProcessor(width: 7)]
        var expected = image
        for processor in processors { expected = processor.process(expected) ?? expected }
        let actual = try await ReaderPageView.processRawImage(image, processors: processors)
        #expect(actual.size == expected.size)
        #expect(actual.scale == expected.scale)
        #expect(actual.imageOrientation == expected.imageOrientation)
        #expect(actual.pngData() == expected.pngData())
        let actualBytes = try #require(actual.cgImage?.dataProvider?.data)
        let expectedBytes = try #require(expected.cgImage?.dataProvider?.data)
        #expect(actualBytes as Data == expectedBytes as Data)
    }

    @Test func cancelledRawProcessingDoesNotRunProcessors() async throws {
        let image = makeImage()
        let task = Task { @MainActor in
            try await ReaderPageView.processRawImage(image, processors: [MustNotRunProcessor()])
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled raw page was processed")
        } catch is CancellationError { }
    }

    private func makeImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 31, height: 29), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 31, height: 29))
            UIColor.red.setFill()
            context.fill(CGRect(x: 3, y: 5, width: 21, height: 17))
        }
    }
}

private struct MainActorRoundTripProcessor: ImageProcessing {
    let identifier = "audit-main-actor-round-trip"
    func process(_ image: PlatformImage) -> PlatformImage? {
        // Fail without hanging the suite if the blocking work regresses onto main.
        guard !Thread.isMainThread else {
            Issue.record("Synchronous raw-image processing blocks the main thread")
            return image
        }
        return BlockingTask {
            await MainActor.run { image }
        }.get()
    }
}

private struct MustNotRunProcessor: ImageProcessing {
    let identifier = "audit-cancelled-processor"
    func process(_ image: PlatformImage) -> PlatformImage? {
        Issue.record("A cancelled raw-image operation reached its processor")
        return image
    }
}
