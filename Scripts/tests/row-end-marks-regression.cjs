// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
// Row-end punctuation just past the OCR box: probe ownership and restoration.
// node Scripts/tests/row-end-marks-regression.cjs [--source path/to/BrowserSourcePanelRestoration.swift]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const at = process.argv.indexOf('--source');
const file = at < 0 ? path.resolve(__dirname, '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserSourcePanelRestoration.swift') : process.argv[at + 1];
const script = fs.readFileSync(file, 'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const { marks, restore } = new Function(script + ';return {marks:aidokuRowEndMarks,restore:aidokuRestoreSourcePanel};')();
let passed = 0;
function test(name, run) { run(); passed++; console.log('PASS ' + name); }
const paper = [254, 254, 254], ink = [4, 4, 4], palette = { foreground: ink, background: paper, confidence: { foreground: 1 } };
function page(w, h) {
    const rgba = new Uint8ClampedArray(w * h * 4);
    for (let i = 0; i < w * h; i++) rgba.set([...paper, 255], i * 4);
    return { w, h, rgba, set(x, y, c = ink) { if (x >= 0 && y >= 0 && x < w && y < h) rgba.set([...c, 255], (y * w + x) * 4); } };
}
function rect(p, x0, y0, x1, y1, c) { for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) p.set(x, y, c); }
function ring(p, cx, cy, r, t = 2) {
    for (let y = cy - r - 1; y <= cy + r + 1; y++) for (let x = cx - r - 1; x <= cx + r + 1; x++) {
        const d = Math.hypot(x - cx, y - cy); if (d <= r && d > r - t) p.set(x, y);
    }
}
// A horizontal row of four 30 px "glyphs" (box x 10..140, y 20..52) in a 220 x 72 strip.
function row(p) { for (let k = 0; k < 4; k++) { rect(p, 12 + k * 32, 22, 38 + k * 32, 26); rect(p, 12 + k * 32, 22, 16 + k * 32, 50); rect(p, 34 + k * 32, 22, 38 + k * 32, 50); } }
const box = [10, 20, 130, 32], glyph = 30;
// The probe strip past the end starts inside the box (as in the overlay).
function endStrip(p, from = 134) {
    const w = p.w - from, out = new Uint8ClampedArray(w * p.h * 4);
    for (let y = 0; y < p.h; y++) out.set(p.rgba.subarray((y * p.w + from) * 4, (y * p.w + p.w) * 4), y * w * 4);
    return { rgba: out, w, h: p.h, box: [box[0] - from, box[1], box[2], box[3]], from };
}
function probe(p) { const s = endStrip(p); return marks(s.rgba, s.w, s.h, s.box, glyph, palette, false, 'end', []).map(r => [r[0] + s.from, r[1], r[2], r[3]]); }

