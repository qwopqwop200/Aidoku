const fs=require('fs'),path=require('path'),crypto=require('crypto');
const root=process.argv[2],out=process.argv[3];
const source=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const anchor=source.indexOf('    // Polarity-preserving legibility.'),start=source.indexOf('    if(opacity===1&&',anchor),end=source.indexOf('    // Page style cohorts:',start);
if(anchor<0||end<start)throw Error('missing frozen polarity');
const block=source.slice(start,end),colors=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserSourceTextColor.swift'),'utf8');
const ls=colors.indexOf('const aidokuSourceColorLuminance ='),le=colors.indexOf(';',colors.indexOf('}, 0)',ls))+1;
const run=new Function('c',`
${colors.slice(ls,le)}
const opacity=1,appearance={preserveSourceTextColor:true,preserveSourceBackgroundColor:true},performance={now:()=>0};
const css=v=>v?'rgb('+v.join(',')+')':'invalid';
const owner={dataset:{aidokuImageOcrOverlay:'source-readability-panel',aidokuRegion:'x'},style:{backgroundColor:css(c.plate),backgroundImage:'none'},querySelectorAll:()=>c.sharedOwner?[node,{}]:[node]};
const otherPlate={dataset:{foreignFills:c.foreignOwner?owner.style.backgroundColor:''},style:{}};
const backing={dataset:{aidokuRegion:'x'},style:{backgroundColor:css(c.plate)}};
const node={dataset:{aidokuRegion:'x',sourceBackgroundColor:'readability-panel',sourceSampledTextRGB:css(c.source),sourceSampledBackgroundRGB:css(c.backing),sourceStrokeColor:c.strokePreserved?'preserved':'none',outlinedLettering:JSON.stringify({kind:c.ringKind,action:c.ringAction,core:c.ringCore})},style:{color:css(c.fill),fontSize:c.font+'px',webkitTextStrokeWidth:c.strokeWidth+'px'},textContent:'abc',parentElement:owner};
const others=c.otherInks.map(v=>({style:{color:css(v)},textContent:'neighbor'}));
const nodes=[node,...others],root={dataset:{},querySelectorAll:s=>s.includes('source-readability-backing')?[backing]:s.includes('source-readability-panel')?[owner,otherPlate]:nodes};
const items=[{id:'x',sourceColorEligible:true}],rotatedPlates=[];
const cachedSourceSample=()=>({confidence:{foreground:c.confidence}}),getComputedStyle=n=>n.style;
const aidokuPlateMeets=()=>true,document={createRange:()=>({selectNodeContents(){},getBoundingClientRect:()=>({left:0,top:0,right:1,bottom:1})})};
${block}
if(root.dataset.polarityKeptError)throw Error(root.dataset.polarityKeptError);
return {fill:node.dataset.polarityKept?JSON.parse(node.dataset.polarityKept).fill[1]:null,plate:node.dataset.polarityKept?JSON.parse(node.dataset.polarityKept).plate[1]:null,contrast:node.dataset.polarityKept?Number(node.dataset.sourceFinalMinimumContrast):null,rejection:node.dataset.polarityReject||null};
`);
const base={plate:[210,125,65],fill:[10,10,10],source:[245,245,235],backing:[210,125,65],confidence:.8,font:18,strokeWidth:0,strokePreserved:false,ringAction:null,ringKind:null,ringCore:null,sharedOwner:false,foreignOwner:false,otherInks:[]};
const f=[];const add=p=>{const input={...structuredClone(base),...p};f.push({input,expected:run(input)});};
for(const plate of [[210,125,65],[70,150,140],[150,150,150],[245,245,245],[5,5,5],[150,100,170]])for(const source of [[245,245,235],[230,215,250],[20,20,20],[40,80,30],[180,185,220]])for(const font of [12,18,36])add({plate,backing:plate,source,fill:source[0]<100?[245,245,245]:[10,10,10],font});
for(const ringKind of [null,'outline','halo','none'])for(const ringAction of [null,'none','fill'])for(const ringCore of [null,[20,20,20],[245,245,235]])add({ringKind,ringAction,ringCore});
for(const confidence of [0,.54,.55,1])for(const strokeWidth of [0,.1,2])for(const strokePreserved of [false,true])add({confidence,strokeWidth,strokePreserved});
for(const sharedOwner of [false,true])for(const foreignOwner of [false,true])for(const otherInks of [[],[null],[[10,10,10]],[[255,255,255]],[[240,230,250],[255,255,255]]])add({sharedOwner,foreignOwner,otherInks});
for(const backing of [[250,250,250],[178,125,65],[177,125,65],null])add({backing});
for(const plate of [null,[260,100,100],[-1,20,20]])add({plate});
fs.writeFileSync(out,JSON.stringify(f));console.log(JSON.stringify({cases:f.length,positive:f.filter(x=>x.expected.fill).length,frozenSHA256:crypto.createHash('sha256').update(block).digest('hex')}));
