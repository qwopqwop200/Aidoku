const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const directory = path.join(__dirname, '../../Aidoku/Core/Translation/NativeEngine/Overlay');
const script = name => fs.readFileSync(path.join(directory, name + '.swift'), 'utf8')
    .match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const w = 80, h = 80, n = w * h;
const rgba = new Uint8ClampedArray(n * 4);
for (let i = 0; i < n; i++) rgba.set([180, 170, 160, 255], i * 4);
for (let y = 25; y < 45; y++) for (let x = 30; x < 34; x++) rgba.set([20, 20, 20, 255], (y * w + x) * 4);
const before = rgba.slice();
const palette = {foreground: [20, 20, 20], background: [180, 170, 160]};
const options = {requireSafeDonors: true};
let donorSafe = false, segmentation = true, broadCalls = 0;
const context = vm.createContext({
    Uint8Array, Uint8ClampedArray, Int32Array,
    aidokuForcedTextMask() {
        if (!segmentation) return null;
        const mask = new Uint8Array(n), core = new Uint8Array(n), outline = new Uint8Array(n);
        for (let y = 25; y < 45; y++) for (let x = 30; x < 34; x++) mask[y*w+x] = core[y*w+x] = 1;
        Object.assign(mask, {sourceCoreCandidateMask: core, sourceOutlineCandidateMask: outline});
        return mask;
    },
    aidokuForcedDonorFill(input, width, height, mask) {
        if (!donorSafe) return null;
        const output = input.slice();
        for (let i = 0; i < n; i++) if (mask[i]) output.set([180, 170, 160, 255], i * 4);
        return {rgba: output, quality: {safe: true}, method: 'edge-aware-donors'};
    },
    aidokuFillFromDonorFront(input, width, count, queue, tail, mask) {
        broadCalls++;
        for (let k = 0; k < tail; k++) mask[queue[k]] = 0;
    },
    aidokuHarmonicFill() { broadCalls++; }
});
vm.runInContext(script('BrowserForcedSourceInpainting') + script('BrowserForcedComponentInpainting'), context);
for (const name of ['aidokuForceInpaintSource', 'aidokuForceInpaintSourceComponent']) {
    const fill = context[name];
    assert.equal(fill(rgba, w, h, [25, 20, 20, 30], palette, options), null,
        'unrecoverable title must retain the panel');
    assert.equal(fill.lastFailure, 'display-donors-unverified');
    assert.equal(broadCalls, 0, 'unsafe title cannot reach broad interpolation');
    donorSafe = true;
    assert.ok(fill(rgba, w, h, [25, 20, 20, 30], palette, options)?.sourceErasureVerified,
        'title with safe glyph donors still uses inpainting');
    donorSafe = false;
    assert.equal(fill(rgba, w, h, [25, 20, 20, 30], palette, {}), null,
        'ordinary captions also reject uncertified diffusion');
    assert.equal(fill.lastFailure, 'uncertified-background-surface');
    assert.equal(broadCalls, 0, 'failed quality cannot silently reach broad interpolation');
    broadCalls = 0;
}
segmentation = false;
assert.equal(context.aidokuForceInpaintSource(rgba, w, h, [25, 20, 20, 30], palette, options), null);
assert.equal(context.aidokuForceInpaintSource.lastFailure, 'display-mask-unverified');
assert.equal(broadCalls, 0, 'unsegmented title cannot erase an entire OCR rectangle');
assert.deepEqual(rgba, before, 'rejected title never mutates original artwork');
const renderer = fs.readFileSync(path.join(directory, 'BrowserOverlayView.swift'), 'utf8');
assert.ok(renderer.includes("requireSafeDonors:(item.sourceLettering==='display'||item.sourceLettering==='title')&&!item.balloonInterior?.contourVerified"),
    'only display/title lettering outside verified balloons opts in');
assert.ok(renderer.includes("panel.dataset.inpaintingFallback=forceOptions.requireSafeDonors?'unrecoverable-display':'unrecoverable-source'"));
assert.ok(renderer.includes("if(inpaintingEnabled&&(role==='display'||role==='title'))continue;"),
    'early title gloss cannot bypass the repair/panel decision');
// Exercise the production renderer's rejection branch with an existing panel
// and an incomplete earlier patch, so a failed repair cannot release the panel.
segmentation = true;
const panel = {dataset: {aidokuRegion: 'title'}};
const item = {id: 'title', sourceLettering: 'title', sourceBounds: [.3, .2, .25, .375],
    sourceFrame: [0, 0, w, h], sourceFontSize: 8};
let removed = false;
const old = {canvas: {isConnected: true, remove() { removed = true; }}, provisional: true};
const geometry = new Map([[item, old]]), restored = new Set([item]);
Object.assign(context, {
    opacity: 1, inpaintingEnabled: true, sourceImage: {complete: true, naturalWidth: w, naturalHeight: h},
    items: [item], keptItems: [], cleanupImageGeometry: {frame: item.sourceFrame},
    restoredPanelGeometry: geometry, restoredSourcePanels: restored,
    cachedSourceSample: () => palette,
    document: {createElement: () => ({getContext: () => ({
        clearRect() {}, drawImage() {}, getImageData: () => ({data: rgba})
    })})},
    root: {dataset: {}, querySelectorAll: () => [panel]}
});
const start = renderer.indexOf("    if(opacity===1&&inpaintingEnabled&&typeof aidokuForceInpaintSource==='function'");
const end = renderer.indexOf('    // Resolve the final caption geometry', start);
assert.ok(start > 0 && end > start);
vm.runInContext(renderer.slice(start, end), context);
assert.equal(context.root.dataset.forcedSourceInpaintError, undefined);
assert.equal(panel.dataset.inpaintingFallback, 'unrecoverable-display');
assert.equal(removed, true, 'discard incomplete erasure instead of displaying its smear');
assert.equal(geometry.has(item), false, 'later panel release cannot treat rejected erasure as certified');
assert.equal(restored.has(item), false);
assert.equal(JSON.parse(context.root.dataset.forcedSourceInpaintAudit)[0].reason, 'helper-rejected');
console.log('PASS title panel retained, incomplete patch removed, safe title acceptance, normal caption controls');
