//
//  UIImage.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 6/13/22.
//

import Photos
import UIKit

@MainActor
private enum PhotoAlbumSaveQueue {
    static var task: Task<Void, Never>?
    static var generation: UInt64 = 0
}

extension UIImage {
    @MainActor
    func saveToAlbum(_ name: String? = nil, viewController: UIViewController) {
        let previous = PhotoAlbumSaveQueue.task
        PhotoAlbumSaveQueue.generation &+= 1
        let generation = PhotoAlbumSaveQueue.generation
        PhotoAlbumSaveQueue.task = Task { @MainActor [weak viewController] in
            // Rapid saves must see the album created by the preceding transaction.
            await previous?.value
            defer {
                if PhotoAlbumSaveQueue.generation == generation { PhotoAlbumSaveQueue.task = nil }
            }
            var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined {
                status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            guard status == .authorized || status == .limited else {
                guard let viewController else { return }
                let alert = confirmAction(
                    title: NSLocalizedString("ENABLE_PERMISSION"),
                    message: NSLocalizedString("PHOTOS_ACCESS_DENIED_TEXT"),
                    continueActionName: NSLocalizedString("SETTINGS"),
                    destructive: false
                ) {
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settings)
                    }
                }
                viewController.present(alert, animated: true)
                return
            }
            let albumName = name ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Aidoku"
            do {
                try await saveToPhotoLibrary(albumName: albumName, authorizationStatus: status)
            } catch {
                LogManager.logger.error("Failed to save image: \(error.localizedDescription)")
                guard let viewController else { return }
                let alert = UIAlertController(title: NSLocalizedString("UNKNOWN_ERROR"),
                    message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .default))
                viewController.present(alert, animated: true)
            }
        }
    }

    /// Limited access permits adding images but not fetching or creating user albums.
    @MainActor
    @discardableResult
    func saveToPhotoLibrary(albumName: String, authorizationStatus: PHAuthorizationStatus) async throws -> String? {
        let supportsAlbums = authorizationStatus == .authorized
        let album = supportsAlbums ? fetchAlbum(albumName) : nil
        let result = PhotoAssetSaveResult()
        try await PHPhotoLibrary.shared().performChanges {
            let asset = PHAssetChangeRequest.creationRequestForAsset(from: self)
            guard let placeholder = asset.placeholderForCreatedAsset else { return }
            result.set(placeholder.localIdentifier)
            guard supportsAlbums else { return }
            let collection = album.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
            collection.addAssets([placeholder] as NSFastEnumeration)
        }
        return result.get()
    }

}

@MainActor
private func confirmAction(
    title: String? = nil,
    message: String? = nil,
    actions: [UIAlertAction] = [],
    continueActionName: String = NSLocalizedString("CONTINUE"),
    destructive: Bool = true,
    proceed: @escaping () -> Void
) -> UIAlertController {
    let alertView = UIAlertController(
        title: title,
        message: message,
        preferredStyle: UIDevice.current.userInterfaceIdiom == .pad ? .alert : .actionSheet
    )

    for action in actions {
        alertView.addAction(action)
    }
    let action = UIAlertAction(
        title: continueActionName,
        style: destructive ? .destructive : .default
    ) { _ in
        proceed()
    }
    alertView.addAction(action)

    alertView.addAction(UIAlertAction(title: NSLocalizedString("CANCEL"), style: .cancel))

    return alertView
}

private func fetchAlbum(_ name: String) -> PHAssetCollection? {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "title == %@", name)
    return PHAssetCollection.fetchAssetCollections(
        with: .album, subtype: .any, options: options
    ).firstObject
}

private final class PhotoAssetSaveResult: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: String?

    func set(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        identifier = value
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return identifier
    }
}
