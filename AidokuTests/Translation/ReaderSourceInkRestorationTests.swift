import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderSourceInkRestorationTests {
    private nonisolated static var folder: URL { URL.documentsDirectory.appendingPathComponent("InkRestoration") }

    @Test func haloIsBoundedAndProtectsDrawingAndDifferentColors() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html><body></body></html>", baseURL: nil)
        while web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        let value = try await web.callAsyncJavaScript(BrowserSourceInkCleanup.script + """
        const w=30,h=30,n=w*h,rgba=new Uint8ClampedArray(n*4),mask=new Uint8Array(n),protect=new Uint8Array(n);
        for(let i=0;i<n;i++)rgba.set([195,195,199,255],i*4);
        const pixel=(x,y,color)=>rgba.set([...color,255],(y*w+x)*4);
        mask[10*w+10]=1;
        pixel(12,10,[225,225,228]); // Detached outline fringe, two pixels away.
        pixel(13,10,[225,225,228]); // Must not grow from the repaired fringe.
        pixel(9,9,[200,40,40]); // Different-color artwork near the same glyph.
        pixel(10,8,[220,220,223]);
        protect[7*w+10]=1; // Preserve the one-pixel moat around protected art.
        aidokuRecoverInkHalo(rgba,w,h,mask,[10,10,14],[195,195,199],[251,251,253],protect);
        return {fringe:mask[10*w+12],distant:mask[10*w+13],color:mask[9*w+9],
          moat:mask[8*w+10],protected:mask[7*w+10],seed:mask[10*w+10],border:mask[0]};
        """, arguments: [:], in: nil, contentWorld: .page)
        let result = try #require(value as? [String: Int])
        #expect(result["fringe"] == 1)
        #expect(result["seed"] == 1)
        for key in ["distant", "color", "moat", "protected", "border"] { #expect(result[key] == 0) }
    }

    // Opt-in local corpus replay: no OCR/provider requests or credentials. The
    // same native layout, image and WKWebView render both cleanup implementations.
}
