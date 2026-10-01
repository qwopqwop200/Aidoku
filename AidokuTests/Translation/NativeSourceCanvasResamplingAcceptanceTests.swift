import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeSourceCanvasResamplingAcceptanceTests {
    @Test func exactScenePassesButAllSourceCorruptionsFail() {
        let width = 16, height = 16, frame = CGRect(x: 4, y: 4, width: 8, height: 8)
        let prefix = Data(repeating: 0, count: width * height * 4)
        var pixels = [UInt8](prefix)
        for y in 4..<12 { for x in 4..<12 {
            let color: [UInt8] = y < 8 ? (x < 8 ? [255,0,0,255] : [0,255,0,255])
                : (x < 8 ? [0,0,255,255] : [255,255,0,255])
            let offset = (y * width + x) * 4
            for c in 0..<4 { pixels[offset + c] = color[c] }
        } }
        let data = Data(pixels)
        for mode in [NativeSourceCanvasResamplingAcceptance.Mode.sourceDraw, .halfSizeCapture] {
            #expect(NativeSourceCanvasResamplingAcceptance.assess(reference: data, candidate: data,
                width: width, height: height, frames: [frame], outputScale: 1, mode: mode).accepted)
            let controls = NativeSourceCanvasResamplingAcceptance.negativeControls(reference: data, candidate: data,
                prefix: prefix, width: width, height: height, frames: [frame], outputScale: 1, mode: mode)
            #expect(controls.count == 4 && controls.values.allSatisfy { $0 })
        }
    }

    @Test func distantPixelDamageAndOpaqueAlphaLossCannotHideInAverage() {
        let width = 16, height = 16, frame = CGRect(x: 4, y: 4, width: 8, height: 8)
        let reference = Data(Array(repeating: [UInt8(20), 40, 60, 255], count: width * height).flatMap { $0 })
        var distant = reference
        distant[0] += 1
        var alpha = reference
        for y in 4..<12 { for x in 4..<12 { alpha[(y * width + x) * 4 + 3] -= 1 } }
        for mode in [NativeSourceCanvasResamplingAcceptance.Mode.sourceDraw, .halfSizeCapture] {
            for changed in [distant, alpha] {
                #expect(!NativeSourceCanvasResamplingAcceptance.assess(reference: reference, candidate: changed,
                    width: width, height: height, frames: [frame], outputScale: 1, mode: mode).accepted)
            }
        }
    }
}
