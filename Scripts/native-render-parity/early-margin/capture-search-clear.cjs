const fs=require('fs');const [root,out,fp]=process.argv.slice(2);const ref=root+'/Scripts/native-render-parity/reference-source/';const view=fs.readFileSync(ref+'BrowserOverlayView.swift','utf8'),typo=fs.readFileSync(ref+'BrowserOverlayTypography.swift','utf8');
function extract(text,name){let start=text.indexOf('const '+name+' =');if(start<0)start=text.indexOf('function '+name+'(');if(start<0)throw Error(name);const begin=text.indexOf('{',start);let depth=0,end=begin;for(;end<text.length;end++){if(text[end]==='{')depth++;if(text[end]==='}'&&--depth===0)break;}return text.slice(start,end+2);}
const helpers=['aidokuRestoredFontFloor','aidokuBalloonFontSizes','aidokuEmergencyBalloonFontSizes','aidokuKoreanFlowRank'].map(n=>extract(typo,n)).join('\n');
const start=view.indexOf('              const font=parseFloat(node.style.fontSize),priorFont=',view.indexOf('            fitBalloon:'));const prelude=view.slice(start,view.indexOf('              const plate=',start));
const fitStart=view.indexOf('                const fitAt=',start),fitEnd=view.indexOf('                // Unsafe restored pixels',fitStart);const normal=view.slice(fitStart,fitEnd);const clearStart=view.indexOf('                search: for(const size of late?[]:sizes)',fitEnd),clearEnd=view.indexOf('                return late&&safeAreaFit();',clearStart);const body=normal+view.slice(clearStart,clearEnd)+'return false;';
const run=new Function('f',helpers+`
const cleanupImageGeometry=null;const trace=[],sourceCX=f.source[0],sourceCY=f.source[1],cx=f.original[0],cy=f.original[1],sourceWidth=f.sourceWidth,baseWidth=f.baseWidth,minimumFontSize=f.minimum,offsetSearch=f.offset,clearSearch=true,legible=true,late=false;
const node={style:{fontSize:String(f.font)},dataset:{artworkOriginalFont:f.prior?String(f.prior):undefined,sourceErasurePolicy:f.aux?'auxiliary-original-preserved':undefined}},item={sourceFontSize:f.glyph,sourceBounds:[0,0,1,1],sourceFrame:[0,0,100,100]},panelGeometry={provisional:f.provisional};
${prelude}
const centers=(offsetSearch?[[sourceCX,sourceCY],[sourceCX-6,sourceCY],[sourceCX+6,sourceCY],[sourceCX,sourceCY-6],[sourceCX,sourceCY+6],[sourceCX-12,sourceCY],[sourceCX+12,sourceCY],[sourceCX,sourceCY-12],[sourceCX,sourceCY+12]]:[[sourceCX,sourceCY],[cx,cy]]).filter(([xx,yy],i,all)=>all.findIndex(([a,b])=>Math.abs(a-xx)<.5&&Math.abs(b-yy)<.5)===i);
const widthsFor=size=>[...new Set([baseWidth*size/font,sourceWidth,baseWidth*.75,baseWidth*1.15,sourceWidth*.8,...(offsetSearch?[sourceWidth*.6,baseWidth*.55]:[])].map(value=>Math.floor(value*4)/4))];
const w=f.grid[0],h=f.grid[1],cx0=0,cy0=0,kx=1,ky=1,sl=0,st=0,sr=w,sb=h,scx=sourceCX,scy=sourceCY;let moves=0,layoutFrame=null;const measured=null;const probeMargin=size=>clearSearch&&size>font?[Math.max(1,size*.1),Math.max(.75,size*.1)]:[1,.75];const clear=(l,t,bw,bh)=> !f.obstacles.some(r=>l<r[0]+r[2]&&l+bw>r[0]&&t<r[1]+r[3]&&t+bh>r[1]);
const wordWidthFor=size=>f.word*size,frames=new Map(),original={lines:1,breaks:[],hangulFragments:0,punctuationOnly:0,badStarts:[],badEnds:[]},liveOriginal={left:0,top:0,width:20,height:10},p={left:0,top:0,right:100,bottom:100};let attempts=0,exhausted=false,accepted=false,readabilityPanels=1,centerFrames=null;
const layout=(size,x,y,width)=>{
 trace.push([size,x,y,width]);const frame={left:x-width/2,top:y-size/2,right:x+width/2,bottom:y+size/2};
 layoutFrame=frame;
 if(size>f.maximum||width<f.minWidth||Math.abs(x-f.target[0])>f.radius||Math.abs(y-f.target[1])>f.radius)return null;
 return {lines:1,breaks:[],hangulFragments:width<f.cleanWidth?1:0,punctuationOnly:0,badStarts:[],badEnds:[]};
};const plate={remove:()=>{}};let hit;
const decide=()=>{${body}};hit=decide();
return {id:f.id,accepted:hit===true,trace,chosen:hit===true?{size:Number(node.dataset.sourcePanelFinalFont),wordFlow:node.dataset.balloonFitWidth==='word-flow',emergency:node.dataset.balloonEmergencyFontFit==='true',clearRegion:node.dataset.balloonClearRegion==='true'}:null,frames:hit===true?null:Array.from(centerFrames||[]).map(([key,r])=>[key,[r.left,r.top,r.right-r.left,r.bottom-r.top]])};
`);fs.writeFileSync(out,JSON.stringify(JSON.parse(fs.readFileSync(fp)).map(f=>{const v=run(f);if(v===false)return {id:f.id,accepted:false,trace:[],chosen:null,frames:[]};if(v===true)throw Error('unexpected outer return true '+f.id);return v;})));
