//
//  SearchContentView+ViewModel.swift
//  Aidoku
//
//  Created by Skitty on 11/14/25.
//

import AidokuRunner
import SwiftUI

extension SearchContentView {
    @MainActor
    class ViewModel: ObservableObject {
        struct SearchResult: Identifiable, Equatable {
            let source: AidokuRunner.Source
            let links: [HomeComponent.Value.Link]
            let contentID: String

            var id: String { source.id }

            init(source: AidokuRunner.Source, result: AidokuRunner.MangaPageResult) {
                self.source = source
                var hasher = Hasher()
                links = result.entries.map {
                    hasher.combine($0)
                    return $0.intoLink()
                }
                contentID = "\(source.key).\(hasher.finalize())"
            }

            static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
                lhs.id == rhs.id
            }
        }

        var sources: [AidokuRunner.Source] = []
        var filters: [FilterValue] = []

        @Published var results: [SearchResult] = []
        @Published var history: [String] = []
        @Published var isLoading: Bool = false

        static let maxHistoryEntries = 20

        private var searchQuery: String = ""
        private var generation = 0
        private var debounceTask: Task<Void, Never>?
        private var pendingSources: ArraySlice<AidokuRunner.Source> = []
        private var activeRequests: [UUID: Task<Void, Never>] = [:]
        private var completedSources: Set<ObjectIdentifier> = []
        private var searchVisible = true
        private var resumeOnAppearance = false

        var resultsIsEmpty: Bool {
            !results.contains(where: { !$0.links.isEmpty })
        }

        init() {
            history = UserDefaults.standard.stringArray(forKey: "Search.history") ?? []
        }

        deinit {
            debounceTask?.cancel()
            for request in activeRequests.values { request.cancel() }
        }
    }
}

extension SearchContentView.ViewModel {
    func search(query: String, delay: Bool) {
        if !delay {
            updateHistory(query: query)
        }

        guard searchQuery != query || (!delay && debounceTask != nil) else { return }
        searchQuery = query
        completedSources.removeAll()
        if !results.isEmpty { results = [] }
        restartSearch(delay: delay)
    }

    func waitForSearch() async {
        guard isLoading else { return }
        for await loading in $isLoading.values {
            if !loading { return }
        }
    }

    func setSearchVisible(_ visible: Bool) {
        guard searchVisible != visible else { return }
        searchVisible = visible
        if visible {
            if resumeOnAppearance { restartSearch(delay: false) }
        } else if isLoading {
            restartSearch(delay: false)
        }
    }

    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: "Search.history")
        withAnimation {
            history = []
        }
    }

    func removeHistory(item: String) {
        if let index = history.firstIndex(of: item) {
            withAnimation {
                _ = history.remove(at: index)
            }
            UserDefaults.standard.set(history, forKey: "Search.history")
        }
    }

    func updateSources(_ newSources: [AidokuRunner.Source]) {
        guard !sources.elementsEqual(newSources, by: { $0 === $1 }) else { return }
        completedSources.formIntersection(newSources.map(ObjectIdentifier.init))
        sources = newSources
        // A pending debounce reads the latest sources when it starts.
        if !searchQuery.isEmpty && debounceTask == nil {
            updateFilters(filters)
        }
    }

    func updateFilters(_ filters: [FilterValue]) {
        self.filters = filters
        if !searchQuery.isEmpty { restartSearch(delay: false) }
    }
}

extension SearchContentView.ViewModel {
    private func updateHistory(query: String) {
        guard !query.isEmpty else { return }

        var newHistory = history

        if let index = newHistory.firstIndex(of: query) {
            newHistory.remove(at: index)
        }
        newHistory.append(query)

        if newHistory.count > Self.maxHistoryEntries {
            newHistory.remove(at: 0)
        }

        UserDefaults.standard.set(newHistory, forKey: "Search.history")
        withAnimation {
            history = newHistory
        }
    }

    private func filteredSources() -> [AidokuRunner.Source] {
        sources.filter { source in
            for filter in filters {
                switch filter {
                    case .multiselect(let id, let included, let excluded):
                        switch id {
                            case "contentRating":
                                let includedRatings = included.compactMap { SourceContentRating(string: $0) }
                                let excludedRatings = excluded.compactMap { SourceContentRating(string: $0) }
                                let sourceRating = source.contentRating
                                if !includedRatings.isEmpty && !includedRatings.contains(sourceRating) {
                                    return false
                                } else if !excludedRatings.isEmpty && excludedRatings.contains(sourceRating) {
                                    return false
                                }
                            case "languages":
                                let sourceLanguages = source.getSelectedLanguages()
                                if !included.isEmpty && !sourceLanguages.contains(where: { included.contains($0) }) {
                                    return false
                                } else if !excluded.isEmpty && sourceLanguages.contains(where: { excluded.contains($0) }) {
                                    return false
                                }
                            case "sources":
                                let sourceKey = source.key
                                if !included.isEmpty && !included.contains(sourceKey) {
                                    return false
                                } else if !excluded.isEmpty && excluded.contains(sourceKey) {
                                    return false
                                }
                            default:
                                continue
                        }
                    default:
                        continue
                }
            }
            return true
        }
    }

    private func restartSearch(delay: Bool) {
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingSources = []
        for request in activeRequests.values { request.cancel() }
        resumeOnAppearance = !searchVisible && !searchQuery.isEmpty
        isLoading = searchVisible && !searchQuery.isEmpty
        guard isLoading else { return }
        if delay {
            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                self.debounceTask = nil
                self.scheduleSources()
            }
        } else {
            scheduleSources()
        }
    }

    private func scheduleSources() {
        let eligible = filteredSources()
        let allowed = Set(eligible.map(ObjectIdentifier.init))
        completedSources.formIntersection(allowed)
        if results.contains(where: { !allowed.contains(ObjectIdentifier($0.source)) }) {
            results.removeAll { !allowed.contains(ObjectIdentifier($0.source)) }
        }
        pendingSources = eligible.filter { !completedSources.contains(ObjectIdentifier($0)) }[...]
        startAvailableRequests()
    }

    private func startAvailableRequests() {
        guard isLoading, debounceTask == nil else { return }
        // A runner can finish after cancellation. Keep its slot occupied until it returns,
        // even when the tab has reopened or the query has already changed.
        while activeRequests.count < 3, let source = pendingSources.popFirst() {
            let id = UUID()
            let requestGeneration = generation
            let query = searchQuery
            activeRequests[id] = Task { [weak self] in
                let page = Task.isCancelled ? nil : try? await source.getSearchMangaList(query: query, page: 1, filters: [])
                guard let self else { return }
                self.activeRequests.removeValue(forKey: id)
                if !Task.isCancelled, self.generation == requestGeneration, let page {
                    self.completedSources.insert(ObjectIdentifier(source))
                    if !page.entries.isEmpty {
                        self.results.append(.init(source: source, result: page))
                    }
                }
                self.startAvailableRequests()
            }
        }
        if pendingSources.isEmpty && activeRequests.values.allSatisfy(\.isCancelled) {
            pendingSources = []
            isLoading = false
        }
    }
}
