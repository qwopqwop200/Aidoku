// Run the production centering pass in WebKit: moved neighbours must remain
// collision obstacles while DOM measurements grow linearly with caption count.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { webkit } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const source = fs.readFileSync(path.join(__dirname,
    '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserOverlayView.swift'), 'utf8');
const start = source.indexOf('    // Final ink belongs to the measured balloon body');
const end = source.indexOf('    // Plates are final.', start);
assert.ok(start > 0 && end > start);
const pass = source.slice(start, end);
(async () => {
    const browser = await webkit.launch();
    try {
        const page = await browser.newPage({ viewport: { width: 800, height: 800 } });
        await page.setContent('<style>body{margin:0}</style><div id="root"></div>');
        const results = await page.evaluate(pass => {
            const run = (positions, targets) => {
                const root = document.querySelector('#root');
                root.replaceChildren();
                const items = positions.map((x, id) => {
                    const node = document.createElement('div');
                    node.dataset.aidokuImageOcrOverlay = 'item';
                    node.dataset.aidokuRegion = String(id);
                    node.style.cssText = `position:absolute;left:${x}px;top:100px;font:10px/12px monospace`;
                    node.textContent = 'AA';
                    root.append(node);
                    return { id, balloonInterior: { contourVerified: true } };
                });
                const nodes = [...root.children];
                const rect = node => { const r = document.createRange(); r.selectNodeContents(node); return r.getBoundingClientRect(); };
                const before = nodes.map(rect);
                const shapes = items.map((item, i) => ({ cx: targets[i] + before[i].width / 2,
                    cy: before[i].top + before[i].height / 2, outside: () => false }));
                let reads = 0, ranges = 0;
                const measure = Range.prototype.getBoundingClientRect;
                const create = document.createRange;
                Range.prototype.getBoundingClientRect = function () { reads++; return measure.call(this); };
                document.createRange = function () { ranges++; return create.call(this); };
                try {
                    new Function('root', 'items', 'opacity', 'cleanupImageGeometry', 'nativeBalloonShape', pass)
                        (root, items, 1, { frame: [0, 0, 800, 800] }, item => shapes[item.id]);
                } finally {
                    Range.prototype.getBoundingClientRect = measure;
                    document.createRange = create;
                }
                return { reads, ranges, left: nodes.map(n => parseFloat(n.style.left)),
                    shifted: nodes.map(n => Boolean(n.dataset.balloonCenterShift)) };
            };
            return {
                dense: run(Array.from({ length: 128 }, (_, i) => i * 40), Array.from({ length: 128 }, (_, i) => i * 40 + 3)),
                movedObstacle: run([0, 80], [40, 40]),
                vacatedSpace: run([0, 80], [40, 0])
            };
        }, pass);
        assert.equal(results.dense.ranges, 1);
        assert.equal(results.dense.reads, 256, 'one initial and one post-move measurement per caption');
        assert.ok(results.dense.shifted.every(Boolean));
        assert.deepEqual(results.movedObstacle.left, [40, 80], 'later caption must respect the moved neighbour');
        assert.deepEqual(results.movedObstacle.shifted, [true, false]);
        assert.deepEqual(results.vacatedSpace.left, [40, 0], 'later caption can occupy the vacated position');
        console.log('PASS WebKit centering: 128 captions, 256 Range reads / 1 Range allocation; updated collision bounds retained');
    } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
