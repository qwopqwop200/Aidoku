import Testing
import WebKit
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct DictionaryPopupNameRegressionTests {
    @Test func prototypeDictionaryNamesRenderAndNormalDOMIsPreserved() async throws {
        let url = try #require(Bundle.main.url(forResource: "popup", withExtension: "js"))
        let production = try String(contentsOf: url, encoding: .utf8)
        let old = "const grouped = {};"
        let fixed = "const grouped = Object.create(null);"
        // Both variants use the complete production script. This remains useful
        // before and after integration; only the one grouping declaration differs.
        let baseline = production.replacingOccurrences(of: fixed, with: old)
        let candidate = production.replacingOccurrences(of: old, with: fixed)
        #expect(baseline.components(separatedBy: old).count == 2)
        #expect(candidate.components(separatedBy: fixed).count == 2)
        var ordinaryDOM: [String] = []
        for (script, isBaseline) in [(baseline, true), (candidate, false)] {
            for name in ["Ordinary Dictionary", "constructor", "__proto__", "toString"] {
                let bridge = PopupNameBridge()
                let config = WKWebViewConfiguration()
                config.userContentController.add(bridge, name: "buttonRects")
                let web = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 600), configuration: config)
                let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
                let window = UIWindow(windowScene: scene)
                window.frame = web.frame
                let controller = UIViewController()
                window.rootViewController = controller
                controller.view.addSubview(web)
                window.makeKeyAndVisible()
                defer {
                    web.removeFromSuperview()
                    window.isHidden = true
                    window.rootViewController = nil
                    previousKeyWindow?.makeKey()
                }
                web.loadHTMLString("<html><body><div id='entries-container'></div></body></html>", baseURL: nil)
                for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
                #expect(!web.isLoading)
                _ = try await web.evaluateJavaScript(script + "\n;null;")
                let raw = try await web.callAsyncJavaScript("""
                    window.cardFormatCount = 0;
                    window.useAnkiConnect = true;
                    window.isAnkiConnectReachable = false;
                    window.dictionaryStyles = Object.create(null);
                    window.lookupEntries = [{expression:'日本',reading:'',frequencies:[],pitches:[],
                        glossaries:[{dictionary:dictionaryName,content:'definition',definitionTags:'',termTags:''}]}];
                    window.entryCount = 1;
                    try {
                        await window.renderPopup();
                        const target = document.getElementById('entries-container');
                        return {ok:true,html:target.innerHTML,text:target.textContent,
                            count:target.querySelectorAll('.glossary-group').length};
                    } catch(error) { return {ok:false,error:String(error)}; }
                    """, arguments: ["dictionaryName": name], in: nil, contentWorld: .page)
                let result = try #require(raw as? [String: Any])
                let expectedSuccess = !isBaseline || name == "Ordinary Dictionary"
                #expect((result["ok"] as? Bool) == expectedSuccess)
                if expectedSuccess {
                    #expect((result["count"] as? Int) == 1)
                    #expect((result["text"] as? String)?.contains("definition") == true)
                } else {
                    #expect((result["error"] as? String)?.contains("push") == true)
                }
                if name == "Ordinary Dictionary" {
                    ordinaryDOM.append(try #require(result["html"] as? String))
                }
                config.userContentController.removeScriptMessageHandler(forName: "buttonRects")
            }
        }
        #expect(ordinaryDOM.count == 2 && ordinaryDOM[0] == ordinaryDOM[1])
    }
}

@MainActor
private final class PopupNameBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}
