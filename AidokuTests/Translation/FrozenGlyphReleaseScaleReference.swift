import Foundation

/// A separate test-only oracle contract. Late glyph release must convert the
/// transformed border box back into CSS layout coordinates before reparenting.
/// Frozen sources and default historical renders remain unchanged.
enum FrozenGlyphReleaseScaleReference {
    static let contract = "frozen-web-with-independent-scale-release-v1"
    enum TransformError: Error { case missingOrAmbiguousMarker }

    static let originalAssignment = #"""
        root.appendChild(node);
        Object.assign(node.style,{position:'absolute',left:`${box.left+scrollX}px`,top:`${box.top+scrollY}px`,
          width:`${box.width}px`,height:`${box.height}px`,zIndex:'3',color:`rgb(${fg.join(',')})`,
          background:'transparent',textShadow:'none',paintOrder:'stroke fill',overflow:'visible'});
    """#

    static let correctedAssignment = #"""
        const referenceReleaseStyle=getComputedStyle(node);
        const referenceReleaseScale=String(referenceReleaseStyle.scale||'none').trim().split(/\s+/);
        const referenceReleaseX=referenceReleaseScale[0]==='none'?1:Number(referenceReleaseScale[0]);
        const referenceReleaseY=referenceReleaseScale.length>1?Number(referenceReleaseScale[1]):referenceReleaseX;
        const referenceReleaseOrigin=String(referenceReleaseStyle.transformOrigin).split(/\s+/).map(parseFloat);
        const referenceReleaseGeometry={left:box.left,top:box.top,width:box.width,height:box.height};
        const referenceReleaseScaled=referenceReleaseX!==1||referenceReleaseY!==1;
        if(referenceReleaseScaled){
          if(!(referenceReleaseX>0&&referenceReleaseY>0)||
              ![referenceReleaseX,referenceReleaseY,...referenceReleaseOrigin.slice(0,2)].every(Number.isFinite)||
              referenceReleaseOrigin.length<2||
              referenceReleaseStyle.transform&&referenceReleaseStyle.transform!=='none'||
              referenceReleaseStyle.rotate&&referenceReleaseStyle.rotate!=='none'||
              referenceReleaseStyle.translate&&referenceReleaseStyle.translate!=='none')
            throw new Error('Unsupported transformed glyph release in corrected reference');
          referenceReleaseGeometry.left-=referenceReleaseOrigin[0]*(1-referenceReleaseX);
          referenceReleaseGeometry.top-=referenceReleaseOrigin[1]*(1-referenceReleaseY);
          referenceReleaseGeometry.width/=referenceReleaseX;
          referenceReleaseGeometry.height/=referenceReleaseY;
        }
        root.appendChild(node);
        Object.assign(node.style,{position:'absolute',left:`${referenceReleaseGeometry.left+scrollX}px`,top:`${referenceReleaseGeometry.top+scrollY}px`,
          width:`${referenceReleaseGeometry.width}px`,height:`${referenceReleaseGeometry.height}px`,zIndex:'3',color:`rgb(${fg.join(',')})`,
          background:'transparent',textShadow:'none',paintOrder:'stroke fill',overflow:'visible'});

    """#

    // Observe only the completed release. An intermediate layout flush between
    // paintOrder and the original stroke reset can expose stale WebKit paint.
    static let correctedTrace = #"""
        if(referenceReleaseScaled){
          const referenceReleasedBox=node.getBoundingClientRect();
          (globalThis.__aidokuReferenceGlyphReleaseScaleTrace ||= []).push({id:String(item.id),
            scale:[referenceReleaseX,referenceReleaseY],origin:referenceReleaseOrigin.slice(0,2),
            before:[box.left,box.top,box.width,box.height],logical:{...referenceReleaseGeometry},
            after:[referenceReleasedBox.left,referenceReleasedBox.top,referenceReleasedBox.width,referenceReleasedBox.height],css:node.style.cssText});
        }
    """#
    static let completionMarker = """
        released.push(id);
      }
      root.dataset.glyphPlatesReleased=JSON.stringify(released);
    """

    static func correcting(_ script: String, collectDiagnostics: Bool = true) throws -> String {
        guard script.components(separatedBy: originalAssignment).count == 2,
              script.components(separatedBy: completionMarker).count == 2 else {
            throw TransformError.missingOrAmbiguousMarker
        }
        return script.replacingOccurrences(of: originalAssignment, with: correctedAssignment)
            .replacingOccurrences(of: completionMarker, with: (collectDiagnostics ? correctedTrace + "\n" : "") + completionMarker)
    }
}
