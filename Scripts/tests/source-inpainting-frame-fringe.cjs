const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), zlib = require('node:zlib'), crypto = require('node:crypto');
const script = fs.readFileSync(path.join(__dirname,
    '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserSourcePanelRestoration.swift'), 'utf8')
    .match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const { restore, fringe, observed } = new Function(script +
    ';return {restore:aidokuRestoreSourcePanel,fringe:aidokuPreserveFrameFringe,observed:aidokuRestoreObservedSourcePanel};')();
// Isolate the classifier contract from later palette retries and halo repair.
// A frozen hash of the entire pipeline incorrectly rejects those independent
// changes. With identical current reconstruction, classification alone must
// still leave every repair pixel exactly unchanged.
const withoutClassification = new Function(script +
    ';aidokuPreserveFrameFringe=()=>0;return aidokuRestoreObservedSourcePanel;')();
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-frame-fringe.json')));
for (const f of fixture.fixtures) {
    const rgba = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64')));
    assert.equal(hash(rgba), f.sha256);
    const result = restore(rgba, f.w, f.h, f.b, f.palette, f.options);
    assert.ok(result);
    assert.equal(result.sourceErasureVerified, true, `${f.name}: contour fringe must not force a readability panel`);
    assert.equal(result.sourceRemainingInk, 0);
    assert.equal(result.sourceFramePixels, 0);
    const [x, y] = f.preservedContour;
    assert.equal(result.rgba[(y * f.w + x) * 4 + 3], 0, 'keep original contour pixels');
    if (f.name === 'device-contour-fringe') {
        assert.ok(result.erased >= 80000, 'retain the observed full white halo instead of a core-only repair');
        assert.equal(result.method, 'local-diffusion');
    }
    const options = { ...f.options, ...(f.name === 'device-contour-fringe' ? { compactMask: true } : {}) };
    const classified = observed(rgba, f.w, f.h, f.b, f.palette, options);
    const unclassified = withoutClassification(rgba, f.w, f.h, f.b, f.palette, options);
    assert.ok(classified && unclassified, 'both classifier states must reconstruct the captured page');
    assert.deepEqual(classified.rgba, unclassified.rgba, 'fringe classification alone never changes repair pixels');
    assert.equal(hash(rgba), f.sha256, 'input remains immutable');
}

// Ownership requires an exterior frame, a color ramp and multiple supporting
// core pixels. It cannot spread, erase drawing, or certify interior ink.
function control({ core = false, painted = false, interior = false, wrongColor = false, neighbors = 2 } = {}) {
    const w = 16, h = 16, b = [3, 3, 10, 10], rgba = new Uint8ClampedArray(w * h * 4).fill(255);
    const raw = new Uint8Array(w * h), mask = raw.slice(), protectedInk = raw.slice(), frame = raw.slice();
    const x = interior ? 8 : 12, y = 8, i = y * w + x;
    rgba.set(wrongColor ? [230, 40, 40, 255] : [100, 170, 235, 255], i * 4);
    protectedInk[i] = 1; raw[i] = Number(core); mask[i] = Number(painted);
    for (let k = 0; k < neighbors; k++) {
        const j = (y + k) * w + x + 1;
        frame[j] = raw[j] = protectedInk[j] = 1;
        rgba.set([0, 120, 220, 255], j * 4);
    }
    const beforeMask = hash(mask), beforeProtected = hash(protectedInk), beforePixels = hash(rgba);
    const count = fringe(rgba, w, h, b, [255, 255, 255], raw, mask, protectedInk, frame);
    assert.equal(hash(mask), beforeMask); assert.equal(hash(protectedInk), beforeProtected); assert.equal(hash(rgba), beforePixels);
    return count;
}
assert.equal(control(), 1);
for (const options of [{ core: true }, { painted: true }, { interior: true }, { wrongColor: true }, { neighbors: 1 }, { neighbors: 0 }])
    assert.equal(control(options), 0, JSON.stringify(options));
console.log(`PASS: ${fixture.fixtures.length} captured contour fringes and 7 ownership controls`);
