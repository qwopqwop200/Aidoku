const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { webkit } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const source = fs.readFileSync(path.join(__dirname,
  '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserOverlayTypography.swift'), 'utf8')
  .split('static let script = #"""')[1].split('"""#')[0];
(async () => {
  const browser = await webkit.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 430, height: 607 } });
    await page.setContent('<style>body{margin:0}</style>');
    await page.evaluate(source + ';window.straighten=aidokuUprightCaptionPlate;');
    const results = await page.evaluate(() => {
      const run = (angle, flag = true, display = true, clip = false, proven = true, pageClip = false) => {
        const root = document.createElement('div'), node = document.createElement('div'), plate = document.createElement('div');
        document.body.append(root); root.append(plate, node);
        node.dataset.aidokuImageOcrOverlay = 'item'; node.dataset.aidokuRegion = '0';
        node.dataset.uprightQuad = String(proven);
        node.textContent = '루나틱쿤'; node.style.cssText = 'position:absolute;left:325px;top:180px;font:700 40px sans-serif';
        plate.dataset.aidokuImageOcrOverlay = 'source-rotated-panel'; plate.dataset.aidokuRegion = '0';
        plate.style.cssText = `position:absolute;left:311.02929px;top:28.45787px;width:116.21347px;height:374.55975px;transform:rotate(${angle}rad);transform-origin:50% 50%;background:rgb(250,247,253)`;
        if (clip) plate.style.clipPath = 'polygon(0px 0px,5px 0px,5px 5px,0px 5px)';
        const rect = plate.getBoundingClientRect(), cx = (rect.left + rect.right) / 2, cy = (rect.top + rect.bottom) / 2;
        const inverse = new DOMMatrix(getComputedStyle(plate).transform).inverse();
        if (pageClip) plate.style.clipPath = `polygon(${[[0,0],[430,0],[430,607],[0,607]].map(([x,y]) => {
          const p = inverse.transformPoint({x:x-cx,y:y-cy}); return `${p.x+116.21347/2}px ${p.y+374.55975/2}px`;
        }).join(',')})`;
        const old = plate.style.cssText, oldText = node.style.cssText;
        window.straighten(root, [{ id:'0', rotation:angle, uprightQuadText:flag, sourceLettering:display?'display':null,
          vertical:false, sourceFrame:[0,0,430,607] }]);
        const after = plate.getBoundingClientRect();
        const result = {changed:old!==plate.style.cssText, textUnchanged:oldText===node.style.cssText,
          transform:plate.style.transform, proof:plate.dataset.uprightQuadProof,
          expected:[Math.max(0,rect.left),Math.max(0,rect.top),Math.min(430,rect.right),Math.min(607,rect.bottom)],
          actual:[after.left,after.top,after.right,after.bottom]};
        root.remove(); return result;
      };
      return [run(-.061420099665),run(.061420099665,true,true,false,true,true),
        run(-.25),run(-.0614,false),run(-.0614,true,false),run(-.0614,true,true,true),run(-.0614,true,true,false,false)];
    });
    for (const r of results.slice(0,2)) {
      assert.equal(r.transform,'none'); assert.equal(r.proof,'enclosed-source-plate');
      r.actual.forEach((v,i) => assert.ok(Math.abs(v-r.expected[i])<.02,'same page-clipped footprint'));
    }
    for (const r of results.slice(2)) assert.equal(r.changed,false,'preserve slanted/body/custom-clip/unproven controls');
    for (const r of results) assert.equal(r.textUnchanged,true,'plate correction cannot change text layout');
    console.log('PASS 2 upright title plates and 5 refusal controls; text layout and page-clipped extents preserved');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode=1; });
