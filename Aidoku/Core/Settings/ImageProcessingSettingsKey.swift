//
//  ImageProcessingSettingsKey.swift
//  Aidoku
//
//  Created by 686udjie on 26/11/2025.
//

import Foundation

enum ImageProcessingSettingsKey {
    static func getProcessorSettingsKey() -> String {
        let crop = UserDefaults.standard.bool(forKey: "Reader.cropBorders")
        let downsample = UserDefaults.standard.bool(forKey: "Reader.downsampleImages")
        return "original-v2-\(crop)-\(downsample)"
    }
}
