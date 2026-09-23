// Runs production source-color JavaScript without Swift, WebKit, or font rasterization.
// Usage: node Scripts/tests/source-color-regression.cjs [--baseline] [--source file] [--filter text]
// The fixtures below describe pixels, not a second implementation of the estimator.
// Exact dense/panel fixtures are reused from the Swift tests; font-based palette
// assertions use deterministic glyphs. WebKit rasterization and UI integration
// remain covered by the iOS tests, not simulated by this runner.
// Captured synthetic antialias pixels additionally cover fragmented outlines;
// decoding these fixtures needs only Node's built-in zlib, not a canvas package.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const zlib = require('node:zlib');

const args = process.argv.slice(2);
function option(name, fallback) {
    const index = args.indexOf(name);
    if (index < 0) return fallback;
    assert.ok(args[index + 1] && !args[index + 1].startsWith('--'), `${name} requires a value`);
    return args[index + 1];
}
const sourcePath = option('--source', path.resolve(__dirname,
    '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourceTextColor.swift'));
const swift = fs.readFileSync(sourcePath, 'utf8');
const script = swift.match(/static let script = """\r?\n([\s\S]*?)\r?\n    """/);
assert.ok(script, 'production Swift multiline script must be present');
assert.ok(!script[1].includes('\\('), 'Swift interpolation needs explicit decoding before JavaScript execution');
const context = vm.createContext({ console, performance });
vm.runInContext(script[1].replace(/^    /gm, '') + `
    globalThis.sourceColor = {
        estimate: aidokuEstimateSourceColors,
        text: aidokuEstimateTextColor,
        readable: aidokuReadableSourceColor,
        contrast: aidokuSourceColorContrast,
        panel: aidokuRecoverSourcePanel,
        outlined: aidokuRecoverOutlinedColor,
        halo: aidokuRecoverHaloInk,
        interior: aidokuInteriorCaptionSurface,
        surface: aidokuObservedSourceSurface,
        lettering: aidokuObservedLetteringInk
    };
`, context, { filename: sourcePath });
const production = context.sourceColor;

