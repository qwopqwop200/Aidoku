import Photos
import Testing
import UIKit
@testable import Aidoku

@MainActor @Suite(.serialized)
struct ImageAlbumSavingTests {
    @Test
    func repeatedSavesCreateOneAlbumAndRetainBothImages() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        try #require(status == .authorized, "Photo regression requires simulator Photos permission; status \(status.rawValue)")
        let title = "Aidoku-audit-\(UUID().uuidString)"
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        let controller = UIViewController()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        image.saveToAlbum(title, viewController: controller)
        image.saveToAlbum(title, viewController: controller)
        var album: PHAssetCollection?
        for _ in 0..<400 {
            album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject
            if let album, PHAsset.fetchAssets(in: album, options: nil).count == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let saved = try #require(album)
        let assets = PHAsset.fetchAssets(in: saved, options: nil)
        #expect(assets.count == 2)
        #expect(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).count == 1)
        // Delete only records this uniquely named test created.
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
            PHAssetCollectionChangeRequest.deleteAssetCollections([saved] as NSArray)
        }
    }

    @Test
    func limitedAccessSavePathAddsAssetWithoutCreatingUserAlbum() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        try #require(status == .authorized, "This Photos integration fixture requires full simulator permission")
        let title = "Aidoku-limited-audit-\(UUID().uuidString)"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 23, height: 19)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 23, height: 19))
        }
        // Exercise the production limited-permission branch with actual Photos writes.
        // Simulator permission remains full so the fixture can inspect and remove its asset.
        let identifier = try #require(try await image.saveToPhotoLibrary(albumName: title, authorizationStatus: .limited))
        let added = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        #expect(added.count == 1)
        #expect(added.firstObject?.pixelWidth == 23 * Int(UIScreen.main.scale))
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        #expect(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).count == 0)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(added)
        }
    }

}
