import AidokuRunner
import CommonCrypto
import CryptoKit
import UIKit

/// Native port of ja.soraraw helpers.rs. These fixed values belong to the published
/// image protocol; they are not user credentials. Native adapter version support is registered separately.
enum SoraRawImageCodec {
    private static let payloadKey = Array("/fuCkYou!!!".utf8)
    private static let pathSecret = Array("202508055d0db38bae2e86cc41649f90".utf8)
    private static let scrambleSecret = "6a0248ad1ca4208275aed64d336e81595ecb149422a8e621f70e23b9f01b9c1c"

    struct Tile: Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        var source: Int
        var turns: Int
    }

    /// ImageIO needs more than a Range response to expose properties for some
    /// JPEG/WebP images. Read the same bounded frame headers as the upstream source.
    static func headerSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = Array(data.prefix(16 * 1024))
        func bigEndian(_ index: Int) -> Int? {
            guard index >= 0, index + 1 < bytes.count else { return nil }
            return Int(bytes[index]) << 8 | Int(bytes[index + 1])
        }
        if bytes.starts(with: [0xFF, 0xD8]) {
            var index = 2
            while index + 1 < bytes.count, bytes[index] == 0xFF {
                let marker = bytes[index + 1]
                switch marker {
                    case 0xFF: index += 1
                    case 0x01, 0xD0...0xD9: index += 2
                    case 0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                        guard let height = bigEndian(index + 5), let width = bigEndian(index + 7) else { return nil }
                        return (width, height)
                    default:
                        guard let length = bigEndian(index + 2), length >= 2 else { return nil }
                        index += 2 + length
                }
            }
            return nil
        }
        guard bytes.count >= 30, bytes[0..<4].elementsEqual("RIFF".utf8),
              bytes[8..<12].elementsEqual("WEBP".utf8), bytes[12..<16].elementsEqual("VP8 ".utf8),
              bytes[23..<26].elementsEqual([0x9D, 0x01, 0x2A]) else { return nil }
        let width = (Int(bytes[26]) | Int(bytes[27]) << 8) & 0x3FFF
        let height = (Int(bytes[28]) | Int(bytes[29]) << 8) & 0x3FFF
        return (width, height)
    }

    static func stackedPageCount(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 1 }
        let count = (Float(height) / (Float(width) * sqrt(2)) + 0.5).rounded(.down)
        return count >= 1 && count <= 64 ? Int(count) : 1
    }

    static func decodeBase64(_ input: String) -> [UInt8]? {
        var output: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in input.utf8 {
            let value: UInt8
            switch byte {
                case 65...90: value = byte - 65
                case 97...122: value = byte - 97 + 26
                case 48...57: value = byte - 48 + 52
                case 43, 45: value = 62
                case 47, 95: value = 63
                case 61: return output
                case 9, 10, 13, 32: continue
                default: return nil
            }
            buffer = (buffer << 6) | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: buffer >> bits))
            }
        }
        return output
    }

    static func deobfuscate(_ payload: String) -> String? {
        guard var bytes = decodeBase64(payload) else { return nil }
        for index in bytes.indices { bytes[index] ^= payloadKey[index % payloadKey.count] }
        guard var text = String(bytes: bytes, encoding: .utf8) else { return nil }
        while text.first == "\u{feff}" { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return text.isEmpty ? nil : text
    }

    static func decryptPath(_ payload: String, uuid: String) -> String? {
        let characters = Array(uuid.utf8)
        guard characters.count == 64 else { return nil }
        var key: [UInt8] = []
        for index in stride(from: 0, to: 64, by: 2) {
            guard let high = hex(characters[index]), let low = hex(characters[index + 1]) else { return nil }
            key.append(high * 16 + low)
        }
        guard var bytes = decodeBase64(payload), bytes.count > 16 else { return nil }
        for index in bytes.indices { bytes[index] ^= pathSecret[index % pathSecret.count] }
        var counter = Array(bytes.prefix(16))
        var path: [UInt8] = []
        for start in stride(from: 16, to: bytes.count, by: 16) {
            var block = [UInt8](repeating: 0, count: 16)
            var written = 0
            let status = key.withUnsafeBytes { keyBytes in
                counter.withUnsafeBytes { counterBytes in
                    block.withUnsafeMutableBytes { blockBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                                keyBytes.baseAddress, key.count, nil, counterBytes.baseAddress, 16,
                                blockBytes.baseAddress, 16, &written)
                    }
                }
            }
            guard status == kCCSuccess, written == 16 else { return nil }
            for offset in 0..<min(16, bytes.count - start) { path.append(bytes[start + offset] ^ block[offset]) }
            for index in (0..<16).reversed() {
                counter[index] &+= 1
                if counter[index] != 0 { break }
            }
        }
        guard let result = String(bytes: path, encoding: .utf8), !result.isEmpty else { return nil }
        return result
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 65 + 10
            case 97...102: byte - 97 + 10
            default: nil
        }
    }

    static func scramblePlan(width: Int, height: Int, seed: String) -> [Tile]? {
        guard width >= 8, height >= 8 else { return nil }
        let key = SHA256.hash(data: Data((seed + scrambleSecret).utf8)).map { String(format: "%02x", $0) }.joined()
        let digest = Array(SHA256.hash(data: Data("\(key):nxn:8:\(width)x\(height)".utf8)))
        var random = Mulberry32(state: digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        var tiles: [Tile] = []
        for (y, tileHeight) in spans(height) {
            for (x, tileWidth) in spans(width) {
                tiles.append(Tile(x: x, y: y, width: tileWidth, height: tileHeight, source: tiles.count, turns: 0))
            }
        }
        var groups: [[Int]] = []
        for index in tiles.indices {
            if let group = groups.firstIndex(where: {
                tiles[$0[0]].width == tiles[index].width && tiles[$0[0]].height == tiles[index].height
            }) {
                groups[group].append(index)
            } else { groups.append([index]) }
        }
        for group in groups {
            var order = Array(group.indices)
            if group.count >= 2 {
                for count in stride(from: group.count, through: 2, by: -1) {
                    order.swapAt(count - 1, Int(random.next() * Double(count)))
                }
            }
            let square = tiles[group[0]].width == tiles[group[0]].height
            for (index, tile) in group.enumerated() {
                tiles[tile].source = group[order[index]]
                tiles[tile].turns = square ? Int(random.next() * 4) : (random.next() < 0.5 ? 0 : 2)
            }
        }
        return tiles
    }

    private static func spans(_ length: Int) -> [(Int, Int)] {
        var offset = 0
        return (0..<8).map { index in
            let size = length / 8 + (index < length % 8 ? 1 : 0)
            defer { offset += size }
            return (offset, size)
        }
    }

    private struct Mulberry32 {
        var state: UInt32
        mutating func next() -> Double {
            state &+= 0x6D2B79F5
            var value = (state ^ (state >> 15)) &* (state | 1)
            value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
            return Double(value ^ (value >> 14)) / 4_294_967_296
        }
    }

    static func unscramble(_ image: PlatformImage, seed: String) -> PlatformImage? {
        guard image.imageOrientation == .up, let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard let tiles = scramblePlan(width: width, height: height, seed: seed),
              let input = rgbaPixels(cgImage) else { return nil }
        var output = [UInt8](repeating: 0, count: input.count)
        for tile in tiles {
            let source = tiles[tile.source]
            for y in 0..<tile.height {
                for x in 0..<tile.width {
                    let sourceX: Int, sourceY: Int
                    switch tile.turns {
                        case 1: (sourceX, sourceY) = (y, tile.width - 1 - x)
                        case 2: (sourceX, sourceY) = (tile.width - 1 - x, tile.height - 1 - y)
                        case 3: (sourceX, sourceY) = (tile.height - 1 - y, x)
                        default: (sourceX, sourceY) = (x, y)
                    }
                    let from = ((source.y + sourceY) * width + source.x + sourceX) * 4
                    let to = ((tile.y + y) * width + tile.x + x) * 4
                    output[to..<(to + 4)] = input[from..<(from + 4)]
                }
            }
        }
        return imageFromRGBA(output, width: width, height: height, scale: image.scale)
    }

    static func slice(_ image: PlatformImage, slice: Int, slices: Int) -> PlatformImage? {
        guard image.imageOrientation == .up, let cgImage = image.cgImage,
              slices >= 2, slices <= 64, slice >= 0, slice < slices else { return nil }
        let top = cgImage.height * slice / slices
        let bottom = cgImage.height * (slice + 1) / slices
        guard bottom > top, let cropped = cgImage.cropping(to: CGRect(x: 0, y: top, width: cgImage.width, height: bottom - top))
        else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    private static func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        // Reject unreasonable decoded dimensions before allocating two page buffers.
        let (count, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow, count > 0, count <= 64 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return success ? bytes : nil
    }

    private static func imageFromRGBA(_ bytes: [UInt8], width: Int, height: Int, scale: CGFloat) -> PlatformImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                    .union(.byteOrder32Big), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}
