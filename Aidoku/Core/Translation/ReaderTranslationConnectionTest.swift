import Combine
import Foundation

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

    func start(
        settings: ReaderTranslationSettings, apiKey: String,
        onResult: @escaping (Result<String, Error>) -> Void = { _ in }
    ) {
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
            onResult(result)
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
        transport: any TranslationHTTPTransport = BoundedURLSessionTransport()
    ) async throws -> String {
        let credentials = TestCredentials(
            account: settings.selectedCredentialAccount,
            draft: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), saved: savedCredentials
        )
        return try await ReaderTranslationAPIValidator.probe(
            settings, client: RemoteTranslationClient(credentialStore: credentials, transport: transport)
        )
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
