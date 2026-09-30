// Run against fresh production-renderer DOM dumps for the two reported pages.
// Usage: node Scripts/tests/captured-panel-release-regression.cjs <replay-output-directory>
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const directory = process.argv[2];
assert.ok(directory, 'a freshly rendered real-page output directory is required');
for (const [page, region] of [['case-13', '3'], ['case-15', '1']]) {
    const dump = JSON.parse(fs.readFileSync(path.join(directory, `${page}.items.json`), 'utf8'));
    const item = dump.items.find(value => value.region === region);
    assert.ok(item && !item.hidden, `${page}: reported caption must remain visible`);
    assert.equal(item.dataset.sourceBackgroundColor, 'inpainted', `${page}: restore the original surface`);
    assert.equal(item.dataset.glyphPlateReleased, 'true', `${page}: release the opaque fallback`);
    assert.equal(item.background, 'rgba(0, 0, 0, 0)', `${page}: caption must have transparent backing`);
    assert.ok(item.fontSize >= 8, `${page}: removing a panel must not hide the caption by shrinking it`);
    assert.equal(item.overflowX, 0, `${page}: caption must remain horizontally contained`);
    assert.equal(item.overflowY, 0, `${page}: caption must remain vertically contained`);
    assert.ok(!dump.layers.some(layer =>
        ['source-readability-panel', 'source-readability-backing', 'source-rotated-panel'].includes(layer.kind)),
    `${page}: no opaque fallback may remain elsewhere on the page`);
    assert.ok(!dump.root.forcedSourceInpaintError && !dump.root.glyphPlateError,
        `${page}: source restoration and panel release must complete without an exception`);
    const forced = JSON.parse(dump.root.forcedSourceInpaintAudit || '[]');
    if (page === 'case-13') {
        const repair = forced.find(value => value.id === region);
        assert.equal(repair?.reason, 'accepted', 'the unverified local erasure needs a certified replacement');
        assert.equal(repair.postFillPaletteInkPixels, 0, 'certified replacement must leave no source palette ink');
        assert.ok(repair.pixels <= 750000, 'repair must retain the per-caption pixel budget');
        assert.ok(repair.paintShare < 0.5, 'repair must remain localized rather than repainting the full crop');
    }
}
console.log('PASS real captured panel incidents: visible readable captions, transparent backings, certified bounded repair');
