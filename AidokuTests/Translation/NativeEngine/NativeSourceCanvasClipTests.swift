import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeSourceCanvasClipTests {
    private struct Fixture: Decodable {
        let id: String
        let raw, used, parent: [Double]
        let clip, expected: [Double]?
        let state: String
    }

    // Captured WKPDF basic-shape operators from the literal frozen cleanupClip
    // helper at DPR2. The tolerance is PDF decimal serialization precision;
    // the strict final RGBA gate retains zero tolerance.
    @Test(arguments: Array(0..<12))
    func authoredFixedInsetsMatchCapturedWebShape(index: Int) throws {
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(Self.captured.utf8))
        let fixture = fixtures[index]
        func rect(_ values: [Double]) -> CGRect {
            CGRect(x: values[0] + fixture.parent[0], y: values[1] + fixture.parent[1],
                   width: values[2], height: values[3])
        }
        let actual = NativeSourceCanvasClip.liveClip(authoredRect: rect(fixture.raw),
            domRect: rect(fixture.used), cleanupClip: fixture.clip.map(rect), deviceScale: 2)
        switch fixture.state {
        case "none":
            #expect(actual == nil, "\(fixture.id): CSS none")
        case "empty":
            #expect(actual == .zero, "\(fixture.id): empty basic shape")
        default:
            let actual = try #require(actual)
            let expected = try #require(fixture.expected)
            let values = [actual.origin.x, actual.origin.y, actual.size.width, actual.size.height]
            for (value, reference) in zip(values, expected) {
                #expect(abs(value - reference) <= 0.0001, "\(fixture.id): captured PDF coordinate")
            }
        }
    }

    private static let captured = #"""
    [
      {
        "id": "positive-captured",
        "raw": [
          162.55462184873952,
          212.3529411764706,
          67.5126050420168,
          86.35714285714286
        ],
        "used": [
          162.546875,
          212.34375,
          67.5,
          86.34375
        ],
        "parent": [
          200,
          10
        ],
        "clip": [
          0.009,
          0.019,
          200.009,
          300.019
        ],
        "expected": [
          362.5,
          222.5,
          37.45078,
          86.5
        ],
        "state": "rect"
      },
      {
        "id": "negative-captured",
        "raw": [
          -20.009,
          -10.019,
          100.009,
          99.989
        ],
        "used": [
          -20,
          -10.015625,
          100,
          99.984375
        ],
        "parent": [
          200,
          170
        ],
        "clip": [
          0.009,
          0.019,
          200.009,
          300.019
        ],
        "expected": [
          200.018,
          170.03798999999998,
          79.98199,
          89.96201
        ],
        "state": "rect"
      },
      {
        "id": "four-insets",
        "raw": [
          1.127,
          2.783,
          100.009,
          80.013
        ],
        "used": [
          1.125,
          2.78125,
          100,
          80
        ],
        "parent": [
          200,
          330
        ],
        "clip": [
          3.003,
          5.009,
          94.999,
          69.983
        ],
        "expected": [
          202.876,
          335.2259999999999,
          94.98999,
          69.97
        ],
        "state": "rect"
      },
      {
        "id": "inside",
        "raw": [
          10.009,
          10.019,
          100.009,
          99.989
        ],
        "used": [
          10,
          10.015625,
          100,
          99.984375
        ],
        "parent": [
          200,
          490
        ],
        "clip": [
          -100,
          -100,
          1000,
          1000
        ],
        "expected": null,
        "state": "none"
      },
      {
        "id": "no-geometry",
        "raw": [
          10.009,
          10.019,
          100.009,
          99.989
        ],
        "used": [
          10,
          10.015625,
          100,
          99.984375
        ],
        "parent": [
          200,
          650
        ],
        "clip": null,
        "expected": null,
        "state": "none"
      },
      {
        "id": "outside",
        "raw": [
          20.1,
          30.2,
          10.3,
          11.4
        ],
        "used": [
          20.09375,
          30.1875,
          10.296875,
          11.390625
        ],
        "parent": [
          200,
          810
        ],
        "clip": [
          100,
          100,
          1,
          1
        ],
        "expected": [
          0.0,
          0.0,
          0.0,
          0.0
        ],
        "state": "empty"
      },
      {
        "id": "almost-empty",
        "raw": [
          10,
          10,
          1.02,
          5
        ],
        "used": [
          10,
          10,
          1.015625,
          5
        ],
        "parent": [
          200,
          970
        ],
        "clip": [
          11.015,
          10,
          1,
          5
        ],
        "expected": [
          0.0,
          0.0,
          0.0,
          0.0
        ],
        "state": "empty"
      },
      {
        "id": "used-width-exhausted",
        "raw": [
          10,
          10,
          0.019,
          5
        ],
        "used": [
          10,
          10,
          0.015625,
          5
        ],
        "parent": [
          200,
          1130
        ],
        "clip": [
          10.018,
          10,
          1,
          5
        ],
        "expected": null,
        "state": "empty"
      },
      {
        "id": "sub-layout-unit-insets",
        "raw": [
          12.0007,
          15.0008,
          20.0009,
          30.001
        ],
        "used": [
          12,
          15,
          20,
          30
        ],
        "parent": [
          200,
          1290
        ],
        "clip": [
          12.0037,
          15.0048,
          19.9949,
          29.991
        ],
        "expected": [
          212.003,
          1305.00401,
          19.994,
          29.98999
        ],
        "state": "rect"
      },
      {
        "id": "negative-four-insets",
        "raw": [
          -1.127,
          -2.783,
          100.009,
          80.013
        ],
        "used": [
          -1.125,
          -2.78125,
          100,
          80
        ],
        "parent": [
          200,
          1450
        ],
        "clip": [
          3.003,
          5.009,
          89.999,
          64.983
        ],
        "expected": [
          203.13,
          1454.7920299999998,
          89.98999,
          64.96997
        ],
        "state": "rect"
      },
      {
        "id": "half-positive",
        "raw": [
          10.25,
          10.25,
          100.25,
          99.25
        ],
        "used": [
          10.25,
          10.25,
          100.25,
          99.25
        ],
        "parent": [
          200,
          1610
        ],
        "clip": [
          11.75,
          11.75,
          97.25,
          96.25
        ],
        "expected": [
          212.0,
          1622.0,
          97.5,
          96.5
        ],
        "state": "rect"
      },
      {
        "id": "half-negative",
        "raw": [
          -20.25,
          -10.25,
          100.25,
          99.25
        ],
        "used": [
          -20.25,
          -10.25,
          100.25,
          99.25
        ],
        "parent": [
          200,
          1770
        ],
        "clip": [
          -18.75,
          -8.75,
          97.25,
          96.25
        ],
        "expected": [
          181.5,
          1761.5,
          97.5,
          96.5
        ],
        "state": "rect"
      }
    ]
    """#
}
