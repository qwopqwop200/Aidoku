import Foundation
import Testing
@testable import Aidoku

@MainActor
struct ReaderFailureLocalizationTests {
    private struct ProviderFailure: LocalizedError {
        var errorDescription: String? { "인증 정보를 확인할 수 없습니다." }
    }

    @Test func ocrFallbackAccessibilityExplainsCauseWithoutClaimingOCRIsDisplayed() {
        let cause = ProviderFailure()
        let fallback = ReaderTranslationOCRFallback(regions: [], underlying: cause)
        let description = ReaderTranslationCoordinator.localizedFailureDescription(fallback)
        #expect(description == cause.localizedDescription)
        #expect(ReaderTranslationCoordinator.localizedFailureDescription(cause) == cause.localizedDescription)
        #expect(!ReaderTranslationCoordinator.localizedFailureDescription(fallback).contains("ReaderTranslationOCRFallback"))
    }
}
