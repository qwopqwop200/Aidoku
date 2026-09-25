import Testing
import UIKit
import WebKit

@MainActor @Suite(.serialized)
struct RegressionWebFixtureTests {
    @Test func reuseResetsDocumentAndNativeAppearance() async throws {
        let first = RegressionWebFixture()
        let web = first.acquire(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        let originalInset = web.scrollView.contentInsetAdjustmentBehavior
        let originalOpaque = web.isOpaque
        let originalBackground = web.backgroundColor
        let originalStyle = web.overrideUserInterfaceStyle
        do {
            try await RegressionWebFixture.load("<div id='old-document'></div>", in: web)
            _ = try await web.evaluateJavaScript("window.oldFixture = true; Object.prototype.oldFixture = true")
            web.scrollView.contentInsetAdjustmentBehavior = .never
            web.isOpaque = !originalOpaque
            web.backgroundColor = .red
            web.overrideUserInterfaceStyle = .dark
        } catch {
            first.release(web)
            throw error
        }
        first.release(web)
        let second = RegressionWebFixture()
        let reused = second.acquire(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        defer { second.release(reused) }
        #expect(reused === web)
        #expect(reused.frame.size == CGSize(width: 390, height: 780))
        #expect(reused.scrollView.contentInsetAdjustmentBehavior == originalInset)
        #expect(reused.isOpaque == originalOpaque)
        #expect(reused.backgroundColor == originalBackground)
        #expect(reused.overrideUserInterfaceStyle == originalStyle)
        try await RegressionWebFixture.load("<div id='new-document'></div>", in: reused)
        let clean = try await reused.evaluateJavaScript("""
        typeof window.oldFixture === 'undefined' &&
        typeof Object.prototype.oldFixture === 'undefined' &&
        !document.getElementById('old-document') && !!document.getElementById('new-document')
        """) as? Bool
        #expect(clean == true)
    }

    @Test func overlappingCheckoutsNeverShareADocument() async throws {
        let first = RegressionWebFixture()
        let second = RegressionWebFixture()
        let a = first.acquire()
        let b = second.acquire()
        defer { first.release(a); second.release(b) }
        #expect(a !== b)
        try await RegressionWebFixture.load("<div id='a'></div>", in: a)
        try await RegressionWebFixture.load("<div id='b'></div>", in: b)
        #expect(try await a.evaluateJavaScript("!!document.getElementById('a') && !document.getElementById('b')") as? Bool == true)
        #expect(try await b.evaluateJavaScript("!!document.getElementById('b') && !document.getElementById('a')") as? Bool == true)
    }

    @Test func resizedAttachedViewportIsStableWhenLoadReturns() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let fixture = RegressionWebFixture()
        for height in [900.0, 260.0, 780.0, 260.0] {
            let web = fixture.acquire(frame: CGRect(x: 0, y: 0, width: 430, height: height))
            defer { fixture.release(web) }
            web.scrollView.contentInsetAdjustmentBehavior = .never
            window.rootViewController?.view.addSubview(web)
            try await RegressionWebFixture.load("""
            <meta name='viewport' content='width=device-width,initial-scale=1'>
            <style>html,body{margin:0;height:100%}div{position:absolute;top:20px;height:210px;
            display:flex;align-items:center;font:31.5px sans-serif}</style><div>viewport</div>
            """, in: web)
            let measure = """
            (()=>{const r=document.createRange();r.selectNodeContents(document.querySelector('div'));
            const b=r.getBoundingClientRect();return [innerWidth,innerHeight,scrollY,
            visualViewport.height,visualViewport.offsetTop,b.x,b.y,b.width,b.height]})()
            """
            let first = try #require(try await web.evaluateJavaScript(measure) as? [Double])
            _ = try await web.callAsyncJavaScript(
                "await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))",
                arguments: [:], in: nil, contentWorld: .page)
            let next = try #require(try await web.evaluateJavaScript(measure) as? [Double])
            #expect(first == next)
            #expect(first[0] == 430)
            #expect(first[1] == height)
        }
    }

}
