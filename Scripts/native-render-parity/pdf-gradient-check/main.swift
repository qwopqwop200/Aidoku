import Foundation
import CoreGraphics

struct Fixture: Decodable {
    struct Frame: Decodable { let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat }
    let page: String
    let index: Int
    let frame: Frame
    let deviceScale: CGFloat
    let usesPattern: Bool
    let dimensions: [CGFloat]
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: input))
var failures: [[String: Any]] = []
for fixture in fixtures {
    let frame = CGRect(x: fixture.frame.x, y: fixture.frame.y, width: fixture.frame.width, height: fixture.frame.height)
    let actual = NativeTranslationPDFCapture.gradientGeometry(frame: frame, deviceScale: fixture.deviceScale)
    let dimensions = [actual.destination.width, actual.destination.height, actual.tile.width, actual.tile.height]
    if actual.usesPattern != fixture.usesPattern || dimensions != fixture.dimensions {
        failures.append(["page": fixture.page, "index": fixture.index, "actualPattern": actual.usesPattern,
            "expectedPattern": fixture.usesPattern, "actualDimensions": dimensions, "expectedDimensions": fixture.dimensions])
    }
}
let report: [String: Any] = ["passed": failures.isEmpty, "fixtures": fixtures.count, "failures": failures,
    "scope": "Actual native helper versus measured tile dimensions and pattern/vector decisions from frozen WK PDF capture. This checks capture geometry, not final PNG equality."]
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
exit(failures.isEmpty ? 0 : 1)