function raster(width, height, color) {
    const rgba = new Uint8ClampedArray(width * height * 4);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        rgba.set([...(typeof color === 'function' ? color(x, y) : color), 255], (y * width + x) * 4);
    }
    return { width, height, rgba };
}
function rect(image, x, y, width, height, color) {
    for (let yy = Math.max(0, y); yy < Math.min(image.height, y + height); yy++) {
        for (let xx = Math.max(0, x); xx < Math.min(image.width, x + width); xx++) {
            image.rgba.set([...color, 255], (yy * image.width + xx) * 4);
        }
    }
}
// The same deterministic H mask used by
// ReaderOCRPreviewColorTests.largeOutlinedColumnsRestoreSpatialBackgroundWithinBudget.
function glyph(image, x, y, color, scale = 1) {
    rect(image, x, y, 4 * scale, 28 * scale, color);
    rect(image, x + 16 * scale, y, 4 * scale, 28 * scale, color);
    rect(image, x, y + 12 * scale, 20 * scale, 4 * scale, color);
}
function lettering(foreground, background = [255, 255, 255]) {
    const image = raster(144, 64, background);
    for (const x of [16, 56, 96]) glyph(image, x, 18, foreground);
    return image;
}
function eLettering(foreground) {
    const image = raster(128, 64, [255, 255, 255]);
    for (let i = 0; i < 4; i++) {
        const x = 12 + 27 * i;
        rect(image, x, 18, 4, 26, foreground);
        for (const y of [18, 29, 40]) rect(image, x, y, 17, 4, foreground);
    }
    return image;
}
function estimate(image) { return production.estimate(image.rgba, image.width, image.height); }
function close(actual, expected, tolerance = 0, label = 'color') {
    assert.ok(Array.isArray(actual) && actual.length === 3,
        `${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    assert.ok(expected.every((value, index) => Math.abs(value - actual[index]) <= tolerance),
        `${label}: expected ${JSON.stringify(expected)} ± ${tolerance}, got ${JSON.stringify(actual)}`);
}
function palette(image, foreground, background) {
    const result = estimate(image);
    close(result?.foreground, foreground, 8, `foreground (${result?.confidence?.reason})`);
    if (background) close(result?.background, background, 8, 'background');
    return result;
}
const cases = [];
function test(name, run, baseline = false) { cases.push({ name, run, baseline }); }

for (const name of ['blank', 'plain white glyphs', 'single frame', 'solid art']) {
    test(`lettering display: ${name} cannot establish an outline color`, () => {
        const image = raster(96, 160, [40, 50, 60]);
        if (name === 'plain white glyphs') {
            for (const y of [16, 60, 104]) glyph(image, 30, y, [255, 255, 255]);
        } else if (name === 'single frame') {
            rect(image, 30, 12, 12, 136, [180, 42, 59]);
            rect(image, 34, 16, 4, 128, [255, 255, 255]);
        } else if (name === 'solid art') rect(image, 30, 12, 30, 136, [180, 42, 59]);
        assert.equal(production.lettering(image.rgba, 96, 160, [24, 8, 40, 144]), null);
    });
}

test('display: white antialias fringe does not wash out enclosed orange ink', () => {
    const image=raster(128,128,[255,255,255]);
    for(const [x,y] of [[10,10],[45,49],[80,88]]) {
        glyph(image,x,y,[237,175,154]);
        rect(image,x+1,y+1,2,26,[220,100,70]);
        rect(image,x+17,y+1,2,26,[220,100,70]);
        rect(image,x+1,y+13,18,2,[220,100,70]);
    }
    const result=production.halo(image.rgba,128,128,[0,0,128,128]);
    close(result?.foreground,[220,100,70],0,'enclosed core ink');
});
test('display: bright mode does not replace spatially varying balloon interior', () => {
    const image=raster(120,100,(x,y)=>y<50?[255,255,255]:[231,219,209]);
    for(const x of [16,56,96])glyph(image,x,18,[0,130,210]);
    const result=production.interior(image.rgba,120,100,[0,0,120,100],
        {foreground:[0,130,210],background:[255,255,255],confidence:{background:.9}});
    assert.ok(result.background[2]<240 && result.background[0]>result.background[2]);
    assert.deepEqual(Array.from(result.foreground),[0,130,210]);
});
test('display: genuine white paper remains white despite colored lettering', () => {
    const image=lettering([0,130,210]);
    const result=production.interior(image.rgba,image.width,image.height,[0,0,image.width,image.height],
        {foreground:[0,130,210],background:[255,255,255],confidence:{background:.9}});
    assert.deepEqual(Array.from(result.background),[255,255,255]);
});
// Exact deterministic pixels and expectations from ReaderSourceTextColorTests.
test('existing: dense inverted panel', () => {
    const image = raster(72, 44, (x, y) => {
        const ink = [5, 27, 49].some(left => x >= left && x < left + 18 && y >= 5 && y < 39 &&
            !(x >= left + 5 && x < left + 13 && y >= 10 && y < 34));
        return ink ? [255, 255, 255] : [16, 16, 16];
    });
    palette(image, [255, 255, 255], [16, 16, 16]);
}, true);

for (const [name, foreground, background] of [
    ['red', [176, 32, 48], [255, 255, 255]],
    ['blue', [32, 48, 176], [255, 255, 255]],
    ['black', [16, 16, 16], [255, 255, 255]],
    ['white', [255, 255, 255], [16, 16, 16]]
]) test(`existing palette with deterministic glyphs: ${name}`, () => {
    palette(lettering(foreground, background), foreground, background);
}, true);

test('existing: blank and filled artwork abstain from foreground', () => {
    const image = raster(180, 80, [255, 255, 255]);
    assert.equal(estimate(image).foreground, null);
    rect(image, 15, 15, 80, 35, [176, 32, 48]);
    assert.equal(estimate(image).foreground, null);
}, true);

test('existing: invalid, transparent, small, oversized input rejected', () => {
    assert.equal(production.estimate(null, 32, 32), null);
    assert.equal(production.estimate(new Uint8ClampedArray(3), 32, 32), null);
    assert.equal(estimate(raster(4, 4, [255, 255, 255])), null);
    assert.equal(estimate(raster(192, 192, [255, 255, 255])), null);
    const image = lettering([176, 32, 48]); image.rgba[3] = 249;
    assert.equal(estimate(image), null);
}, true);

test('display: readable source RGB stays exact and low contrast improves', () => {
    for (const [color, light, opacity, panel] of [
        [[176, 32, 48], true, .84, null],
        [[255, 255, 255], true, .84, null],
        [[255, 255, 255], false, .84, null],
        [[160, 160, 160], true, .2, null],
        [[219, 100, 144], true, .84, null],
        [[165, 127, 174], true, .84, [255, 254, 255]],
        [[255, 255, 224], true, .2, null]
    ]) {
        const adjusted=production.readable(color,light,opacity,panel);
        const before=production.contrast(color,light,opacity,panel);
        const after=production.contrast(adjusted,light,opacity,panel);
        if(before>=4.5)close(adjusted,color);
        else assert.ok(after>=before, 'tone adjustment must not reduce contrast');
    }
}, true);

function panelRecovery(left, right, background = null, foreground = [12, 12, 12]) {
    const image = raster(60, 100, x => {
        const value = x < 20 ? left : x >= 40 ? right : 255;
        return [value, value, value];
    });
    return production.panel(image.rgba, 60, 100, [20, 10, 20, 80],
        { foreground, background, stroke: [255, 255, 255], confidence: {} });
}
for (const [name, left, right, background, foreground, expected] of [
    ['matching gray sides', 128, 128, null, [12, 12, 12], [128, 128, 128]],
    ['bright halo replaced', 200, 200, [255, 252, 255], [12, 12, 12], [200, 200, 200]],
    ['different artwork sides', 40, 200, null, [12, 12, 12], null],
    ['intentional colored panel', 200, 200, [24, 40, 64], [12, 12, 12], [24, 40, 64]],
    ['missing ink independent', 195, 195, null, null, [195, 195, 195]],
    ['missing ink and white halo', 195, 195, [255, 255, 255], null, [195, 195, 195]],
    ['missing ink and mismatched sides', 40, 200, null, null, null]
]) test(`existing panel recovery: ${name}`, () => {
    const result = panelRecovery(left, right, background, foreground);
    if (expected) close(result.background, expected); else assert.equal(result.background, null);
    if (foreground) close(result.foreground, foreground); else assert.equal(result.foreground, null);
    close(result.stroke, [255, 255, 255]);
}, true);

test('existing outlined recovery: solid rectangles and alpha rejected', () => {
    const image = raster(180, 120, [255, 255, 255]);
    for (let i = 0; i < 4; i++) rect(image, 10 + i * 40, 30, 24, 45, [221, 96, 70]);
    assert.equal(production.outlined(image.rgba, 180, 120, { background: [255, 255, 255] }), null);
    assert.equal(production.outlined(image.rgba, 180, 120,
        { foreground: [20, 30, 40], confidence: { foreground: .9 } }), null);
    image.rgba[3] = 0;
    assert.equal(production.outlined(image.rgba, 180, 120, {}), null);
}, true);

test('existing: antialiasing retains source ink rather than edge gray', () => {
    const image = lettering([176, 32, 48]);
    // A one-pixel antialiased fringe follows the foreground/background axis.
    const before = image.rgba.slice();
    for (let y = 1; y < image.height - 1; y++) for (let x = 1; x < image.width - 1; x++) {
        const index = y * image.width + x;
        if (before[index * 4] !== 255) continue;
        if ([index - 1, index + 1, index - image.width, index + image.width]
            .some(neighbor => before[neighbor * 4] === 176)) {
            image.rgba.set([216, 144, 152, 255], index * 4);
        }
    }
    palette(image, [176, 32, 48], [255, 255, 255]);
}, true);

test('existing: mixed lettering may abstain but cannot invent a third ink', () => {
    const image = lettering([176, 32, 48]);
    glyph(image, 96, 18, [0, 0, 192]);
    const result = estimate(image);
    if (result.foreground !== null) {
        assert.ok([[176, 32, 48], [0, 0, 192]].some(color =>
            color.every((value, channel) => Math.abs(value - result.foreground[channel]) <= 16)),
        `mixed lettering returned invented RGB ${JSON.stringify(result.foreground)}`);
    }
}, true);

test('existing: deterministic E glyphs have a supported red fill', () => {
    palette(eLettering([176, 32, 48]), [176, 32, 48], [255, 255, 255]);
}, true);

// A panel border must not determine the text seed merely because it is darker.
test('regression: unrelated black border does not hide red glyphs', () => {
    const image = lettering([176, 32, 48]);
    rect(image, 0, 0, image.width, 3, [0, 0, 0]);
    palette(image, [176, 32, 48], [255, 255, 255]);
});
test('regression: a single black top row does not hide red E glyphs', () => {
    const image = eLettering([176, 32, 48]);
    rect(image, 0, 0, image.width, 1, [0, 0, 0]);
    palette(image, [176, 32, 48], [255, 255, 255]);
});
test('regression: unrelated saturated art cannot blend into an invented ink seed', () => {
    const image = lettering([176, 32, 48]);
    rect(image, 0, 0, 5, 64, [0, 0, 224]);
    rect(image, 139, 0, 5, 64, [0, 176, 0]);
    palette(image, [176, 32, 48], [255, 255, 255]);
});
test('regression: sparse off-axis specks cannot recolor coherent lettering', () => {
    const image = lettering([176, 32, 48]);
    for (let x = 5; x < 140; x += 3) rect(image, x, 5, 1, 1, [0, 0, 0]);
    palette(image, [176, 32, 48], [255, 255, 255]);
});
for (const [name, foreground, background] of [
    ['gray on white', [208, 208, 208], [255, 255, 255]],
    ['muted red on pale panel', [208, 168, 168], [240, 220, 220]],
    ['muted blue on gray panel', [112, 128, 152], [152, 160, 192]]
]) test(`regression: coherent low-contrast ${name}`, () => {
    palette(lettering(foreground, background), foreground, background);
});
test('regression: repeated pale gray E glyphs below the old contrast threshold', () => {
    palette(eLettering([220, 220, 220]), [220, 220, 220], [255, 255, 255]);
});
test('regression: contrasting isolated noise is not accepted as glyphs', () => {
    const image = raster(144, 64, [255, 255, 255]);
    for (let y = 10; y < 55; y += 13) for (let x = 10; x < 135; x += 17) {
        rect(image, x, y, 1, 1, [176, 32, 48]);
    }
    assert.equal(estimate(image).foreground, null);
});
test('regression: repeated low-contrast speck blocks are not faint lettering', () => {
    const image = raster(128, 64, [255, 255, 255]);
    for (let y = 10; y < 55; y += 15) for (let x = 10; x < 120; x += 18) {
        rect(image, x, y, 3, 3, [220, 220, 220]);
    }
    const result = estimate(image);
    assert.ok(result.foreground === null,
        `compact repeated noise was accepted as ${JSON.stringify(result.foreground)}`);
});
test('regression: low-amplitude background gradient does not become lettering', () => {
    const image = raster(144, 64, (x, y) => {
        const value = 200 + Math.round(x / 143 * 35 + y / 63 * 15);
        return [value, value, value];
    });
    assert.equal(estimate(image).foreground, null);
});

function observedSurface(left, right) {
    const image = raster(60, 100, (x, y) => x < 20 ? left(y) :
        x >= 40 ? right(y) : [255, 242, 248]);
    return production.surface(image.rgba, 60, 100, [20, 10, 20, 80], {
        background: [255, 242, 248], foreground: [176, 32, 48],
        confidence: { background: 1, foreground: 1 }
    });
}
for (const [left, right] of [[30, 200], [200, 30]]) {
    test(`regression: observed surface rejects unrelated sides (${left}/${right})`, () => {
        const result = observedSurface(() => [left, left, left], () => [right, right, right]);
        assert.ok(result === null, `unrelated side artwork produced ${JSON.stringify(result?.color)}`);
    });
}
test('existing observed surface: matching gray sides stay supported', () => {
    const result = observedSurface(() => [128, 128, 128], () => [128, 128, 128]);
    close(result?.color, [128, 128, 128]);
    assert.ok(result.stops.length >= 3);
    for (const stop of result.stops) close(stop, [128, 128, 128]);
}, true);
test('existing observed surface: matching gradient keeps its variation', () => {
    const gradient = y => [60 + y, 70 + y, 90 + y];
    const result = observedSurface(gradient, gradient);
    assert.ok(result && result.stops.length >= 3, 'matching gradient must be retained');
    assert.ok(result.stops.at(-1)[0] - result.stops[0][0] >= 50,
        `matching gradient collapsed to ${JSON.stringify(result.stops)}`);
    for (const stop of result.stops) {
        assert.equal(stop[1] - stop[0], 10);
        assert.equal(stop[2] - stop[1], 20);
    }
}, true);
test('regression: observed surface requires pixels on both sides', () => {
    const image = raster(40, 100, x => x < 20 ? [255, 242, 248] : [128, 128, 128]);
    const result = production.surface(image.rgba, 40, 100, [0, 10, 20, 80], {
        background: [255, 242, 248], foreground: [176, 32, 48]
    });
    assert.ok(result === null, `one-sided artwork produced ${JSON.stringify(result?.color)}`);
});
test('regression: matching medians without local color support do not prove a surface', () => {
    const image = raster(60, 100, (x, y) => {
        if (x >= 20 && x < 40) return [255, 242, 248];
        const value = [40, 128, 210][(x + y) % 3];
        return [value, value, value];
    });
    const result = production.surface(image.rgba, 60, 100, [20, 10, 20, 80], {
        background: [255, 242, 248], foreground: [176, 32, 48]
    });
    assert.ok(result === null, `unsupported texture median produced ${JSON.stringify(result?.color)}`);
});
test('existing observed surface: transposing a shared gradient preserves every stop', () => {
    const gradient = along => [60 + along, 70 + along, 90 + along];
    const vertical = observedSurface(gradient, gradient);
    const image = raster(100, 60, (x, y) => y < 20 || y >= 40 ? gradient(x) : [255, 242, 248]);
    const horizontal = production.surface(image.rgba, 100, 60, [10, 20, 80, 20], {
        background: [255, 242, 248], foreground: [176, 32, 48],
        confidence: { background: 1, foreground: 1 }
    });
    assert.ok(vertical && horizontal, 'both orientations must retain the shared gradient');
    assert.equal(vertical.vertical, true);
    assert.equal(horizontal.vertical, false);
    close(horizontal.color, vertical.color);
    assert.equal(horizontal.stops.length, vertical.stops.length);
    horizontal.stops.forEach((stop, index) => close(stop, vertical.stops[index]));
}, true);

// Binary H/E masks do not reproduce thin antialiased outline fragments. These
// exact source pixels preserve that topology without depending on local fonts.
const capturedOutlines = JSON.parse(fs.readFileSync(path.join(__dirname,
    'fixtures/source-color-outlined-regressions.json'), 'utf8')).fixtures;
function capturedImage(name) {
    const fixture = capturedOutlines.find(value => value.name === name);
    assert.ok(fixture, `missing captured source-color fixture: ${name}`);
    const bytes = fixture.width * fixture.height * 4;
    const rgba = zlib.inflateSync(Buffer.from(fixture.rgbaZlibBase64, 'base64'), { maxOutputLength: bytes });
    assert.equal(rgba.length, bytes, 'captured RGBA byte length');
    return { ...fixture, rgba };
}
for (const name of ['white-brown-nested-panel', 'black-white-gradient']) {
    test(`regression captured outline: ${name} cannot become the fill`, () => {
        const image = capturedImage(name);
        const result = estimate(image);
        // Ambiguous source roles may abstain. A mode retry must not upgrade
        // the independently observed outline into confidently wrong fill.
        if (result.foreground !== null) close(result.foreground, image.fill, 12,
            `source fill, not its outline (${result.confidence?.reason})`);
    }, true);
}
test('existing captured gradient: observed halo does not become a flat panel', () => {
    const result = estimate(capturedImage('white-gradient-observed-halo'));
    close(result.foreground, [255, 255, 255], 8, 'white source fill');
    assert.equal(result.background, null, 'the gradient has no validated flat backing');
    close(result.stroke, [100, 104, 108], 8, 'observed source halo');
}, true);

const selected = cases.filter(value => (!args.includes('--baseline') || value.baseline) &&
    value.name.includes(option('--filter', '')));
assert.ok(selected.length, 'no tests matched');
let passed = 0;
for (const value of selected) {
    try { value.run(); passed++; console.log(`PASS ${value.name}`); }
    catch (error) { console.error(`FAIL ${value.name}\n  ${error.message}`); }
}
console.log(`${passed}/${selected.length} source-color regressions passed`);
if (passed !== selected.length) process.exitCode = 1;
