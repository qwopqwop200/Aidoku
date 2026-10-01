// Replays saved overlay payloads in WebKit and measures each verified speech
// caption before/after the final contour-aware centering pass. Usage:
// node balloon-center-corpus-audit.cjs PAYLOAD_DIR ITEMS_DIR OUTPUT_JSON [FIRST LAST]
// or: ... OUTPUT_JSON --set VERIFIED_GALLERY_IDS_JSON
const fs = require('node:fs');
const path = require('node:path');
const { webkit } = require(process.env.PLAYWRIGHT_MODULE ||
  '/Users/ijunjae/PycharmProjects/new_aidoku/output/typesetting-quality/tools/node_modules/playwright');

const [payloadDir, itemsDir, outputFile] = process.argv.slice(2);
if (!payloadDir || !itemsDir || !outputFile) throw Error('Pass PAYLOAD_DIR ITEMS_DIR OUTPUT_JSON');
const fromSet = process.argv[5] === '--set';
const first = Number(fromSet ? 0 : process.argv[5] || 141);
const last = Number(fromSet ? 0 : process.argv[6] || 193);
if (!fromSet && (!Number.isInteger(first) || !Number.isInteger(last) || first > last || last - first > 255))
  throw Error('Invalid page range');
const rawSet = fromSet ? JSON.parse(fs.readFileSync(process.argv[6])) : null;
const setEntries = Array.isArray(rawSet) ? rawSet : rawSet?.cachedPages ?? rawSet?.originals ?? [];
const ids = fromSet ? setEntries.map(entry => String(
  typeof entry === 'object' ? entry.id ?? entry.page ?? entry.sampleIndex : entry)) :
  Array.from({ length: last - first + 1 }, (_, offset) => String(first + offset));
if (!ids.length || ids.length > 256 || new Set(ids).size !== ids.length || ids.some(id => !id || id === 'undefined'))
  throw Error('Invalid page ID set');
const typography = fs.readFileSync(path.resolve(__dirname,
  '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserOverlayTypography.swift'), 'utf8');
const start = typography.indexOf('    const aidokuContainBalloonText =');
const end = typography.indexOf('    // Last geometry-only polish', start);
if (start < 0 || end < start) throw Error('Final balloon typography function was not found');
const pass = typography.slice(start, end);
const fileFor = (directory, id, suffix) => {
  const names = [id, /^\d+$/.test(id) ? String(Number(id)).padStart(4, '0') : id, `case-${id}`];
  return names.flatMap(name => [path.join(directory, `${name}.${suffix}.json`),
    path.join(directory, `${name}.json`)]).find(fs.existsSync);
};

