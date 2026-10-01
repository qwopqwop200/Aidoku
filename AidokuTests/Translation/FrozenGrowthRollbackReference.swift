import Foundation

/// Explicit test-only repair for the frozen renderer's accepted-growth rollback
/// defect. The frozen source stays immutable, and ordinary oracle callers opt out.
enum FrozenGrowthRollbackReference {
    static let contract = "frozen-web-with-accepted-growth-rollback-v1"
    enum TransformError: Error { case missingOrAmbiguousMarker(String) }

    static func correcting(_ script: String) throws -> String {
        let start = "growBalloon: (cap=Infinity, extraBreaks=1, styleGlyph=0, condensedOnly=false) => {"
        let end = "// A caption set in place on its restoration can inherit the narrow"
        guard script.components(separatedBy: start).count == 2,
              script.components(separatedBy: end).count == 2,
              let begin = script.range(of: start), let finish = script.range(of: end), begin.upperBound < finish.lowerBound else {
            throw TransformError.missingOrAmbiguousMarker("growBalloon body")
        }
        var body = String(script[begin.lowerBound..<finish.lowerBound])
        let stateMarker = "let accepted=null;"
        let acceptMarker = "accepted=size;"
        let failureMarker = "if(error===unsupportedSurfaceGrowth)return null;"
        let keptMarker = "data:Object.fromEntries(['balloonGrowthWidth','displayGrowth','balloonGrowthWide'].map(k=>[k,node.dataset[k]]))};"
        for marker in [stateMarker, acceptMarker, failureMarker, keptMarker] {
            guard body.components(separatedBy: marker).count == 2 else {
                throw TransformError.missingOrAmbiguousMarker(marker)
            }
        }
        let state = """
        const referenceGrowthSnapshot=()=>({x,y,width,height,style:node.style.cssText,
          children:Array.from(node.childNodes).map(n=>n.cloneNode(true)),data:{...node.dataset},
          font:parseFloat(node.style.fontSize)});
        const referenceGrowthRestore=s=>{({x,y,width,height}=s);node.style.cssText=s.style;
          node.replaceChildren(...s.children.map(n=>n.cloneNode(true)));
          for(const key of Object.keys(node.dataset))delete node.dataset[key];
          Object.assign(node.dataset,s.data);};
        const referenceOriginalGrowth=referenceGrowthSnapshot();
        let referenceAcceptedGrowth=null;
        let accepted=null;
        """
        let failure = """
        if(error===unsupportedSurfaceGrowth){
          if(accepted!==null&&!referenceAcceptedGrowth)
            throw new Error('Missing accepted growth rollback state');
          const failedFont=parseFloat(node.style.fontSize),saved=referenceAcceptedGrowth||referenceOriginalGrowth;
          referenceGrowthRestore(saved);
          accepted=referenceAcceptedGrowth?saved.font:null;
          (globalThis.__aidokuReferenceGrowthRollbackTrace ||= []).push({id:String(item.id),
            failedFont,restoredFont:saved.font,hadAcceptedState:Boolean(referenceAcceptedGrowth),
            restoredCSS:node.style.cssText,restoredData:{...node.dataset},
            restoredChildren:node.textContent,returnedFont:accepted});
          return accepted;
        }
        if(error===unsupportedSurfaceGrowth)return null;
        """
        body = body.replacingOccurrences(of: stateMarker, with: state)
        body = body.replacingOccurrences(of: acceptMarker, with: acceptMarker + "referenceAcceptedGrowth=referenceGrowthSnapshot();")
        // The crop-bound candidate records its base marker immediately after
        // acceptance; capture again once this complete kept state exists.
        body = body.replacingOccurrences(of: keptMarker, with: keptMarker + "referenceAcceptedGrowth=referenceGrowthSnapshot();")
        // Keep the historical marker below the guarded return so read-only
        // diagnostic transforms still compose without touching their source.
        body = body.replacingOccurrences(of: failureMarker, with: failure)
        return String(script[..<begin.lowerBound]) + body + String(script[finish.lowerBound...])
    }
}
