import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeTranslationPixelKernelBridgeTests {
    @Test func invalidBridgeInputsAreRejectedBeforeNativeMutation() throws {
        let bytes = try NativeKernelBuffer<UInt8>(values: [20, 30, 40, 255])
        let out = try NativeKernelBuffer<Int32>(values: [17, 18, 19, 20])
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.lettering_support(rgba: bytes, w: -1, h: 1,
                l: 0, r: 1, t: 0, b: 1, ir: 20, ig: 30, ib: 40, out: out)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.lettering_support(rgba: bytes, w: 1, h: 1,
                l: .infinity, r: 1, t: 0, b: 1, ir: 20, ig: 30, ib: 40, out: out)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.lettering_support(rgba: bytes, w: 1, h: 1,
                l: 0, r: 1, t: 0, b: 1, ir: 256, ig: 30, ib: 40, out: out)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.lettering_support(rgba: bytes, w: 2, h: 1,
                l: 0, r: 1, t: 0, b: 1, ir: 20, ig: 30, ib: 40, out: out)
        }
        #expect(bytes.values == [20, 30, 40, 255])
        #expect(out.values == [17, 18, 19, 20])

        let queue = try NativeKernelBuffer<Int32>(values: [0])
        let rgba = try NativeKernelBuffer<UInt8>(count: 36)
        let mask = try NativeKernelBuffer<UInt8>(count: 9)
        let work = try NativeKernelBuffer<Float>(count: 27)
        let links = try NativeKernelBuffer<UInt8>(count: 1)
        // Harmonic fill reads all four neighbors; even a valid pixel index on an edge is unsafe.
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.harmonic_fill(p: rgba, w: 3, n: 9, queue: queue,
                tail: 1, blocked: mask, paint: mask, accelerated: 1, work: work, links: links)
        }
        queue[0] = 9
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try NativeTranslationPixelKernels.harmonic_fill(p: rgba, w: 3, n: 9, queue: queue,
                tail: 1, blocked: mask, paint: mask, accelerated: 1, work: work, links: links)
        }
        #expect(rgba.values == Array(repeating: UInt8(0), count: 36))
        #expect(work.values == Array(repeating: Float(0), count: 27))
    }

    @Test func borrowedScratchViewsValidateBoundsAlignmentAndRetainStorage() throws {
        var parent: NativeKernelBuffer<Double>? = try NativeKernelBuffer(values: [0, 0])
        let child = try parent!.view(as: UInt8.self, byteOffset: 0, count: 16)
        let grandchild = try child.view(as: Int32.self, byteOffset: 8, count: 2)
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try child.view(as: Int32.self, byteOffset: 1, count: 1)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try child.view(as: Double.self, byteOffset: 8, count: 2)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try child.view(as: UInt8.self, byteOffset: -1, count: 1)
        }
        #expect(throws: NativeTranslationPixelKernels.KernelError.self) {
            try child.view(as: UInt8.self, byteOffset: 0, count: -1)
        }
        parent = nil
        grandchild[0] = 0x01020304
        #expect(Array(child.values[8..<12]) == [4, 3, 2, 1])
        #expect(grandchild.values == [0x01020304, 0])
    }
}
