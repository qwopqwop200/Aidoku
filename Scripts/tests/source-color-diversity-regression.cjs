// Real, visually reviewed text crops. Run without the 20,000-page corpus.
// --source FILE --measure-only compares a frozen production baseline.
// --report FILE writes every match/miss, source role, and sampling budget.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const zlib = require('node:zlib');
const crypto = require('node:crypto');
const { harness, raster, rect } = require('./source-color-test-harness.cjs');
const arg = name => process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : null;
const fixture = JSON.parse(fs.readFileSync(arg('--fixtures') || path.join(__dirname, 'fixtures/source-color-diversity.json')));
// Export the same RGBA fixtures to the opt-in native replay without Pillow,
// the corpus, or a PNG package. Each PNG uses unfiltered RGBA scanlines.
if (arg('--export-replay')) {
    const directory = arg('--export-replay'); fs.mkdirSync(directory, { recursive: true });
    const replayName = arg('--replay-name') || 'color-diversity';
    assert.match(replayName, /^[a-z][a-z-]+$/);
    const crc32 = data => { let crc = 0xffffffff; for (const byte of data) { crc ^= byte;
        for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0); } return (crc ^ 0xffffffff) >>> 0; };
    const chunk = (type, data) => { const name = Buffer.from(type), length = Buffer.alloc(4), crc = Buffer.alloc(4);
        length.writeUInt32BE(data.length); crc.writeUInt32BE(crc32(Buffer.concat([name, data])));
        return Buffer.concat([length, name, data, crc]); };
    const manifest = [];
    for (const f of fixture.fixtures) {
        assert.match(f.id, /^[a-z][0-9]+$/);
        const rgba = zlib.inflateSync(Buffer.from(f.rgba, 'base64'));
        assert.equal(crypto.createHash('sha256').update(rgba).digest('hex'), f.pixelSHA256);
        const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(f.width); ihdr.writeUInt32BE(f.height, 4); ihdr[8] = 8; ihdr[9] = 6;
        const stride = f.width * 4, scanlines = Buffer.alloc((stride + 1) * f.height);
        for (let y = 0; y < f.height; y++) rgba.copy(scanlines, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
        const png = Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr),
            chunk('IDAT', zlib.deflateSync(scanlines)), chunk('IEND', Buffer.alloc(0))]);
        const image = 'diversity-' + f.id + '.png'; fs.writeFileSync(path.join(directory, image), png);
        manifest.push({ name: f.id, image, regions: [{ bounds: f.bounds, source: f.source,
            expected: f.expected, acceptedColors: f.acceptedColors, outlineFreeDisplayColors: f.outlineFreeDisplayColors,
            requireColorMatch: f.requireColorMatch }] });
    }
    fs.writeFileSync(path.join(directory, replayName + '-replay.json'), JSON.stringify(manifest));
    if (arg('--baseline-source')) {
        const swift = fs.readFileSync(arg('--baseline-source'), 'utf8');
        const match = swift.match(/static let script = """\n([\s\S]*?)\n    """/); assert.ok(match);
        fs.writeFileSync(path.join(directory, replayName + '-baseline.js'), match[1]);
    }
    console.log(`Exported ${manifest.length} native color fixtures to ${directory}`);
    if (process.argv.includes('--export-only')) process.exit(0);
}
assert.equal(new Set(fixture.fixtures.map(f => f.id)).size, fixture.fixtures.length, 'fixture IDs are unique');
assert.equal(new Set(fixture.fixtures.map(f => f.evaluationGroup)).size, fixture.fixtures.length,
    'each real-image fixture represents a distinct work group');
