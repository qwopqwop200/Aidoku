// Shared deterministic Canvas harness for source-color sampler and corpus regressions.
// Exercise the production sampler with deterministic area-averaged source pixels.
// This harness covers crop geometry/budgets, not platform-specific Canvas filters.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { performance } = require('node:perf_hooks');

const source = fs.readFileSync(path.resolve(__dirname,
    '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourceTextColor.swift'), 'utf8');
const script = source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const ink = [180, 42, 59], panel = [246, 234, 217];

function raster(width, height, color = panel) {
    const data = new Uint8ClampedArray(width * height * 4), rgba = [...color, 255];
    for (let i = 0; i < width * height; i++) data.set(rgba, i * 4);
    return { complete: true, naturalWidth: width, naturalHeight: height, data };
}
function rect(image, x, y, width, height, color) {
    const rgba = [...color, 255];
    for (let yy = y; yy < y + height; yy++) for (let xx = x; xx < x + width; xx++)
        image.data.set(rgba, (yy * image.naturalWidth + xx) * 4);
}
function line(height = 1600) {
    const image = raster(64, height);
    for (let y = 24; y + 28 < height - 24; y += 44) {
        rect(image, 20, y, 4, 28, ink);
        rect(image, 40, y, 4, 28, ink);
        rect(image, 20, y + 12, 24, 4, ink);
    }
    return image;
}
function outlinedLine(fill = ink, background = [96, 85, 105]) {
    const image = raster(64, 1600, background);
    for (let y = 24; y + 28 < 1576; y += 44) {
        rect(image, 18, y - 2, 28, 32, [255, 255, 255]);
        rect(image, 20, y, 2, 28, fill);
        rect(image, 42, y, 2, 28, fill);
        rect(image, 20, y + 12, 24, 2, fill);
    }
    return image;
}
function whiteOutlinedGlyphs(shape, stroke) {
    const image = raster(64, 1600, [70, 70, 70]), mask = [];
    for (let y = 0; y < 28; y++) for (let x = 0; x < 24; x++) {
        const h = x < 4 || x >= 20 || (y >= 12 && y < 16);
        const e = x < 4 || y < 4 || (y >= 12 && y < 16) || y >= 24;
        const outer = ((x - 11.5) / 12) ** 2 + ((y - 13.5) / 14) ** 2;
        const inner = ((x - 11.5) / 8) ** 2 + ((y - 13.5) / 10) ** 2;
        if (shape === 'H' ? h : shape === 'E' ? e : outer <= 1 && inner >= 1) mask.push([x, y]);
    }
    for (let y = 24; y + 28 < 1576; y += 44) {
        for (const [gx, gy] of mask) for (let dy = -3; dy <= 3; dy++) for (let dx = -3; dx <= 3; dx++)
            if (dx * dx + dy * dy <= 9) rect(image, 20 + gx + dx, y + gy + dy, 1, 1, stroke);
        for (const [gx, gy] of mask) rect(image, 20 + gx, y + gy, 1, 1, [255, 255, 255]);
    }
    return image;
}
function transpose(image) {
    const result = raster(image.naturalHeight, image.naturalWidth);
    for (let y = 0; y < image.naturalHeight; y++) for (let x = 0; x < image.naturalWidth; x++) {
        const from = (y * image.naturalWidth + x) * 4, to = (x * image.naturalHeight + y) * 4;
        result.data[to] = image.data[from]; result.data[to + 1] = image.data[from + 1];
        result.data[to + 2] = image.data[from + 2]; result.data[to + 3] = image.data[from + 3];
    }
    return result;
}
function resize(image, sx, sy, sw, sh, width, height) {
    const result = new Uint8ClampedArray(width * height * 4);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        const left = sx + x * sw / width, right = sx + (x + 1) * sw / width;
        const top = sy + y * sh / height, bottom = sy + (y + 1) * sh / height;
        const sums = [0, 0, 0, 0];
        for (let yy = Math.floor(top); yy < Math.ceil(bottom); yy++) {
            const dy = Math.min(bottom, yy + 1) - Math.max(top, yy);
            for (let xx = Math.floor(left); xx < Math.ceil(right); xx++) {
                const weight = dy * (Math.min(right, xx + 1) - Math.max(left, xx));
                const at = (yy * image.naturalWidth + xx) * 4;
                for (let c = 0; c < 4; c++) sums[c] += image.data[at + c] * weight;
            }
        }
        const area = (right - left) * (bottom - top);
        for (let c = 0; c < 4; c++) result[(y * width + x) * 4 + c] = Math.round(sums[c] / area);
    }
    return result;
}
// Cache compilation only: every harness still owns a fresh realm, sampler cache,
// canvas state and overrides. Key by extracted source, including --source inputs.
const compiledScripts = new Map();
function harness(helpers = null, readError = false, sourceOverride = null) {
    const evaluatedScript = sourceOverride ? fs.readFileSync(sourceOverride, 'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1] : script;
    const evaluatedSampler = evaluatedScript.slice(evaluatedScript.indexOf('    const aidokuSourceColorSampler ='));
    const draws = [];
    const context = vm.createContext({ performance, Uint8ClampedArray,
        aidokuObservedCaptionPalette: (_rgba,_w,_h,_inner,result) => result,
        aidokuSourceDisplayInk: result => result?.foreground || result?.displayForeground,
        aidokuRecoverHaloInk: () => null,
        aidokuObservedLetteringInk: () => null,
        aidokuObservedGlyphPalette: () => null,
        aidokuObservedStrokePalette: (_rgba,_w,_h,_inner,_glyphs,_display,value) => value?.stroke
            ? { foreground:value.foreground, stroke:value.stroke, widthEvidence:value.widthEvidence } : null,
        aidokuResolveDisplayGlyphs: result => result?.foreground || null,
        document: { createElement(tag) {
            assert.equal(tag, 'canvas');
            let draw;
            const canvas = { width: 0, height: 0 };
            canvas.getContext = () => ({
                drawImage(image, sx, sy, sw, sh, dx, dy, w, h) {
                    assert.equal(dx, 0); assert.equal(dy, 0);
                    assert.equal(w, canvas.width); assert.equal(h, canvas.height);
                    assert.ok(sx >= 0 && sy >= 0 && sx + sw <= image.naturalWidth && sy + sh <= image.naturalHeight);
                    assert.ok(w * h <= 24576, 'each read stays within the estimator limit');
                    draw = { image, sx, sy, sw, sh, w, h }; draws.push(draw);
                },
                getImageData() {
                    if (readError) throw new Error('tainted canvas');
                    return { data: resize(draw.image, draw.sx, draw.sy, draw.sw, draw.sh, draw.w, draw.h) };
                }
            });
            return canvas;
        } }, ...(helpers || {}) });
    // Bind the realm's own intrinsic once, avoiding VM global-proxy lookups in
    // pixel loops without sharing or replacing Math across isolated contexts.
    const program = 'const Math = globalThis.Math;\n' + (helpers ? evaluatedSampler : evaluatedScript) + '\n' +
        'globalThis.sampleSource = aidokuSourceColorSampler;' +
        (helpers ? '' : 'globalThis.estimateSource = aidokuEstimateSourceColors;globalThis.observedCaption=aidokuObservedCaptionPalette;globalThis.enclosedInk=aidokuRecoverOutlinedColor;');
    let compiled = compiledScripts.get(program);
    if (!compiled) {
        compiled = new vm.Script(program);
        compiledScripts.set(program, compiled);
    }
    compiled.runInContext(context);
    return { context, draws, sampler: context.sampleSource, estimate: context.estimateSource, observed: context.observedCaption, enclosed: context.enclosedInk };
}
function near(actual, expected, tolerance = 12) {
    assert.ok(actual && expected.every((v, c) => Math.abs(v - actual[c]) <= tolerance),
        `expected ${expected}, got ${actual}`);
}

module.exports = { harness, raster, rect, line, outlinedLine, whiteOutlinedGlyphs, transpose, resize, near, ink, panel };
