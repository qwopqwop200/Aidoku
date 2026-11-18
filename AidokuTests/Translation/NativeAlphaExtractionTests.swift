import Foundation
import CoreGraphics
import CoreText
import Testing
@testable import Aidoku

// Append to NativeTextBoxReplacementTests.swift; no production/test trial globals.
extension NativeTextBoxReplacementTests {
    @Test func tiledAlphaRowsHalosAndFinalTileMatchOldExtractor() throws {
        #expect(try Lane08AlphaFixtureCT.compareBytes() > 0)
    }

    @Test func tiledAlphaPainterFailureAndGeometryMismatchDoNotReusePixels() throws {
        try Lane08AlphaFixtureCT.failureAndMismatch()
    }

    @Test func tiledAlphaCertificateRejectionAndUnknownRemainDistinct() throws {
        #expect(try Lane08AlphaFixtureCT.certificates().count == 9)
    }
}

private enum Lane08AlphaFixtureCT {
    typealias R = NativeTranslationRenderer
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    // Independent old extraction oracle, including its original CGContext setup.
    // Uses the SAME full-canvas dimensions, not a separately sized stripe raster.
    static func oldAlpha(_ tile: R.TextDomainTile, painter: (CGContext) throws -> Void) throws -> [UInt8] {
        try Task.checkCancellation()
        let grid = tile.grid
        guard tile.firstRow >= 0, tile.rowCount > 0, tile.firstRow < grid.height,
              tile.rowCount <= grid.height - tile.firstRow,
              tile.lattice.grid.width == grid.width, tile.lattice.grid.height == grid.height,
              tile.lattice.grid.bounds == grid.bounds,
              tile.lattice.grid.pdfDeviceScale == grid.pdfDeviceScale else {
            throw R.TextDomainTileError.invalidGeometry
        }
        let c = tile.lattice.context
        c.saveGState()
        defer { c.restoreGState(); c.textMatrix = .identity; c.textPosition = .zero; c.beginPath() }
        let stripe = CGRect(x: 0, y: grid.height - tile.firstRow - tile.rowCount - tile.halo,
            width: grid.width, height: tile.height)
        c.beginPath(); c.clear(stripe); c.clip(to: stripe)
        c.translateBy(x: 0, y: CGFloat(grid.height))
        c.scaleBy(x: CGFloat(grid.width) / grid.bounds.width, y: -CGFloat(grid.height) / grid.bounds.height)
        c.translateBy(x: -grid.bounds.minX, y: -grid.bounds.minY)
        c.clip(to: grid.bounds); c.textMatrix = .identity; c.textPosition = .zero
        try painter(c)
        guard let bytes = c.data?.assumingMemoryBound(to: UInt8.self) else {
            throw R.TextDomainTileError.allocation
        }
        return (0..<tile.pixels).map { i in
            let row = tile.firstRow - tile.halo + i / grid.width
            return row < 0 || row >= grid.height ? 0 : bytes[(row * grid.width + i % grid.width) * 4 + 3]
        }
    }

