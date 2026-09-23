// Raster ground truth across scripts, hue, polarity, gradients and antialiased outlines.
// --measure-only --color-source FILE --restoration-source FILE --report FILE
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const crypto = require('node:crypto');
const { resize } = require('./source-color-test-harness.cjs');
const arg = name => process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : null;
const root = path.resolve(__dirname, '../../Aidoku/Core/Translation/NativeEngine/Overlay');
const script = file => fs.readFileSync(file, 'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const document = { createElement() {
    let draw;
    return { getContext() { return {
        drawImage(image, sx, sy, sw, sh, dx, dy, w, h) { draw = { image, sx, sy, sw, sh, w, h }; },
        getImageData() { const d = draw; return { data: resize(d.image, d.sx, d.sy, d.sw, d.sh, d.w, d.h) }; }
    }; } };
} };
const [sample, display] = new Function('document', script(arg('--color-source') || path.join(root, 'BrowserSourceTextColor.swift')) +
    ';return [aidokuSourceColorSampler, aidokuSourceDisplayInk];')(document);
const restore = new Function(script(arg('--restoration-source') || path.join(root, 'BrowserSourcePanelRestoration.swift')) +
    ';return aidokuRestoreSourcePanel;')();
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-segmentation.json')));
const decode = s => new Uint8ClampedArray(zlib.inflateSync(Buffer.from(s, 'base64')));
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const rows = [];
for (const f of fixture.fixtures) {
    const rgba = decode(f.rgba), clean = decode(f.clean), labels = decode(f.labels);
    assert.equal(hash(rgba), f.pixelSHA256);
    const budget = { pixels: 393216, detailPixels: 98304 };
    const sampler = sample({ complete: true, naturalWidth: f.w, naturalHeight: f.h, data: rgba }, true, 'ocr', budget);
    const palette = sampler.sample(f.b.map((v, i) => v / (i % 2 ? f.h : f.w)));
    const color = display(palette), colorError = color ? Math.max(...color.map((v, c) => Math.abs(v - f.foreground[c]))) : 255;
    const restored = restore(rgba, f.w, f.h, f.b, palette, { readabilityGate: true });
    let ink = 0, erased = 0, error = 0, outsideError = 0, outside = 0;
    for (let i = 0; i < f.w * f.h; i++) {
        const painted = restored?.rgba[i * 4 + 3] === 255;
        if (labels[i] >= 32 && Math.max(...[0, 1, 2].map(c => Math.abs(rgba[i * 4 + c] - clean[i * 4 + c]))) >= 12) {
            ink++; erased += painted;
            for (let c = 0; c < 3; c++) error += Math.abs((painted ? restored.rgba : rgba)[i * 4 + c] - clean[i * 4 + c]);
        }
        if (painted && labels[i] === 0) {
            outside++;
            for (let c = 0; c < 3; c++) outsideError += Math.abs(restored.rgba[i * 4 + c] - clean[i * 4 + c]);
        }
        const x = i % f.w, y = Math.floor(i / f.w);
        if (x < 8 || y < 8 || x >= f.w - 8 || y >= f.h - 8) assert.ok(!painted, `${f.id}: crop boundary preserved`);
    }
    const row = { id: f.id, color, colorError, ink, erased, recall: erased / ink,
        mae: error / (ink * 3), outsideMAE: outsideError / Math.max(1, outside * 3), pixels: sampler.stats.pixels };
    rows.push(row);
    assert.equal(hash(rgba), f.pixelSHA256, 'input is immutable');
    assert.ok(budget.pixels >= 0 && budget.detailPixels >= 0);
    if (!process.argv.includes('--measure-only')) {
        assert.ok(colorError <= 25, `${f.id}: source color error ${colorError}`);
        assert.ok(row.recall >= .99, `${f.id}: ink coverage ${row.recall}`);
        assert.ok(row.mae <= 5 && row.outsideMAE <= 2, `${f.id}: background error ${row.mae}/${row.outsideMAE}`);
    }
}
if (arg('--report')) fs.writeFileSync(arg('--report'), JSON.stringify({ methodology: fixture.methodology, cases: rows }, null, 2));
console.log(`${rows.filter(r => r.colorError <= 25).length}/${rows.length} source colors within 25 RGB units`);
console.log(`${rows.filter(r => r.recall >= .99 && r.mae <= 5).length}/${rows.length} masks cover >=99% of observed ink with background MAE <=5`);
// Display-role validation may reject a halo without invalidating its observed
// ink pixels. These captured dense/colored source crops require that separation.
const owned = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-owned-ink.json')));
for (const f of process.argv.includes('--measure-only') ? [] : owned) {
    const rgba = decode(f.rgba), before = hash(rgba);
    const options = { readabilityGate: true, vertical: f.vertical, sampleScale: f.scale };
    const actual = sample({ complete: true, naturalWidth: f.w, naturalHeight: f.h, data: rgba }, true)
        .sample(f.b.map((v, i) => v / (i % 2 ? f.h : f.w)));
    assert.ok(actual?.sourceInk?.foreground && actual.sourceInk.background, 'sampler retains independent erasure evidence');
    assert.ok(restore(rgba, f.w, f.h, f.b, actual, options), `${f.name}/${f.id}: integrated sampler still restores`);
    const palette = { ...f.displayPalette, sourceInk: f.sourceInk };
    const serialized = JSON.stringify(palette);
    const restored = restore(rgba, f.w, f.h, f.b, palette, options);
    const reference = restore(rgba, f.w, f.h, f.b, f.sourceInk, options);
    assert.ok(reference && restored, `${f.name}/${f.id}: observed ink remains usable`);
    assert.deepEqual(restored.rgba, reference.rgba, 'same independently validated mask and background');
    assert.equal(JSON.stringify(palette), serialized, 'display roles remain untouched');
    assert.equal(hash(rgba), before, 'source stays immutable');
}
if (!process.argv.includes('--measure-only')) console.log(`${owned.length} captured erasure-evidence regressions passed`);
// Human-reviewed contour pixels must survive, and textured crossing art must
// not be whitened just because its nearby donor pixels resemble smooth paper.
const art = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-art-guard.json')));
for (const f of process.argv.includes('--measure-only') ? [] : art.fixtures) {
    const rgba = decode(f.rgba), before = hash(rgba);
    const out = restore(rgba, f.w, f.h, f.b, f.palette,
        { readabilityGate: true, vertical: f.vertical, sampleScale: f.scale });
    assert.equal(!!out, f.expectAccepted, `${f.name}/${f.id}: reviewed art protection`);
    for (const i of f.protectedPixels) assert.equal(out.rgba[i * 4 + 3], 0, 'balloon contour is preserved');
    assert.equal(hash(rgba), before, 'source stays immutable');
}
if (!process.argv.includes('--measure-only')) console.log(`${art.fixtures.length} captured artwork protection regressions passed`);
// A native Canvas halo can be one pixel narrower than the deterministic
// resampler. Nearby unobscured sky, reviewed as a smooth vertical gradient,
// provides approximate color references independent of the reconstruction.
if (!process.argv.includes('--measure-only')) {
    const f = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-gradient-fringe.json')));
    const rgba = decode(f.rgba), before = hash(rgba);
    const out = restore(rgba, f.w, f.h, f.b, f.palette,
        { readabilityGate: true, vertical: f.vertical, sampleScale: f.scale });
    assert.ok(out);
    for (const probe of f.probes) {
        const i = probe.pixel[1] * f.w + probe.pixel[0], j = probe.reference[1] * f.w + probe.reference[0];
        assert.equal(out.rgba[i * 4 + 3], 255, 'source fringe is covered');
        for (let c = 0; c < 3; c++) assert.ok(Math.abs(out.rgba[i * 4 + c] - rgba[j * 4 + c]) <= f.tolerance,
            'source halo does not lighten the reconstructed sky');
    }
    assert.equal(hash(rgba), before);
    console.log('Native-width gradient fringe regression passed');
}
// Additional work-disjoint development crops: thin ink, pale subtitles, colored
// UI, and repeated background patterns. These are reviewed regression labels,
// not a pixel-gold corpus or the separate 205-work confirmation set.
if (!process.argv.includes('--measure-only')) {
    const expanded = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-expanded-environments.json')));
    for (const f of expanded.fixtures) {
        const rgba = decode(f.rgba), before = hash(rgba), budget = { pixels: 393216, detailPixels: 98304 };
        assert.equal(before, f.pixelSHA256);
        const sampler = sample({ complete: true, naturalWidth: f.w, naturalHeight: f.h, data: rgba }, true, 'ocr', budget);
        const palette = sampler.sample(f.b.map((v, i) => v / (i % 2 ? f.h : f.w)));
        if (f.expectedColor) {
            const color = display(palette);
            assert.ok(color && color.every((v, c) => Math.abs(v - f.expectedColor[c]) <= f.colorTolerance),
                `${f.name}: ${f.review}; observed ${color}, reference ${f.expectedColor}`);
        }
        if (typeof f.expectAccepted === 'boolean') {
            const out = restore(rgba, f.w, f.h, f.b, palette,
                { readabilityGate: true, vertical: f.vertical, sampleScale: f.scale });
            assert.equal(!!out, f.expectAccepted, `${f.name}: ${f.review}`);
            if (f.expectedSurface) assert.equal(out?.surfaceQuality?.reason, f.expectedSurface, 'pattern must not become a flat fill');
            for (const i of f.protectedPixels || []) assert.ok(!out?.rgba[i * 4 + 3], 'original balloon contour stays unpainted');
        }
        assert.equal(hash(rgba), before);
        assert.ok(budget.pixels >= 0 && budget.detailPixels >= 0 && sampler.stats.pixels <= 393216);
    }
    console.log(`${expanded.fixtures.length} expanded-environment regressions passed`);
}
