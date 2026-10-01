import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCSSCoveragePathTests {
    private func points(_ path: CGPath) -> [CGPoint] {
        var result: [CGPoint] = []
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                result.append(element.pointee.points[0])
            }
        }
        return result
    }

    @Test func absoluteSVGTranslatesIndividualFloatVertices() throws {
        // Actual real25/panel7 CSS union M0,0 H33.84375 V59.359375 H0.
        let owner = CGRect(x: 117.34375, y: 240.125, width: 33.84375, height: 59.359375)
        let declaration = try #require(NativeCSSCoveragePath.declaration(coverage: [owner], origin: owner.origin, commands: .absolute))
        let reference = NativeSourceCanvasClip.referenceRect(domRect: owner, deviceScale: 3)
        let path = try #require(NativeCSSCoveragePath.path(declaration, referenceBox: reference))
        let actual = points(path)
        #expect(actual[0].x == CGFloat(Float(117 + 1.0 / 3)))
        #expect(actual[1].x == CGFloat(Float(Float(117 + 1.0 / 3) + Float(33.84375))))
        #expect(actual[1].x - actual[0].x == 33.84375762939453)
        // A translated CGRect/addRect preserves the old Double width instead.
        #expect(actual[1].x - actual[0].x != owner.width)
    }

    @Test func relativeReverseCommandRetainsItsFloatAccumulation() throws {
        let coverage = CGRect(x: 10.1, y: -1.2, width: 0.2, height: 0.7)
        let absolute = try #require(NativeCSSCoveragePath.declaration(coverage: [coverage], origin: CGPoint(x: 10, y: -2), commands: .absolute))
        let relative = try #require(NativeCSSCoveragePath.declaration(coverage: [coverage], origin: CGPoint(x: 10, y: -2), commands: .relative))
        #expect(absolute.subpaths[0][3].x == absolute.subpaths[0][0].x)
        #expect(relative.subpaths[0][3].x != relative.subpaths[0][0].x)
        #expect(relative.subpaths[0][3].x == CGFloat(Float(Float(0.1) + Float(0.2)) + Float(-0.2)))
    }

    @Test func copiedLocalDeclarationMovesWithoutRebuildingCoverage() throws {
        let frame = CGRect(x: -10.25, y: -3.5, width: 40.25, height: 30.25)
        let pieces = [CGRect(x: -12.4, y: -1.2, width: 9.7, height: 13.3), CGRect(x: 5.1, y: 3.2, width: 8.3, height: 11.1)]
        let declaration = try #require(NativeCSSCoveragePath.declaration(coverage: pieces, origin: frame.origin, commands: .relative))
        var copied = NativeTranslationSourceStylePostPolish.Panel(rect: frame, background: [20, 40, 60], coverage: pieces, clipped: true, coverageClip: declaration)
        copied.rect.origin.x += 17.03125
        copied.rect.size.width += 3
        let stored = try #require(copied.coverageClip)
        let path = try #require(NativeCSSCoveragePath.path(stored, referenceBox: copied.rect))
        #expect(points(path).count == 8)
        #expect(copied.coverage == pieces)
        #expect(copied.coverageClip?.subpaths == declaration.subpaths)
        #expect(points(path)[0].x == CGFloat(Float(Double(Float(copied.rect.minX)) + Double(Float(declaration.subpaths[0][0].x)))))
    }

    @Test func percentInsetReevaluatesAgainstTheClipReferenceSize() throws {
        let owner = CGRect(x: 150.25, y: 20.25, width: 33.84375, height: 59.359375)
        let declaration = try #require(NativeCSSCoveragePath.inset([10, 20, 30, 40], unit: .percent))
        let reference = NativeSourceCanvasClip.referenceRect(domRect: owner, deviceScale: 2)
        let border = NativeTranslationPDFCapture.snappedRect(owner, deviceScale: 2)
        #expect(reference.width == 34 && border.width == 33.5)
        let path = try #require(NativeCSSCoveragePath.path(declaration, referenceBox: reference))
        let resized = try #require(NativeCSSCoveragePath.path(declaration, referenceBox: CGRect(x: reference.minX, y: reference.minY, width: 60, height: 80)))
        #expect(points(path)[0].x == CGFloat(Float(reference.minX) + Float(13.6)))
        #expect(points(resized)[0].x == CGFloat(Float(reference.minX) + Float(24)))
        #expect(points(path)[0] != points(resized)[0])
    }

    @Test func snappedZeroSizeIsAValidEmptyShapeOrNegativeInsetExpansion() throws {
        let owner = CGRect(x: 10.25, y: 20.25, width: 0.1, height: 0.1)
        let reference = NativeSourceCanvasClip.referenceRect(domRect: owner, deviceScale: 2)
        #expect(reference.width == 0 && reference.height == 0)
        let empty = try #require(NativeCSSCoveragePath.inset([0, 0, 0, 0], unit: .pixels))
        let emptyPath = try #require(NativeCSSCoveragePath.path(empty, referenceBox: reference))
        #expect(points(emptyPath).count == 5)
        #expect(emptyPath.boundingBoxOfPath.width == 0)
        let grown = try #require(NativeCSSCoveragePath.inset([-1, -2, -3, -4], unit: .pixels))
        let grownPath = try #require(NativeCSSCoveragePath.path(grown, referenceBox: reference))
        #expect(grownPath.boundingBoxOfPath.width == 6 && grownPath.boundingBoxOfPath.height == 4)
    }

    @Test func emptyInsetReplacesAPendingPathAndClipsAllPaint() throws {
        let owner = CGRect(x: 0, y: 0, width: 10, height: 10)
        let declaration = try #require(NativeCSSCoveragePath.inset([0, 11, 0, 0], unit: .pixels))
        var pixels = [UInt8](repeating: 0, count: 20 * 20 * 4)
        try pixels.withUnsafeMutableBytes { memory in
            let context = try #require(CGContext(data: memory.baseAddress, width: 20, height: 20,
                bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            // A pending path must not turn a genuine empty CSS shape into paint.
            context.addRect(CGRect(x: 0, y: 0, width: 20, height: 20))
            NativeTranslationRenderer.applyCoverageClip(declaration, coverage: [owner], owner: owner, context: context, pixelSnapScale: 1)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        #expect(pixels.allSatisfy { $0 == 0 })
    }

    @Test func finalCaptionPolishClearsCurrentDeclarationButRetainsHistory() throws {
        let old = CGRect(x: 203.25, y: 405.859375, width: 31.28125, height: 54.109375)
        let declaration = try #require(NativeCSSCoveragePath.declaration(coverage: [old], origin: old.origin, commands: .relative))
        var entry = NativeTranslationCaptionPanelPolish.Entry(id: "22", sourceTextOnly: false,
            rotation: 0, vertical: false, lettering: "piece", wrappingScript: "korean", font: 6.5,
            frame: CGRect(x: 0, y: 212.30263157894737, width: 390, height: 275.39473684210526),
            sources: [CGRect(x: 221.63533834586468, y: 408.890977443609, width: 9.896616541353383, height: 48.139097744360896)],
            balancedColumn: false, column: nil, columnPaddingTop: 0,
            ink: CGRect(x: 206.3563125, y: 424.90625, width: 22.178, height: 15),
            panels: [.init(rect: old, background: [72, 54, 41], coverage: [old], clipped: true, coverageClip: declaration)])
        entry.panels[0].captionUnionClipped = true
        let result = NativeTranslationCaptionPanelPolish.polish([entry], opacity: 1, kept: [])
        #expect(result[0].panels[0].coverageClip == nil)
        #expect(result[0].panels[0].clipped == false)
        #expect(result[0].panels[0].captionUnionClipped)
        #expect(entry.panels[0].coverageClip?.subpaths == declaration.subpaths)
    }
    @Test func acceptedPackingWritesAbsolutePathWhileSkippedCopiesRetainCurrentNone() throws {
        let input = [
            NativeCaptionPacking.Entry(id: "a", text: "가가가", font: 12,
                ink: CGRect(x: 25, y: 25, width: 45, height: 15),
                source: CGRect(x: 25, y: 25, width: 30, height: 15), packingValid: false,
                panels: [.init(rect: CGRect(x: 20, y: 20, width: 60, height: 30), color: [255,255,255])]),
            NativeCaptionPacking.Entry(id: "b", text: "가가가", font: 12,
                ink: CGRect(x: 80, y: 60, width: 50, height: 15),
                source: CGRect(x: 80, y: 60, width: 30, height: 15), packingValid: false,
                panels: [.init(rect: CGRect(x: 70, y: 40, width: 70, height: 60), color: [0,0,0])])
        ]
        func measure(_ e: NativeCaptionPacking.Entry, _ cell: CGRect, _ font: Double) -> NativeCaptionPacking.Measurement? {
            let available = max(0, Double(cell.width)-6), demand = Double(e.text.count)*font
            let width = min(demand, available), height = font*1.2*max(1,ceil(demand/max(1,available)))
            return .init(ink: CGRect(x: cell.midX-width/2, y: cell.midY-height/2, width: width, height: height))
        }
        let result = NativeCaptionPacking.pack(input, page: CGRect(x: 0,y: 0,width: 300,height: 300), opacity: 1, measure: measure)
        let accepted = result.entries.filter { $0.cell != nil }
        #expect(!accepted.isEmpty)
        for entry in accepted {
            let clip = try #require(entry.panels.first?.coverageClip)
            #expect(entry.panels[0].coverageClipActive == true)
            #expect(clip.inset == nil && !clip.subpaths.isEmpty)
            #expect(clip.subpaths.allSatisfy { $0[0].x == $0[3].x })
        }
        var skipped = input[0]
        skipped.sourceErasurePreserved = true
        skipped.panels[0].clipped = true // retained historical caption-union admission marker
        skipped.panels[0].coverageClipActive = false // actual CSS none
        let unchanged = NativeCaptionPacking.pack([skipped], page: CGRect(x: 0,y: 0,width: 300,height: 300), opacity: 1, measure: { _,_,_ in nil })
        #expect(unchanged.skippedIDs.contains("a"))
        #expect(unchanged.entries[0].panels[0].coverageClipActive == false)
        #expect(unchanged.entries[0].panels[0].coverageClip == nil)
        #expect(unchanged.entries[0].panels[0].clipped)
    }

    @Test(arguments: [0, 1, 2]) func unchangedGrowthRetainsInsetAbsoluteOrNoneUntilAnActualWrite(mode: Int) throws {
        let owner = CGRect(x: 10.25, y: 20.25, width: 100.25, height: 80.25)
        let initial: NativeCSSCoveragePath.Declaration?
        switch mode {
        case 0: initial = NativeCSSCoveragePath.inset([10,20,30,40], unit: .percent)
        case 1: initial = NativeCSSCoveragePath.declaration(coverage: [owner], origin: owner.origin, commands: .absolute)
        default: initial = nil
        }
        var panel = NativeTranslationSourceStylePostPolish.Panel(rect: owner, background: [20,40,60],
            coverage: [owner], clipped: mode != 2, coverageClip: initial)
        panel.captionUnionClipped = true
        let input = NativeTypographyPlateGrowth.Input(text: "가나다라마바사", font: 10,
            originalFont: 10, sourceGlyph: 20, cap: 15, plate: owner,
            currentInk: CGRect(x: 30,y: 40,width: 30,height: 12), coverage: [owner], frame: nil)
        let result = try #require(NativeTypographyPlateGrowth.grow(input,
            state: .init(), budget: .init(), advance: { _,font in font },
            measure: { proposal in .init(ink: CGRect(x: 30,y: 40,width: 30,height: 12),
                lineRects: [CGRect(x: 30,y: 40,width: 30,height: 12)],
                scrollWidth: 30, clientWidth: Double(proposal.box.width), scrollHeight: 12, clientHeight: Double(proposal.box.height)) },
            roomProvider: { _,_ in nil }))
        #expect(result.coverageClipWritten == false)
        NativeTranslationRenderer.commitPlateGrowthCoverage(&panel, result: result)
        #expect(panel.coverageClip?.subpaths == initial?.subpaths)
        #expect(panel.coverageClip?.inset?.values == initial?.inset?.values)
        #expect(panel.clipped == (mode != 2) && panel.captionUnionClipped)
        var changed = result
        changed.coverage = [owner, CGRect(x: owner.maxX-3,y: 25,width: 8,height: 20)]
        changed.coverageClipWritten = true
        NativeTranslationRenderer.commitPlateGrowthCoverage(&panel, result: changed)
        #expect(panel.coverageClip?.inset == nil)
        #expect(panel.coverageClip?.subpaths.count == 2 && panel.clipped)
    }

}
