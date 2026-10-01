// Actual WebKit artifacts from the captured source-position incident and three control pages.
// node Scripts/tests/source-anchor-replay-regression.cjs <overlay-four-defects replay directory>
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
assert.ok(root, 'Pass the real-page replay directory');
const read = file => JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
const centre = r => [r[0] + r[2] / 2, r[1] + r[3] / 2];
const error = (item, source) => {
  const f = source.sourceFrame, s = source.sourceBounds, c = centre(item.ink);
  return Math.hypot(c[0] - f[0] - (s[0] + s[2] / 2) * f[2], c[1] - f[1] - (s[1] + s[3] / 2) * f[3]);
};
const before = read('before/position.items.json').items.find(i => i.region === '4');
const afterPage = read('anchor-final/position.items.json');
const after = afterPage.items.find(i => i.region === '4');
const source = read('position.payload.json').items.find(i => i.id === '4');
assert.ok(error(before, source) > 8, 'Fixture must reproduce the displaced caption');
assert.ok(error(after, source) < 0.05, 'Final glyph ink stays at its source centre');
assert.ok(after.fontSize >= source.fontSize, 'Anchoring must not shrink below the planned readable size');
assert.equal(after.dataset.sourceBackgroundColor, 'inpainted');
assert.ok(!afterPage.layers.some(l => l.kind === 'source-readability-panel' && l.region === '4'));
for (let n = 1; n <= 3; n++) {
  const old = read(`holdout-before/holdout-${n}.items.json`);
  const fresh = read(`holdout-after/holdout-${n}.items.json`);
  const payload = read(`holdout-${n}.payload.json`);
  assert.equal(fresh.items.length, old.items.length);
  for (const item of fresh.items) {
    const prior = old.items.find(i => i.region === item.region);
    const planned = payload.items.find(i => i.id === item.region);
    assert.equal(item.text.replace(/\s+/g, ' '), prior.text.replace(/\s+/g, ' '));
    assert.equal(item.hidden, prior.hidden);
    for (const key of ['overflowX', 'overflowY']) assert.ok(item[key] <= prior[key] + 0.05);
    assert.ok(error(item, planned) <= error(prior, planned) + 0.05, 'No control caption moves farther from its source');
    if (item.fontSize !== prior.fontSize) {
      const anchored = error(item, planned) < 0.05 && item.fontSize >= planned.fontSize;
      // Replacing an opaque control card can require a slightly smaller font on
      // its verified restored surface. Bound that tradeoff and require actual contrast.
      const cleanSurface = prior.dataset.sourceBackgroundColor === 'readability-panel' &&
        item.dataset.sourceBackgroundColor === 'inpainted' && item.fontSize >= Math.max(9, prior.fontSize * 0.85) &&
        Number(item.dataset.sourceFinalMinimumContrast) >= 4.5;
      assert.ok(anchored || cleanSurface, 'Readable source anchor or bounded, contrast-proven card removal');
    }
  }
}
console.log('PASS source-centred final ink, readable font, inpainting, and three real-page controls');
