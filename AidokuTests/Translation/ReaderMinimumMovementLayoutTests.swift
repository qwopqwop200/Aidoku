import Testing
import UIKit
@testable import Aidoku

struct ReaderMinimumMovementLayoutTests {
    @Test func colophonCaptionMovesUpWithoutChangingFontOrCardSize() {
        // Real credit-page geometry: multiple columns must not turn its two
        // disclaimer rows into a side-by-side band after minimum-cost packing.
        let sources = [
            CGRect(x: 214.789215686275, y: 324.576388888889, width: 18.759803921569, height: 10.959722222222),
            CGRect(x: 166.308823529412, y: 346.074305555556, width: 113.191176470588, height: 8.430555555556),
            CGRect(x: 114.034313725490, y: 365.886111111111, width: 26.558823529412, height: 8.641319444444),
            CGRect(x: 200.034313725490, y: 365.253819444444, width: 53.117647058824, height: 19.390277777778),
            CGRect(x: 114.034313725490, y: 394.971527777778, width: 18.338235294118, height: 9.695138888889),
            CGRect(x: 189.495098039216, y: 394.550000000000, width: 51.431372549020, height: 10.748958333333),
            CGRect(x: 148.392156862745, y: 395.393055555556, width: 34.357843137255, height: 8.852083333333),
            CGRect(x: 113.823529411765, y: 415.204861111111, width: 27.401960784314, height: 29.928472222222),
            CGRect(x: 147.970588235294, y: 415.415625000000, width: 120.357843137255, height: 48.264930555556),
            CGRect(x: 107.289215686275, y: 485.810763888889, width: 115.720588235294, height: 8.430555555556),
            CGRect(x: 115.299019607843, y: 494.873611111111, width: 241.769607843137, height: 28.874652777778),
        ]
        let preferred = [
            CGRect(x: 211.669117647059, y: 322.556250000000, width: 25.000000000000, height: 15.000000000000),
            CGRect(x: 166.310661764706, y: 342.789583333333, width: 113.187500000000, height: 15.000000000000),
            CGRect(x: 114.040287990196, y: 362.706770833333, width: 26.546875000000, height: 15.000000000000),
            CGRect(x: 200.038449754902, y: 363.386458333333, width: 53.109375000000, height: 23.125000000000),
            CGRect(x: 113.703431372549, y: 392.319097222222, width: 19.000000000000, height: 15.000000000000),
            CGRect(x: 189.499846813725, y: 392.424479166667, width: 51.421875000000, height: 15.000000000000),
            CGRect(x: 148.399203431373, y: 392.319097222222, width: 34.343750000000, height: 15.000000000000),
            CGRect(x: 113.829197303922, y: 413.661284722222, width: 27.390625000000, height: 33.015625000000),
            CGRect(x: 147.977634803922, y: 415.423090277778, width: 120.343750000000, height: 48.250000000000),
            CGRect(x: 107.290134803922, y: 482.526041666667, width: 115.718750000000, height: 15.000000000000),
            CGRect(x: 107.457261029412, y: 494.881250000000, width: 257.453125000000, height: 28.859375000000),
        ]
        let layouts = preferred.map { BrowserOverlayCardLayout(rect: $0, maximumFontSize: 8, contentInsets: .zero) }
        let result = BrowserOverlayLayoutPlanner.relaxingCardPositions(layouts, sources: sources,
            sourceVerticals: Array(repeating: false, count: sources.count), viewport: CGSize(width: 430, height: 607),
            preferredRects: preferred, allowsDetachedPlacements: Array(repeating: true, count: sources.count))
        #expect(result.count == layouts.count)
        #expect(abs(result[9].rect.minX - preferred[9].minX) < 0.01)
        let captionShift = result[9].rect.minY - preferred[9].minY
        #expect(captionShift < 0 && captionShift > -5)
        for index in [4, 10] {
            #expect(abs(result[index].rect.minX - preferred[index].minX) < 0.01)
            #expect(abs(result[index].rect.minY - preferred[index].minY) < 0.01)
        }
        #expect(!BrowserOverlayCollisionGeometry.hasOverlap(in: result.map(\.rect)))
        for index in layouts.indices {
            #expect(result[index].rect.size == layouts[index].rect.size)
            #expect(result[index].maximumFontSize == layouts[index].maximumFontSize)
            #expect(result[index].contentInsets == layouts[index].contentInsets)
        }
        // Compare against a known feasible local solution, not just a loose
        // distance limit that would allow the old 58-point sideways jumps.
        let upperShift = preferred[10].minY - 2 - preferred[9].maxY
        let movement = result.indices.reduce(CGFloat.zero) { total, index in
            let dx = result[index].rect.midX - preferred[index].midX
            let dy = result[index].rect.midY - preferred[index].midY
            return total + dx * dx + dy * dy
        }
        #expect(movement <= upperShift * upperShift + 0.25)
    }

