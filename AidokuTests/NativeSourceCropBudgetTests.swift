import CoreGraphics
import Testing
@testable import Aidoku

/// Geometry-only checks. No original image, model, inference or dataset label.
struct NativeSourceCropBudgetTests {
    @Test func partiallyOffPageOwnerUsesOnlyVisiblePixelsInLocalBox() throws {
        let page = CGSize(width: 2160, height: 2880)
        let box = CGRect(x: 0.42289256004838938 * page.width, y: 0.58386654651250169 * page.height,
            width: 0.02753781491016033 * page.width, height: 0.42274954383797603 * page.height)
        let crop = try NativeSourceInputFactory.sourceCrop(box: box, pageSize: page)
        let local = NativeSourceInputFactory.localVisibleBox(box, crop: crop)
        let visible = box.intersection(CGRect(origin: .zero, size: page))
        let expectedCrop = visible.insetBy(dx: -visible.width * 0.15, dy: -visible.height * 0.15)
            .integral.intersection(CGRect(origin: .zero, size: page))
        #expect(crop == expectedCrop)
        #expect(box.maxY > page.height)
        #expect(local.minX == box.minX - crop.minX)
        #expect(local.minY == box.minY - crop.minY)
        #expect(abs(local.width - box.width) < 1e-10)
        #expect(abs(local.maxY - crop.height) < 1e-10)
    }

    @Test func contextPaddingCannotAdmitAnEntirelyOffPageOwner() {
        #expect(throws: NativeSourceInputFactory.Failure.self) {
            try NativeSourceInputFactory.sourceCrop(box: CGRect(x: 8, y: 101, width: 20, height: 20),
                pageSize: CGSize(width: 100, height: 100))
        }
    }

    @Test func reportedOriginalResolutionBoxRetainsEntireBoxWithinBudget() throws {
        let page = CGSize(width: 2160, height: 2880)
        let box = CGRect(x: 0.54397215406202193 * page.width, y: 0.056144712272797818 * page.height,
            width: 0.42375294324572615 * page.width, height: 0.36952053132912388 * page.height)
        let ordinary = box.insetBy(dx: -box.width * 0.15, dy: -box.height * 0.15).integral
            .intersection(CGRect(origin: .zero, size: page))
        #expect(ordinary.width * ordinary.height > 1_500_000)
        let crop = try NativeSourceInputFactory.sourceCrop(box: box, pageSize: page)
        #expect(crop.contains(box))
        #expect(crop == crop.integral)
        #expect(crop.width * crop.height <= 1_500_000)
        #expect(crop != ordinary)
    }

    @Test func normalAndPageClippedCropsAreExactlyUnchanged() throws {
        let page = CGSize(width: 2160, height: 2880)
        for box in [CGRect(x: 100.2, y: 200.3, width: 100.4, height: 250.6),
                    CGRect(x: 0, y: 0, width: 900, height: 1000),
                    CGRect(x: 2000.1, y: 2700.2, width: 159.9, height: 179.8)] {
            let expected = box.insetBy(dx: -box.width * 0.15, dy: -box.height * 0.15).integral
                .intersection(CGRect(origin: .zero, size: page))
            let actual = try NativeSourceInputFactory.sourceCrop(box: box, pageSize: page)
            #expect(actual == expected)
            #expect(actual.contains(box))
        }
    }

    @Test func exactBudgetBaseIsKeptWithoutShrinkingAndLargerBaseIsTypedFailure() throws {
        let page = CGSize(width: 3000, height: 3000)
        let exact = CGRect(x: 500, y: 500, width: 1000, height: 1500)
        #expect(try NativeSourceInputFactory.sourceCrop(box: exact, pageSize: page) == exact)
        do {
            _ = try NativeSourceInputFactory.sourceCrop(box: CGRect(x: 500, y: 500, width: 1001, height: 1500), pageSize: page)
            Issue.record("An over-budget bbox must fail explicitly, not shrink")
        } catch NativeSourceInputFactory.Failure.sourceCropBudgetExceeded(let width, let height, let budget) {
            #expect(width == 1001 && height == 1500 && budget == 1_500_000)
        }
    }

    @Test func integralRoundingAndPageClipAreIncludedInBudgetSearch() throws {
        let page = CGSize(width: 1300, height: 1300)
        let box = CGRect(x: 0.2, y: 0.3, width: 1100.4, height: 1100.5)
        let crop = try NativeSourceInputFactory.sourceCrop(box: box, pageSize: page)
        #expect(crop.contains(box))
        #expect(crop.minX == 0 && crop.minY == 0)
        #expect(crop.width * crop.height <= 1_500_000)
        #expect(crop.maxX <= page.width && crop.maxY <= page.height)
    }
}
