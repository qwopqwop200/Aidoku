// Native WebKit crops keep the actual device OCR, compression, palette and scale.
// These assert source removal and bounded artwork coverage, not just acceptance.
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), zlib = require('node:zlib'), crypto = require('node:crypto');
const at = process.argv.indexOf('--source');
const file = at < 0 ? path.resolve(__dirname, '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift') : process.argv[at + 1];
const script = fs.readFileSync(file, 'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore = new Function(script + ';return aidokuRestoreSourcePanel;')();
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-panel-incidents.json')));
let pixels = 0;
for (const f of fixture.fixtures) {
    const rgba = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64')));
    assert.equal(hash(rgba), f.sha256);
    const result = restore(rgba, f.w, f.h, f.b, f.palette, f.options);
    assert.ok(result, `${f.name}: must restore lettering instead of a flat plate`);
    assert.equal(result.preservedCore, 0, `${f.name}: no stranded source core`);
    const ink = f.palette.sourceInk || f.palette;
    const distance = (a, b) => Math.max(...a.map((v, c) => Math.abs(v - b[c])));
    const colors = [ink.foreground, ink.stroke].filter(c => c && distance(c, ink.background) >= 48);
    let total = 0, erased = 0;
    for (let y = 0; y < f.h; y++) for (let x = 0; x < f.w; x++) {
        const i = (y * f.w + x) * 4;
        if (x < 2 || y < 2 || x >= f.w - 2 || y >= f.h - 2)
            assert.equal(result.rgba[i + 3], 0, `${f.name}: context boundary stays intact`);
        if (x < f.b[0] || x >= f.b[0] + f.b[2] || y < f.b[1] || y >= f.b[1] + f.b[3]) continue;
        const rgb = [...rgba.subarray(i, i + 3)];
        if (distance(rgb, ink.background) < 40 || !colors.some(c => distance(c, rgb) <= 20)) continue;
        total++; if (result.rgba[i + 3]) erased++;
    }
    assert.ok(total > 100, `${f.name}: substantial observed lettering`);
    assert.ok(erased / total >= .999, `${f.name}: observed ink coverage ${erased}/${total}`);
    assert.equal(hash(rgba), f.sha256, 'input remains immutable');
    // JPEG chroma islands and antialiased fringe used to survive source
    // removal, become diffusion donors, and then force a dark caption/card.
    const residualProbes = {
        'color-columns-1': [64, 389], 'color-columns-5': [54, 620], 'white-columns-7': [40, 469],
        'white-columns-3': [101, 166]
    };
    const probe = residualProbes[f.name];
    if (probe) {
        const i = (probe[1] * f.w + probe[0]) * 4;
        assert.equal(result.rgba[i + 3], 255, `${f.name}: compressed ink island erased`);
        assert.equal(result.sourceErasureVerified, true, `${f.name}: complete erasure certified`);
        if (f.name === 'white-columns-3')
            assert.ok(Math.min(...result.rgba.subarray(i, i + 3)) >= 245,
                'partial purple fringe must not tint the reconstructed paper');
    }
    pixels += total;
    console.log(`PASS ${f.name}: ${erased}/${total} observed ink pixels`);
}
console.log(`${fixture.fixtures.length} native incident crops passed; ${pixels} source-ink pixels checked`);
for (const f of fixture.artControls) {
    const rgba = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64')));
    assert.equal(hash(rgba), f.sha256);
    assert.equal(restore(rgba, f.w, f.h, f.b, f.palette, f.options), null, `${f.name}: ${f.review}`);
    assert.equal(hash(rgba), f.sha256, 'protected source remains immutable');
}
console.log(`${fixture.artControls.length} native contour protection controls passed`);

for (const f of fixture.incompleteControls || []) {
    const rgba = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64')));
    assert.equal(hash(rgba), f.sha256);
    const result = restore(rgba, f.w, f.h, f.b, f.palette, f.options);
    assert.ok(result, `${f.name}: still restore independently owned glyphs`);
    assert.equal(result.sourceErasureVerified, false, `${f.name}: ${f.review}`);
    assert.equal(hash(rgba), f.sha256, 'source remains immutable');
}
console.log(`${fixture.incompleteControls?.length || 0} incomplete source-erasure controls passed`);
