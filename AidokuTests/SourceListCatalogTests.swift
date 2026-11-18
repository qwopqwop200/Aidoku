import Foundation
import Testing
@testable import Aidoku

struct SourceListCatalogTests {
    private let firstURL = URL(fileURLWithPath: "/first/index.json")
    private let secondURL = URL(fileURLWithPath: "/second/index.json")

    private func list(at url: URL, rows: [(String, String, Int)], legacy: Bool = false) throws -> SourceList {
        let entries = rows.map { id, name, version in
            ["id": id, "name": name, "version": version] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: entries)
        let sources = try JSONDecoder().decode([ExternalSourceInfo].self, from: data)
        return SourceList(url: url, name: "Fixture", sources: sources.map { $0.with(sourceUrl: url) }, legacy: legacy)
    }

    @Test func matchesOnlyRequestedIDsAndPreservesTheFirstEqualVersion() throws {
        var catalog = SourceListCatalog()
        catalog.states[firstURL] = .loaded(try list(at: firstURL, rows: [
            ("installed", "Old", 1), ("other", "Other", 9)
        ], legacy: true))
        catalog.states[secondURL] = .loaded(try list(at: secondURL, rows: [
            ("installed", "New", 4), ("installed", "Tie", 4)
        ]))

        let result = catalog.latestSources(for: ["installed", "missing"])
        #expect(Set(result.keys) == ["installed"])
        #expect(result["installed"]?.name == "New")
        #expect(result["installed"]?.sourceUrl == secondURL)
        #expect(catalog.latestSources(for: ["installed", "missing"]) == result)
        #expect(Set(catalog.latestSources(for: ["other"]).keys) == ["other"])
        #expect(catalog.latestSources(for: []).isEmpty)
    }

    @Test func listTransitionsInvalidatePositiveAndMissingMatches() throws {
        var catalog = SourceListCatalog()
        let ids: Set<String> = ["installed"]
        catalog.states = [firstURL: .loading, secondURL: .unavailable]
        #expect(catalog.latestSources(for: ids).isEmpty)
        catalog.states[firstURL] = .loaded(try list(at: firstURL, rows: [("installed", "First", 2)], legacy: true))
        #expect(catalog.latestSources(for: ids)["installed"]?.version == 2)
        catalog.states[secondURL] = .loaded(try list(at: secondURL, rows: [("installed", "Second", 5)]))
        #expect(catalog.latestSources(for: ids)["installed"]?.version == 5)
        catalog.states.removeValue(forKey: secondURL)
        #expect(catalog.latestSources(for: ids)["installed"]?.sourceUrl == firstURL)
        catalog.states[firstURL] = .loaded(try list(at: firstURL, rows: [("installed", "Replaced", 1)]))
        #expect(catalog.latestSources(for: ids)["installed"]?.version == 1)
        catalog.states = [:]
        #expect(catalog.latestSources(for: ids).isEmpty)
    }
}
