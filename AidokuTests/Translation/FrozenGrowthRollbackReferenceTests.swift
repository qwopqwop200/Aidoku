import Foundation
import JavaScriptCore
import Testing

@Suite
@MainActor
struct FrozenGrowthRollbackReferenceTests {
    @Test func correctedRuntimeCopyComposesWithActualFrozenCheckpoints() throws {
        let original = LegacyReaderTranslationRenderScript.renderScript
        let corrected = try FrozenGrowthRollbackReference.correcting(original)
        let traced = try FrozenTypographyStageTrace.instrument(corrected, regionIDs: ["5"])
        #expect(traced.contains("referenceAcceptedGrowth=referenceGrowthSnapshot()"))
        #expect(traced.contains("__aidokuReferenceGrowthRollbackTrace"))
        let originalUnchanged = original == LegacyReaderTranslationRenderScript.renderScript
        #expect(originalUnchanged)
    }

    @Test(arguments: ["accepted-then-unsupported", "unsupported-without-acceptance", "ordinary-success", "unrelated-error"])
    func repairChangesOnlyUnsupportedGrowthAndRestoresCompleteState(_ scenario: String) throws {
        let script = Self.fixtureScript
        func run(_ source: String) throws -> [String: Any] {
            let context = try #require(JSContext())
            context.setObject(scenario, forKeyedSubscript: "scenario" as NSString)
            let value = context.evaluateScript(source)
            let exception = context.exception?.toString()
            try #require(exception == nil, "Synthetic reference failed: \(exception ?? "unknown")")
            let json = try #require(value?.toString())
            let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8))
            return try #require(decoded as? [String: Any])
        }
        let original = try run(script)
        let corrected = try run(FrozenGrowthRollbackReference.correcting(script))
        let traces = try #require(corrected["trace"] as? [[String: Any]])
        if scenario == "accepted-then-unsupported" {
            #expect(original["font"] as? String == "16.25px")
            #expect(corrected["font"] as? String == "12.25px" && corrected["result"] as? Double == 12.25)
            #expect(corrected["coordinates"] as? [Double] == [20, 30, 40, 50])
            #expect(corrected["children"] as? [String] == ["approved first", "approved second"])
            let dataset = try #require(corrected["dataset"] as? [String: String])
            #expect(dataset == ["baseline": "kept", "accepted": "12.25", "balloonGrowthBase": "12.25"])
            #expect(traces.count == 1 && traces.first?["hadAcceptedState"] as? Bool == true)
        } else if scenario == "unsupported-without-acceptance" {
            #expect(corrected["font"] as? String == "10.5px")
            #expect(corrected["coordinates"] as? [Double] == [1, 2, 3, 4])
            #expect(corrected["children"] as? [String] == ["original"])
            let dataset = try #require(corrected["dataset"] as? [String: String])
            #expect(dataset == ["baseline": "kept"])
            #expect(corrected["result"] is NSNull)
            #expect(traces.count == 1 && traces.first?["hadAcceptedState"] as? Bool == false)
        } else {
            let originalJSON = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
            let correctedJSON = try JSONSerialization.data(withJSONObject: corrected, options: [.sortedKeys])
            let unchanged = originalJSON == correctedJSON
            #expect(unchanged, "Ordinary success and unrelated errors must retain the historical behavior")
            #expect(traces.isEmpty)
        }
    }

    private static let fixtureScript = #"""
    (()=>{
      const child=text=>({textContent:text,cloneNode(){return child(this.textContent)}});
      let css={fontSize:'10.5px',color:'blue'};
      const style=new Proxy({}, {get:(_,k)=>k==='cssText'?JSON.stringify(css):css[k],
        set:(_,k,v)=>{if(k==='cssText')css=JSON.parse(v);else css[k]=v;return true;}});
      const node={style,dataset:{baseline:'kept'},childNodes:[child('original')],
        replaceChildren(...items){this.childNodes=items},
        get textContent(){return this.childNodes.map(c=>c.textContent).join('')}};
      let x=1,y=2,width=3,height=4;
      const initialCSS=style.cssText,restoreGrowth=()=>{x=1;y=2;width=3;height=4;style.cssText=initialCSS;node.replaceChildren(child('original'));};
      const item={id:'5'},unsupportedSurfaceGrowth=Symbol('unsupportedSurfaceGrowth');
      const entry={growBalloon: (cap=Infinity, extraBreaks=1, styleGlyph=0, condensedOnly=false) => {
        let accepted=null;
        try {
          if(scenario!=='unsupported-without-acceptance'){
            x=20;y=30;width=40;height=50;style.fontSize='12.25px';node.dataset.accepted='12.25';
            node.replaceChildren(child('approved first'),child('approved second'));
            const size=12.25;accepted=size;node.dataset.balloonGrowthBase=String(size);
            const kept={size,x,y,width,height,style:node.style.cssText,children:Array.from(node.childNodes).map(n=>n.cloneNode(true)),
              data:Object.fromEntries(['balloonGrowthWidth','displayGrowth','balloonGrowthWide'].map(k=>[k,node.dataset[k]]))};
          }
          if(scenario!=='ordinary-success'){
            x=100;y=101;width=102;height=103;style.fontSize='16.25px';node.dataset.leaked='trial';
            node.replaceChildren(child('rejected trial'));
            if(scenario==='unrelated-error')throw new Error('unrelated failure');
            throw unsupportedSurfaceGrowth;
          }
          return accepted;
        }catch(error){
          if(error===unsupportedSurfaceGrowth)return null;
          throw error;
        }finally{if(accepted===null)restoreGrowth();}
      },
      // A caption set in place on its restoration can inherit the narrow
      sentinel:true};
      let result=null,error=null;
      try{result=entry.growBalloon();}catch(e){error=e.message;}
      return JSON.stringify({result,error,font:style.fontSize,coordinates:[x,y,width,height],
        dataset:{...node.dataset},children:node.childNodes.map(c=>c.textContent),
        trace:globalThis.__aidokuReferenceGrowthRollbackTrace||[]});
    })()
    """#
}
