import Gifu
import ImageIO
import Testing
import UIKit
@testable import Aidoku

@MainActor
struct MangaCoverGIFLifetimeTests {
    @Test(arguments: [false, true])
    func reuseReleasesCoverFramesAndAllowsReconstruction(list: Bool) throws {
        let cell: UICollectionViewCell = list ? MangaListCell() : MangaGridCell()
        let imageView = list ? (cell as! MangaListCell).coverImageView : (cell as! MangaGridCell).imageView
        let data = try makeGIF()
        imageView.animate(withGIFData: data)
        #expect(imageView.frameCount == 2)

        cell.prepareForReuse()
        #expect(imageView.frameCount == 0)
        #expect(!imageView.isAnimatingGIF)

        imageView.animate(withGIFData: data)
        #expect(imageView.frameCount == 2)
        #expect(imageView.isAnimatingGIF)
        cell.prepareForReuse()
    }

    @Test(arguments: [false, true])
    func missingCoverReleasesPreviousAnimation(list: Bool) async throws {
        let data = try makeGIF()
        if list {
            let cell = MangaListCell()
            cell.coverImageView.animate(withGIFData: data)
            #expect(cell.coverImageView.frameCount == 2)
            cell.startImageLoad(url: nil)
            await cell.preparationTask?.value
            #expect(cell.coverImageView.frameCount == 0)
        } else {
            let cell = MangaGridCell()
            cell.imageView.animate(withGIFData: data)
            #expect(cell.imageView.frameCount == 2)
            cell.startImageLoad(url: nil)
            await cell.preparationTask?.value
            #expect(cell.imageView.frameCount == 0)
        }
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
