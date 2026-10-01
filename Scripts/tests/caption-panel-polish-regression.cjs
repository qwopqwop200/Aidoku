// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
// Run with PLAYWRIGHT_MODULE pointing to a Playwright installation.
// Uses actual WebKit geometry and the production final pass; no layout mocks.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {webkit} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const script = fs.readFileSync(path.join(__dirname,
  '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserOverlayTypography.swift'),'utf8')
  .split('static let script = #"""')[1].split('"""#')[0];
(async()=>{
  const browser=await webkit.launch();
  try {
    const page=await browser.newPage({viewport:{width:700,height:600},deviceScaleFactor:2});
    await page.setContent('<style>body{margin:0;background:#dcc8ad} .ink{position:absolute;font:20px/24px sans-serif;color:black;white-space:pre}</style><div id="root"></div>');
    await page.evaluate(script+';window.polish=aidokuPolishCaptionPanels;');
    const result=await page.evaluate(()=>{
      const root=document.querySelector('#root'),items=[];
      const panel=(id,x,y,w,h,erasure=false)=>{const p=document.createElement('div');
        p.dataset.aidokuImageOcrOverlay='source-readability-panel';p.dataset.aidokuRegion=id;
        if(erasure)p.dataset.sourceErasure='true';
        Object.assign(p.style,{position:'absolute',left:x+'px',top:y+'px',width:w+'px',height:h+'px',backgroundColor:'rgb(205,185,160)'});
        root.appendChild(p);return p;};
      const text=(id,x,y,text,source)=>{const n=document.createElement('div');n.className='ink';n.textContent=text;
        n.dataset.aidokuImageOcrOverlay='item';n.dataset.aidokuRegion=id;
        Object.assign(n.style,{left:x+'px',top:y+'px'});root.appendChild(n);
        const item={id,text,sourceFrame:[0,0,700,600],sourceBounds:source.map((v,i)=>v/(i%2?600:700)),
          sourceTextOnly:false,wrappingScript:'korean'};items.push(item);return {node:n,item};};
      const a=panel('a',20,20,80,180,true),b=panel('a',20,55,120,145);
      const n=text('a',32,70,'후헤헤\n깨끗하게\n닦아 놨잖아',[30,30,60,160]);
      const c=panel('c',180,20,130,180);text('c',190,35,'나에게도\n너와 비슷한',[190,30,65,150]);
      panel('d',285,20,90,180);text('d',290,45,'그렇게\n보지 말아',[292,30,60,150]);
      const stroke=text('stroke',420,35,'에엑\n그럼 너도 같이',[420,30,90,110]);
      Object.assign(stroke.node.style,{color:'white',webkitTextStroke:'4px black'});
      const title=text('title',420,180,'효과음',[420,180,90,50]);title.item.sourceLettering='sfx';
      Object.assign(title.node.style,{color:'white',webkitTextStroke:'4px black'});
      const halo=text('halo',420,480,'어두운 바탕',[420,480,90,50]);
      Object.assign(halo.node.style,{color:'rgb(25,35,60)',webkitTextStroke:'4px white'});
      halo.node.dataset.sourceAppliedBackgroundRGB='25,35,60';
      const row=[text('r1',20,300,'정말!\n왜 네가',[20,260,40,100]),text('r2',100,340,'미안…',[100,260,40,100])];
      row.forEach((e,i)=>{e.item.balancedColumn=true;e.item.columnLayout={x:15+i*80,y:260,width:75,height:160,paddingTop:2};});
      // A separate paragraph can move within its own plate, but never resize.
      panel('move',180,260,130,150);const move=text('move',185,295,'같이',[185,280,30,40]);
      panel('obstacle',160,260,32,150);text('obstacle',160,275,'옆',[160,270,15,20]);
      const nestedPanel=panel('nested',400,280,150,100);nestedPanel.style.zIndex='2';
      const nested=text('nested',0,0,'가려지면 안 돼',[410,290,100,50]);
      nestedPanel.appendChild(nested.node);nested.node.style.zIndex='auto';
      nestedPanel.dataset.captionUnionClipped='true';nestedPanel.dataset.sourceBridgeClipped='true';nestedPanel.dataset.panelCoverage='[[400,280,150,100]]';
      nestedPanel.style.clipPath='inset(0px)';
      const priorSize=getComputedStyle(move.node).fontSize;
      const blockedA=panel('blocked',560,20,50,100,true),blockedB=panel('blocked',580,50,70,90);
      text('blocked',590,70,'보존',[565,25,30,80]);
      const kept=[{sourceFrame:[0,0,700,600],sourceBounds:[625/700,60/600,20/700,20/600]}];
      window.polish(root,items,1,kept);
      const ink=n=>{const r=document.createRange();r.selectNodeContents(n);const b=r.getBoundingClientRect();return [b.left,b.top,b.right,b.bottom];};
      return {keptProtected:blockedA.isConnected&&blockedB.isConnected,merged:root.querySelectorAll('[data-aidoku-region="a"][data-aidoku-image-ocr-overlay="source-readability-panel"]').length,
        union:[b.offsetLeft,b.offsetTop,b.offsetWidth,b.offsetHeight],trimmed:c.dataset.captionTrimmed,
        cRight:c.getBoundingClientRect().right,stroke:parseFloat(getComputedStyle(stroke.node).webkitTextStrokeWidth),
        haloStroke:parseFloat(getComputedStyle(halo.node).webkitTextStrokeWidth),titleStroke:parseFloat(getComputedStyle(title.node).webkitTextStrokeWidth),row:row.map(e=>ink(e.node)[1]),
        shifted:move.node.dataset.captionMinimalShift,priorSize,size:getComputedStyle(move.node).fontSize,
        text:n.node.textContent,nestedVisible:document.elementFromPoint(420,290)===nested.node};
    });
    assert.equal(result.keptProtected,true);assert.equal(result.nestedVisible,true);assert.equal(result.merged,1);assert.deepEqual(result.union,[20,20,120,180]);
    assert.equal(result.trimmed,'true');assert.ok(result.cRight<290);
    assert.equal(result.stroke,2.2);assert.equal(result.titleStroke,4);assert.equal(result.haloStroke,4);
    assert.deepEqual(result.row,[262,262]);assert.deepEqual(JSON.parse(result.shifted),[7.75,0]);assert.equal(result.size,result.priorSize);
    assert.equal(result.text,'후헤헤\n깨끗하게\n닦아 놨잖아');
    const margins=await page.evaluate(()=>{
      const run=mode=>{
        const root=document.createElement('div');document.body.appendChild(root);
        const panel=document.createElement('div'),node=document.createElement('div');
        panel.dataset.aidokuImageOcrOverlay='source-readability-panel';panel.dataset.aidokuRegion='margin';
        panel.dataset.captionUnionClipped='true';panel.dataset.panelCoverage='[[20,20,40,110],[60,20,40,105]]';
        panel.style.cssText='position:absolute;left:20px;top:20px;width:80px;height:110px;background:rgb(205,185,160);clip-path:polygon(0 0,100% 0,100% 95%,50% 95%,50% 100%,0 100%)';
        node.dataset.aidokuImageOcrOverlay='item';node.dataset.aidokuRegion='margin';node.textContent='대사';
        node.style.cssText='position:absolute;left:25px;top:30px;font:16px/20px sans-serif';root.append(panel,node);
        const item={id:'margin',sourceTextOnly:false,wrappingScript:'korean',sourceFrame:[0,0,700,600],sourceBounds:[20/700,20/600,20/700,109/600]};
        const kept=[{sourceFrame:[0,0,700,600],sourceBounds:[60/700,125/600,40/700,10/600]}];
        const reader=mode==='missing'?null:()=>{
          const pixels=new Uint8ClampedArray([230,220,210,255,230,220,210,255]);pixels.captionWidth=2;
          if(mode==='ink')pixels[0]=100;return pixels;
        };
        window.polish(root,[item],1,kept,reader);
        const unified=panel.dataset.captionUnified==='true';root.remove();return unified;
      };return ['missing','ink','blank'].map(run);
    });
    assert.deepEqual(margins,[false,false,true],'only pixel-certified blank kept margins may be filled');
    const packed=await page.evaluate(()=>{
      const root=document.createElement('div');document.body.appendChild(root);
      const specs=[{x:8,w:41,ink:11.6,iw:34,sx:29,sw:13,piece:true},
        {x:45,w:30,ink:49,iw:24,sx:55,sw:10},{x:71,w:54,ink:75,iw:48,sx:71.77,sw:43}];
      const items=[],panels=[],nodes=[];
      specs.forEach((s,i)=>{
        const id='group-'+i,p=document.createElement('div'),n=document.createElement('div'),span=document.createElement('span');
        p.dataset.aidokuImageOcrOverlay='source-readability-panel';p.dataset.aidokuRegion=id;
        p.style.cssText=`position:absolute;left:${s.x}px;top:20px;width:${s.w}px;height:100px;background:rgb(130,115,110)`;
        n.dataset.aidokuImageOcrOverlay='item';n.dataset.aidokuRegion=id;
        n.style.cssText=`position:absolute;left:${s.ink}px;top:40px;font:10px/20px sans-serif`;
        span.style.cssText=`display:inline-block;width:${s.iw}px;height:20px`;span.textContent='대사';n.appendChild(span);
        root.append(p,n);panels.push(p);nodes.push(n);
        items.push({id,sourceTextOnly:false,wrappingScript:'korean',sourceLettering:s.piece?'piece':null,
          sourceFrame:[0,0,200,200],sourceBounds:[s.sx/200,20/200,s.sw/200,100/200]});
      });
      window.polish(root,items,1);
      const boxes=panels.map(p=>{const r=p.getBoundingClientRect();return [r.left,r.right];});
      const shifts=nodes.map(n=>Number(n.dataset.captionGroupShift||0));root.remove();return {boxes,shifts};
    });
    assert.ok(packed.boxes[1][0]-packed.boxes[0][1]>=.95);
    assert.ok(packed.boxes[2][0]-packed.boxes[1][1]>=.95);
    assert.ok(packed.shifts[0]<0&&packed.shifts[1]<0,'free space by jointly moving the first and middle captions');
    if(process.env.CAPTION_SCREENSHOT)await page.screenshot({path:process.env.CAPTION_SCREENSHOT});
    console.log('PASS WebKit: rectangular union, blank-padding trim, minimum movement, shared row top, dialogue stroke, SFX preservation, unchanged text/font');
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
