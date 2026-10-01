const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const root=path.resolve(__dirname,'../../..'),frozen=fs.readFileSync(path.join(root,'AidokuTests/Translation/LegacyReaderTranslationRenderScript.swift'),'utf8');
const t=frozen.match(/static let BrowserOverlayTypography = #?"""\n([\s\S]*?)\n    """/)[1];
const gs=frozen.indexOf('                const c=panelGeometry,kx=c.iw/c.frame[2]*c.sx,ky=c.ih/c.frame[3]*c.sy;');
const ge=frozen.indexOf('                  attempts=0;exhausted=false;',gs);
if(gs<0||ge<0)throw Error('late safe fit source not found');
const ctx=vm.createContext({});vm.runInContext(t,ctx);
const block=frozen.slice(gs,ge).replace(/\\\\/g,'\\');
vm.runInContext(`globalThis.oracle=v=>{
const f=v.page,source=v.core[0],w0=v.width,h0=v.height,crop=v.crop;
const c0={w:w0,h:h0,iw:f[2],ih:f[3],frame:f,x:crop[0],y:crop[1],sx:w0/crop[2],sy:h0/crop[3],safe:Uint8Array.from(v.safe)};
if(v.painted)c0.canvas={width:w0,height:h0,getContext:()=>({getImageData:()=>({data:Uint8Array.from(v.painted.flatMap(a=>[0,0,0,a]))})})};
const panelGeometry=c0,item={sourceBounds:[source[0]/f[2],source[1]/f[3],source[2]/f[2],source[3]/f[3]],sourceFontSize:v.glyph,auxiliaryInkRects:v.core.slice(1).map(a=>[a[0]/f[2],a[1]/f[3],a[2]/f[2],a[3]/f[3]])};
const sourceCX=source[0]+source[2]/2,sourceCY=source[1]+source[3]/2,frame=f,reach=0,cleanupContext=null,sourceImage=null;
const otherBackgrounds=v.obstacles.map(a=>({left:a[0],top:a[1],right:a[0]+a[2],bottom:a[1]+a[3]})),otherInks=[];
const balloonInteriorOf=()=>v.interior?{tight:false,E:{left:crop[0],top:crop[1]},k:w0/crop[2],w:w0,h:h0,fill:Uint8Array.from(v.interior)}:null;
const font=v.font,lineHeightRatio=v.ratio,original={lines:v.lines},sourceWidth=source[2],baseWidth=v.baseWidth;
let balloonSafeFitBudget=v.budget,sizeForMeasure=font;
const koreanWrapMeasure={font:String(font)},setKoreanFont=font=>{sizeForMeasure=Number(/ ([0-9.]+)px /.exec(font)?.[1]||font);};
const node={style:{fontWeight:700,fontFamily:'NativeSharedFont'}};
const koreanTextWidth=s=>s?v.widths[sizeForMeasure.toFixed(6)+'|'+Buffer.from(s,'utf8').toString('base64')]:0;
const wordWidthFor=size=>{sizeForMeasure=size;return Math.floor(aidokuKoreanWordWidth(v.text,size,koreanTextWidth)*4)/4;};
const widthsFor=size=>{sizeForMeasure=size;const advance=koreanTextWidth(v.text);return [...new Set([baseWidth*size/font,sourceWidth,baseWidth*.75,baseWidth*1.15,sourceWidth*.8,...(advance+2<size*1.8?[Math.ceil((advance+2)*4)/4]:[])].map(x=>Math.floor(x*4)/4))];};
const probeMargin=()=>[1,.75],displayedText=v.text;
${block}
return placed;
};
const predicted=safeAreaFit();return{proposals:predicted===false?[]:predicted,budget:balloonSafeFitBudget,gridValid:true};
};`,Object.assign(ctx,{Buffer}));
let input='';process.stdin.setEncoding('utf8');process.stdin.on('data',s=>input+=s);process.stdin.on('end',()=>{
for(const line of input.trim().split('\n')){const v=JSON.parse(line);try{console.log(JSON.stringify(ctx.oracle(v)));}catch(e){console.log(JSON.stringify({error:String(e),stack:e.stack}));}}
});
