import Foundation
import Testing
@testable import Aidoku
struct NativePNGMetadataUnavailableTests {
    @Test
    func metadataLookupFailureIsUnknownNotNewRenderFailure() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let source = NativePNGMetadata.source(at: missing)
        #expect(source.resolutionStatus == "source-properties-unavailable")
        #expect(source.physicalWidthInches == nil)
        #expect(source.physicalHeightInches == nil)
    }
}
