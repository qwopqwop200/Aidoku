import Testing
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct DictionaryPopupSecurityTests {
    @Test func structuredGlossaryCannotExecuteScriptAndPreservesNormalMarkup() async throws {
        let url = try #require(Bundle.main.url(forResource: "popup", withExtension: "js"))
        let current = try String(contentsOf: url, encoding: .utf8)
        // Recreate the pre-fix renderer by removing only the added guard. Both paths
        // execute the actual production script in WebKit, not a DOM mock.
        let guardCode = """
            // Dictionary glossary data must not execute code in the native bridge's page.
            if (typeof tagName === 'string' && tagName.toLowerCase() === 'script') {
                return;
            }
        """
        #expect(current.components(separatedBy: guardCode).count == 2)
        let baseline = current.replacingOccurrences(of: guardCode, with: "")
        var normalDOM: [String] = []
        for (script, isBaseline) in [(baseline, true), (current, false)] {
            let web = WKWebView()
            web.loadHTMLString("<html><body><div id='test'></div></body></html>", baseURL: nil)
            for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!web.isLoading)
            // The production script ends in a function assignment. Preserve its
            // page-global declarations while returning a WebKit-bridgeable value.
            _ = try await web.evaluateJavaScript(script + "\n;null;")
            let result = try await web.callAsyncJavaScript("""
                const target = document.getElementById('test');
                for (const tag of ['script', 'ScRiPt']) {
                    renderStructuredContent(target, {tag, content: 'window.__auditMarker = 71;'});
                }
                const executed = window.__auditMarker === 71;
                target.replaceChildren();
                renderStructuredContent(target, {type:'structured-content', content:[
                    {tag:'ruby',content:[{tag:'span',content:'日本語'},{tag:'rt',content:'にほんご'}]},
                    {tag:'table',content:{tag:'tr',content:{tag:'td',colSpan:2,content:'definition'}}},
                    {tag:'span',lang:'ja',title:'title',data:{testValue:'one'},style:{fontWeight:'bold'},content:'entry'},
                    {tag:'a',href:'https://example.invalid/definition',content:'reference'}
                ]});
                return {executed, dom:target.innerHTML};
                """, arguments: [:], in: nil, contentWorld: .page)
            let data = try #require(result as? [String: Any])
            #expect((data["executed"] as? Bool) == isBaseline)
            normalDOM.append(try #require(data["dom"] as? String))
        }
        #expect(normalDOM.count == 2 && normalDOM[0] == normalDOM[1])
    }
}
