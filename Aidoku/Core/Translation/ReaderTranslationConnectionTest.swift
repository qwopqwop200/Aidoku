import Combine
import UIKit

/// A manual test always makes a live request, without saving the form or its key.
@MainActor
final class ReaderTranslationConnectionTest: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }
    typealias Runner = @Sendable (ReaderTranslationSettings, String) async throws -> String
    @Published private(set) var state: State = .idle
    private let run: Runner
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(run: @escaping Runner = { settings, key in
        try await ReaderTranslationConnectionTest.translate(settings: settings, apiKey: key)
    }) {
        self.run = run
    }

    deinit { task?.cancel() }

    func start(settings: ReaderTranslationSettings, apiKey: String) {
        guard state != .running else { return }
        generation = UUID()
        let issued = generation
        let run = run
        state = .running
        task = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await run(settings, apiKey)) } catch { result = .failure(error) }
            guard let self, generation == issued, !Task.isCancelled else { return }
            task = nil
            switch result {
            case .success(let text): state = .success(text)
            case .failure(let error): state = .failure(error.localizedDescription)
            }
        }
    }

    func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        state = .idle
    }

    nonisolated static func translate(
        settings: ReaderTranslationSettings, apiKey: String,
        savedCredentials: any TranslationCredentialProviding = KeychainTranslationCredentialStore(),
        transport: any TranslationHTTPTransport = BoundedURLSessionTransport(),
        imageSupport: TranslationImageSupport = .shared
    ) async throws -> String {
        let credentials = TestCredentials(
            account: settings.selectedCredentialAccount,
            draft: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), saved: savedCredentials
        )
        return try await probe(
            settings, client: RemoteTranslationClient(credentialStore: credentials, transport: transport,
                imageSupport: imageSupport, rechecksImageSupport: true)
        )
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
        var request = RemoteTranslationRequest(
            sourceLanguage: settings.sourceLanguage, targetLanguage: settings.targetLanguage,
            segments: [.init(id: "connection-test", text: sample)]
        )
        request.translatesPageLettering = true
        request.filtersSFX = true
        request.filtersBackground = true
        // Exercise the required page request format without uploading a user page.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 32, height: 32)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        request.imageJPEG = try ReaderTranslationImagePreparation.translationJPEG(image)
        let response = try await client.translate(request, configuration: settings.configuration)
        try Task.checkCancellation()
        guard response.translations.count == 1,
              response.translations[0].id == "connection-test",
              !response.translations[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteTranslationError.invalidResponse("The connection test returned no translated text.")
        }
        return response.translations[0].text
    }

    private struct TestCredentials: TranslationCredentialProviding {
        let account: String
        let draft: String
        let saved: any TranslationCredentialProviding
        func secret(for account: String) throws -> String {
            guard account == self.account else { throw TranslationCredentialStoreError.notFound }
            if draft.isEmpty { return try saved.secret(for: account) }
            guard draft.utf8.count <= KeychainTranslationCredentialStore.maximumSecretBytes,
                  !draft.contains("\r"), !draft.contains("\n"), !draft.contains("\0") else {
                throw TranslationCredentialStoreError.invalidSecret
            }
            return draft
        }
    }
}
