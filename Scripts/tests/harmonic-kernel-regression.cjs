// Compare the actual embedded WASM fill with the production JavaScript fallback.
// Covers linked and blocked donors, dense/sparse regions and shuffled traversal,
// preserving the same queue ordering, Float32 rounding and stopping rules.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const directory = path.resolve(__dirname, '../../Aidoku/Core/Translation/NativeEngine/Overlay');
const script = name => fs.readFileSync(path.join(directory, name + '.swift'), 'utf8')
    .match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restoration = script('BrowserSourcePanelRestoration');
const native = new Function(script('BrowserSourceTextColor') + restoration +
    ';return {fill:aidokuHarmonicFill,available:!!aidokuPixelKernels(1024)};')();
const fallback = new Function(restoration + ';return aidokuHarmonicFill;')();
assert.ok(native.available, 'must exercise WASM rather than silently compare two fallbacks');
let seed = 173, cases = 0;
const random = () => { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; return seed >>> 0; };
for (let sample = 0; sample < 128; sample++) {
    const width = 8 + random() % 33, height = 8 + random() % 33, n = width * height;
    const pixels = new Uint8ClampedArray(n * 4), blocked = new Uint8Array(n), paint = new Uint8Array(n), indices = [];
    for (let i = 0; i < n; i++) {
        pixels.set([random() % 256, random() % 256, random() % 256, 255], i * 4);
        blocked[i] = sample % 4 === 0 || random() % 5 === 0 ? 1 : 0;
    }
    for (let y = 1; y < height - 1; y++) for (let x = 1; x < width - 1; x++) {
        if (sample % 4 === 1 || random() % 3 !== 0) { indices.push(y * width + x); paint[y * width + x] = 1; }
    }
    if (sample % 2) for (let i = indices.length - 1; i > 0; i--) {
        const j = random() % (i + 1); [indices[i], indices[j]] = [indices[j], indices[i]];
    }
    const queue = Int32Array.from(indices);
    for (const accelerated of [false, true]) {
        const expected = pixels.slice(), actual = pixels.slice();
        fallback(expected, width, n, queue, queue.length, blocked, paint, accelerated);
        native.fill(actual, width, n, queue, queue.length, blocked, paint, accelerated);
        assert.deepEqual(actual, expected, `full RGBA sample ${sample}, accelerated=${accelerated}`);
        cases++;
    }
}
console.log(`PASS harmonic WASM / JavaScript fallback: ${cases} exact full-RGBA cases`);
