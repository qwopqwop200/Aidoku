import Testing
@testable import Aidoku

struct NativeOverlappingSourceUnitGroupingTests {
    @Test func excludesNumericMarkersAndSingleCharacterInterjections() {
        #expect(!NativeOverlappingSourceUnitGrouping.hasSentenceBody("1.2."))
        #expect(!NativeOverlappingSourceUnitGrouping.hasSentenceBody("ろ……"))
        #expect(!NativeOverlappingSourceUnitGrouping.hasSentenceBody("!"))
    }

    @Test func retainsJapaneseSentenceFragments() {
        #expect(NativeOverlappingSourceUnitGrouping.hasSentenceBody("止めるから"))
        #expect(NativeOverlappingSourceUnitGrouping.hasSentenceBody("イツたら"))
        #expect(NativeOverlappingSourceUnitGrouping.hasSentenceBody("あーっと"))
    }
}
