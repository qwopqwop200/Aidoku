const fs=require('fs'),vm=require('vm'),path=require('path');
const source=fs.readFileSync(process.argv[2],'utf8');
let code=source.slice(source.indexOf('    const coverSource='),source.indexOf('    // A widened display card',source.indexOf('    const coverSource=')));
code=code.replace('paintContext.putImageData(image,0,0);','paintContext.putImageData(image,0,0); node.proof={rgba:Array.from(data),cover:Array.from(cover),letters:Array.from(letters),art:Array.from(art),width:w,height:h,sourceCrop:[x0,y0,sw,sh]};');
const input=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const outputs=input.map(f=>{
 let rect=f.plate.rect,owner={dataset:{aidokuImageOcrOverlay:'source-readability-panel',aidokuRegion:'one'},style:{},isConnected:true,offsetWidth:f.plate.size[0],offsetHeight:f.plate.size[1],offsetLeft:f.plate.origin[0],offsetTop:f.plate.origin[1],offsetParent:null,getBoundingClientRect:()=>({left:rect[0],top:rect[1],right:rect[0]+rect[2],bottom:rect[1]+rect[3]}),querySelectorAll:()=>[node]};
 const node={dataset:{aidokuRegion:'one',sourceBackgroundColor:f.mode||'readability-panel',outlinedLettering:JSON.stringify(f.record),sourceSampledTextRGB:f.sampled?.join(',')},textContent:f.text||'ABC',style:{fontSize:'20px'},parentElement:owner};
 if(f.displayGroup)node.dataset.displayGroup='true';if(f.frameLines)owner.dataset.sourceFrameLines='true';
 const root={dataset:{},querySelectorAll:q=>q.includes('"item"')?[node]:q.includes('source-readability-panel')?[owner]:[],insertBefore:()=>{}};owner.parentElement=root;
 const style={backgroundColor:'rgb(200, 180, 150)',backgroundImage:'none',display:'block',visibility:'visible',boxShadow:'none',borderTopWidth:'0px',borderLeftWidth:'0px',transformOrigin:'0px 0px',transform:'none',clipPath:'none',zIndex:'auto',...(f.style||{})};
 if(f.coverage){style.clipPath='path(x)';owner.dataset.panelCoverage=JSON.stringify(f.coverage)}
 const context={createImageData:(w,h)=>({data:new Uint8ClampedArray(w*h*4)}),putImageData:()=>{}};
 const document={createElement:()=>({getContext:()=>context,dataset:{},style:{},setAttribute:()=>{}}),createRange:()=>({selectNodeContents:()=>{},getBoundingClientRect:()=>({left:0,top:0,right:0,bottom:0})})};
 class DOMMatrix {constructor(m){Object.assign(this,{a:1,b:0,c:0,d:1,e:0,f:0,is2D:true},f.matrix||{})}inverse(){let det=this.a*this.d-this.b*this.c;return {a:this.d/det,b:-this.b/det,c:-this.c/det,d:this.a/det,e:(this.c*this.f-this.d*this.e)/det,f:(this.b*this.e-this.a*this.f)/det}}}
 const read=(ctx,x,y,sw,sh,w,h)=>{let out=new Uint8ClampedArray(w*h*4);for(let yy=0;yy<h;yy++)for(let xx=0;xx<w;xx++){let sx=x+Math.floor((xx+.5)*sw/w),sy=y+Math.floor((yy+.5)*sh/h);for(let c=0;c<4;c++)out[(yy*w+xx)*4+c]=f.rgba[(sy*f.width+sx)*4+c]}return out};
 const sandbox={root,items:[{id:'one',sourceBounds:f.bounds,sourceFrame:f.frame,sourceFontSize:f.glyph}],opacity:f.opacity??1,inpaintingEnabled:true,appearance:{preserveSourceTextColor:true,preserveSourceBackgroundColor:true},sourceImage:{complete:true,naturalWidth:f.width,naturalHeight:f.height},cleanupImageGeometry:null,sourcePixelReader:{read},rotatedPlates:node.dataset.sourceBackgroundColor==='rotated-panel'?[owner]:[],document,DOMMatrix,getComputedStyle:()=>style,aidokuSourceColorLuminance:a=>a.map(c=>{c/=255;return c<=.04045?c/12.92:((c+.055)/1.055)**2.4}).reduce((v,c,i)=>v+c*[.2126,.7152,.0722][i],0),aidokuCleanupClip:()=>'',scrollX:0,scrollY:0,performance:{now:()=>0},console};
 vm.runInNewContext(code,sandbox);
 const metadata=node.dataset.glyphCover?JSON.parse(node.dataset.glyphCover):null;
 return {id:f.id,rejection:node.dataset.glyphCoverReject||null,result:node.proof?{...node.proof,metadata,foreground:f.record.core,outline:f.record.outline,outlineWidth:parseFloat(node.style.webkitTextStrokeWidth)}:null,budget:{pixels:65536-(Number(root.dataset.glyphCoverCrops)>0?(node.proof?node.proof.width*node.proof.height:f.cropPixels):0),analysed:Number(root.dataset.glyphCoverCrops||0),covers:Number(root.dataset.glyphCovers||0)},error:root.dataset.glyphCoverError||null};
});fs.writeFileSync(process.argv[4],JSON.stringify(outputs));
