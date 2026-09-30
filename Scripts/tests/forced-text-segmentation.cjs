// Regression for the bounded source-glyph mask used by the no-panel fallback.
// Optional --real DIR replays the two cached phone pages without bundling them.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const crypto = require('node:crypto');

let source = fs.readFileSync(path.resolve(__dirname,
    '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourceGlyphSegmentation.swift'), 'utf8')
    .match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const adapter = fs.readFileSync(path.resolve(__dirname,
    '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourceGlyphConservative.swift'), 'utf8');
const replacements = [...adapter.matchAll(/of:\s*"([^"]+)"\s*,\s*with:\s*"([^"]+)"/g)];
assert.equal(replacements.length, 3, 'all production conservative substitutions are audited');
for (const [, before, after] of replacements) {
    assert.ok(source.includes(before), `segmenter still contains the adapted expression: ${before}`);
    source = source.replace(before, after);
}
const segment = new Function(source + ';return aidokuForcedTextMask')();
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const count = mask => mask.reduce((n, value) => n + value, 0);
function verify(mask, width, height) {
    assert.ok(mask instanceof Uint8Array && mask.length === width * height);
    assert.equal(mask.sourceCoreCandidateMask.length, mask.length);
    assert.equal(mask.sourceOutlineCandidateMask.length, mask.length);
    assert.equal(count(mask.sourceCoreCandidateMask), mask.sourceCoreCandidateCount);
    assert.equal(count(mask.sourceOutlineCandidateMask), mask.sourceOutlineCandidateCount);
    assert.ok(mask.sourceCoreCandidateCovered <= mask.sourceCoreCandidateCount);
    assert.ok(mask.sourceOutlineCandidateCovered <= mask.sourceOutlineCandidateCount);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        if (x < 2 || y < 2 || x >= width - 2 || y >= height - 2)
            assert.equal(mask[y * width + x], 0, 'crop edge must survive');
    }
}

const guarded = JSON.parse(fs.readFileSync(path.join(__dirname,
    'fixtures/source-inpainting-art-guard.json'))).fixtures;
for (const item of guarded) {
    const rgba = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(item.rgba, 'base64')));
    const before = hash(rgba);
    const mask = segment(rgba, item.w, item.h, item.b, item.palette,
        { vertical: item.vertical, sampleScale: item.scale });
    assert.ok(mask, `${item.name}/${item.id}: mask exists`);
    verify(mask, item.w, item.h);
    for (const index of item.protectedPixels)
        assert.equal(mask[index], 0, `${item.name}/${item.id}: reviewed artwork preserved`);
    assert.equal(hash(rgba), before, 'source image immutable');
}
console.log(`${guarded.length} artwork-protection crops passed`);

const realArg = process.argv.indexOf('--real');
if (realArg >= 0) {
    const dir = process.argv[realArg + 1];
    assert.ok(dir, '--real needs the cached .inputs.json directory');
    const rows = [];
    for (const page of ['phone-1', 'phone-2']) {
        const inputs = JSON.parse(fs.readFileSync(path.join(dir, `${page}.inputs.json`)));
        for (let index = 0; index < inputs.length; index++) {
            const item = inputs[index], before = hash(Uint8Array.from(item.rgba));
            const mask = segment(item.rgba, item.w, item.h, item.b, item.palette,
                { ...item.options, trailing: 46 });
            assert.ok(mask, `${page}/${index}: observed source has a mask`);
            verify(mask, item.w, item.h);
            assert.equal(hash(Uint8Array.from(item.rgba)), before, 'source image immutable');
            rows.push({ page, index, maskPixels: count(mask), core: [mask.sourceCoreCandidateCovered,
                mask.sourceCoreCandidateCount], outline: [mask.sourceOutlineCandidateCovered,
                mask.sourceOutlineCandidateCount] });
            if (page === 'phone-1' && index === 1) {
                let hair = 0;
                for (let y = 330; y < 395; y++) for (let x = 115; x < 165; x++)
                    hair += mask[y * item.w + x];
                assert.ok(hair < 250, `phone-1 title balloon hair protected (${hair})`);
            }
            if (page === 'phone-2' && index === 11) {
                let tail = 0, art = 0;
                for (let y = 342; y < 392; y++) for (let x = 215; x < 260; x++)
                    tail += mask[y * item.w + x];
                for (let y = 360; y < 405; y++) for (let x = 270; x < 330; x++)
                    art += mask[y * item.w + x];
                assert.ok(tail > 1000, `trailing outlined kana is covered (${tail})`);
                assert.equal(art, 0, 'adjacent illustration remains unmasked');
            }
        }
    }
    assert.equal(rows.length, 23);
    console.log(JSON.stringify({ realCrops: rows.length, rows }));
}


// Native OCR glyph size permits large outlined characters while a long rule
// stays excluded. A fixed 56/78-pixel cap used to drop these source components.
{
    const w=320,h=270,rgba=new Uint8ClampedArray(w*h*4);
    for(let i=0;i<w*h;i++)rgba.set([130,160,190,255],i*4);
    for(const x0 of [70,130]){
        for(let y=53;y<167;y++)for(let x=x0-7;x<x0+15;x++)rgba.set([250,250,250,255],(y*w+x)*4);
        for(let y=60;y<160;y++)for(let x=x0;x<x0+8;x++)rgba.set([68,68,137,255],(y*w+x)*4);
    }
    for(let y=10;y<255;y++)for(let x=210;x<215;x++)rgba.set([68,68,137,255],(y*w+x)*4);
    const palette={foreground:[68,68,137],stroke:[250,250,250],confidence:{stroke:.9},
        sourceInk:{foreground:[68,68,137],background:[130,160,190],confidence:{background:.9}}};
    for(let y=173;y<193;y++)for(let x=163;x<183;x++)rgba.set([250,250,250,255],(y*w+x)*4);
    for(let y=180;y<186;y++)for(let x=170;x<176;x++)rgba.set([68,68,137,255],(y*w+x)*4);
    const b=[50,35,185,205];
    assert.equal(segment(rgba,w,h,b,palette,{}),null,'fixed cap misses independently outlined large characters');
    const mask=segment(rgba,w,h,b,palette,{glyphSize:90});
    assert.ok(mask,'OCR-derived glyph size recovers large characters');
    assert.equal(mask[100*w+73],1,'source core selected');
    assert.equal(mask[100*w+212],0,'long illustration rule still excluded');
    assert.equal(mask[176*w+166],1,'detached dot receives its full thick observed outline');
    verify(mask,w,h);
    console.log('PASS OCR-sized large glyph components and long-rule protection');
}
