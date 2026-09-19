//
//  CropBordersProcessor.swift
//  Aidoku (iOS)
//
//  Created by Axel Lopez on 20/06/2023.
//

import Foundation
import Nuke
import UIKit

struct CropBordersProcessor: ImageProcessing {

    var identifier: String {
        "com.github.Aidoku/Aidoku/cropBorders-v2"
    }

    private let whiteThreshold = 0xAA
    private let blackThreshold = 0x05
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func process(_ image: PlatformImage) -> PlatformImage? {
        guard let cgImage = image.cgImage else { return image }

        return autoreleasepool {
            // Sample native pixels to preserve narrow strokes and asymmetric rotated borders.
            let newRect = createCropRect(cgImage)
            guard !newRect.isEmpty else { return image }

            if let croppedImage = cgImage.cropping(to: newRect) {
                return PlatformImage(cgImage: croppedImage, scale: image.scale, orientation: image.imageOrientation)
            } else {
                return image
            }
        }
    }

    func createCropRect(_ cgImage: CGImage, scale: CGFloat = 1) -> CGRect {
        guard scale.isFinite, scale > 0 else { return .zero }
        let height = cgImage.height
        let width = cgImage.width

        var lowX = width
        var lowY = height
        var highX = -1
        var highY = -1
        // Native resolution preserves one-pixel strokes without a full-page RGBA
        // allocation. At most 128 scanlines are decoded into scratch storage.
        let stripHeight = min(128, height)
        guard let context = createARGBBitmapContext(width: width, height: stripHeight),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return .zero }
        for originY in stride(from: 0, to: height, by: stripHeight) {
            let rows = min(stripHeight, height - originY)
            guard let strip = cgImage.cropping(to: CGRect(x: 0, y: originY, width: width, height: rows)) else { return .zero }
            context.clear(CGRect(x: 0, y: 0, width: width, height: stripHeight))
            context.draw(strip, in: CGRect(x: 0, y: stripHeight - rows, width: width, height: rows))
            for y in 0..<rows {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    if data[offset] == 0 { continue }
                    let red = data[offset + 1]
                    let green = data[offset + 2]
                    let blue = data[offset + 3]
                    if red > whiteThreshold && green > whiteThreshold && blue > whiteThreshold { continue }
                    if red < blackThreshold && green < blackThreshold && blue < blackThreshold { continue }
                    lowX = min(x, lowX)
                    highX = max(x, highX)
                    lowY = min(originY + y, lowY)
                    highY = max(originY + y, highY)
                }
            }
        }

        guard highX >= lowX, highY >= lowY else { return .zero }
        return CGRect(x: CGFloat(lowX) / scale, y: CGFloat(lowY) / scale,
            width: CGFloat(highX - lowX + 1) / scale, height: CGFloat(highY - lowY + 1) / scale)
    }

    func createARGBBitmapContext(width: Int, height: Int) -> CGContext? {

        let bitmapBytesPerRow = width * 4

        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bitmapBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )

        return context
    }

}
