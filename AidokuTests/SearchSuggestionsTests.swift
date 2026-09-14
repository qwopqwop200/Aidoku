import AidokuRunner
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
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

    @Test func loadsOnlyExplicitSourceConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.json")
        try Data(#"{"info":{"id":"example.catalog"},"config":{"supportsTagSearch":true}}"#.utf8).write(to: file)
        #expect(SearchSuggestionConfiguration.load(sourceURL: directory) == nil)
        try Data(#"{"config":{"searchSuggestions":{"urlTemplate":"https://catalog.example/?q={query}","format":"strings"}}}"#.utf8)
            .write(to: file)
        #expect(SearchSuggestionConfiguration.load(sourceURL: directory)?.format == .strings)
        try Data(#"{"config":{"searchSuggestions":{"format":"unknown"}}}"#.utf8).write(to: file)
        #expect(SearchSuggestionConfiguration.load(sourceURL: directory) == nil)
    }

    @Test func preservesEarlierTermsAndExclusion() throws {
        let context = try query("language:en -author:ali")
        #expect(context.term == "ali")
        #expect(context.namespace == "author")
        let edit = try #require(context.applying(.init(text: "alice example", namespace: "author", count: 12)))
        #expect(edit.text == "language:en -author:alice_example ")
        #expect(edit.selection.location == edit.text.utf16.count)
    }

    @Test func completesAtCursorAndPreservesSuffixWithUnicode() throws {
        let text = "📚 language:en author:alxx category:history"
        let offset = (text as NSString).range(of: "alxx").location + 2
        let context = try #require(SearchSuggestionQuery(
            text: text, selection: NSRange(location: offset, length: 0), configuration: configuration()
        ))
        #expect(context.term == "al")
        let edit = try #require(context.applying(.init(text: "alice", namespace: "author")))
        #expect(edit.text == "📚 language:en author:alice category:history")
        #expect(edit.selection.location == "📚 language:en author:alice".utf16.count)
    }

    @Test func selectedTokenIsReplacedButSelectionAcrossTermsIsIgnored() throws {
        let text = "author:alice category:history"
        let context = try #require(SearchSuggestionQuery(
            text: text, selection: NSRange(location: 7, length: 5), configuration: configuration()
        ))
        #expect(context.applying(.init(text: "bob"))?.text == "author:bob category:history")
        #expect(SearchSuggestionQuery(
            text: text, selection: NSRange(location: 7, length: 10), configuration: configuration()
        ) == nil)
    }

    @Test(arguments: ["", " ", "-", ":", "author:alice "])
    func emptyFragmentsDoNotFetch(text: String) {
        #expect(SearchSuggestionQuery(
            text: text, selection: NSRange(location: text.utf16.count, length: 0), configuration: configuration()
        ) == nil)
    }

    @Test(arguments: ["author:", "-author:", "language:en author:", "category:history -author:"])
    func namespaceOnlyRequestsRootAndPreservesOtherTerms(text: String) throws {
        var config = configuration()
        config.minimumQueryLength = 8
        let context = try query(text, config: config)
        #expect(context.term.isEmpty)
        #expect(context.namespace == "author")
        #expect(config.request(for: context)?.url?.absoluteString == "https://catalog.example/author.json")
        let edit = try #require(context.applying(.init(text: "alice example", namespace: "author")))
        #expect(edit.text == text + "alice_example ")
    }

    @Test func namespaceEndpointCanBeConfiguredWithoutChangingNonemptyRequests() throws {
        var config = configuration()
        config.namespaceURLTemplate = "https://catalog.example/suggest?category={namespace}&q={query}"
        #expect(config.request(for: try query("author:"))?.url?.absoluteString == "https://catalog.example/suggest?category=author&q=")
        #expect(config.request(for: try query("author:al"))?.url?.absoluteString == "https://catalog.example/author/a/l.json")
        config.namespaces = ["category"]
        #expect(config.request(for: try query("author:")) == nil)
    }

    @Test func queryModeCompletesWholePhraseWithoutTokenSyntax() throws {
        let context = try query("great public lib", config: configuration(mode: .query))
        #expect(context.term == "great public lib")
        #expect(context.applying(.init(text: "great public libraries"))?.text == "great public libraries")
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

    @Test func unknownNamespaceAndShortQueriesAreIgnored() throws {
        var config = configuration()
        config.namespaces = ["author", "all"]
        #expect(config.request(for: try query("category:history")) == nil)
        config.minimumQueryLength = 3
        #expect(SearchSuggestionQuery(text: "ab", selection: .init(location: 2, length: 0), configuration: config) == nil)
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

    @Test func memoryCacheReusesResultsAndFailuresStayRetryable() async throws {
        let transport = SuggestionTestTransport()
        let config = configuration()
        let service = SearchSuggestionService(configuration: config, transport: { await transport.respond(to: $0) })
        let context = try query("author:ali")
        let first = try await service.suggestions(for: context)
        #expect(first == [.init(text: "alice", namespace: "author", count: 12)])
        _ = try await service.suggestions(for: context)
        #expect(await transport.requestCount == 1)
        await transport.setStatus(503)
        await #expect(throws: (any Error).self) { try await service.suggestions(for: query("author:bo")) }
        await transport.setStatus(200)
        #expect(try await !service.suggestions(for: query("author:bo")).isEmpty)
        #expect(await transport.requestCount == 3)
        await transport.setStatus(404)
        #expect(try await service.suggestions(for: query("author:no")).isEmpty)
    }

    @Test func mapsSourceNamespacesAndHidesForeignCounts() throws {
        var config = configuration()
        config.namespaces = ["parody", "category"]
        config.requestNamespaceMappings = ["parody": "series", "category": "type"]
        #expect(config.request(for: try query("parody:al", config: config))?.url?.path == "/series/a/l.json")
        #expect(config.request(for: try query("category:", config: config))?.url?.path == "/type.json")
        #expect(config.request(for: try query("series:al", config: config)) == nil)
        let data = Data(#"[["sample",12,"male"],["sample",34,"female"],["example",56,"series"],["manga",78,"type"]]"#.utf8)
        let entries = try SearchSuggestionService.decode(data, format: .tuples,
            namespaceMappings: ["male": "tag", "female": "tag", "series": "parody", "type": "category"], hideCounts: true)
        #expect(entries == [.init(text: "sample", namespace: "tag"), .init(text: "example", namespace: "parody"), .init(text: "manga", namespace: "category")])
    }

    @Test func quotedCompletionPreservesExclusionAndRoundTrips() throws {
        var config = configuration()
        config.quoteTokens = true
        let context = try query("language:english -tag:full", config: config)
        let edit = try #require(context.applying(.init(text: "full color", namespace: "tag")))
        #expect(edit.text == "language:english -tag:\"full color\" ")
        let roundTrip = try query(String(edit.text.dropLast()), config: config)
        #expect(roundTrip.term == "full color")
        #expect(roundTrip.excluded)
        #expect(config.request(for: roundTrip)?.url?.path == "/tag/f/u/l/l/_/c/o/l/o/r.json")
        #expect(SearchSuggestionQuery(text: edit.text, selection: edit.selection, configuration: config) == nil)
        let unclosed = try query("tag:\"full co", config: config)
        #expect(unclosed.term == "full co")
        #expect(unclosed.applying(.init(text: "full color"))?.text == "tag:\"full color\" ")
    }

    @Test func quotedTokenEditsAtCursorAndEscapesValues() throws {
        var config = configuration()
        config.quoteTokens = true
        let text = "📚 tag:\"full color\" language:english"
        let cursor = (text as NSString).range(of: "color").location + 2
        let context = try #require(SearchSuggestionQuery(text: text, selection: NSRange(location: cursor, length: 0), configuration: config))
        #expect(context.term == "full co")
        #expect(context.applying(.init(text: "full color"))?.text == text)
        let edit = try #require(try query("artist:al", config: config).applying(.init(text: "alice \"a\" \\ example")))
        let roundTrip = try query(String(edit.text.dropLast()), config: config)
        #expect(roundTrip.term == "alice \"a\" \\ example")
        let selection = NSRange(location: (text as NSString).range(of: "full").location, length: 25)
        #expect(SearchSuggestionQuery(text: text, selection: selection, configuration: config) == nil)
    }

    @Test func buildsNativeJSONBodyWithoutURLEncodingValues() throws {
        var config = SearchSuggestionConfiguration(urlTemplate: "https://catalog.example/api/tags/search", format: .objects)
        config.queryMode = .token
        config.minimumQueryLength = 1
        config.quoteTokens = true
        config.jsonRequestBody = .init(queryField: "query", namespaceField: "type", limitField: "limit", limit: 10)
        let context = try query("tag:\"full color & 색\"", config: config)
        let request = try #require(config.request(for: context))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["query"] as? String == "full color & 색")
        #expect(body["type"] as? String == "tag")
        #expect(body["limit"] as? Int == 10)
        for (text, absent) in [("full_co", "type"), ("language:", "query")] {
            let request = try #require(config.request(for: query(text, config: config)))
            let bodyData = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            #expect(body[absent] == nil)
        }
    }

    @Test func readsNativeTagNamesNamespacesAndCounts() throws {
        let data = Data(#"[{"id":1,"type":"tag","name":"full color","count":83124},{"id":2,"type":"language","name":"english","count":100},{"id":3,"type":"tag","name":"full color","count":83124},{"type":"tag","count":9}]"#.utf8)
        let entries = try SearchSuggestionService.decode(data, format: .objects,
            objectFields: .init(text: "name", namespace: "type", count: "count"))
        #expect(entries == [.init(text: "full color", namespace: "tag", count: 83124), .init(text: "english", namespace: "language", count: 100)])
    }

    @Test func postCacheSeparatesQueriesAndNamespaces() async throws {
        var config = SearchSuggestionConfiguration(urlTemplate: "https://catalog.example/native/cache", format: .objects)
        config.queryMode = .token
        config.minimumQueryLength = 1
        config.jsonRequestBody = .init(queryField: "query", namespaceField: "type")
        let transport = NativeSuggestionTestTransport()
        let service = SearchSuggestionService(configuration: config, transport: { try await transport.respond(to: $0) })
        for text in ["tag:alpha", "tag:beta", "artist:alpha", "tag:alpha"] {
            let context = try query(text, config: config)
            let entries = try await service.suggestions(for: context)
            #expect(entries.first?.text == context.term)
            #expect(entries.first?.namespace == context.namespace)
        }
        #expect(await transport.count == 3)
    }

    @Test func nativeRateLimitIsSharedAndCancelledQueriesDoNotSend() async throws {
        var config = SearchSuggestionConfiguration(urlTemplate: "https://catalog.example/rate/\(UUID().uuidString)", format: .objects)
        config.queryMode = .token
        config.minimumQueryLength = 1
        config.jsonRequestBody = .init(queryField: "query", namespaceField: "type")
        config.minimumRequestIntervalMilliseconds = 150
        let transport = NativeSuggestionTestTransport()
        let first = SearchSuggestionService(configuration: config, transport: { try await transport.respond(to: $0) })
        let second = SearchSuggestionService(configuration: config, transport: { try await transport.respond(to: $0) })
        _ = try await first.suggestions(for: query("alpha", config: config))
        let context = try query("cancelled", config: config)
        let pending = Task { try await second.suggestions(for: context) }
        try await Task.sleep(nanoseconds: 10_000_000)
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await transport.count == 1)
        _ = try await second.suggestions(for: query("beta", config: config))
        let times = await transport.times
        #expect(times.count == 2)
        #expect(times[1] - times[0] >= 0.12)
    }

    @Test @MainActor func supersededAndDismissedResultsCannotReappear() async throws {
        let gate = SuggestionGatedTransport()
        let config = configuration()
        let service = SearchSuggestionService(configuration: config, transport: { await gate.respond(to: $0) })
        let model = SearchSuggestionsViewModel(configuration: config, service: service, delay: 0)
        var requests = gate.events.makeAsyncIterator()
        model.update(text: "author:old", selection: .init(location: 10, length: 0))
        let old = try #require(await requests.next())
        model.update(text: "author:new", selection: .init(location: 10, length: 0))
        let new = try #require(await requests.next())
        await gate.complete(new, text: "new result")
        await model.waitForUpdate()
        #expect(model.suggestions.first?.text == "new result")
        await gate.complete(old, text: "old result")
        #expect(model.suggestions.first?.text == "new result")
        model.update(text: "author:last", selection: .init(location: 11, length: 0))
        let last = try #require(await requests.next())
        model.dismiss()
        await gate.complete(last, text: "late result")
        #expect(model.query == nil)
        #expect(model.suggestions.isEmpty)
    }

    @Test @MainActor func candidatesRenderAndSelectionFillsToken() async throws {
        let config = configuration()
        let transport = SuggestionTestTransport()
        let service = SearchSuggestionService(configuration: config, transport: { await transport.respond(to: $0) })
        let model = SearchSuggestionsViewModel(configuration: config, service: service, delay: 0)
        let parent = UIViewController()
        parent.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = SearchSuggestionsViewController(viewModel: model)
        controller.attach(to: parent)
        var result: String?
        controller.onSelect = { query, suggestion in result = query.applying(suggestion)?.text }
        model.update(text: "author:ali", selection: .init(location: 10, length: 0))
        await model.waitForUpdate()
        parent.view.layoutIfNeeded()
        #expect(!controller.view.isHidden)
        #expect(controller.tableView.numberOfRows(inSection: 0) == 1)
        let cell = try #require(controller.tableView(
            controller.tableView, cellForRowAt: .init(row: 0, section: 0)
        ) as? SearchSuggestionCell)
        #expect(cell.titleLabel.text == "alice (author)")
        #expect(cell.countLabel.text == "12")
        #expect(cell.titleLabel.numberOfLines == 1)
        controller.tableView(controller.tableView, didSelectRowAt: .init(row: 0, section: 0))
        #expect(result == "author:alice ")
        #expect(controller.view.isHidden)
    }

    @Test @MainActor func compactCellHighlightsMatchesAndClearsReusedMetadata() throws {
        let cell = SearchSuggestionCell(style: .default, reuseIdentifier: "test")
        cell.configure(with: .init(text: "Alpine tales of ALPS", namespace: "category", count: 1234), matching: "al")
        #expect(cell.titleLabel.text == "Alpine tales of ALPS (category)")
        let label = try #require(cell.titleLabel.attributedText)
        for index in [0, 16] {
            #expect(label.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor == .link)
        }
        #expect(cell.accessoryView == nil)
        #expect(cell.countLabel.text == 1234.formatted())
        cell.configure(with: .init(text: "History"), matching: "")
        #expect(cell.titleLabel.text == "History")
        #expect(cell.countLabel.text == nil)
        #expect(SearchSuggestionCell.rowHeight >= 44)
    }

    @Test @MainActor func sourceSearchBarIntegratesSuggestionsWithoutChangingFilters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = #"""
        {"config":{"searchSuggestions":{
          "urlTemplate":"https://catalog.example/{namespace}/{queryPath}.json",
          "format":"tuples","queryMode":"token","minimumQueryLength":1
        }}}
        """#
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("source.json"))
        let config = try #require(SearchSuggestionConfiguration.load(sourceURL: directory))
        let transport = SuggestionTestTransport()
        let service = SearchSuggestionService(configuration: config, transport: { await transport.respond(to: $0) })
        let source = AidokuRunner.Source(
            url: directory, key: "test.suggestions", name: "Example Catalog", version: 1,
            contentRating: .safe, runner: TestableSourceRunner()
        )
        let controller = NewSourceViewController(source: source, onlySearch: true, suggestionService: service)
        let navigation = UINavigationController(rootViewController: controller)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer {
            controller.viewWillDisappear(false)
            window.isHidden = true
            previousWindow?.makeKey()
        }
        window.layoutIfNeeded()
        let search = try #require(controller.navigationItem.searchController)
        search.isActive = true
        let field = search.searchBar.searchTextField
        #expect(field.becomeFirstResponder())
        let suggestions = try #require(controller.children.compactMap { $0 as? SearchSuggestionsViewController }.first)
        let results = try #require(controller.children.compactMap { $0 as? SourceSearchViewController }.first)
        let filters: [FilterValue] = [.select(id: "category", value: "history")]
        results.enabledFilters = filters
        search.searchBar.text = "language:en -author:ali"
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        controller.searchBar(search.searchBar, textDidChange: field.text ?? "")
        await suggestions.viewModel.waitForUpdate()
        window.layoutIfNeeded()
        #expect(!suggestions.view.isHidden)
        #expect(suggestions.view.bounds.height > 0)
        #expect(!search.obscuresBackgroundDuringPresentation)
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try #require(screenshot.pngData())
        Attachment.record(png, named: "search-suggestions-ui.png")
        suggestions.tableView(suggestions.tableView, didSelectRowAt: .init(row: 0, section: 0))
        #expect(search.searchBar.text == "language:en -author:alice ")
        #expect(results.searchText == search.searchBar.text)
        #expect(results.enabledFilters == filters)
        #expect(field.isFirstResponder)
        #expect(suggestions.view.isHidden)

        // A second namespace-only token must fetch its root and keep the preceding query intact.
        let names = (0..<50).map { "Catalog topic \($0 + 1)" }
        try await transport.setEntries(names, namespace: "category")
        search.searchBar.text = "language:en category:"
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        controller.searchBar(search.searchBar, textDidChange: field.text ?? "")
        await suggestions.viewModel.waitForUpdate()
        window.layoutIfNeeded()
        #expect(await transport.requestedURLs.last?.path == "/category.json")
        #expect(suggestions.tableView.numberOfRows(inSection: 0) == 10)
        #expect(suggestions.view.bounds.height > 6 * suggestions.tableView.rowHeight)
        #expect(suggestions.view.bounds.height <= controller.view.keyboardLayoutGuide.layoutFrame.minY + 1)
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            Attachment.record(try #require(image.pngData()), named: "compact-suggestions-\(style.rawValue).png")
        }
        suggestions.tableView.scrollToRow(at: .init(row: 9, section: 0), at: .bottom, animated: false)
        window.layoutIfNeeded()
        #expect(suggestions.tableView.indexPathsForVisibleRows?.contains(.init(row: 9, section: 0)) == true)
        suggestions.tableView(suggestions.tableView, didSelectRowAt: .init(row: 9, section: 0))
        #expect(search.searchBar.text == "language:en category:Catalog_topic_10 ")
        #expect(results.enabledFilters == filters)
    }
}

private actor SuggestionTestTransport {
    private(set) var requestCount = 0
    private(set) var requestedURLs: [URL] = []
    private var status = 200
    private var data = Data(#"[["alice",12,"author"]]"#.utf8)

    func setStatus(_ value: Int) { status = value }

    func setEntries(_ names: [String], namespace: String) throws {
        data = try JSONSerialization.data(withJSONObject: names.enumerated().map { index, name in
            [name, 5000 - index * 73, namespace] as [Any]
        })
    }

    func respond(to request: URLRequest) -> (Data, URLResponse) {
        requestCount += 1
        requestedURLs.append(request.url!)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

private actor SuggestionGatedTransport {
    nonisolated let events: AsyncStream<UUID>
    private let continuation: AsyncStream<UUID>.Continuation
    private var pending: [UUID: (URL, CheckedContinuation<(Data, URLResponse), Never>)] = [:]

    init() {
        (events, continuation) = AsyncStream.makeStream(of: UUID.self)
    }

    func respond(to request: URLRequest) async -> (Data, URLResponse) {
        let id = UUID()
        return await withCheckedContinuation { callback in
            pending[id] = (request.url!, callback)
            continuation.yield(id)
        }
    }

    func complete(_ id: UUID, text: String) {
        guard let (url, callback) = pending.removeValue(forKey: id) else { return }
        let data = (try? JSONSerialization.data(withJSONObject: [[text, 1, "author"]])) ?? Data()
        callback.resume(returning: (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }
}

private actor NativeSuggestionTestTransport {
    private(set) var count = 0
    private(set) var times: [TimeInterval] = []

    func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        count += 1
        times.append(ProcessInfo.processInfo.systemUptime)
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        var entry: [String: Any] = ["text": body["query"] as? String ?? ""]
        entry["namespace"] = body["type"] as? String
        return (
            try JSONSerialization.data(withJSONObject: [entry]),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
