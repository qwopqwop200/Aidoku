// Run the production short-caption release pass in WebKit. The separate
// ReaderCaptionOriginalReplayTests verifies the user's exact original page.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {webkit} = require('playwright');
const source = fs.readFileSync(path.join(__dirname, '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserOverlayView.swift'), 'utf8');
const start = source.indexOf('    // Short captions need only a glyph outline');
const end = source.indexOf('    let captionReadBudget=', start);
assert.ok(start > 0 && end > start);
const body = source.slice(start, end);
(async () => {
  const browser = await webkit.launch();
  try {
    const page = await browser.newPage();
    const cases = [
      ['clear', true], ['drawing-edge', true], ['isolated-ink', false],
      ['short-edge-ink', false], ['too-much-art', false], ['long', false],
      ['rotation', false], ['auxiliary', false], ['neighbor', false], ['disabled', false],
      ['unverified', false], ['provisional', false]
    ];
    for (const [name, expected] of cases) {
      const result = await page.evaluate(({body, name}) => {
        document.body.innerHTML = '';
        const root = document.createElement('div'); document.body.append(root);
        const canvas = document.createElement('canvas');canvas.width=100;canvas.height=100;root.append(canvas);
        const context = canvas.getContext('2d');context.fillStyle='#78b0d0';context.fillRect(0,0,100,100);
        const plate = document.createElement('div');plate.dataset.aidokuImageOcrOverlay='source-readability-panel';plate.dataset.aidokuRegion='1';
        Object.assign(plate.style,{position:'absolute',left:'20px',top:'20px',width:'60px',height:'60px',background:'#78b0d0'});root.append(plate);
        const node=document.createElement('div');node.textContent='감사해';node.dataset.aidokuImageOcrOverlay='item';node.dataset.aidokuRegion='1';
        Object.assign(node.style,{fontSize:'12px',width:'50px',height:'20px'});plate.append(node);
        const item={id:'1',text:name==='long'?'이 문장은 짧은 대사가 아니랍니다':'감사해',sourceSingleColumn:true,
          sourceBounds:[.2,.2,.6,.6],sourceFrame:[0,0,100,100],sourceFontSize:10,
          rotation:name==='rotation'?10:0,auxiliaryInkRects:name==='auxiliary'?[[.1,.1,.1,.1]]:[]};
        const safe=new Uint8Array(10000).fill(1);
        if(name==='drawing-edge')for(let x=78;x<100;x++)safe[22*100+x]=0;
        if(name==='isolated-ink')safe[50*100+50]=0;
        if(name==='short-edge-ink'){item.sourceBounds=[.2,.2,.79,.6];for(let x=97;x<100;x++)safe[22*100+x]=0;}
        if(name==='too-much-art')for(let y=20;y<80;y++)for(let x=70;x<100;x++)safe[y*100+x]=0;
        const c={canvas,safe,w:100,h:100,iw:100,ih:100,x:0,y:0,sx:1,sy:1,frame:[0,0,100,100],
          erasureComplete:true,sourceRemainingInk:name==='unverified'?20:0,provisional:name==='provisional'};
        const items=[item];if(name==='neighbor')items.push({id:'2',sourceBounds:[.3,.3,.1,.1],sourceFrame:[0,0,100,100]});
        const restoredPanelGeometry=new Map([[item,c]]),restoredSourcePanels=new Set();
        // Speck filling is separately exercised by the native restoration fixtures.
        const aidokuFillEnclosedSpecks=()=>null;
        new Function('items','root','restoredPanelGeometry','restoredSourcePanels','aidokuFillEnclosedSpecks','inpaintingEnabled','opacity',body)
          (items,root,restoredPanelGeometry,restoredSourcePanels,aidokuFillEnclosedSpecks,name!=='disabled',1);
        return {released:!plate.isConnected,text:node.textContent,connected:node.isConnected,z:node.style.zIndex,
          stroke:parseFloat(node.style.webkitTextStrokeWidth),tag:node.dataset.smallCaptionInpainted};
      },{body,name});
      assert.equal(result.released,expected,name);
      assert.equal(result.text,'감사해');assert.equal(result.connected,true,'caption remains visible');
      if(expected){assert.equal(result.z,'3');assert.ok(result.stroke>0&&result.stroke<=.7);assert.equal(result.tag,'true');}
      console.log('PASS',name);
    }
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
