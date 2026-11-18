import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeHorizontalSourceLeadingTests {
    private let viewport = CGSize(width: 800, height: 300)
    private func rows() -> [[String: Any]] {
        [("first", 50.0, 80.0, 550.0), ("second", 51.0, 140.0, 330.0)].map { id, x, y, width in
            let b = [x / 800, y / 300, width / 800, 32.0 / 300]
            return ["id": id, "text": "한 줄의 번역", "sourceVertical": false, "vertical": false,
                "sourceBounds": b, "sourceFontSize": 28.0, "fontSize": 28.0,
                "sourceMemberPolygons": [[[x,y],[x+width,y],[x+width,y+32],[x,y+32]]],
                "textAlignment": "center", "renderExpansionBoundaryAuthority": "local-source-window",
                "textPlacementGuide": ["rectNormalized": b, "horizontal": "center", "vertical": "center"],
                "textExpansionPolicy": ["kind": "source-near-limited-expansion",
                    "allowedRectNormalized": [0.02,0.05,0.96,0.9],
                    "candidates": [[0.02,0.05,0.96,0.9]], "backgroundRisk": [0.05],
                    "maskCoverage": [1.0], "sourceFontPixels": 28.0]]
        }
    }

    @Test func unequalWidthStackedRowsAcquireOnlySharedEffectLeadingX() throws {
        let original = rows(), result = NativeHorizontalSourceLeading.annotate(original, viewport: viewport, sourcePixelSize: viewport)
        #expect(result.groups.count == 1)
        let packets = try result.items.map { try #require($0["sourceClusterAlignment"] as? [String: Any]) }
        #expect(packets[0]["groupID"] as? String == packets[1]["groupID"] as? String)
        #expect(packets[0]["axis"] as? String == "left")
        #expect(packets[0]["anchorNormalized"] as? Double == 50.5 / 800)
        for i in original.indices {
            let guide = try #require(result.items[i]["textPlacementGuide"] as? [String: Any])
            #expect(guide["horizontal"] as? String == "left")
            #expect(guide["vertical"] as? String == "center")
            #expect(result.items[i]["textAlignment"] as? String == "center")
            for key in ["text", "sourceFontSize", "sourceBounds", "sourceMemberPolygons"] {
                #expect(NSDictionary(dictionary: ["value": original[i][key]!]).isEqual(to: ["value": result.items[i][key]!]))
            }
        }
    }

    @Test func knownBodiesRolesAndMissingOutsideEvidenceAbstain() {
        for change: (inout [String: Any]) -> Void in [
            { $0["balloonPlacement"] = ["bodyID": "known"] },
            { $0["balloonInterior"] = ["rect": [0.0,0,1,1]] },
            { $0["role"] = "title" }, { $0["role"] = "dialogue" },
            { $0.removeValue(forKey: "renderExpansionBoundaryAuthority") },
            { $0["sourceVertical"] = true },
            { $0.removeValue(forKey: "sourceMemberPolygons") },
            { $0["sourceClusterAlignment"] = ["groupID": "explicit"] }
        ] {
            var input = rows(); change(&input[0])
            #expect(NativeHorizontalSourceLeading.annotate(input, viewport: viewport, sourcePixelSize: viewport).groups.isEmpty)
        }
    }

    @Test func centeredTitlesAndDistantRowsAreNotRecruited() {
        var centered = rows()
        centered[1]["sourceBounds"] = [160.0/800,140.0/300,330.0/800,32.0/300]
        #expect(NativeHorizontalSourceLeading.annotate(centered, viewport: viewport, sourcePixelSize: viewport).groups.isEmpty)
        var distant = rows()
        distant[1]["sourceBounds"] = [51.0/800,220.0/300,330.0/800,32.0/300]
        #expect(NativeHorizontalSourceLeading.annotate(distant, viewport: viewport, sourcePixelSize: viewport).groups.isEmpty)
    }

    @Test func refreshIsIdempotentAndNewBalloonRevokesDerivedPacket() throws {
        let once = NativeHorizontalSourceLeading.annotate(rows(), viewport: viewport, sourcePixelSize: viewport)
        let twice = NativeHorizontalSourceLeading.annotate(once.items, viewport: viewport, sourcePixelSize: viewport)
        #expect(NSArray(array: once.items).isEqual(to: twice.items))
        let reversed = NativeHorizontalSourceLeading.annotate(Array(rows().reversed()), viewport: viewport, sourcePixelSize: viewport)
        #expect(NSArray(array: once.items).isEqual(to: Array(reversed.items.reversed())))
        var changed = once.items; changed[0]["balloonPlacement"] = ["bodyID": "new-body"]
        let refreshed = NativeHorizontalSourceLeading.annotate(changed, viewport: viewport, sourcePixelSize: viewport)
        #expect(refreshed.groups.isEmpty)
        #expect(refreshed.items.allSatisfy { $0["sourceClusterAlignment"] == nil })
        #expect((refreshed.items[0]["textPlacementGuide"] as? [String: Any])?["horizontal"] as? String == "center")
    }

    @Test func renderCacheProjectionIncludesChangedPlacementSemantics() {
        #expect(NativeRenderVariantPolicy.projection["horizontalSourceLeading"] == NativeHorizontalSourceLeading.identity)
    }

    @Test func originalPixelEMConvertsToLogicalViewportExactlyOnce() throws {
        let full = NativeHorizontalSourceLeading.annotate(rows(), viewport: viewport, sourcePixelSize: viewport)
        let logical = NativeHorizontalSourceLeading.annotate(rows(), viewport: .init(width: 400, height: 150), sourcePixelSize: viewport)
        #expect(full.groups.count == 1 && logical.groups.count == 1)
        let a = try #require(full.items[0]["sourceClusterAlignment"] as? [String: Any])
        let b = try #require(logical.items[0]["sourceClusterAlignment"] as? [String: Any])
        #expect(a["anchorNormalized"] as? Double == b["anchorNormalized"] as? Double)
        #expect(NativeHorizontalSourceLeading.annotate(rows(), viewport: .init(width: 400, height: 300), sourcePixelSize: viewport).groups.isEmpty)
    }

    @Test func actualGrayCanvasPainterAdmitsSharedLeadingWithoutChangingFonts() throws {
        let input = NativeHorizontalSourceLeading.annotate(rows(), viewport: viewport, sourcePixelSize: viewport).items
        let context = try #require(CGContext(data: nil, width: 800, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(origin: .zero, size: viewport))
        let background = try #require(context.makeImage())
        let painterItems = input.map { raw in
            let b = raw["sourceBounds"] as! [Double]
            return NativeAOTRawTextPainter.Item(id: raw["id"] as! String, text: raw["text"] as! String,
                frame: CGRect(x: b[0]*800, y: b[1]*300, width: b[2]*800, height: b[3]*300),
                fontSize: 28, lineHeight: 39.2, chosenFill: CGColor(gray: 0, alpha: 1), colorAuthority: "synthetic-gray-only")
        }
        let layer = try NativeAOTRawTextPainter.renderCentered(items: painterItems, rawItems: input,
            viewport: viewport, restored: background, allowShrink: false)
        let admissions = try #require(layer.audit["finalPaintAdmission"] as? [[String: Any]])
        let leading = try admissions.map { try #require(($0["finalFootprintOutputPixels"] as? [CGFloat])?.first) }
        #expect(leading.count == 2)
        #expect(leading[0] == leading[1])
        #expect(admissions.allSatisfy { $0["fontChanged"] as? Bool == false })
    }
}
