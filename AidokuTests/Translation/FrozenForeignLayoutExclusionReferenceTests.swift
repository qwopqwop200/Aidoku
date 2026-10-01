import Foundation
import JavaScriptCore
import Testing

@Suite @MainActor struct FrozenForeignLayoutExclusionReferenceTests {
    @Test func correctionComposesWithAssembledFrozenRendererAndOtherExplicitRepairs() throws {
        let original = LegacyReaderTranslationRenderScript.renderScript
        let growth = try FrozenGrowthRollbackReference.correcting(original)
        let release = try FrozenGlyphReleaseScaleReference.correcting(growth)
        let corrected = try FrozenForeignLayoutExclusionReference.correcting(release)
        let traced = try FrozenTypographyStageTrace.instrument(corrected, regionIDs: ["5"])
        #expect(traced.contains("__aidokuReferenceForeignLayoutTrace"))
        let frozenUnchanged = original == LegacyReaderTranslationRenderScript.renderScript
        #expect(frozenUnchanged)
    }

    @Test(arguments: ["foreign-ink", "blank-paper", "overlapping-bounds", "already-blocked", "no-overlap",
                      "other-method", "detached", "incomplete-proof", "foreign-paint", "invalid-rectangle"])
    func originalForeignOwnershipRestrictsOnlyLayoutAndNeverPaint(_ scenario: String) throws {
        let context = try #require(JSContext())
        context.setObject(scenario, forKeyedSubscript: "scenario" as NSString)
        let source = Self.fixturePrefix + FrozenForeignLayoutExclusionReference.correction + Self.fixtureSuffix
        let value = context.evaluateScript(source)
        let exception = context.exception?.toString()
        try #require(exception == nil, "Reference fixture failed: \(exception ?? "unknown")")
        let json = try #require(value?.toString())
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let result = try #require(object as? [String: Any])
        #expect(result["rgbaUnchanged"] as? Bool == true)
        #expect(result["sourceUnchanged"] as? Bool == true)
        #expect(result["proofUnchanged"] as? Bool == true)
        let records = try #require(result["records"] as? [[String: Any]])
        if scenario == "foreign-paint" || scenario == "invalid-rectangle" {
            #expect(result["error"] as? String != nil)
            #expect(records.isEmpty)
            #expect(result["safeUnchanged"] as? Bool == true)
        } else if ["foreign-ink", "blank-paper", "overlapping-bounds"].contains(scenario) {
            #expect(result["error"] is NSNull)
            #expect(result["allForeignBlocked"] as? Bool == true)
            #expect(result["outsideSafeUnchanged"] as? Bool == true)
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record["excludedPixels"] as? Int == 12)
            #expect(record["addedUnsafePixels"] as? Int == 12)
            #expect(record["foreignInkPixels"] as? Int == (scenario == "blank-paper" ? 0 : 1))
        } else {
            #expect(result["error"] is NSNull)
            #expect(records.isEmpty)
            #expect(result["safeUnchanged"] as? Bool == true)
        }
    }

    private static let fixturePrefix = #"""
    (()=>{
      const w=8,h=8,iw=8,ih=8,x=0,y=0,sx=1,sy=1,item={id:'foreign-owner'},palette={background:[253,253,253]};
      const detached=scenario==='detached';
      const original=new Uint8ClampedArray(w*h*4);
      for(let i=0;i<w*h;i++)original.set([253,253,253,255],i*4);
      if(scenario!=='blank-paper')original.set([103,214,190,255],(2*w+5)*4);
      const restored={method:scenario==='other-method'?'local-component-paper':'chromatic-balloon-glyphs',
        rgba:new Uint8ClampedArray(w*h*4),layoutSafe:new Uint8Array(w*h).fill(1),
        sourceErasureVerified:scenario!=='incomplete-proof',sourceGlyphsVerified:true,
        erased:1,surfaceQuality:{safe:true,reason:'chromatic-local-donors'},sourceRemainingInk:0};
      restored.rgba.set([253,253,253,255],(w+1)*4);
      if(scenario==='foreign-paint')restored.rgba.set([253,253,253,255],(2*w+5)*4);
      const rubyExclusions=scenario==='no-overlap'?[[2,2,.1,.1]]:[[.5,.125,.375,.5]];
      if(scenario==='overlapping-bounds')rubyExclusions.push([.5,.125,.375,.5]);
      if(scenario==='invalid-rectangle')rubyExclusions[0][0]=NaN;
      if(scenario==='already-blocked')for(let yy=1;yy<5;yy++)for(let xx=4;xx<7;xx++)restored.layoutSafe[yy*w+xx]=0;
      const safeBefore=restored.layoutSafe.slice(),rgbaBefore=restored.rgba.slice(),sourceBefore=original.slice();
      const proof=()=>JSON.stringify(Object.fromEntries(Object.entries(restored).filter(([k])=>k!=='rgba'&&k!=='layoutSafe')));
      const proofBefore=proof();let error=null;
      try{
    """#
    private static let fixtureSuffix = #"""
      }catch(e){error=e.message;}
      let allForeignBlocked=true,outsideSafeUnchanged=true;
      for(let yy=0;yy<h;yy++)for(let xx=0;xx<w;xx++){
        const i=yy*w+xx,foreign=xx>=4&&xx<7&&yy>=1&&yy<5;
        if(foreign&&restored.layoutSafe[i]!==0)allForeignBlocked=false;
        if(!foreign&&restored.layoutSafe[i]!==safeBefore[i])outsideSafeUnchanged=false;
      }
      return JSON.stringify({error,allForeignBlocked,outsideSafeUnchanged,
        safeUnchanged:restored.layoutSafe.every((v,i)=>v===safeBefore[i]),
        rgbaUnchanged:restored.rgba.every((v,i)=>v===rgbaBefore[i]),
        sourceUnchanged:original.every((v,i)=>v===sourceBefore[i]),proofUnchanged:proof()===proofBefore,
        records:globalThis.__aidokuReferenceForeignLayoutTrace||[]});
    })()
    """#
}
