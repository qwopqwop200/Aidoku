import Foundation
import CoreGraphics
import Testing
@Suite struct NumericMacroProbe {
    @Test func exactOptionalCGFloatAgainstInferredDouble() {
        let authoredTop = 262.03007518796994
        let stored: CGFloat? = authoredTop
        let actual = stored!
        let ordinaryEquality = stored == authoredTop
        print("NUMERIC", actual.native.bitPattern, authoredTop.bitPattern, ordinaryEquality)
        #expect(ordinaryEquality)
        #expect(Double(actual).bitPattern == authoredTop.bitPattern)
        #expect(stored == authoredTop)
    }
}
@main struct Entry { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }
