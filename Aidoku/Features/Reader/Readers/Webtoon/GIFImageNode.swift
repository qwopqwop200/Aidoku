//
//  GIFImageNode.swift
//  Aidoku
//
//  Created by Skitty on 6/23/25.
//

import AsyncDisplayKit
import Gifu
import VisionKit

class GIFImageNode: ASControlNode {
    var imageView: GIFImageView?
    var animatedData: Data?
    var storedInteractions: [UIInteraction] = []

    override var contentMode: UIView.ContentMode {
        didSet {
            imageView?.contentMode = contentMode
        }
    }

    private var imageGeneration = UUID()

    var image: UIImage? {
        didSet {
            imageGeneration = UUID()
            let generation = imageGeneration
            Task { @MainActor in
                guard generation == imageGeneration else { return }
                imageView?.image = image
                NotificationCenter.default.post(name: ReaderTranslationPage.imageChanged, object: nil)
            }
        }
    }

    override var isUserInteractionEnabled: Bool {
        didSet {
            imageView?.isUserInteractionEnabled = isUserInteractionEnabled
        }
    }

    @available(iOS 16.0, *)
    var imageAnalaysisInteraction: ImageAnalysisInteraction? {
        imageView?.interactions.first(where: { $0 is ImageAnalysisInteraction }) as? ImageAnalysisInteraction
    }

    override init() {
        super.init()

        setViewBlock { [weak self] in
            let gifView = GIFImageView()
            gifView.image = self?.image
            gifView.isUserInteractionEnabled = true
            if let contentMode = self?.contentMode {
                gifView.contentMode = contentMode
            }
            if let data = self?.animatedData {
                gifView.animate(withGIFData: data)
                self?.animatedData = nil
            }
            if let storedInteractions = self?.storedInteractions {
                storedInteractions.forEach {
                    gifView.addInteraction($0)
                }
                self?.storedInteractions = []
            }
            self?.imageView = gifView
            // Texture can create the backing view after the preload image notification.
            // Publish readiness again so visible-page translation binds to this view.
            Task { @MainActor [weak self] in
                guard self?.imageView === gifView else { return }
                NotificationCenter.default.post(name: ReaderTranslationPage.imageChanged, object: nil)
            }
            return gifView
        }
    }

    func animate(withGIFData data: Data) {
        if let imageView {
            Task { @MainActor in
                imageView.animate(withGIFData: data)
            }
        } else {
            animatedData = data
        }
    }

    func reset() {
        animatedData = nil
        image = nil
        let generation = imageGeneration

        Task { @MainActor [weak self] in
            guard let self, generation == imageGeneration else { return }
            imageView?.stopAnimatingGIF()
            imageView?.image = nil
        }
    }

    @MainActor
    func addInteraction(_ interaction: UIInteraction) {
        if let imageView {
            imageView.addInteraction(interaction)
        } else {
            storedInteractions.append(interaction)
        }
    }

    @MainActor
    @available(iOS 16.0, *)
    func removeImageAnalysisInteraction() {
        guard
            let imageView,
            let interaction = imageView.interactions.first(where: { $0 is ImageAnalysisInteraction })
        else {
            return
        }
        imageView.removeInteraction(interaction)
    }
}
