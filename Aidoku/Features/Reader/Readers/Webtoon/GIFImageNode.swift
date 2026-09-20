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
    var onImageAssigned: (@MainActor (GIFImageView) -> Bool)?

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
            Task { @MainActor [weak self] in
                guard let self, generation == imageGeneration else { return }
                commitImage()
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
            gifView.isUserInteractionEnabled = true
            if let contentMode = self?.contentMode {
                gifView.contentMode = contentMode
            }
            if let storedInteractions = self?.storedInteractions {
                storedInteractions.forEach {
                    gifView.addInteraction($0)
                }
                self?.storedInteractions = []
            }
            self?.imageView = gifView
            // The view can appear after decoding. Install raw pixels and the prepared
            // canvas in one main-actor turn before publishing readiness.
            Task { @MainActor [weak self] in
                guard let self, imageView === gifView else { return }
                commitImage()
            }
            return gifView
        }
    }

    @MainActor
    @discardableResult
    func commitImage() -> Bool {
        guard let imageView else { return false }
        imageView.image = image
        guard onImageAssigned?(imageView) != false else {
            imageView.stopAnimatingGIF()
            imageView.image = nil
            return false
        }
        if let animatedData, image != nil {
            imageView.animate(withGIFData: animatedData)
            self.animatedData = nil
        }
        NotificationCenter.default.post(name: ReaderTranslationPage.imageChanged, object: imageView)
        return true
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
