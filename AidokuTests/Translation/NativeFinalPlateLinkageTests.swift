import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeFinalPlateLinkageTests {
    private let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    private func resolve(artwork: Bool = true, isolatedMark: Bool = false, displaced: Bool = false,
                         opacity: Double = 1) -> NativeFinalPlateLinkage.Result {
        let item = NativeFinalPlateLinkage.Item(id: "a", rotation: 0, vertical: false, sourceVertical: true, sourceFont: 20,
            sourceBounds: displaced ? [0.2,0.45,0.6,0.2] : [0.43,0.1,0.14,0.65], auxiliaryBounds: [])
        let node = NativeFinalPlateLinkage.Node(id: "a", ink: displaced ? CGRect(x: 26,y: 12,width: 45,height: 16) : CGRect(x: 20,y: 20,width: 60,height: 16),
            font: 12, shown: true, transformed: false, fits: true, sampledColors: [[10,10,10],[120,120,120]])
        let panel = NativeFinalPlateLinkage.Panel(id: "a", box: CGRect(x: 15,y: 5,width: 70,height: 80), coverage: nil, color: [240,240,240],
            rootChild: true, sourceErasure: false, preservedCaption: false, foreignFills: false, transformed: false, backing: false,
            shown: true, unknownClip: false, restoration: nil)
        return NativeFinalPlateLinkage.resolve(items: [item], nodes: [node], panels: [panel], frame: frame,
            imageSize: CGSize(width: 100,height: 100), opacity: opacity, preserveBackground: true) { crop in
            var rgba = [UInt8](repeating: 240,count: crop.width*crop.height*4)
            for y in 0..<crop.height { for x in 0..<crop.width {
                let sx = crop.x+x, sy = crop.y+y, i = (y*crop.width+x)*4
                rgba[i+3] = 255
                if artwork && (displaced ? sy < 35 : ((sx >= 18 && sx < 34) || (sx >= 66 && sx < 82)) && sy >= 48 && sy < 77) {
                    rgba[i] = 100; rgba[i+1] = 80; rgba[i+2] = 240
                }
                if isolatedMark && sx >= 23 && sx < 27 && sy >= 55 && sy < 59 { rgba[i] = 10; rgba[i+1] = 10; rgba[i+2] = 10 }
            } }
            return rgba
        }
    }
    @Test func cornersReleaseArtworkButKeepSourceAndCaptionCovered() {
        let result = resolve()
        #expect(result.links.count == 1)
        #expect(result.links[0].releases.count == 2)
        for point in [CGPoint(x: 50,y: 15),CGPoint(x: 50,y: 70),CGPoint(x: 25,y: 25)] {
            #expect(result.links[0].pieces.contains { $0.contains(point) })
        }
        #expect(!result.links[0].pieces.contains { $0.contains(CGPoint(x: 25,y: 60)) })
    }
    @Test func isolatedSourceLikeMarkProtectsItsCorner() {
        let result = resolve(isolatedMark: true)
        #expect(result.links.count == 1)
        #expect(result.links[0].releases.count == 1)
        #expect(result.links[0].pieces.contains { $0.contains(CGPoint(x: 25,y: 60)) })
        #expect(!result.links[0].pieces.contains { $0.contains(CGPoint(x: 72,y: 60)) })
    }
    @Test func displacedCaptionMovesOnlyWhenItReleasesFormerArtworkFootprint() {
        let accepted = resolve(displaced: true)
        #expect(accepted.links.first?.move != nil)
        let rejected = resolve(artwork: false,displaced: true)
        #expect(rejected.links.isEmpty)
        #expect(rejected.panels[0].box == CGRect(x: 15,y: 5,width: 70,height: 80))
    }
    @Test func translucentPlateDoesNotReadOrReleasePixels() {
        let result = resolve(opacity: 0.99)
        #expect(result.links.isEmpty)
        #expect(result.remainingPixels == 1_048_576)
    }
}