    static func paint(_ c: CGContext, grid: R.TextDomainGrid, mode: Int, snap: CGFloat?) {
        guard mode != 0 else { return }
        c.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: mode == 1 ? 0.5 : 1))
        if mode == 1 { c.fill(grid.bounds); return }
        let unitY = grid.bounds.height / CGFloat(grid.height)
        let boundaryY = grid.bounds.minY + 63.25 * unitY
        let x = grid.bounds.minX + grid.bounds.width * 0.17
        let px = snap.map { floor(x * $0) / $0 } ?? x
        c.fill(CGRect(x: px, y: boundaryY, width: grid.bounds.width * 0.63, height: 4.5 * unitY))
        // Authored neutral Korean: shape anew for each painter, no retained glyph program.
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 9, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "가나다", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1)
        ]))
        c.textPosition = CGPoint(x: grid.bounds.minX + 0.25, y: grid.bounds.minY + 4.5)
        CTLineDraw(line, c)
        // Stress restoration before the next painter on the shared lattice.
        c.clip(to: CGRect(x: px, y: grid.bounds.minY, width: 0.5, height: 0.5))
        c.textMatrix = CGAffineTransform(scaleX: 0.75, y: 1.25)
    }

    static func compareBytes() throws -> Int {
        var comparisons = 0
        for width in [1, 3, 17] {
            for height in [1, 5, 65, 67, 129] {
                let grid = R.TextDomainGrid(bounds: CGRect(x: -3.25, y: 8.5,
                    width: CGFloat(width) / 1.5, height: CGFloat(height) / 1.5),
                    width: width, height: height, pdfDeviceScale: 1.75)
                let actualArena = try R.TextDomainLattice(grid: grid)
                let oldArena = try R.TextDomainLattice(grid: grid)
                for tileRows in [1, 64] {
                    for first in stride(from: 0, to: height, by: tileRows) {
                        let count = min(tileRows, height - first)
                        let actual = R.TextDomainTile(grid: grid, firstRow: first, rowCount: count, lattice: actualArena)
                        let old = R.TextDomainTile(grid: grid, firstRow: first, rowCount: count, lattice: oldArena)
                        for snap: CGFloat? in [nil, 1.75] {
                            for mode in [1, 2, 0, 2, 0] {
                                let got = try actual.alpha { paint($0, grid: grid, mode: mode, snap: snap) }
                                let expected = try oldAlpha(old) { paint($0, grid: grid, mode: mode, snap: snap) }
                                try check(got == expected, "Old/new alpha byte mismatch")
                                try check(got.count == actual.pixels, "Wrong halo/output count")
                                if mode == 0 { try check(got.allSatisfy { $0 == 0 }, "Painter pixels survived clear") }
                                for row in 0..<actual.height {
                                    let sourceRow = first - actual.halo + row
                                    if sourceRow < 0 || sourceRow >= height {
                                        try check(got[(row * width)..<((row + 1) * width)].allSatisfy { $0 == 0 },
                                            "Out-of-source halo is not zero")
                                    }
                                }
                                comparisons += 1
                            }
                        }
                    }
                }
            }
        }
        return comparisons
    }

    static func failureAndMismatch() throws {
        let grid = R.TextDomainGrid(bounds: CGRect(x: 0, y: 0, width: 17, height: 67),
            width: 17, height: 67, pdfDeviceScale: 1.75)
        let arena = try R.TextDomainLattice(grid: grid)
        let tile = R.TextDomainTile(grid: grid, firstRow: 64, rowCount: 3, lattice: arena)
        do {
            _ = try tile.alpha { c in
                c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(grid.bounds)
                throw Failure(message: "Authored painter failure")
            }
            throw Failure(message: "Painter error was swallowed")
        } catch let e as Failure { try check(e.message == "Authored painter failure", "Wrong thrown failure") }
        try check(try tile.alpha { _ in }.allSatisfy { $0 == 0 }, "Failed painter left pixels")
        let mismatch = R.TextDomainGrid(bounds: grid.bounds, width: 17, height: 67, pdfDeviceScale: 2)
        let bad = R.TextDomainTile(grid: mismatch, firstRow: 64, rowCount: 3, lattice: arena)
        var painterCalled = false
        do {
            _ = try bad.alpha { _ in painterCalled = true }
            throw Failure(message: "Mismatched grid accepted")
        } catch R.TextDomainTileError.invalidGeometry { }
        try check(!painterCalled, "Invalid grid ran painter")
    }

    static func certificates() throws -> [R.TextDomainCertificate] {
        let grid = R.TextDomainGrid(bounds: CGRect(x: -1.25, y: 2.5, width: 17, height: 67),
            width: 17, height: 67, pdfDeviceScale: 1.75)
        func run(_ mode: Int) throws -> R.TextDomainCertificate {
            var work = mode == 8 ? 0 : 1_000_000
            return try R.certifyTextDomainTiled(grid: grid, remainingWork: &work,
                maximumScratchBytes: 32 * 1024 * 1024, tileRows: 64, evidence: { _, tile in
                    (0..<tile.rowCount).map { _ in
                        let full = [UInt8](repeating: 255, count: grid.width)
                        let empty = [UInt8](repeating: 0, count: grid.width)
                        return .init(observedSafeAlpha: mode == 0 || mode >= 3 ? full : empty,
                            modelSafeAlpha: mode == 1 ? full : empty,
                            supportKnown: mode == 2 ? empty : full,
                            protectionAlpha: mode == 3 ? full : empty,
                            protectionKnown: mode == 2 ? empty : full,
                            peerUnionAlpha: mode == 4 ? full : empty, peerKnown: full,
                            ownBaselineAlpha: empty)
                    }
                }, paintRaw: { c, _ in
                    guard mode != 6 else { return }
                    c.setFillColor(CGColor(gray: 0, alpha: 1))
                    c.fill(CGRect(x: 0.25, y: 64.75, width: 7.5, height: 3.5))
                }, paintCandidate: { c, _ in
                    guard mode != 6 else { return }
                    if mode == 5 { c.clip(to: CGRect(x: -1.25, y: 2.5, width: 2, height: 67)) }
                    c.setFillColor(CGColor(gray: 0, alpha: 1))
                    c.fill(CGRect(x: 0.25, y: 64.75, width: 7.5, height: 3.5))
                })
        }
        var result: [R.TextDomainCertificate] = []
        for mode in 0...8 {
            let c = try run(mode); result.append(c)
            switch mode {
            case 0:
                try check(c.verdict == .observedPass && c.measurementComplete == true, "Observed pass lost")
                try check(c.rawOccupiedPixels.map { $0 > 0 } == true, "Pass became empty")
                try check(c.measuredDeviceSamples == 2 * grid.width * grid.height, "Final tile not visited")
            case 1: try check(c.verdict == .modelConditional && c.measurementComplete == true, "Model relabeled")
            case 2: try check(c.verdict == .unknown && c.reason == "unknown-evidence", "Unknown relabeled")
            case 3, 4, 5:
                try check(c.verdict == .rejected && c.measurementComplete == false, "Witness became pass/full")
                try check(c.rawOccupiedPixels == nil && c.protectedPixels == nil, "Partial totals fabricated")
                try check(c.measuredDeviceSamples != nil && c.expectedDeviceSamples != nil, "Coverage removed")
                try check(c.reason == [3: "protected-support", 4: "new-peer-collision", 5: "clip-loss"][mode],
                    "Wrong rejection witness")
            case 6: try check(c.verdict == .rejected && c.reason == "empty-alpha", "Empty alpha passed")
            case 7: try check(c.verdict == .observedPass, "Repeat pass stale")
            case 8:
                try check(c.verdict == .unknown && c.reason == "tile-work-budget", "Budget unknown relabeled")
                try check(c.rawOccupiedPixels == nil && c.measuredDeviceSamples == nil, "Unvisited measured")
            default: break
            }
        }
        return result
    }
}
