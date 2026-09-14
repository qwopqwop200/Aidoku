import UIKit

/// Connection probes. Reader activation always probes live; cached validation
/// remains available to callers that explicitly request shared results.
@MainActor
final class ReaderTranslationAPIValidator {
    static let shared = ReaderTranslationAPIValidator()
    private struct Identity: Equatable {
        let configuration: RemoteTranslationConfiguration
        let sourceLanguage: String
        let targetLanguage: String
        init(_ settings: ReaderTranslationSettings) {
            configuration = settings.configuration
            sourceLanguage = settings.sourceLanguage
            targetLanguage = settings.targetLanguage
        }
    }
    private let client: any RemoteTranslating
    private let onFailure: (Error) -> Void
    private var identity: Identity?
    private var result: Result<Void, Error>?
    private var task: Task<Void, Error>?
    private var generation = UUID()

    init(
        client: any RemoteTranslating = RemoteTranslationClient(),
        onFailure: @escaping (Error) -> Void = { _ in }
    ) {
        self.client = client
        self.onFailure = onFailure
    }

    deinit {
        task?.cancel()
    }

    /// User activation must recover after a network/VPN change without an app
    /// restart or settings edit. Await directly so disabling cancels this probe.
    func validateFreshForActivation(_ settings: ReaderTranslationSettings) async throws {
        _ = try await Self.probe(settings, client: client)
        try Task.checkCancellation()
    }

    func refresh(_ settings: ReaderTranslationSettings, force: Bool = false) {
        let next = Identity(settings)
        guard force || identity != next else { return }
        task?.cancel()
        generation = UUID()
        let issued = generation
        identity = next
        result = nil
        let client = client
        task = Task { [weak self] in
            do {
                _ = try await Self.probe(settings, client: client)
                guard let self, generation == issued else { throw CancellationError() }
                result = .success(())
            } catch {
                if let self, generation == issued, !Task.isCancelled {
                    result = .failure(error)
                    onFailure(error)
                }
                throw error
            }
        }
    }

    func validateForActivation(_ settings: ReaderTranslationSettings) async throws {
        refresh(settings)
        let issued = generation
        if let result { try result.get(); return }
        try await task?.value
        try Task.checkCancellation()
        guard generation == issued else { throw CancellationError() }
    }

    /// An explicit settings-screen retest may recover a failed background check.
    func recordSuccess(settings: ReaderTranslationSettings) {
        guard identity == Identity(settings) else { return }
        task?.cancel()
        generation = UUID()
        result = .success(())
    }

    nonisolated static func probe(_ settings: ReaderTranslationSettings, client: any RemoteTranslating) async throws -> String {
        try settings.validate()
        let sample: String
        switch settings.sourceLanguage {
        case "ko": sample = "연결 테스트"
        case "ja": sample = "接続テスト"
        case "zh-Hans", "zh-Hant": sample = "连接测试"
        default: sample = "Hello, world!"
        }
        let request = RemoteTranslationRequest(
            sourceLanguage: settings.sourceLanguage, targetLanguage: settings.targetLanguage,
            segments: [.init(id: "connection-test", text: sample)]
        )
        let response = try await client.translate(request, configuration: settings.configuration)
        try Task.checkCancellation()
        guard response.translations.count == 1,
              response.translations[0].id == "connection-test",
              !response.translations[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteTranslationError.invalidResponse("The connection test returned no translated text.")
        }
        return response.translations[0].text
    }

    func recordFailure(_ error: Error, settings: ReaderTranslationSettings) {
        guard identity == Identity(settings) else { return }
        task?.cancel()
        generation = UUID()
        result = .failure(error)
        onFailure(error)
    }
}