    @Test func thrownSidebarReturnsWhenNeighboursMakeRoomWithShortMoves() {
        // comic-8367 geometry: a right-edge synopsis column was thrown onto the
        // panel art because two small captions sat 12 points into its card.
        let bounds = CGRect(x: 0, y: 137.8, width: 402, height: 598.3)
        let sources = [
            CGRect(x: 365.9, y: 480, width: 29.3, height: 217.8),
            CGRect(x: 325, y: 462.2, width: 32.4, height: 39.3),
            CGRect(x: 314.7, y: 601.2, width: 42.4, height: 48.9),
            CGRect(x: 199.1, y: 459.7, width: 45.2, height: 58)
        ]
        let preferred = [
            CGRect(x: 352.4, y: 480, width: 56.2, height: 217.8),
            sources[1], sources[2], CGRect(x: 199.1, y: 450.7, width: 45.2, height: 76)
        ]
        let thrown = CGRect(x: 256.5, y: 304.1, width: 56.2, height: 217.8)
        let layouts = [thrown, sources[1], sources[2], preferred[3]].map {
            BrowserOverlayCardLayout(rect: $0, maximumFontSize: 6, contentInsets: .zero)
        }
        let result = BrowserOverlayLayoutPlanner.returningDisplacedCards(
            layouts, sources: sources,
            preferredRects: preferred, placementBounds: bounds, movable: [true, true, true, true])
        #expect(abs(result[0].rect.minX - (bounds.maxX - 56.2)) < 0.01)
        #expect(abs(result[0].rect.minY - 480) < 0.01)
        for index in [1, 2] {
            #expect(result[index].rect.maxX <= result[0].rect.minX)
            #expect(abs(result[index].rect.minX - sources[index].minX) < 14)
            #expect(result[index].rect.minY == sources[index].minY)
        }
        #expect(result[3].rect == layouts[3].rect)
        #expect(!BrowserOverlayCollisionGeometry.hasOverlap(in: result.map(\.rect)))
        for index in layouts.indices {
            #expect(result[index].rect.size == layouts[index].rect.size)
            #expect(result[index].maximumFontSize == layouts[index].maximumFontSize)
        }
    }

    @Test func overlapInsideBothOCRBoxesDoesNotKeepACardFromItsSource() {
        // comic-0042: a giant title box reaches into the author name's box. The
        // overlap both boxes claim is unavoidable and must not throw the name
        // to the top of the page; a card fixed in place still blocks a return.
        let bounds = CGRect(x: 0, y: 143.6, width: 402, height: 586.9)
        let sources = [
            CGRect(x: 18.6, y: 517.7, width: 341.4, height: 172.1),
            CGRect(x: 273.4, y: 666.9, width: 123.7, height: 48.9)
        ]
        let layouts = [
            BrowserOverlayCardLayout(rect: sources[0], maximumFontSize: 11.75, contentInsets: .zero),
            BrowserOverlayCardLayout(rect: CGRect(x: 201.4, y: 147.4, width: 123.7, height: 48.9),
                                     maximumFontSize: 11.75, contentInsets: .zero)
        ]
        let result = BrowserOverlayLayoutPlanner.returningDisplacedCards(layouts, sources: sources,
                                                                         preferredRects: sources, placementBounds: bounds, movable: [true, true])
        #expect(result[1].rect == sources[1])
        #expect(result[0].rect == sources[0])

        // A caption from elsewhere fully in the way that cannot move keeps the name out.
        let blocker = CGRect(x: 270, y: 660, width: 130, height: 60)
        let blockerSource = CGRect(x: 200, y: 600, width: 20, height: 10)
        let blocked = BrowserOverlayLayoutPlanner.returningDisplacedCards(
            layouts + [BrowserOverlayCardLayout(rect: blocker, maximumFontSize: 9, contentInsets: .zero)],
            sources: sources + [blockerSource], preferredRects: sources + [blocker], placementBounds: bounds,
            movable: [false, true, false])
        #expect(blocked[1].rect == layouts[1].rect)
    }

    @Test func returnDoesNotUncoverANeighboursLetteringForLittleGain() {
        // diverse2-0072: a two-glyph sound returning to its line would push the
        // paragraph below off the top of its own source lettering.
        let bounds = CGRect(x: 0, y: 364.3, width: 402, height: 145.3)
        let sources = [
            CGRect(x: 103.9, y: 394.3, width: 14.7, height: 4.8),
            CGRect(x: 104.1, y: 401.7, width: 86.8, height: 41)
        ]
        let preferred = [CGRect(x: 102.8, y: 392.3, width: 17, height: 12), CGRect(x: 77.3, y: 399.1, width: 140.5, height: 62.5)]
        let layouts = [
            BrowserOverlayCardLayout(rect: CGRect(x: 58.3, y: 401.1, width: 17, height: 12), maximumFontSize: 6, contentInsets: .zero),
            BrowserOverlayCardLayout(rect: preferred[1], maximumFontSize: 5, contentInsets: .zero)
        ]
        let result = BrowserOverlayLayoutPlanner.returningDisplacedCards(layouts, sources: sources,
                                                                         preferredRects: preferred, placementBounds: bounds, movable: [true, true])
        // The paragraph keeps covering its lettering; the sound may only take a
        // free spot next to its line (here just above the paragraph).
        #expect(result[1].rect == layouts[1].rect)
        #expect(!BrowserOverlayCollisionGeometry.hasOverlap(in: result.map(\.rect)))
        #expect(result[0].rect.intersects(sources[0]) || result[0].rect == layouts[0].rect)
    }
}
