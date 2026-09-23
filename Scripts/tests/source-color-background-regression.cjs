// Frozen background annotations over original, captured dataset pixels.
// --source FILE --labels FILE --captures FILE --measure-only --split development --report FILE
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const zlib = require('node:zlib');
const crypto = require('node:crypto');
const { harness, raster, rect, transpose } = require('./source-color-test-harness.cjs');
const arg = name => process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : null;
const labels = JSON.parse(fs.readFileSync(arg('--labels') || path.join(__dirname, 'fixtures/source-color-background.json')));
const captures = JSON.parse(fs.readFileSync(arg('--captures') || path.join(__dirname, 'fixtures/source-color-diversity.json'))).fixtures;
const h = harness(null, false, arg('--source'));
vm.runInContext('globalThis.caption=aidokuCaptionPalette;globalThis.display=aidokuSourceDisplayInk;' +
    'globalThis.interior=typeof aidokuObservedCaptionBackground === "function" ? aidokuObservedCaptionBackground : null;', h.context);
if (!process.argv.includes('--measure-only')) {
    let controls = 0;
    for (const panel of [[255,255,255], [26,45,76], [245,217,126], [116,31,67], [17,130,101]]) {
        for (const vertical of [false, true]) {
            let image = raster(160, 100, [240,240,240]);
            rect(image, 20, 16, 120, 68, panel);
            const ink = panel[0] + panel[1] + panel[2] > 400 ? [8,8,8] : [248,248,248];
            for (const x of [30,65,100]) {
                rect(image, x, 30, 3, 40, ink); rect(image, x+20, 30, 3, 40, ink);
                rect(image, x, 48, 23, 3, ink);
            }
            if (vertical) image = transpose(image);
            const source = { foreground: [210,190,90], background: [240,240,240], stroke: [9,9,9],
                confidence: { foreground: .7, background: .2, stroke: .6 }, displayEvidence: { color: ink } };
            const original = JSON.stringify(source), bytes = Buffer.from(image.data);
            const result = h.context.interior(image.data, image.naturalWidth, image.naturalHeight,
                vertical ? [24,24,52,108] : [24,24,108,52], source);
            assert.ok(result.captionBackground, 'an exposed interior must override the unrelated outer frame');
            assert.ok(panel.every((v,i) => Math.abs(v-result.captionBackground[i]) <= 2));
            for (const key of ['foreground','background','stroke','confidence','displayEvidence'])
                assert.deepEqual(result[key], source[key], 'display evidence cannot authorize erasure or recolor ink');
            assert.equal(JSON.stringify(source), original);
            assert.deepEqual(Buffer.from(image.data), bytes);
            controls++;
        }
    }
    // Spatial gradients have a known clean background before glyphs are added.
    // A histogram's bright half must not erase the darker half of the surface.
    const image = raster(160,100), clean = [0,0,0];
    for (let y=0;y<100;y++) for (let x=0;x<160;x++) {
        const rgb = [224 + Math.round(24*y/99), 189 + Math.round(34*y/99), 161 + Math.round(44*y/99)];
        rect(image,x,y,1,1,rgb); rgb.forEach((v,i) => clean[i] += v / 16000);
    }
    for (const x of [24,62,100]) { rect(image,x,20,4,60,[10,10,10]); rect(image,x,45,24,4,[10,10,10]); }
    const source = { foreground:[10,10,10], background:[255,255,255], confidence:{background:.9} };
    const gradient = h.context.interior(image.data,160,100,[0,0,160,100],source);
    assert.ok(clean.every((v,i)=>Math.abs(v-gradient.captionBackground[i])<=5));
    for (const inner of [null, [0,0,-1,5], [NaN,0,10,10], [0,0,0,0]])
        assert.strictEqual(h.context.interior(image.data,160,100,inner,source),source);
    const transparent = image.data.slice(); transparent[3]=0;
    assert.strictEqual(h.context.interior(transparent,160,100,[0,0,160,100],source),source);
    // Heavy strokes leave sparse but spatially distributed background after
    // local halo exclusion. A similarly sized isolated corner is insufficient.
    const dense = raster(144,144,[131,149,172]);
    for (let p=0;p<144;p+=12) { rect(dense,p,0,3,144,[0,0,0]); rect(dense,0,p,144,3,[0,0,0]); }
    const denseSource = {foreground:[0,0,0],background:[165,180,200]};
    const recovered = h.context.interior(dense.data,144,144,[0,0,144,144],denseSource);
    assert.deepEqual(Array.from(recovered.captionBackground),[131,149,172]);
    const corner = raster(144,144,[0,0,0]); rect(corner,0,0,144,28,[131,149,172]);
    assert.strictEqual(h.context.interior(corner.data,144,144,[0,0,144,144],denseSource),denseSource);
    // The dark panel lies inside the ordinary ink-color exclusion tolerance.
    // Recover it only from a narrower, spatially distributed exposed surface.
    const dim = raster(144,144,[37,37,37]);
    for (let p=0;p<144;p+=12) { rect(dim,p,0,3,144,[5,5,5]); rect(dim,0,p,144,3,[5,5,5]); }
    const dimResult = h.context.interior(dim.data,144,144,[0,0,144,144],{foreground:[5,5,5],background:[4,4,4]});
    assert.deepEqual(Array.from(dimResult.captionBackground),[37,37,37]);
    // A broad lighter span of the same chromatic panel must contribute even
    // when the darker end owns most pixels. This clean surface is the oracle.
    const blue = raster(160,100,[10,30,94]); rect(blue,0,0,40,100,[150,170,234]);
    const blueMean = [45,65,129];
    for (const x of [24,62,100]) { rect(blue,x,20,3,60,[0,0,0]); rect(blue,x,45,24,3,[0,0,0]); }
    const blueResult = h.context.interior(blue.data,160,100,[0,0,160,100],{foreground:[0,0,0],background:[10,30,94]});
    assert.ok(blueMean.every((v,i)=>Math.abs(v-blueResult.captionBackground[i])<=12));
    // Dark outlined lettering shares its color neighborhood with a broad
    // background. Removing that connected backdrop would leave only the light end.
    const shaded = raster(160,100,[35,10,4]); rect(shaded,0,0,40,100,[150,125,119]);
    for (const x of [24,62,100]) {
        rect(shaded,x-2,18,7,64,[250,250,250]); rect(shaded,x,20,3,60,[56,38,37]);
    }
    for (const vertical of [false,true]) {
        const pixels = vertical ? transpose(shaded) : shaded;
        const observed = h.context.interior(pixels.data,pixels.naturalWidth,pixels.naturalHeight,
            [0,0,pixels.naturalWidth,pixels.naturalHeight],{foreground:[56,38,37],background:[160,130,120]});
        assert.ok([64,39,33].every((v,i)=>Math.abs(v-observed.captionBackground[i])<=12));
    }
    // Display may flatten a validated pale fill to its orange outline. The
    // physical fill remains available for masking, independent of display color.
    const warm = raster(160,100,[230,62,10]);
    for (const x of [24,62,100]) rect(warm,x,20,4,60,[254,249,247]);
    const warmSource = {foreground:[254,249,247],stroke:[248,88,21],background:[60,40,30],
        displayEvidence:{color:[249,89,20]},confidence:{foreground:.85,
            reason:'agreeing native detail palettes preserve fill and outline roles'}};
    const warmResult = h.context.interior(warm.data,160,100,[0,0,160,100],warmSource);
    assert.deepEqual(Array.from(warmResult.captionBackground),[230,62,10]);
    assert.deepEqual(warmResult.displayEvidence,warmSource.displayEvidence);
    // A known clean halftone continues through the OCR box and surrounding rim.
    // Its tiny dark dots must contribute to the background instead of receiving
    // a glyph halo mask. Include both reading directions and real glyph strokes.
    const halftone = raster(200,120,[250,250,250]);
    for(let y=1;y<120;y+=5)for(let x=1;x<200;x+=5)rect(halftone,x,y,2,2,[13,13,13]);
    const halftoneMean = 250 * .84 + 13 * .16;
    for(const x of [40,80,120]){
        rect(halftone,x-2,28,8,54,[250,250,250]);rect(halftone,x,30,2,50,[13,13,13]);
    }
    const dotSource = {foreground:[13,13,13],background:[250,250,250]};
    for(const vertical of [false,true]){
        const pixels = vertical ? transpose(halftone) : halftone;
        const value = h.context.interior(pixels.data,pixels.naturalWidth,pixels.naturalHeight,
            vertical ? [20,20,80,160] : [20,20,160,80],dotSource);
        assert.ok(value.captionBackground.every(v=>Math.abs(v-halftoneMean)<=10));
        assert.deepEqual(value.foreground,dotSource.foreground);
        assert.deepEqual(value.background,dotSource.background);
    }
    // Fine punctuation confined to text cannot establish a surrounding texture.
    const punctuation = raster(200,120,[250,250,250]);
    for(let y=21;y<100;y+=5)for(let x=21;x<180;x+=5)rect(punctuation,x,y,2,2,[13,13,13]);
    const punctuationResult=h.context.interior(punctuation.data,200,120,[20,20,160,80],dotSource);
    assert.strictEqual(punctuationResult,dotSource,'dense punctuation alone cannot authorize a textured background');
    console.log(`PASS: ${controls} known colored/white/dark panels, gradient, source-role isolation and invalid/transparent inputs`);
}
const rows = [];
for (const label of labels.fixtures) {
    if (arg('--split') && label.split !== arg('--split')) continue;
    const f = captures.find(f => f.id === label.id);
    assert.ok(f, label.id);
    const data = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64')));
    const hash = () => crypto.createHash('sha256').update(data).digest('hex');
    assert.equal(hash(), f.pixelSHA256);
    const image = { complete: true, naturalWidth: f.width, naturalHeight: f.height, data };
    const budget = { pixels: 393216, detailPixels: 98304, remainingSamples: 1 };
    const sampler = h.sampler(image, true, 'ocr', budget), result = sampler.sample(f.bounds);
    const palette = h.context.caption(result, h.context.display(result), true);
    const error = palette.observed ? Math.max(...label.expectedBackground.map((v, i) => Math.abs(v - palette.background[i]))) : 255;
    const row = { ...label, background: palette.background, observed: palette.observed, error, matched: error <= 25,
        ink: h.context.display(result), stats: { ...sampler.stats }, result };
    rows.push(row);
    if (!process.argv.includes('--measure-only')) assert.ok(error <= (label.maximumError ?? 25),
        `${label.id}: background ${palette.background}, expected ${label.expectedBackground}, error ${error}`);
    assert.ok(budget.pixels >= 0 && budget.detailPixels >= 0);
    assert.strictEqual(sampler.sample(f.bounds), result);
    assert.equal(hash(), f.pixelSHA256, 'source pixels must remain unchanged');
}
if (arg('--report')) fs.writeFileSync(arg('--report'), JSON.stringify({ methodology: labels.methodology, rows }, null, 2));
for (const split of ['development', 'holdout']) {
    const selected = rows.filter(r => r.split === split);
    if (selected.length) console.log(`${split}: ${selected.filter(r => r.matched).length}/${selected.length} backgrounds within RGB error 25`);
}
for (const row of rows.filter(r => !r.matched)) console.log(`MISS ${row.id} ${row.surface}: ${row.background}; reference ${row.expectedBackground}; error ${row.error}`);
