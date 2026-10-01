// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
// Replays cached speech captions in WebKit and checks that final typography
// moves painted ink toward the measured balloon centre without leaving paper.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { webkit } = require(process.env.PLAYWRIGHT_MODULE ||
  '/Users/ijunjae/PycharmProjects/new_aidoku/output/typesetting-quality/tools/node_modules/playwright');

const output = process.argv[2] || path.resolve(__dirname, '../../../output/visual-quality');
const source = fs.readFileSync(path.resolve(__dirname,
  '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserOverlayTypography.swift'), 'utf8');
const script = source.split('static let script = #"""')[1].split('"""#')[0];

(async () => {
  const browser = await webkit.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 430, height: 574 } });
    let examined = 0, improved = 0;
    for (const id of ['phone-1', 'phone-2']) {
      const payload = JSON.parse(fs.readFileSync(path.join(output, 'fresh-payloads', `${id}.payload.json`)));
      const dump = JSON.parse(fs.readFileSync(path.join(output, 'v139-visual', `${id}.items.json`)));
      await page.setContent('<style>body{margin:0}</style><div id="root"></div>');
      const result = await page.evaluate(({ items, dump, script }) => {
        const root = document.querySelector('#root');
        for (const item of dump.items) {
          const node = document.createElement('div');
          node.innerHTML = item.html;
          node.style.cssText = item.css;
          Object.assign(node.dataset, item.dataset);
          root.appendChild(node);
        }
        const boxes = node => {
          const range = document.createRange(); range.selectNodeContents(node);
          const all = [...range.getClientRects()].filter(r => r.width > 0 && r.height > 0);
          return all.filter((r, i) => !all.some((other, j) => i !== j &&
            r.height > other.height * 1.65 && other.left >= r.left - .05 &&
            other.right <= r.right + .05 && other.top >= r.top - .05 &&
            other.bottom <= r.bottom + .05 && other.height < r.height - .1));
        };
        const capture = () => items.filter(i => i.balloonInterior?.contourVerified).map(item => {
          const node = [...root.children].find(n => n.dataset.aidokuRegion === String(item.id));
          if (!node) return null;
          const rects = boxes(node), f = item.sourceFrame, b = item.balloonInterior;
          if (!rects.length || !f || !b?.center) return null;
          const cx = (Math.min(...rects.map(r => r.left)) + Math.max(...rects.map(r => r.right))) / 2;
          const cy = (Math.min(...rects.map(r => r.top)) + Math.max(...rects.map(r => r.bottom))) / 2;
          const targetX = f[0] + b.center[0] * f[2], targetY = f[1] + b.center[1] * f[3];
          const top = f[1] + b.rect[1] * f[3], height = b.rect[3] * f[3], count = b.spans.length / 2;
          const pad = .5 + (parseFloat(getComputedStyle(node).webkitTextStrokeWidth) || 0) / 2;
          const inside = rects.every(r => {
            const y0 = r.top - pad, y1 = r.bottom + pad;
            if (y0 < top || y1 > top + height) return false;
            const first = Math.max(0, Math.floor((y0 - top) / height * count));
            const last = Math.min(count - 1, Math.ceil((y1 - top) / height * count) - 1);
            for (let row = first; row <= last; row++) {
              if (b.spans[row * 2] < 0 || r.left - pad < f[0] + b.spans[row * 2] * f[2] - .05 ||
                  r.right + pad > f[0] + b.spans[row * 2 + 1] * f[2] + .05) return false;
            }
            return true;
          });
          return { id: String(item.id), distance: Math.hypot(cx - targetX, cy - targetY), inside,
            fit: node.dataset.finalBalloonFit || null };
        }).filter(Boolean);
        const before = capture();
        new Function('root', 'items', script + '\n aidokuContainBalloonText(root,items);')(root, items);
        return { before, after: capture() };
      }, { items: payload.items, dump, script });
      for (const before of result.before) {
        const after = result.after.find(x => x.id === before.id);
        assert.ok(after, `${id}/${before.id}: caption remains present`);
        if (!before.inside) continue;
        assert.ok(after.inside, `${id}/${before.id}: previously contained ink remains in balloon`);
        assert.ok(after.distance <= before.distance + .6,
          `${id}/${before.id}: distance to balloon centre must not increase (${before.distance.toFixed(2)} -> ${after.distance.toFixed(2)}, ${after.fit})`);
        examined++;
        if (after.distance < before.distance - .75) improved++;
      }
    }
    assert.ok(examined >= 4, 'real cached contours were exercised');
    assert.ok(improved >= 1, 'at least one caption was measurably recentered');
    console.log(`PASS ${examined} cached captions contained, ${improved} moved closer to balloon centre`);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