test('full-width period past the row end is owned', () => {
    const p = page(220, 72); row(p); ring(p, 152, 44, 5);
    const found = probe(p);
    assert.equal(found.length, 1);
    assert.ok(found[0][0] >= 146 && found[0][0] + found[0][2] <= 159, JSON.stringify(found));
});
test('comma and wave dash are owned; an ellipsis run is owned whole', () => {
    const p = page(220, 72); row(p); rect(p, 148, 42, 152, 50); rect(p, 150, 50, 152, 54);
    assert.equal(probe(p).length, 1);
    const q = page(220, 72); row(q); rect(q, 146, 36, 170, 39);
    assert.equal(probe(q).length, 1, 'a flat wave up to a glyph long');
    const e = page(220, 72); row(e); for (const x of [146, 158, 170]) rect(e, x, 40, x + 4, 44);
    assert.equal(probe(e).length, 3);
});
test('widely spaced repeats are owned together or not at all', () => {
    const p = page(260, 72); row(p); rect(p, 146, 40, 150, 44); rect(p, 176, 40, 180, 44);
    assert.equal(probe(p).length, 2, 'dots about a glyph apart');
    const q = page(260, 72); row(q); rect(q, 146, 40, 150, 44); rect(q, 196, 40, 200, 44);
    assert.deepEqual(probe(q), [], 'the second dot is out of reach: none is erased');
    const e = page(220, 72); row(e); for (const x of [146, 176, 206]) rect(e, x, 40, x + 4, 44);
    const s = endStrip(e), run = marks(s.rgba, s.w, s.h, s.box, glyph, palette, false, 'end', []);
    assert.equal(run.length, 3);
    assert.equal(run.open, true, 'a run reaching the strip end may continue out of view');
    const f = page(320, 72); row(f); for (const x of [146, 176, 206]) rect(f, x, 40, x + 4, 44);
    const t = endStrip(f);
    assert.ok(!marks(t.rgba, t.w, t.h, t.box, glyph, palette, false, 'end', []).open, 'closed on a longer strip');
});
test('a tall single stroke must hug the row', () => {
    const p = page(220, 72); row(p); rect(p, 143, 24, 146, 50);
    assert.equal(probe(p).length, 1, 'a closing bracket next to the last glyph');
    const q = page(220, 72); row(q); rect(q, 148, 24, 151, 50);
    assert.deepEqual(probe(q), [], 'a detached bar is a letter or art');
});
test('a balloon outline between the row and the mark ends the row', () => {
    const p = page(220, 72); row(p); for (let y = 0; y < 72; y++) rect(p, 146, y, 148, y + 1); ring(p, 160, 44, 5);
    assert.deepEqual(probe(p), []);
    // A faint grey outline (below the ink level) blocks too.
    const q = page(220, 72); row(q); for (let y = 0; y < 72; y++) rect(q, 146, y, 147, y + 1, [170, 170, 170]); ring(q, 160, 44, 5);
    assert.deepEqual(probe(q), []);
});
test('a mark fused with the frame, art or texture is never owned', () => {
    const p = page(220, 72); row(p); rect(p, 146, 36, 170, 39); rect(p, 170, 0, 173, 72);
    assert.deepEqual(probe(p), [], 'wave fused with a frame line');
    const d = page(220, 72); row(d); for (let x = 146; x < 220; x += 9) rect(d, x, 42, x + 4, 45);
    assert.deepEqual(probe(d), [], 'dashed border / dot pattern');
    const t = page(220, 72); row(t); ring(t, 152, 44, 5); for (let x = 144; x < 220; x += 2) { t.set(x, 36, [120, 120, 120]); t.set(x, 37, [120, 120, 120]); }
    assert.deepEqual(probe(t), [], 'no clear ring');
});
test('marks outside the rows, too far, too large or in another caption stay', () => {
    const p = page(220, 72); row(p); ring(p, 152, 64, 5);
    assert.deepEqual(probe(p), [], 'below the rows');
    const f = page(220, 72); row(f); ring(f, 172, 44, 5);
    assert.deepEqual(probe(f), [], 'past .75 glyph');
    const g = page(220, 72); row(g); rect(g, 146, 24, 172, 50);
    assert.deepEqual(probe(g), [], 'glyph-sized');
    const o = page(220, 72); row(o); ring(o, 152, 44, 5);
    const s = endStrip(o);
    assert.deepEqual(marks(s.rgba, s.w, s.h, s.box, glyph, palette, false, 'end', [[140 - s.from, 30, 30, 30]]), [], 'excluded box');
});
test('a near mark that fails makes the run ambiguous', () => {
    // The second mark is not in the caption's ink (no dark core): nothing of the run is owned.
    const p = page(220, 72); row(p); rect(p, 146, 40, 150, 44); rect(p, 156, 40, 160, 44, [110, 110, 110]);
    assert.deepEqual(probe(p), []);
});
test('opening marks: close only, unless they pair with the closing mark', () => {
    const p = page(220, 72); row(p);
    const start = (q, pair) => {
        const w = 60, out = new Uint8ClampedArray(w * q.h * 4);
        for (let y = 0; y < q.h; y++) out.set(q.rgba.subarray(y * q.w * 4, (y * q.w + w) * 4), y * w * 4);
        return marks(out, w, q.h, box, glyph, palette, false, 'start', [], pair);
    };
    // Shift the row right so there is room before it.
    const q = page(220, 72); for (let k = 0; k < 4; k++) rect(q, 28 + k * 32, 22, 54 + k * 32, 26);
    const b = [26, 20, 130, 32];
    const s = (r, pair) => { const w = 60, out = new Uint8ClampedArray(w * r.h * 4);
        for (let y = 0; y < r.h; y++) out.set(r.rgba.subarray(y * r.w * 4, (y * r.w + w) * 4), y * w * 4);
        return marks(out, w, r.h, b, glyph, palette, false, 'start', [], pair); };
    rect(q, 3, 30, 15, 42);
    assert.deepEqual(s(q, null), [], 'a square .4 glyph before the start is too far without a pair');
    assert.equal(s(q, [12, 12]).length, 1, 'paired with a matching closing square');
    assert.equal(start(p, null).length, 0);
});
test('restoration erases an owned row-end mark and nothing else', () => {
    const p = page(220, 72); row(p); ring(p, 152, 44, 5); rect(p, 200, 0, 203, 72);
    const found = probe(p);
    const plain = restore(p.rgba, p.w, p.h, box, palette, { readabilityGate: true });
    const owned = restore(p.rgba, p.w, p.h, box, palette, { readabilityGate: true, rowEndMarks: found });
    assert.ok(plain && owned);
    const at = (o, x, y) => o.rgba[(y * p.w + x) * 4 + 3];
    assert.equal(at(plain, 152, 39), 0, 'without ownership the mark stays');
    assert.equal(at(owned, 152, 39), 255, 'the owned mark is erased');
    for (let y = 0; y < 72; y++) assert.equal(at(owned, 201, y), 0, 'the frame line stays');
    let same = true;
    for (let i = 0; i < p.w * p.h; i++) { const x = i % p.w; if (x < 140 && plain.rgba[i * 4 + 3] !== owned.rgba[i * 4 + 3]) same = false; }
    assert.ok(same, 'the body erasure is unchanged');
});
console.log(`row-end marks: ${passed} passed`);
