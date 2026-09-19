//
//  GIFImage.swift
//  Aidoku
//
//  Created by Skitty on 6/23/25.
//

import Gifu
import SwiftUI

struct GIFImage: UIViewRepresentable {
    var image: UIImage?
    var data: Data
    var contentMode: ContentMode = .fill

    final class Coordinator {
        var data: Data?
        weak var image: UIImage?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> GIFImageView {
        let imageView = GIFImageView(frame: .zero)
        imageView.isUserInteractionEnabled = true
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return imageView
    }

    func updateUIView(_ uiView: GIFImageView, context: Context) {
        // SwiftUI also updates this view for layout and theme changes. Restarting
        // the decoder on each update resets the animation and repeats frame work.
        if context.coordinator.data != data {
            context.coordinator.data = data
            context.coordinator.image = image
            uiView.image = image
            uiView.animate(withGIFData: data)
        } else if context.coordinator.image !== image {
            context.coordinator.image = image
            uiView.image = image
        }
        uiView.contentMode = switch contentMode {
            case .fit: .scaleAspectFit
            case .fill: .scaleAspectFill
        }
    }

    static func dismantleUIView(_ uiView: GIFImageView, coordinator: Coordinator) {
        uiView.stopAnimatingGIF()
        coordinator.data = nil
    }
}
