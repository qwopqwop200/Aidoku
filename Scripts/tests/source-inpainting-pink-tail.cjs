// Captured native WebKit crop from the submitted pink vertical-tail incident.
// The OCR body ends before the tail; only independently recovered auxiliary
// ownership may authorize its erasure. Keep the source crop and border intact.
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), zlib = require('node:zlib'), crypto = require('node:crypto');
const f = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-pink-tail.json')));
const source = fs.readFileSync(path.join(__dirname,
    '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift'), 'utf8');
const script = source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore = new Function(script + ';return aidokuRestoreSourcePanel;')();
const rgba = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64')));
const hash = () => crypto.createHash('sha256').update(rgba).digest('hex');
assert.equal(hash(), f.sha256);
const result = restore(rgba, f.w, f.h, f.b, f.palette, f.options);
assert.ok(result);
assert.equal(result.sourceErasureVerified, true);
const tail = f.options.auxiliary[0];
let ink = 0;
for (let y = 0; y < f.h; y++) for (let x = 0; x < f.w; x++) {
    const i = (y * f.w + x) * 4;
    if (x < 2 || y < 2 || x >= f.w - 2 || y >= f.h - 2)
        assert.equal(result.rgba[i + 3], 0, 'crop boundary stays untouched');
    if (y <= f.b[1] + f.b[3] || x < tail[0] || x >= tail[0] + tail[2] || y >= tail[1] + tail[3]) continue;
    if (rgba[i] - rgba[i + 1] < 65 || rgba[i + 2] - rgba[i + 1] < 35) continue;
    ink++;
    assert.equal(result.rgba[i + 3], 255, 'every observed tail pixel beyond the body must be painted');
    assert.ok(result.rgba[i] - result.rgba[i + 1] < 65, 'no source pink remains in the repaired tail');
}
assert.ok(ink >= 100, 'actual tail contains substantial ink outside the OCR body');
assert.equal(hash(), f.sha256, 'source pixels remain immutable');
// Without measured ownership this exact crop cannot certify complete source
// erasure: stale layout payloads must be invalidated when OCR metadata changes.
const stale = restore(rgba, f.w, f.h, f.b, f.palette, { ...f.options, auxiliary: [] });
let retained = 0;
for (let y = Math.ceil(f.b[1] + f.b[3]); y < tail[1] + tail[3]; y++)
    for (let x = Math.ceil(tail[0]); x < tail[0] + tail[2]; x++) {
        const i = (y * f.w + x) * 4;
        if (rgba[i] - rgba[i + 1] >= 65 && rgba[i + 2] - rgba[i + 1] >= 35 && !stale?.rgba[i + 3]) retained++;
    }
assert.ok(retained > 0, 'missing auxiliary geometry reproduces the stale-layout defect');
console.log(`PASS native pink tail: ${ink} source pixels erased; ${retained} stale-layout pixels reproduce the defect`);
