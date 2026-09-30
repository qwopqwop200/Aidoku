// Real cached speech balloons. The final fit must use painted line boxes rather
// than WebKit's extra enclosing Range rectangle, and may move within the same
// measured contour when the source box sits in its tapered shoulder.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { webkit } = require(process.env.PLAYWRIGHT_MODULE || '/Users/ijunjae/PycharmProjects/new_aidoku/output/typesetting-quality/tools/node_modules/playwright');

const output = process.argv[2] || path.resolve(__dirname, '../../../output/visual-quality');
const source = fs.readFileSync(path.resolve(__dirname,
  '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayTypography.swift'), 'utf8');
const script = source.split('static let script = #"""')[1].split('"""#')[0];
assert.ok(script.includes('aidokuContainBalloonText'));

(async () => {
  const browser = await webkit.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 430, height: 574 } });
    for (const id of ['phone-1', 'phone-2']) {
      const payload = JSON.parse(fs.readFileSync(path.join(output, 'fresh-payloads', `${id}.payload.json`)));
      const dump = JSON.parse(fs.readFileSync(path.join(output, 'v139-visual', `${id}.items.json`)));
      await page.setContent('<style>body{margin:0}</style><div id="root"></div>');
      await page.evaluate(items => {
        const root = document.querySelector('#root');
        for (const item of items) {
          const node = document.createElement('div');
          node.innerHTML = item.html;
          node.style.cssText = item.css;
          Object.assign(node.dataset, item.dataset);
          delete node.dataset.finalBalloonFit;
          delete node.dataset.finalBalloonFitRejected;
          root.appendChild(node);
        }
      }, dump.items);
      const results = await page.evaluate(script + `;
        aidokuContainBalloonText(document.querySelector('#root'), ${JSON.stringify(payload.items)});
        const nodes=[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')];
        const actual=n=>{const range=document.createRange();range.selectNodeContents(n);
          const boxes=[...range.getClientRects()].filter(r=>r.width>0&&r.height>0);
          return boxes.filter((r,i)=>!boxes.some((other,j)=>i!==j&&r.height>other.height*1.65&&
            other.left>=r.left-.05&&other.right<=r.right+.05&&other.top>=r.top-.05&&other.bottom<=r.bottom+.05&&
            other.height<r.height-.1));};
        ${JSON.stringify(payload.items)}.filter(i=>i.balloonInterior?.contourVerified).map(item=>{
          const n=nodes.find(n=>n.dataset.aidokuRegion===String(item.id)),b=item.balloonInterior,f=item.sourceFrame,
            top=f[1]+b.rect[1]*f[3],height=b.rect[3]*f[3],count=b.spans.length/2;
          const stroke=(parseFloat(getComputedStyle(n).webkitTextStrokeWidth)||0)/2,pad=.5+stroke;
          const inside=actual(n).every(r=>{
            const y0=r.top-pad,y1=r.bottom+pad;
            if(y0<top||y1>top+height)return false;
            const first=Math.max(0,Math.floor((y0-top)/height*count));
            const last=Math.min(count-1,Math.ceil((y1-top)/height*count)-1);
            for(let row=first;row<=last;row++)if(b.spans[row*2]<0||
              r.left-pad<f[0]+b.spans[row*2]*f[2]-.05||
              r.right+pad>f[0]+b.spans[row*2+1]*f[2]+.05)return false;
            return true;
          });
          return {id:String(item.id),inside,fit:n.dataset.finalBalloonFit||null,rejected:n.dataset.finalBalloonFitRejected||null};
        });`);
      const target = id === 'phone-2' ? ['6', '7', '8'] : ['2', '4', '5'];
      for (const region of target) {
        const result = results.find(x => x.id === region);
        assert.ok(result, `${id}/${region}: fixture must contain a measured balloon`);
        assert.ok(result.inside, `${id}/${region}: ink and stroke must be inside every scanned contour row`);
        assert.equal(result.rejected, null, `${id}/${region}: final fit must find a safe slot`);
      }
      if (id === 'phone-2') {
        for (const region of ['7', '8']) assert.ok(results.find(x => x.id === region).fit,
          `${id}/${region}: tapered bubble needs a measured position correction`);
      }
      console.log(`${id}: ${target.length} measured speech captions contained`);
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
