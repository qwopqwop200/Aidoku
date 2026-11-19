import Foundation
import Testing
@testable import Aidoku

struct SearchSuggestionsTests {
    private func configuration(mode: SearchSuggestionConfiguration.QueryMode = .token) -> SearchSuggestionConfiguration {
        var config = SearchSuggestionConfiguration(urlTemplate: "https://catalog.example/{namespace}/{queryPath}.json", format: .tuples)
        config.queryMode = mode
        config.defaultNamespace = "all"
        config.minimumQueryLength = 1
        config.lowercaseQuery = true
        config.queryCharacterReplacements = [" ": "_", "/": "slash", ".": "dot"]
        return config
    }

    private func query(_ text: String, config: SearchSuggestionConfiguration? = nil) throws -> SearchSuggestionQuery {
        try #require(SearchSuggestionQuery(
            text: text, selection: NSRange(location: text.utf16.count, length: 0), configuration: config ?? configuration()
        ))
    }

    @Test func preservesEarlierTermsAndExclusion() throws {
        let context = try query("language:en -author:ali")
        #expect(context.term == "ali")
        #expect(context.namespace == "author")
        let edit = try #require(context.applying(.init(text: "alice example", namespace: "author", count: 12)))
        #expect(edit.text == "language:en -author:alice_example ")
        #expect(edit.selection.location == edit.text.utf16.count)
    }

    @Test func encodesPathAndNamespaceWithoutChangingHost() throws {
        let config = configuration()
        let context = try query("author:A_B/C.D?", config: config)
        #expect(config.request(for: context)?.url?.absoluteString == "https://catalog.example/author/a/_/b/slash/c/dot/d/%3F.json")
        var queryConfig = SearchSuggestionConfiguration(urlTemplate: "https://catalog.example/?q={query}", format: .strings)
        queryConfig.minimumQueryLength = 1
        let special = try query("a&b#c+한", config: queryConfig)
        #expect(queryConfig.request(for: special)?.url?.query == "q=a%26b%23c%2B%ED%95%9C")
        queryConfig = SearchSuggestionConfiguration(urlTemplate: "http://catalog.example/{query}", format: .strings)
        #expect(queryConfig.request(for: special) == nil)
        queryConfig = SearchSuggestionConfiguration(urlTemplate: "https://{query}.example/", format: .strings)
        #expect(queryConfig.request(for: special) == nil)
    }

    @Test func decodesCommonResponseFormatsAndFiltersUnsafeRows() throws {
        let tuples = Data(#"""
        [["alice",12,"author"],["alice",12,"author"],["",0,"author"],[4],
        ["bad\nline",2,"author"],["bob",8,"bad:prefix"],["carol",null,"author"]]
        """#.utf8)
        #expect(try SearchSuggestionService.decode(tuples, format: .tuples) == [
            .init(text: "alice", namespace: "author", count: 12), .init(text: "carol", namespace: "author")
        ])
        #expect(try SearchSuggestionService.decode(Data(#"["ali",["alice","alicia"]]"#.utf8), format: .openSearch).map(\.text)
            == ["alice", "alicia"])
        #expect(try SearchSuggestionService.decode(Data(#"["alice"]"#.utf8), format: .strings) == [.init(text: "alice")])
        #expect(try SearchSuggestionService.decode(Data(#"[{"text":"alice","count":12}]"#.utf8), format: .objects)
            == [.init(text: "alice", count: 12)])
        #expect(throws: (any Error).self) {
            try SearchSuggestionService.decode(Data("<html>error</html>".utf8), format: .tuples)
        }
        let many = try JSONEncoder().encode((0..<50).map { "entry-\($0)" })
        let decoded = try SearchSuggestionService.decode(many, format: .strings)
        #expect(decoded.count == 10)
        #expect(decoded.last?.text == "entry-9")
    }
}
