
    const box=r=>({x:r.left,y:r.top,width:r.width,height:r.height});
    const properties=['left','top','width','height','fontSize','lineHeight','fontFamily','fontWeight',
      'paddingTop','paddingRight','paddingBottom','paddingLeft','letterSpacing','textAlign',
      'color','backgroundColor','backgroundImage','webkitTextStrokeWidth','webkitTextStrokeColor',
      'paintOrder','transform','transformOrigin','scale','rotate','translate','clipPath',
      'overflow','overflowX','overflowY','boxSizing','alignItems','justifyContent',
      'opacity','visibility','display','borderRadius','zIndex'];
    const parentProperties=['fontStyle','writingMode','whiteSpace','wordBreak','textWrap','overflowWrap'];
    const layoutMetrics=element=>({offsetLeft:element.offsetLeft,offsetTop:element.offsetTop,
      offsetWidth:element.offsetWidth,offsetHeight:element.offsetHeight,
      scrollWidth:element.scrollWidth,scrollHeight:element.scrollHeight,
      clientWidth:element.clientWidth,clientHeight:element.clientHeight,
      clientLeft:element.clientLeft,clientTop:element.clientTop});
    const nodes=Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay]'));
    return JSON.stringify({viewport:{width:innerWidth,height:innerHeight},
      layers:nodes.map(node=>{
        const computed=getComputedStyle(node),range=document.createRange();range.selectNodeContents(node);
        const style=Object.fromEntries([...properties,...parentProperties].map(key=>[key,computed[key]||'']));
        const inline=Object.fromEntries(properties.map(key=>[key,node.style[key]||'']));
        const context=document.createElement('canvas').getContext('2d');
        context.font=`${computed.fontStyle} ${computed.fontWeight} ${computed.fontSize} ${computed.fontFamily}`;
        context.letterSpacing=computed.letterSpacing;
        const metrics=text=>{
          const measured=context.measureText(text);
          return Object.fromEntries(['width','actualBoundingBoxLeft','actualBoundingBoxRight',
            'actualBoundingBoxAscent','actualBoundingBoxDescent','fontBoundingBoxAscent',
            'fontBoundingBoxDescent','emHeightAscent','emHeightDescent','alphabeticBaseline']
            .map(key=>[key,Number.isFinite(measured[key])?measured[key]:null]));
        };
        const scalarRects=[],walker=document.createTreeWalker(node,NodeFilter.SHOW_TEXT);
        let textNode,utf16Offset=0;
        while((textNode=walker.nextNode())){
          let offset=0;
          for(const scalar of Array.from(textNode.data)){
            if(!/^\s$/.test(scalar)&&scalarRects.length<32768){
              const scalarRange=document.createRange();
              scalarRange.setStart(textNode,offset);scalarRange.setEnd(textNode,offset+scalar.length);
              const candidates=Array.from(scalarRange.getClientRects()).filter(r=>r.width>0&&r.height>0);
              if(candidates.length)scalarRects.push({scalar,utf16Offset:utf16Offset+offset,rect:box(candidates[candidates.length-1])});
            }
            offset+=scalar.length;
          }
          utf16Offset+=textNode.data.length;
        }
        return {kind:node.dataset.aidokuImageOcrOverlay,id:node.dataset.aidokuRegion||null,
          parentKind:node.parentElement?.dataset?.aidokuImageOcrOverlay||null,
          ...layoutMetrics(node),childElementCount:node.childElementCount,
          layoutChildren:Array.from(node.children).map(child=>{
            const childStyle=getComputedStyle(child);
            return {tag:child.tagName,kind:child.dataset?.aidokuImageOcrOverlay||null,
              text:child.textContent,rect:box(child.getBoundingClientRect()),...layoutMetrics(child),
              style:Object.fromEntries(properties.map(key=>[key,childStyle[key]||'']))};
          }),
          transformOrigin:computed.transformOrigin,
          text:node.textContent,rect:box(node.getBoundingClientRect()),ink:box(range.getBoundingClientRect()),
          lineRects:Array.from(range.getClientRects()).map(box),style,inline,dataset:{...node.dataset},
          canvasFont:context.font,textMetrics:metrics(node.textContent||''),koreanMetrics:metrics('안녕'),scalarRects};
      })});
