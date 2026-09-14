import Combine
import Foundation

@MainActor
final class SearchSuggestionsViewModel: ObservableObject {
    @Published private(set) var suggestions: [SearchSuggestion] = []
    private(set) var query: SearchSuggestionQuery?

    private let configuration: SearchSuggestionConfiguration
    private let service: SearchSuggestionService
    private let delay: UInt64
    private var task: Task<Void, Never>?
    private var generation = 0

    init(configuration: SearchSuggestionConfiguration, service: SearchSuggestionService? = nil, delay: UInt64 = 250_000_000) {
        self.configuration = configuration
        self.service = service ?? .init(configuration: configuration)
        self.delay = delay
    }

    func update(text: String, selection: NSRange) {
        dismiss()
        guard let query = SearchSuggestionQuery(text: text, selection: selection, configuration: configuration) else { return }
        self.query = query
        let generation = generation
        let service = service
        let delay = delay
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                let suggestions = try await service.suggestions(for: query)
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.suggestions = suggestions
            } catch {
                // Suggestions are optional; errors must not interrupt the ordinary search.
            }
        }
    }

    func dismiss() {
        generation += 1
        task?.cancel()
        task = nil
        query = nil
        suggestions = []
    }

    func waitForUpdate() async {
        await task?.value
    }
}
