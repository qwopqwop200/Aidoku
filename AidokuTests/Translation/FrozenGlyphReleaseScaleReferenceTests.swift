import Foundation
import JavaScriptCore
import Testing

@Suite @MainActor struct FrozenGlyphReleaseScaleReferenceTests {
    @Test func correctionComposesWithFrozenGrowthAndReadOnlyCheckpoints() throws {
        let original = LegacyReaderTranslationRenderScript.renderScript
        let corrected = try FrozenGlyphReleaseScaleReference.correcting(original)
        let untraced = try FrozenGlyphReleaseScaleReference.correcting(original, collectDiagnostics: false)
        #expect(!untraced.contains("const referenceReleasedBox=node.getBoundingClientRect();"))
        #expect(untraced.contains("referenceReleaseGeometry.width/=referenceReleaseX"))
        let both = try FrozenGrowthRollbackReference.correcting(corrected)
        let traced = try FrozenTypographyStageTrace.instrument(both, regionIDs: ["5"])
        #expect(traced.contains("__aidokuReferenceGlyphReleaseScaleTrace"))
        let strokeReset = try #require(corrected.range(of: "node.style.webkitTextStroke=strokeRGB?"))
        let measurement = try #require(corrected.range(of: "const referenceReleasedBox=node.getBoundingClientRect();"))
        #expect(strokeReset.lowerBound < measurement.lowerBound)
        #expect(traced.contains("referenceAcceptedGrowth=referenceGrowthSnapshot()"))
        let unchanged = original == LegacyReaderTranslationRenderScript.renderScript
        #expect(unchanged)
    }

    @Test(arguments: ["none", "0.9 1", "0.75 0.8", "1.2"])
    func releasePreservesThePhysicalBoxAndDoesNotApplyScaleTwice(scale: String) throws {
        let setup = #"""
        let sx=1,sy=1;
        if(scale!=='none'){const p=scale.split(' ').map(Number);sx=p[0];sy=p[1]??sx;}
        const scrollX=0,scrollY=0,fg=[4,4,4],item={id:'scaled-caption'};
        const node={style:{left:'100px',top:'200px',width:'40px',height:'60px',scale},
          getBoundingClientRect(){
            const w=parseFloat(this.style.width),h=parseFloat(this.style.height);
            return {left:parseFloat(this.style.left)+w*.25*(1-sx),top:parseFloat(this.style.top)+h*.75*(1-sy),width:w*sx,height:h*sy};
          }};
        const getComputedStyle=n=>({scale:n.style.scale,transformOrigin:'10px 45px',transform:'none',rotate:'none'});
        const root={appendChild(n){if(n!==node)throw new Error('wrong node')}};
        const box=node.getBoundingClientRect();
        """#
        func run(_ assignment: String, trace: String = "") throws -> [String: Any] {
            let context = try #require(JSContext())
            context.setObject(scale, forKeyedSubscript: "scale" as NSString)
            let value = context.evaluateScript("(()=>{" + setup + assignment + trace + #"return JSON.stringify({before:box,after:node.getBoundingClientRect(),width:parseFloat(node.style.width),height:parseFloat(node.style.height),trace:globalThis.__aidokuReferenceGlyphReleaseScaleTrace||[]});})()"#)
            let exception = context.exception?.toString()
            try #require(exception == nil, "Reference geometry failed: \(exception ?? "unknown")")
            let text = try #require(value?.toString())
            return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let historical = try run(FrozenGlyphReleaseScaleReference.originalAssignment)
        let corrected = try run(FrozenGlyphReleaseScaleReference.correctedAssignment,
            trace: FrozenGlyphReleaseScaleReference.correctedTrace)
        let before = try #require(corrected["before"] as? [String: Double])
        let after = try #require(corrected["after"] as? [String: Double])
        for key in ["left", "top", "width", "height"] {
            let beforeValue = try #require(before[key])
            let afterValue = try #require(after[key])
            #expect(abs(beforeValue - afterValue) < 1e-9)
        }
        #expect(corrected["width"] as? Double == 40 && corrected["height"] as? Double == 60)
        let traces = try #require(corrected["trace"] as? [[String: Any]])
        #expect(traces.count == (scale == "none" ? 0 : 1))
        if scale == "none" {
            let historicalData = try JSONSerialization.data(withJSONObject: historical, options: [.sortedKeys])
            let correctedData = try JSONSerialization.data(withJSONObject: corrected, options: [.sortedKeys])
            let identical = historicalData == correctedData
            #expect(identical)
        } else {
            let faulty = try #require(historical["after"] as? [String: Double])
            #expect(faulty["width"] != before["width"])
        }
    }

    @Test func ambiguousRuntimeCopyIsRejectedBeforeRendering() {
        #expect(throws: (any Error).self) { try FrozenGlyphReleaseScaleReference.correcting("") }
        let duplicated = FrozenGlyphReleaseScaleReference.originalAssignment + FrozenGlyphReleaseScaleReference.originalAssignment
        #expect(throws: (any Error).self) { try FrozenGlyphReleaseScaleReference.correcting(duplicated) }
    }
}
