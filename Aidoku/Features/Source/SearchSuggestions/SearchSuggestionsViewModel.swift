import Combine
import Foundation

@MainActor
final class SearchSuggestionsViewModel: ObservableObject {
    @Published private(set) var suggestions: [SearchSuggestion] = []
    private(set) var query: SearchSuggestionQuery?

    private let configuration: SearchSuggestionConfiguration
    private let service: SearchSuggestionService
    private var task: Task<Void, Never>?
    private var generation = 0

    init(configuration: SearchSuggestionConfiguration) {
        self.configuration = configuration
        self.service = .init(configuration: configuration)
    }

    func update(text: String, selection: NSRange) {
        dismiss()
        guard let query = SearchSuggestionQuery(text: text, selection: selection, configuration: configuration) else { return }
        self.query = query
        let generation = generation
        let service = service
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
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
}
