//
//  UpscaleProcessor.swift
//  Aidoku
//
//  Created by Skitty on 6/24/25.
//

import Nuke
import UIKit
import Vision

struct UpscaleProcessor: ImageProcessing {
    private let modelFile = ModelManager.shared.getEnabledModelFileName()
    private let maxHeight = UserDefaults.standard.integer(forKey: "Reader.upscaleMaxHeight")

    var identifier: String {
        "com.github.Aidoku/Aidoku/upscale-v2/\(modelFile ?? "none")/\(maxHeight)"
    }

    func process(_ image: PlatformImage) -> PlatformImage? {
        guard let cgImage = image.cgImage else { return image }

        // ensure an upscaling model is enabled
        guard let modelFile else {
            return image
        }

        // ensure image is smaller than max height
        guard cgImage.height < maxHeight else { return image }

        return BlockingTask {
            let model: ImageProcessingModel
            do {
                guard let imageModel = try await ModelManager.shared.getModel(fileName: modelFile) else {
                    throw ProcessorError.invalidModel
                }
                model = imageModel
            } catch {
                LogManager.logger.error("Unable to load enabled upscaling model: \(error)")
                return image
            }
            guard let output = await model.process(cgImage) else {
                LogManager.logger.error("Upscaling model failed to process image")
                return image
            }
            return await PlatformImage(cgImage: output, scale: UIScreen.main.scale, orientation: image.imageOrientation)
        }.get()
    }

    enum ProcessorError: Error {
        case invalidModel
    }
}
