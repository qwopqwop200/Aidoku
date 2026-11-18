import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeSourceObstructionRecoveryTests {
    private let size = CGSize(width: 320, height: 160)
    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 320, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return try #require(context.makeImage())
    }
    private func context(protected: Bool) throws -> NativeSourcePhysicalInteriorContext {
        var rgb = [UInt8](repeating: 255, count: 320 * 160 * 3)
        if protected {
            for y in 0..<160 {
                for x in 0..<320 where (x + y) % 2 == 0 {
                    let offset = (y * 320 + x) * 3
                    rgb[offset] = 0; rgb[offset + 1] = 0; rgb[offset + 2] = 0
                }
            }
        }
        return try #require(NativeSourcePhysicalInteriorContext(rgb: rgb, width: 320, height: 160,
            erased: [UInt8](repeating: 0, count: 320 * 160), sourceIdentity: "synthetic-quality-source"))
    }
    private var item: NativeAOTRawTextPainter.Item {
        .init(id: "owner", text: "MMMMMMMM", frame: CGRect(x: 20, y: 25, width: 280, height: 95),
            fontSize: 24, lineHeight: 34, chosenFill: CGColor(gray: 0, alpha: 1), colorAuthority: "synthetic-test")
    }
    private func raw(locked: Bool = false) -> [[String: Any]] {
        [["id": "owner", "text": item.text, "fontSize": 24.0, "fontReference": 24.0,
          "typographyGroupID": "family", "noShrink": locked]]
    }
    private func paint(_ items: [NativeAOTRawTextPainter.Item], raw: [[String: Any]], background: CGImage) throws
        -> NativeAOTTranslationPageComposer.TextLayer {
        try NativeAOTRawTextPainter.renderCentered(items: items, rawItems: raw, viewport: size, restored: background)
    }

    @Test func clearSourceKeepsActualSuccessfulRasterWithoutAdditionalNativeRequests() throws {
        let background = try image(), source = try context(protected: false), options = raw()
        let baseline = try paint([item], raw: options, background: background)
        var calls = 0
        let result = try NativeSourceObstructionRecovery.$sourceContext.withValue(source) {
            try NativeCohortFitPlanner.run(items: [item], authenticatedOptions: options, declaredRaw: options,
                membershipRaw: options, policy: .onFailure, outputScale: 1) { requests in
                calls += 1
                return try paint(requests, raw: options, background: background)
            }
        }
        #expect(calls == 1 && result.layer.complete && result.layer.paintedItems == 1)
        #expect(try NativeMandatoryDisplayStroke.rgba(result.layer.image) == NativeMandatoryDisplayStroke.rgba(baseline.image))
    }

    @Test func incumbentDecodingRetriesFailuresAndDoesNotRetainOverBudget() throws {
        let raster = try image()
        typealias Recovery = NativeSourceObstructionRecovery
        func primitive(_ name: String) -> Recovery.P {
            var value = Recovery.P(image: raster, frame: CGRect(origin: .zero, size: size), fontOutputPixels: 24)
            value.ownerID = name
            return value
        }
        let session = Recovery.Session(source: try context(protected: false),
            initial: [primitive("cached"), primitive("over-budget")], before: .init(supports: [:], costs: [:], audit: []),
            material: [], unrelated: ["cached", "over-budget"])
        #expect(try session.incumbentRGBA(owner: "not-an-owner") { _ in
            Issue.record("Decoder ran without an incumbent image")
            return []
        } == nil)
        var calls = 0
        func decode(_ image: CGImage) throws -> [UInt8] {
            calls += 1
            #expect(image === raster)
            if calls == 1 { throw NativeMandatoryDisplayStroke.Failure.allocation }
            return try NativeMandatoryDisplayStroke.rgba(image)
        }
        do {
            _ = try session.incumbentRGBA(owner: "cached", decode: decode)
            Issue.record("Expected failed first decode")
        } catch NativeMandatoryDisplayStroke.Failure.allocation {}
        let accepted = try session.incumbentRGBA(owner: "cached", decode: decode)
        #expect(try session.incumbentRGBA(owner: "cached", decode: decode) == accepted)
        #expect(accepted?.count == 320 * 160 * 4 && calls == 2)

        let large = [UInt8](repeating: 17, count: 8 * 1024 * 1024)
        for _ in 0..<2 {
            #expect(try session.incumbentRGBA(owner: "over-budget") { _ in
                calls += 1
                return large
            } == large)
        }
        #expect(calls == 4)
        #expect(try session.incumbentRGBA(owner: "cached", decode: decode) == accepted && calls == 4)
    }

    @Test func materialSourceContactCannotOverrideOriginalCallerFontLock() throws {
        let background = try image(), source = try context(protected: true), options = raw(locked: true)
        var calls = 0
        let result = try NativeSourceObstructionRecovery.$sourceContext.withValue(source) {
            try NativeCohortFitPlanner.run(items: [item], authenticatedOptions: options, declaredRaw: options,
                membershipRaw: options, policy: .onFailure, outputScale: 1) { requests in
                calls += 1
                #expect(requests[0].fontSize == 24)
                return try paint(requests, raw: options, background: background)
            }
        }
        #expect(calls == 1 && result.layer.complete)
        let quality = try #require(result.layer.audit["sourceObstructionRecovery"] as? [String: Any])
        #expect(quality["materialOwners"] as? [String] == ["owner"])
        #expect(quality["initialSuccessPreservedOnUnknownOrBudget"] as? Bool == true)
        #expect(quality["status"] as? String != "source-obstruction-recovered")
    }

    @Test func cancellationDuringOptionalQualityRequestStillCancelsCaller() throws {
        let background = try image(), source = try context(protected: true), options = raw()
        var calls = 0, cancelled = false
        do {
            _ = try NativeSourceObstructionRecovery.$sourceContext.withValue(source) {
                try NativeCohortFitPlanner.run(items: [item], authenticatedOptions: options, declaredRaw: options,
                    membershipRaw: options, policy: .onFailure, outputScale: 1) { requests in
                    calls += 1
                    if calls > 1 { throw CancellationError() }
                    return try paint(requests, raw: options, background: background)
                }
            }
        } catch is CancellationError { cancelled = true }
        #expect(cancelled && calls == 2)
    }
}