const h = harness(null, false, arg('--source'));
vm.runInContext('globalThis.displayInk=aidokuSourceDisplayInk;', h.context);
// Negative evidence controls exercise the production helper, including bounds
// validation; a page's mere palette is not evidence of text.
vm.runInContext('globalThis.glyphPalette=typeof aidokuObservedGlyphPalette === "function" ? aidokuObservedGlyphPalette : null;', h.context);
if (h.context.glyphPalette && !arg('--source')) {
    const controls = [raster(120, 80, [110, 80, 130]), raster(120, 80, [245, 235, 210])];
    for (let x = 0; x < 120; x++) { rect(controls[1], x, 0, 1, 4, [25, 25, 25]); rect(controls[1], x, 76, 1, 4, [25, 25, 25]); }
    for (let y = 0; y < 80; y++) { rect(controls[1], 0, y, 4, 1, [25, 25, 25]); rect(controls[1], 116, y, 4, 1, [25, 25, 25]); }
    const solidArt = raster(120, 80, [245, 235, 210]);
    for (let i = 0; i < 3; i++) rect(solidArt, 24 + i * 25, 25, 15, 30, [40, 120, 80]);
    controls.push(solidArt);
    for (const image of controls) assert.equal(h.context.glyphPalette(image.data, 120, 80, [10, 10, 100, 60]).length, 0);
    const transparent = controls[0].data.slice(); transparent[3] = 0;
    assert.equal(h.context.glyphPalette(transparent, 120, 80, [10, 10, 100, 60]), null);
    for (const bounds of [null, [1, 2, -1, 2], [1, 2, NaN, 4]]) assert.equal(h.context.glyphPalette(controls[0].data, 120, 80, bounds), null);
    assert.equal(h.context.glyphPalette(new Uint8ClampedArray(256 * 256 * 4), 256, 256, [0, 0, 256, 256]), null);
    console.log('PASS: flat panels, frames, solid art, transparency and invalid/oversized inputs reject glyph evidence');
}
const report = [];
for (const f of fixture.fixtures) {
    const data = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64')));
    assert.equal(data.length, f.width * f.height * 4);
    assert.equal(crypto.createHash('sha256').update(data).digest('hex'), f.pixelSHA256);
    const image = { complete: true, naturalWidth: f.width, naturalHeight: f.height, data };
    const budget = { pixels: 393216, detailPixels: 98304, remainingSamples: 1 };
    const sampler = h.sampler(image, true, 'ocr', budget), result = sampler.sample(f.bounds);
    const color = h.context.displayInk(result);
    const error = color ? Math.min(...f.acceptedColors.map(rgb => Math.max(...rgb.map((v, i) => Math.abs(v - color[i]))))) : 255;
    report.push({ id: f.id, split: f.split, category: f.category, expected: f.acceptedColors, color, error,
        matched: error <= 25, stats: { ...sampler.stats }, result });
    if (!process.argv.includes('--measure-only')) {
        assert.ok(error <= (f.knownLimitation?.maximumError ?? 25), `${f.id}: ${color}, expected ${f.acceptedColors}; error ${error}`);
        if (f.outlineFreeDisplayColors) assert.ok(color && f.outlineFreeDisplayColors.some(rgb =>
            rgb.every((v, i) => Math.abs(v - color[i]) <= 25)), `${f.id}: preserve defining ink on the pale backing`);
    }
    assert.ok(budget.pixels >= 0 && budget.detailPixels >= 0);
    assert.ok(sampler.stats.pixels <= 393216);
    assert.strictEqual(sampler.sample(f.bounds), result);
    assert.equal(sampler.stats.hits, 1);
    assert.equal(crypto.createHash('sha256').update(data).digest('hex'), f.pixelSHA256, 'source pixels are immutable');
}
if (arg('--report')) fs.writeFileSync(arg('--report'), JSON.stringify({ methodology: fixture.methodology, cases: report }, null, 2));
for (const split of new Set(report.map(row => row.split))) {
    const rows = report.filter(r => r.split === split);
    console.log(`${split}: ${rows.filter(r => r.matched).length}/${rows.length} reference colors matched`);
}
const missed = report.filter(r => !r.matched);
console.log(`${report.length - missed.length}/${report.length} reference colors matched; ${missed.length} tracked limitations`);
for (const r of missed) console.log(`LIMITATION ${r.id}: ${r.color ?? 'abstained'}, reference ${JSON.stringify(r.expected)}, RGB error ${r.error}`);
