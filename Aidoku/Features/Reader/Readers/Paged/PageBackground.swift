//
//  PageBackground.swift
//  Aidoku
//
//  Created by Skitty on 11/22/25.
//

import UIKit

enum PageBackground {
    case color(UIColor)
    case gradient(CAGradientLayer)

    // https://github.com/mihonapp/mihon/blob/fc2c8c06a940392161cf5110e222edbedf9b7e47/core/common/src/main/kotlin/tachiyomi/core/common/util/system/ImageUtil.kt#L333
    // swiftlint:disable:next cyclomatic_complexity
    static func choose(for image: UIImage, isLandscape: Bool) -> PageBackground {
        guard let cgImage = image.cgImage else { return .color(.white) }
        // Normalize every input format (including grayscale and BGRA) into a
        // bounded RGBA bitmap. Sampling raw provider bytes assumes a pixel layout
        // UIImage does not promise and confuses point sizes with pixel sizes.
        let sampleScale = min(1, 512 / CGFloat(max(cgImage.width, cgImage.height)))
        let width = max(1, Int(CGFloat(cgImage.width) * sampleScale))
        let height = max(1, Int(CGFloat(cgImage.height) * sampleScale))
        guard width >= 50, height >= 50,
              let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let ptr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return .color(.white)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        @inline(__always)
        func colorAt(x: Int, y: Int) -> UIColor {
            let offset = (min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))) * 4
            let alpha = CGFloat(ptr[offset + 3]) / 255
            guard alpha > 0 else { return .clear }
            return UIColor(red: CGFloat(ptr[offset]) / 255 / alpha,
                green: CGFloat(ptr[offset + 1]) / 255 / alpha,
                blue: CGFloat(ptr[offset + 2]) / 255 / alpha, alpha: alpha)
        }

        let top = 5
        let bot = height - 5
        let left = Int(Double(width) * 0.0275)
        let right = width - left
        let midX = width / 2
        let midY = height / 2
        let offsetX = Int(Double(width) * 0.01)
        let leftOffsetX = left - offsetX
        let rightOffsetX = right + offsetX

        let topLeftPixel = colorAt(x: left, y: top)
        let topRightPixel = colorAt(x: right, y: top)
        let midLeftPixel = colorAt(x: left, y: midY)
        let midRightPixel = colorAt(x: right, y: midY)
        let topCenterPixel = colorAt(x: midX, y: top)
        let botLeftPixel = colorAt(x: left, y: bot)
        let bottomCenterPixel = colorAt(x: midX, y: bot)
        let botRightPixel = colorAt(x: right, y: bot)

        let topLeftIsDark = topLeftPixel.isDark()
        let topRightIsDark = topRightPixel.isDark()
        let midLeftIsDark = midLeftPixel.isDark()
        let midRightIsDark = midRightPixel.isDark()
        let topMidIsDark = topCenterPixel.isDark()
        let botLeftIsDark = botLeftPixel.isDark()
        let botRightIsDark = botRightPixel.isDark()

        var darkBG =
            (topLeftIsDark && (botLeftIsDark || botRightIsDark || topRightIsDark || midLeftIsDark || topMidIsDark)) ||
            (topRightIsDark && (botRightIsDark || botLeftIsDark || midRightIsDark || topMidIsDark))

        let topAndBotPixels = [topLeftPixel, topCenterPixel, topRightPixel, botRightPixel, bottomCenterPixel, botLeftPixel]
        let isNotWhiteAndCloseTo = topAndBotPixels.enumerated().map { index, color in
            let other = topAndBotPixels[(index + 1) % topAndBotPixels.count]
            return !color.isWhite() && color.isCloseTo(other)
        }
        if isNotWhiteAndCloseTo.allSatisfy({ $0 }) {
            return .color(topLeftPixel)
        }

        let cornerPixels = [topLeftPixel, topRightPixel, botLeftPixel, botRightPixel]
        let numberOfWhiteCorners = cornerPixels.filter { $0.isWhite() }.count
        if numberOfWhiteCorners > 2 { darkBG = false }

        var blackColor: UIColor = if topLeftIsDark {
            topLeftPixel
        } else if topRightIsDark {
            topRightPixel
        } else if botLeftIsDark {
            botLeftPixel
        } else if botRightIsDark {
            botRightPixel
        } else {
            .white
        }

        var overallWhitePixels = 0
        var overallBlackPixels = 0
        var topBlackStreak = 0
        var topWhiteStreak = 0
        var botBlackStreak = 0
        var botWhiteStreak = 0

        let scanXs = [left, right, leftOffsetX, rightOffsetX]
        for x in scanXs {
            var whitePixelsStreak = 0
            var whitePixels = 0
            var blackPixelsStreak = 0
            var blackPixels = 0
            var blackStreak = false
            var whiteStreak = false
            let notOffset = x == left || x == right
            let step = max(1, height / 25)
            let yIndices = stride(from: 0, to: height, by: step).enumerated()
            for (index, y) in yIndices {
                let pixel = colorAt(x: x, y: y)
                let pixelOff = colorAt(x: x + (x < width / 2 ? -offsetX : offsetX), y: y)
                if pixel.isWhite() {
                    whitePixelsStreak += 1
                    whitePixels += 1
                    if notOffset { overallWhitePixels += 1 }
                    if whitePixelsStreak > 14 { whiteStreak = true }
                    if whitePixelsStreak > 6 && whitePixelsStreak >= index - 1 {
                        topWhiteStreak = whitePixelsStreak
                    }
                } else {
                    whitePixelsStreak = 0
                    if pixel.isDark() && pixelOff.isDark() {
                        blackPixels += 1
                        if notOffset { overallBlackPixels += 1 }
                        blackPixelsStreak += 1
                        if blackPixelsStreak >= 14 { blackStreak = true }
                        continue
                    }
                }
                if blackPixelsStreak > 6 && blackPixelsStreak >= index - 1 {
                    topBlackStreak = blackPixelsStreak
                }
                blackPixelsStreak = 0
            }
            if blackPixelsStreak > 6 {
                botBlackStreak = blackPixelsStreak
            } else if whitePixelsStreak > 6 {
                botWhiteStreak = whitePixelsStreak
            }
            if blackPixels > 22 {
                if x == right || x == rightOffsetX {
                    blackColor = if topRightIsDark {
                        topRightPixel
                    } else if botRightIsDark {
                        botRightPixel
                    } else {
                        blackColor
                    }
                }
                darkBG = true
                overallWhitePixels = 0
                break
            } else if blackStreak {
                darkBG = true
                if x == right || x == rightOffsetX {
                    blackColor = if topRightIsDark {
                        topRightPixel
                    } else if botRightIsDark {
                        botRightPixel
                    } else {
                        blackColor
                    }
                }
                if blackPixels > 18 {
                    overallWhitePixels = 0
                    break
                }
            } else if whiteStreak || whitePixels > 22 {
                darkBG = false
            }
        }

        let topIsBlackStreak = topBlackStreak > topWhiteStreak
        let bottomIsBlackStreak = botBlackStreak > botWhiteStreak
        if overallWhitePixels > 9 && overallWhitePixels > overallBlackPixels {
            darkBG = false
        }
        if topIsBlackStreak && bottomIsBlackStreak {
            darkBG = true
        }

        // if the device is in landscape then we can't use gradients
        if isLandscape {
            return .color(darkBG ? blackColor : .white)
        }

        let botCornersIsWhite = botLeftPixel.isWhite() && botRightPixel.isWhite()
        let topCornersIsWhite = topLeftPixel.isWhite() && topRightPixel.isWhite()
        let topCornersIsDark = topLeftIsDark && topRightIsDark
        let botCornersIsDark = botLeftIsDark && botRightIsDark
        let topOffsetCornersIsDark = colorAt(x: leftOffsetX, y: top).isDark() && colorAt(x: rightOffsetX, y: top).isDark()
        let botOffsetCornersIsDark = colorAt(x: leftOffsetX, y: bot).isDark() && colorAt(x: rightOffsetX, y: bot).isDark()

        let gradientColors: [UIColor]

        if darkBG && botCornersIsWhite {
            gradientColors = [blackColor, blackColor, .white, .white]
        } else if darkBG && topCornersIsWhite {
            gradientColors = [.white, .white, blackColor, blackColor]
        } else if darkBG {
            return .color(blackColor)
        } else if topIsBlackStreak || (topCornersIsDark && topOffsetCornersIsDark && (topMidIsDark || overallBlackPixels > 9)) {
            gradientColors = [blackColor, blackColor, .white, .white]
        } else if bottomIsBlackStreak || (botCornersIsDark && botOffsetCornersIsDark && (bottomCenterPixel.isDark() || overallBlackPixels > 9)) {
            gradientColors = [.white, .white, blackColor, blackColor]
        } else {
            return .color(.white)
        }

        let gradient = CAGradientLayer()
        gradient.colors = gradientColors.map { $0.cgColor }
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        return .gradient(gradient)
    }

}

private extension UIColor {
    // swiftlint:disable:next large_tuple
    var rgba: (r: Int, g: Int, b: Int, a: Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
    }

    func isDark() -> Bool {
        let (r, g, b, a) = self.rgba
        return r < 40 && g < 40 && b < 40 && a > 200
    }

    func isWhite() -> Bool {
        let (r, g, b, _) = self.rgba
        return r + g + b > 740
    }

    func isCloseTo(_ other: UIColor) -> Bool {
        let (r1, g1, b1, _) = self.rgba
        let (r2, g2, b2, _) = other.rgba
        return abs(r1 - r2) < 30 && abs(g1 - g2) < 30 && abs(b1 - b2) < 30
    }
}
