// Run with: node Scripts/tests/source-color-sampler-regression.cjs
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
const samplerScript = script.slice(script.indexOf('    const aidokuSourceColorSampler ='));
const ink = [180, 42, 59], panel = [246, 234, 217];

function raster(width, height, color = panel) {
    const data = new Uint8ClampedArray(width * height * 4);
    for (let i = 0; i < width * height; i++) data.set([...color, 255], i * 4);
    return { complete: true, naturalWidth: width, naturalHeight: height, data };
}
function rect(image, x, y, width, height, color) {
    for (let yy = y; yy < y + height; yy++) for (let xx = x; xx < x + width; xx++)
        image.data.set([...color, 255], (yy * image.naturalWidth + xx) * 4);
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
        result.data.set(image.data.subarray(from, from + 4), to);
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
function harness(helpers = null, readError = false) {
    const draws = [];
    const context = vm.createContext({ performance, Uint8ClampedArray,
        aidokuObservedCaptionPalette: (_rgba,_w,_h,_inner,result) => result,
        aidokuSourceDisplayInk: result => result?.foreground || result?.displayForeground,
        aidokuRecoverHaloInk: () => null,
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
    vm.runInContext((helpers ? samplerScript : script) + '\n' +
        'globalThis.sampleSource = aidokuSourceColorSampler;' +
        (helpers ? '' : 'globalThis.estimateSource = aidokuEstimateSourceColors;globalThis.observedCaption=aidokuObservedCaptionPalette;globalThis.enclosedInk=aidokuRecoverOutlinedColor;'), context);
    return { context, draws, sampler: context.sampleSource, estimate: context.estimateSource, observed: context.observedCaption, enclosed: context.enclosedInk };
}
function near(actual, expected, tolerance = 12) {
    assert.ok(actual && expected.every((v, c) => Math.abs(v - actual[c]) <= tolerance),
        `expected ${expected}, got ${actual}`);
}
const bounds = [0, 0, 1, 1];

// Previously, the longest-side limit sent a 64 x 1600 source to a 7 x 192
// raster: the production estimator rejects any dimension smaller than eight.
for (const image of [line(), transpose(line())]) {
    const { sampler, estimate, draws } = harness();
    const sample = sampler(image, true), result = sample.sample(bounds);
    const { w, h } = draws[0];
    assert.deepEqual([Math.min(w, h), Math.max(w, h)], [31, 783]);
    near(result?.foreground, ink);
    near(result?.background, panel);
    assert.equal(draws.length, 1, 'legible main sample needs no extra strips');
    const oldScale = 192 / 1600, ow = Math.floor(image.naturalWidth * oldScale), oh = Math.floor(image.naturalHeight * oldScale);
    assert.equal(estimate(resize(image, 0, 0, image.naturalWidth, image.naturalHeight, ow, oh), ow, oh), null);
    assert.equal(sample.sample(bounds), result);
    assert.equal(sample.stats.hits, 1);
    assert.equal(sample.stats.samples, 1);
    assert.equal(sample.stats.pixels, 31 * 783);
}

// Thin colored interiors can disappear into a confidently classified white
// halo. Native details must recover observed red in either writing direction.
// True white lettering on the same dark panel has no colored interior proof.
for (const horizontal of [false, true]) {
    const { sampler, draws } = harness();
    const outlined = outlinedLine(), image = horizontal ? transpose(outlined) : outlined;
    const result = sampler(image, true).sample(bounds);
    near(result?.foreground, ink, 0);
    near(result?.stroke, [255, 255, 255], 0);
    near(result?.background, [96, 85, 105], 0);
    if (draws.length > 1) assert.equal(result.widthEvidence, null,
        'replacing a misclassified halo cannot retain its old stroke geometry');

    const white = line();
    for (let i = 0; i < white.data.length; i += 4) {
        const isInk = white.data[i] === ink[0];
        white.data.set(isInk ? [255, 255, 255] : [96, 85, 105], i);
    }
    const preserved = sampler(horizontal ? transpose(white) : white, true).sample(bounds);
    near(preserved?.foreground, [255, 255, 255], 2);
    assert.equal(preserved.stroke, null);
    near(preserved?.background, [96, 85, 105], 0);
}

// A white O encloses part of its colored outline inside the counter. That
// minority cannot overturn white fill when most matching color is exterior.
// H/E exercise open shapes; O tests the closed hole in both orientations.
for (const shape of ['H', 'E', 'O']) for (const stroke of [[96, 54, 28], [32, 160, 85]])
    for (const horizontal of [false, true]) {
        const { sampler } = harness(), glyphs = whiteOutlinedGlyphs(shape, stroke);
        const image = horizontal ? transpose(glyphs) : glyphs;
        const result = sampler(image, true).sample(bounds);
        near(result?.foreground, [255, 255, 255], 4);
        near(result?.background, [70, 70, 70], 0);
    }

// Both writing directions include the same source-space margin and mirror
// the OCR box correctly; edge-adjacent boxes must never read outside the image.
for (const horizontal of [false, true]) {
    const image = raster(horizontal ? 720 : 120, horizontal ? 120 : 720);
    const region = horizontal ? [20 / 720, 40 / 120, 680 / 720, 40 / 120]
        : [40 / 120, 20 / 720, 40 / 120, 680 / 720];
    const { sampler, draws } = harness();
    sampler(image, true).sample(region);
    const crop = draws[0];
    assert.deepEqual(horizontal ? [crop.sy, crop.sx, crop.sh, crop.sw] : [crop.sx, crop.sy, crop.sw, crop.sh],
        [24, 4, 72, 712]);
}

// Drive the detail path with controlled low-confidence helpers, and assert
// the actual raster handed to recovery is identical after transposition.
const details = [];
for (const horizontal of [false, true]) {
    const observed = [];
    const helpers = {
        aidokuEstimateSourceColors: () => ({ background: panel, confidence: { foreground: 0, background: 1 } }),
        aidokuRecoverSourcePanel: (_rgba, _w, _h, _inner, value) => value,
        aidokuObservedSourceSurface: () => null,
        aidokuRecoverOutlinedColor: (rgba, w, h, _palette, allowDark) => {
            if (allowDark) return null;
            observed.push({ rgba: Buffer.from(rgba), w, h });
            if(observed.length===1)return null;
            return { foreground: ink, stroke: [255, 255, 255] };
        }
    };
    const { sampler, draws } = harness(helpers);
    const budget = { pixels: 393216, detailPixels: 98304 };
    const image = horizontal ? transpose(line()) : line();
    const sample = sampler(image, true, 'ocr', budget), result = sample.sample(bounds);
    near(result.foreground, ink, 0);
    assert.equal(observed.length, 3, 'local probe plus two independent detail agreements finish recovery');
    assert.equal(sample.stats.pixels, draws.reduce((n, d) => n + d.w * d.h, 0));
    assert.equal(budget.pixels, 393216 - sample.stats.pixels);
    assert.equal(budget.detailPixels, 98304 - draws.slice(1).reduce((n, d) => n + d.w * d.h, 0));
    const [first, second] = draws.filter(d => horizontal ? d.sw < image.naturalWidth : d.sh < image.naturalHeight);
    assert.ok(horizontal ? first.sx + first.sw <= second.sx : first.sy + first.sh <= second.sy,
        'agreement must come from non-overlapping source regions');
    details.push(observed.slice(1));
}
assert.deepEqual(details[0], details[1]);

// OCR and translation share one page budget. Exhausting either allowance
// must never make it negative or accept a single uncorroborated detail strip.
{
    const helpers = {
        aidokuEstimateSourceColors: () => ({ background: panel, confidence: { foreground: 0, background: 1 } }),
        aidokuRecoverSourcePanel: (_rgba, _w, _h, _inner, value) => value,
        aidokuObservedSourceSurface: () => null,
        aidokuRecoverOutlinedColor: () => ({ foreground: ink, stroke: [255, 255, 255] })
    };
    const { sampler, draws } = harness(helpers), image = line();
    const partialBudget = { pixels: 393216, detailPixels: 64 * 192 };
    const partial = sampler(image, true, 'ocr', partialBudget).sample(bounds);
    near(partial.foreground, ink, 0);
    assert.equal(draws.filter(d => d.sh < image.naturalHeight).length, 2, 'remaining allowance is divided between two independent strips');
    const singleBudget = { pixels: draws[0].w * draws[0].h + 6144, detailPixels: 12288 };
    const single = sampler({ ...image }, true, 'ocr', singleBudget).sample(bounds);
    assert.equal(single.foreground, undefined, 'one strip is insufficient to replace the foreground');
    assert.ok(partialBudget.detailPixels >= 0 && partialBudget.detailPixels < 128);
    const budget = { pixels: 393216, detailPixels: 98304 }, start = draws.length;
    let observedPixels = 0, accepted = 0;
    for (let i = 0; i < 40; i++) {
        const sample = sampler({ ...image }, true, i % 2 ? 'translation' : 'ocr', budget);
        if (sample.sample(bounds)?.foreground) accepted++;
        observedPixels += sample.stats.pixels;
        assert.ok(budget.pixels >= 0 && budget.detailPixels >= 0);
    }
    assert.equal(accepted, 3, 'the shared allowance includes reduction probes and corroborated native strips');
    assert.ok(budget.detailPixels >= 0 && budget.detailPixels < 128);
    assert.equal(observedPixels, draws.slice(start).reduce((n, d) => n + d.w * d.h, 0));
    assert.equal(observedPixels + budget.pixels, 393216);
    assert.ok(budget.pixels < 31 * 783, 'sampling stops when another main crop cannot fit');
}

// OCR and translation cache separately, while an image replacement invalidates
// both; disabled/invalid/tainted reads must never leak unrelated colors.
{
    const { sampler, draws } = harness(), image = line();
    sampler(image, false).sample(bounds);
    assert.equal(draws.length, 0);
    const ocr = sampler(image, true), first = ocr.sample(bounds);
    const revisited = sampler(image, true), again = revisited.sample(bounds);
    assert.equal(first, again); assert.equal(revisited.stats.hits, 1);
    const translated = sampler(image, true, 'translation'); translated.sample(bounds);
    assert.equal(translated.stats.hits, 0); assert.equal(translated.stats.samples, 1);
    sampler(line(), true).sample(bounds);
    assert.equal(draws.length, 3);
    for (const invalid of [null, [], [0, 0, 0, 1], [-.1, 0, 1, 1], [0, 0, 2, 1], [NaN, 0, 1, 1]])
        assert.equal(ocr.sample(invalid), null);
    assert.equal(draws.length, 3);
    image.src = 'another-page';
    for (const phase of ['ocr', 'translation']) {
        const reloaded = sampler(image, true, phase); reloaded.sample(bounds);
        assert.equal(reloaded.stats.hits, 0, 'same image element with a new source invalidates both phases');
        assert.equal(reloaded.stats.samples, 1);
    }
    const emptyBudget = { pixels: 100, detailPixels: 0 };
    const lowBudget = sampler(line(), true, 'ocr', emptyBudget).sample(bounds);
    assert.ok(lowBudget.background, 'a low-budget crop still supplies an observed backing');
    assert.ok(emptyBudget.pixels >= 0 && emptyBudget.pixels < 100);
    assert.equal(emptyBudget.detailPixels, 0);
}
{
    const { sampler, draws } = harness(null, true), sample = sampler(line(), true);
    assert.equal(sample.sample(bounds), null);
    assert.equal(sample.sample([0, 0, .5, .5]), null);
    assert.equal(draws.length, 1, 'read failure disables further reads');
}

// A high-confidence artwork color cannot outweigh repeated enclosed dark glyphs.
{
    const {enclosed, observed} = harness();
    const image = raster(64, 800, [255,255,255]);
    rect(image, 0, 0, 12, 800, [210,180,235]);
    for(let y=24;y<740;y+=44) {
        rect(image, 22, y, 4, 28, [3,2,3]);rect(image, 42, y, 4, 28, [3,2,3]);
        rect(image, 22, y+12, 24, 4, [3,2,3]);
    }
    // The helper is bounded to one sampled crop.
    const reduced=resize(image,0,0,64,800,32,400);
    const ink=enclosed(reduced,32,400,{foreground:[210,180,235],background:[255,255,255],confidence:{foreground:.8}},true);
    near(ink.foreground,[3,2,3],12);
    const badge=raster(120,64,[250,250,254]);
    rect(badge,20,10,80,44,[5,4,2]);rect(badge,25,20,70,26,[253,219,70]);
    for(let x=30;x<90;x+=15)rect(badge,x,22,8,22,[5,4,2]);
    const palette=observed(badge.data,120,64,[20,10,80,44],{background:[250,250,254],foreground:null,confidence:{background:.3}});
    near(palette.background,[5,4,2],8);near(palette.displayForeground,[253,219,70],8);
    const artwork=raster(64,80,[85,68,50]);
    rect(artwork,20,10,24,60,[251,251,248]);rect(artwork,28,18,8,44,[20,20,20]);
    const backing=observed(artwork.data,64,80,[18,8,28,64],{background:null,foreground:[20,20,20],stroke:[251,251,248]});
    near(backing.background,[85,68,50],8);
}

// White ink outlines must not pass the interior-only backing support gate.
{
    const {observed} = harness();
    const image=raster(64,120,[84,80,98]);
    for(let y=12;y<100;y+=20)rect(image,20,y,24,12,[253,252,249]);
    const palette=observed(image.data,64,120,[18,8,28,100],{
        background:[253,252,249],foreground:[53,57,56],confidence:{background:0,foreground:.66}});
    near(palette.background,[84,80,98],8);
    const white=raster(64,120,[253,252,249]);
    const preserved=observed(white.data,64,120,[18,8,28,100],{
        background:[253,252,249],foreground:[5,5,5],confidence:{background:.3}});
    near(preserved.background,[253,252,249],8);
}

// Dense pages still sample every caption rather than turning later boxes white.
{
    const {sampler} = harness(), image = line(), budget = {pixels: 4096, detailPixels: 0, remainingSamples: 40};
    for (let i=0; i<40; i++) {
        const result = sampler({...image},true,'ocr',budget).sample(bounds);
        assert.ok(result && result.background, 'each caption receives observed pixels');
        assert.ok(budget.pixels>=0);
    }
}
// Captured translucent balloon: Kanji counters must not become white fill.
// Test all columns, mirrored reading direction and independent raster sizes.
{
    const fixture=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-color-panel-guided-counter.json'),'utf8'));
    const image={complete:true,naturalWidth:fixture.width,naturalHeight:fixture.height,
        data:new Uint8ClampedArray(require('node:zlib').inflateSync(Buffer.from(fixture.rgba,'base64')))};
    for(const scale of [1,.75,2])for(const rotated of [false,true]){
        let input={...image,naturalWidth:Math.round(image.naturalWidth*scale),naturalHeight:Math.round(image.naturalHeight*scale)};
        input.data=resize(image,0,0,image.naturalWidth,image.naturalHeight,input.naturalWidth,input.naturalHeight);
        if(rotated)input=transpose(input);
        for(const box of [[85,40,35,187],[38,40,35,187],[130,40,35,215],[180,40,35,160],[230,40,35,190],[36,39,234,215]]){
            let bounds=box.map((v,i)=>v/(i%2?image.naturalHeight:image.naturalWidth));
            if(rotated)bounds=[bounds[1],bounds[0],bounds[3],bounds[2]];
            const palette=harness().sampler({...input},true,'ocr',{pixels:300000,detailPixels:196608,remainingSamples:1}).sample(bounds);
            assert.ok(Math.max(...palette.foreground)<22, JSON.stringify({scale,rotated,box,palette}));
            assert.ok(Math.min(...palette.background)>175,'independently observed light panel');
        }
    }
    const real=harness();
    const restoration=fs.readFileSync(path.resolve(__dirname,
        '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift'),'utf8')
        .match(/static let script = """\n([\s\S]*?)\n    """/)[1];
    vm.runInContext(restoration+'\nglobalThis.restorePanel=aidokuRestoreSourcePanel;',real.context);
    for(const box of [[36,39,234,215],[85,40,35,187]]){
        const palette=real.sampler({...image},true,'ocr',{pixels:300000,detailPixels:196608,remainingSamples:1})
            .sample(box.map((v,i)=>v/(i%2?image.naturalHeight:image.naturalWidth)));
        const before=image.data.slice();
        const output=real.context.restorePanel(image.data,288,277,box,palette,{readabilityGate:true});
        assert.ok(output,'translucent balloon and dense single Kanji column are restored');
        assert.deepEqual(image.data,before,'source pixels remain immutable');
        let missed=0;
        for(let y=box[1];y<box[1]+box[3];y++)for(let x=box[0];x<box[0]+box[2];x++){
            const i=(y*288+x)*4;
            if(Math.max(...image.data.subarray(i,i+3))<80&&(!output.rgba[i+3]||Math.min(...output.rgba.subarray(i,i+3))<140))missed++;
        }
        assert.equal(missed,0,'all owned dark source strokes are erased');
        if(box[2]>200){
            const fallback=real.context.restorePanel(image.data,288,277,box,{...palette,widthEvidence:null},{readabilityGate:true});
            assert.ok(output.erased<fallback.erased*.75,'measured halo avoids oversized erasure');
        }
    }
    // A real white glyph on a light panel still owns its dark exterior outline.
    // Panel contrast alone must never swap these roles.
    for(const shape of ['H','E','O']){
        const white=whiteOutlinedGlyphs(shape,[4,4,4]);
        for(let i=0;i<white.data.length;i+=4)if(white.data[i]===70&&white.data[i+1]===70&&white.data[i+2]===70)
            white.data.set([226,230,226,255],i);
        const palette=harness().sampler(white,true,'ocr',{pixels:300000,detailPixels:196608,remainingSamples:1}).sample([0,0,1,1]);
        near(palette.foreground,[255,255,255],15);
    }
}
console.log('PASS: long portrait/landscape source colors, bounded area, symmetric margins/detail, independent strips, caches and failed reads');
