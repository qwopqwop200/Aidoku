const fs=require('fs'),path=require('path');
const root=process.argv[2],out=process.argv[3];
const src=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
function block(a,b){let s=src.indexOf(a),e=src.indexOf(b,s);if(s<0||e<s)throw Error('missing '+a);return src.slice(s,e);}
const floor=block('    // The readable floor holds for plate-free','    // Plates are final. A plate erasing lettering');
const center=block('    // Final ink belongs to the measured balloon body','    // Plates are final. A plate hides everything');
const clip=block('    // Plates are final. A plate erasing lettering','    // Final ink belongs to the measured balloon body');
const typo=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayTypography.swift'),'utf8');
const a=typo.indexOf('    const aidokuSolidPanelCoverage ='),b=typo.indexOf('\n    };',a)+7;
const shared=`const opacity=1,performance={now:()=>0},box=a=>({left:a[0],top:a[1],width:a[2],height:a[3],right:a[0]+a[2],bottom:a[1]+a[3]});`;
const runFloor=new Function('c',`${shared}
const aidokuReadableFontSize=9,cleanupImageGeometry={frame:c.frame};
const node={dataset:{aidokuRegion:'x',sourceBackgroundColor:'inpainted'},style:{fontSize:c.font+'px',lineHeight:c.pitch+'px'},scrollWidth:c.scroll[0],clientWidth:c.scroll[1],scrollHeight:c.scroll[2],clientHeight:c.scroll[3]};
const neighbors=c.neighbors.map(r=>({style:{},r}));const nodes=[node,...neighbors],root={dataset:{},querySelectorAll:()=>nodes};node.parentElement=root;
const items=[{id:'x'}],document={createRange:()=>({selectNodeContents(n){this.n=n;},getBoundingClientRect(){return box(this.n===node?(parseFloat(node.style.fontSize)===c.font?c.before:c.after):this.n.r);}})};
${floor}
return node.dataset.readableFloorHeld?{font:parseFloat(node.style.fontSize),pitch:parseFloat(node.style.lineHeight),ink:c.after}:null;
`);
const runCenter=new Function('c',`${shared}
const cleanupImageGeometry={frame:[0,0,200,200]},node={dataset:{aidokuRegion:'x'},style:{fontSize:c.font+'px',left:'0px',top:'0px'}};
const neighbors=c.neighbors.map(r=>({style:{},dataset:{},r})),nodes=[node,...neighbors],root={querySelectorAll:()=>nodes};node.parentElement=c.parent?{getBoundingClientRect:()=>box(c.parent)}:root;
const items=[{id:'x',balloonInterior:{contourVerified:true}}],nativeBalloonShape=()=>({cx:c.center[0],cy:c.center[1],outside:(l,t,r,b)=>l<c.shape[0]||t<c.shape[1]||r>c.shape[0]+c.shape[2]||b>c.shape[1]+c.shape[3]});
const document={createRange:()=>({selectNodeContents(n){this.n=n;},getBoundingClientRect(){if(this.n!==node)return box(this.n.r);const dx=parseFloat(node.style.left),dy=parseFloat(node.style.top);return box([c.ink[0]+dx+(dx||dy?c.drift[0]:0),c.ink[1]+dy+(dx||dy?c.drift[1]:0),c.ink[2],c.ink[3]]);}})};
${center}
return node.dataset.balloonCenterShift?JSON.parse(node.dataset.balloonCenterShift):null;
`);
const runClip=new Function('c',`${shared}
${typo.slice(a,b)}
const panel={dataset:{aidokuRegion:'x',panelCoverage:JSON.stringify(c.coverage)},style:{backgroundColor:'rgb(245,245,245)'},getBoundingClientRect:()=>box(c.panel)};
const node={dataset:{aidokuRegion:'x'},style:{fontSize:'10px'}},root={dataset:{},querySelectorAll:s=>s.includes('source-readability-panel')?[panel]:[node]};
const items=[{id:'x',balloonInterior:{contourVerified:c.verified}},...c.sources.slice(1).map((r,i)=>({id:String(i),r}))];
const balloonImage={complete:true,naturalWidth:200},getComputedStyle=n=>n.style,CSS={supports:()=>true},balloonMilliseconds=0;
const balloonRectsOf=item=>item.r?[box(item.r)]:[box(c.sources[0])],unitMembersOf=()=>c.unit?['x','y']:null;
const balloonInteriorOf=()=>({E:box(c.interior),k:c.scale,w:c.width,h:c.height,fill:new Uint8Array(c.fill),surfaceRGB:[245,245,245],native:c.native});
const document={createRange:()=>({selectNodeContents(){},getClientRects:()=>c.inks.map(box)})};
${clip}
return panel.dataset.balloonInteriorClipped?{coverage:JSON.parse(panel.dataset.panelCoverage),removedPixels:Number(panel.dataset.balloonInteriorClipped)}:null;
`);
const fixtures=[];const add=(type,input,run)=>fixtures.push({type,input,expected:run(input)});
const f={font:8,pitch:9.6,before:[40,40,32,18],after:[39,39,34,19],frame:[0,0,100,100],scroll:[40,40,24,24],neighbors:[]};
for(const font of [7.5,7.75,8,8.25,8.5])for(const after of [[39,39,34,19],[39,39,34,32],[-1,39,34,19],[69,39,34,19]])add('floor',{...f,font,after},runFloor);
for(const scroll of [[42,40,24,24],[41,40,25,24],[40,40,26,24]])add('floor',{...f,scroll},runFloor);
for(const neighbors of [[[38,38,1,1]],[[74,40,1,1]],[[79,40,1,1]],[]])add('floor',{...f,neighbors},runFloor);
const ce={ink:[40,40,30,20],center:[60,55],font:12,shape:[20,20,80,80],parent:null,neighbors:[],drift:[0,0]};
for(const center of [[60,55],[0,0],[100,100],[55,50]])for(const parent of [null,[40,40,30,20],[0,0,100,100]])for(const neighbors of [[],[[44,44,6,6]]])add('center',{...ce,center,parent,neighbors},runCenter);
for(const drift of [[.05,0],[.11,0],[0,.11]])add('center',{...ce,drift},runCenter);
for(const scale of [1,1.5,2])for(const native of [true,false])for(const verified of [true,false])for(const unit of [true,false])for(const pattern of ['oval','flat','split']){
 const width=Math.ceil(100*scale),height=Math.ceil(100*scale),fill=Array.from({length:width*height},(_,i)=>{const x=(i%width+.5)/scale,y=(Math.floor(i/width)+.5)/scale;return +(pattern==='flat'||pattern==='oval'&&((x-50)**2/35**2+(y-50)**2/40**2<1)||pattern==='split'&&((x>15&&x<30)||(x>65&&x<80))&&y>15&&y<85);});
 const c={panel:[0,0,100,100],coverage:[[0,0,100,100]],sources:[[42,40,16,20],[85,0,10,10]],inks:[[44,43,10,15]],interior:[0,0,100,100],scale,width,height,fill,native,verified,unit};add('clip',c,runClip);
}
fs.writeFileSync(out,JSON.stringify(fixtures));console.log(JSON.stringify({cases:fixtures.length,accepted:fixtures.filter(x=>x.expected).length}));