(async () => {
  const browser = await webkit.launch();
  const pages = [];
  try {
    const page = await browser.newPage({ viewport: { width: 430, height: 574 } });
    for (const id of ids) {
      const payloadPath = fileFor(payloadDir, id, 'payload');
      const itemsPath = fileFor(itemsDir, id, 'items');
      if (!payloadPath || !itemsPath) { pages.push({ id, status: 'missing-payload-or-render' }); continue; }
      const payload = JSON.parse(fs.readFileSync(payloadPath));
      const dump = JSON.parse(fs.readFileSync(itemsPath));
      if (!Array.isArray(payload.items) || !Array.isArray(dump.items)) {
        pages.push({ id, status: 'invalid-payload-or-render' }); continue;
      }
      const viewport = payload.viewport || [430, 574];
      if (Array.isArray(viewport) && viewport.length === 2)
        await page.setViewportSize({ width: Math.ceil(viewport[0]), height: Math.ceil(viewport[1]) });
      await page.setContent('<style>body{margin:0}</style><div id="root"></div>');
      const metrics = await page.evaluate(({ items, dump, pass }) => {
        const root = document.querySelector('#root');
        for (const item of dump.items) {
          const node = document.createElement('div');
          node.innerHTML = item.html || '';
          node.style.cssText = item.css || '';
          Object.assign(node.dataset, item.dataset || {});
          if (!node.dataset.aidokuImageOcrOverlay) node.dataset.aidokuImageOcrOverlay = 'item';
          if (!node.dataset.aidokuRegion) node.dataset.aidokuRegion = String(item.region);
          root.appendChild(node);
        }
        const lines = node => {
          const range = document.createRange(); range.selectNodeContents(node);
          const boxes = [...range.getClientRects()].filter(r => r.width > 0 && r.height > 0);
          return boxes.filter((r, i) => !boxes.some((other, j) => i !== j &&
            r.height > other.height * 1.65 && other.left >= r.left - .05 &&
            other.right <= r.right + .05 && other.top >= r.top - .05 &&
            other.bottom <= r.bottom + .05 && other.height < r.height - .1));
        };
        const inspect = () => items.filter(item => item.balloonInterior?.contourVerified &&
          !item.rotation && !item.vertical).map(item => {
          const node = [...root.children].find(n => n.dataset.aidokuRegion === String(item.id));
          if (!node || node.style.visibility === 'hidden') return null;
          const rects = lines(node), b = item.balloonInterior, f = item.sourceFrame;
          if (!rects.length || !Array.isArray(f) || !Array.isArray(b.center) || !Array.isArray(b.spans)) return null;
          const pad = .5 + (parseFloat(getComputedStyle(node).webkitTextStrokeWidth) || 0) / 2;
          const top = f[1] + b.rect[1] * f[3], height = b.rect[3] * f[3], bands = b.spans.length / 2;
          const inside = rects.every(r => {
            const first = Math.max(0, Math.floor((r.top - pad - top) / height * bands));
            const last = Math.min(bands - 1, Math.ceil((r.bottom + pad - top) / height * bands) - 1);
            if (r.top - pad < top || r.bottom + pad > top + height) return false;
            for (let row = first; row <= last; row++)
              if (b.spans[row * 2] < 0 || r.left - pad < f[0] + b.spans[row * 2] * f[2] - .05 ||
                r.right + pad > f[0] + b.spans[row * 2 + 1] * f[2] + .05) return false;
            return true;
          });
          const x = (Math.min(...rects.map(r => r.left)) + Math.max(...rects.map(r => r.right))) / 2;
          const y = (Math.min(...rects.map(r => r.top)) + Math.max(...rects.map(r => r.bottom))) / 2;
          return { id: String(item.id), inside, distance: Math.hypot(x - f[0] - b.center[0] * f[2],
            y - f[1] - b.center[1] * f[3]), fit: node.dataset.finalBalloonFit || null,
            rejected: node.dataset.finalBalloonFitRejected || null };
        }).filter(Boolean);
        const before = inspect();
        new Function('root', 'items', pass + '\n aidokuContainBalloonText(root,items);')(root, items);
        return { before, after: inspect() };
      }, { items: payload.items, dump, pass });
      const before = new Map(metrics.before.map(x => [x.id, x]));
      const pairs = metrics.after.map(after => ({ before: before.get(after.id), after })).filter(x => x.before);
      pages.push({ id, status: 'measured', balloons: pairs.length,
        insideBefore: pairs.filter(x => x.before.inside).length,
        insideAfter: pairs.filter(x => x.after.inside).length,
        newlyOutside: pairs.filter(x => x.before.inside && !x.after.inside).map(x => x.after.id),
        stillOutside: pairs.filter(x => !x.after.inside).map(x => x.after.id),
        improved: pairs.filter(x => x.after.distance < x.before.distance - .75).length,
        worsened: pairs.filter(x => x.before.inside && x.after.distance > x.before.distance + .75)
          .map(x => x.after.id),
        rejected: pairs.filter(x => x.after.rejected).map(x => x.after.id) });
    }
  } finally { await browser.close(); }
  const summary = { source: fromSet ? process.argv[6] : `cached pages ${first}-${last}`, total: pages.length,
    measured: pages.filter(x => x.status === 'measured').length,
    missing: pages.filter(x => x.status !== 'measured').map(x => x.id),
    balloons: pages.reduce((n, x) => n + (x.balloons || 0), 0),
    noBalloonPages: pages.filter(x => x.status === 'measured' && !x.balloons).map(x => x.id),
    newlyOutside: pages.flatMap(x => (x.newlyOutside || []).map(region => ({ page: x.id, region }))),
    stillOutside: pages.flatMap(x => (x.stillOutside || []).map(region => ({ page: x.id, region }))),
    worsened: pages.flatMap(x => (x.worsened || []).map(region => ({ page: x.id, region }))), pages };
  fs.writeFileSync(outputFile, JSON.stringify(summary, null, 2));
  console.log(JSON.stringify({ measured: summary.measured, total: summary.total,
    balloons: summary.balloons, newlyOutside: summary.newlyOutside.length,
    stillOutside: summary.stillOutside.length, worsened: summary.worsened.length, outputFile }));
  if (summary.measured !== ids.length || !summary.balloons ||
      summary.newlyOutside.length || summary.worsened.length)
    process.exitCode = 1;
})().catch(error => { console.error(error); process.exitCode = 1; });
