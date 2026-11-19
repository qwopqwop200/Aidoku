import Foundation
import Testing
@testable import Aidoku

/// A provider that never returns valid structured output must not turn one
/// multi-segment batch into hundreds of serial retries after split repair.
struct TranslationSplitRepairBudgetTests {
    @Test func persistentlyMalformedProviderBoundsSplitDescendantRetries() async throws {
        let client = MalformedClient()
        let service = TranslationService(client: client, cache: TranslationCache(maxSizeMiB: 1))
        let request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko",
            segments: (0..<4).map { RemoteTranslationSegment(id: "segment-\($0)", text: "source-\($0)") })
        await #expect(throws: RemoteTranslationError.self) {
            _ = try await service.translate(request, configuration: .openAI(model: "split-budget"))
        }
        // 4 -> 2 + 2 -> four leaves. The first exhausted leaf aborts the batch, so the
        // count is bounded by 1 + 2 * (1 + 2 * (1 + splitDescendantMaximumRetries)); the
        // old five-retries-per-descendant behaviour needed 27 calls here.
        let leafAttempts = 1 + TranslationService.splitDescendantMaximumRetries
        let calls = await client.calls
        #expect(calls >= 1 + leafAttempts && calls <= 1 + 2 * (1 + 2 * leafAttempts), "calls=\(calls)")
    }
}

private actor MalformedClient: RemoteTranslating {
    private(set) var calls = 0
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        try Task.checkCancellation()
        calls += 1
        throw RemoteTranslationError.invalidResponse("structured translation is not valid JSON")
    }
}
