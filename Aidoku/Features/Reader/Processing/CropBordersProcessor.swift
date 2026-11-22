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
        let height = cgImage.height
        let width = cgImage.width
        let heightFloat = CGFloat(height)
        let widthFloat = CGFloat(width)
        // Native resolution preserves one-pixel strokes without a full-page RGBA
        // allocation. At most 128 scanlines are decoded into scratch storage.
        let stripHeight = min(128, height)

        guard
            let context = createARGBBitmapContext(width: width, height: stripHeight),
            let data = context.data?.assumingMemoryBound(to: UInt8.self)
        else {
            return CGRect.zero
        }

        var lowX = widthFloat
        var lowY = heightFloat
        var highX: CGFloat = -1
        var highY: CGFloat = -1

        // Filter through data and look for non-transparent pixels.
        for y in 0 ..< height {
            let row = y % stripHeight
            if row == 0 {
                let rows = min(stripHeight, height - y)
                guard let strip = cgImage.cropping(to: CGRect(x: 0, y: y, width: width, height: rows)) else { return .zero }
                context.clear(CGRect(x: 0, y: 0, width: width, height: stripHeight))
                context.draw(strip, in: CGRect(x: 0, y: stripHeight - rows, width: width, height: rows))
            }
            let y = CGFloat(y)

            for x in 0 ..< width {
                let x = CGFloat(x)
                let pixelIndex = (widthFloat * CGFloat(row) + x) * 4 /* 4 for A, R, G, B */

                // crop transparent
                if data[Int(pixelIndex)] == 0 { continue }

                // crop white
                if
                    data[Int(pixelIndex+1)] > whiteThreshold
                    && data[Int(pixelIndex+2)] > whiteThreshold
                    && data[Int(pixelIndex+3)] > whiteThreshold
                {
                    continue
                }

                // crop black
                if
                    data[Int(pixelIndex+1)] < blackThreshold
                    && data[Int(pixelIndex+2)] < blackThreshold
                    && data[Int(pixelIndex+3)] < blackThreshold
                {
                    continue
                }

                lowX = min(x, lowX)
                highX = max(x, highX)

                lowY = min(y, lowY)
                highY = max(y, highY)
            }
        }

        guard highX >= lowX, highY >= lowY else { return .zero }
        return CGRect(x: lowX / scale, y: lowY / scale, width: (highX - lowX + 1) / scale, height: (highY - lowY + 1) / scale)
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
