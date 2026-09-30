const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), zlib = require('node:zlib');
const script = fs.readFileSync(path.join(__dirname,
    '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift'), 'utf8')
    .match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore = new Function(script + ';return aidokuNarrowPaperGlyphs;')();
const fixtures = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/narrow-paper-balloons.json'))).fixtures;
// Independent boxes around the visible original glyphs, excluding the solid/dotted rim.
const glyphs = [
    [[31,34,50,53],[38,58,42,78],[38,82,42,87],[38,90,42,95],[38,99,42,103]],
    [[34,38,45,56],[43,39,49,43],[45,55,50,58],[33,63,43,76],[32,80,46,98],
     [34,99,46,113],[35,115,45,120],[34,120,47,125]]
];
for (const [index, f] of fixtures.entries()) {
    const rgba = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64'))), original = rgba.slice();
    const result = restore(rgba, f.w, f.h, f.b, f.palette, f.options);
    assert.ok(result, f.name); assert.ok(result.sourceErasureVerified);
    let cores = 0, preserved = 0;
    for (let y = 0; y < f.h; y++) for (let x = 0; x < f.w; x++) {
        const i = y * f.w + x, k = i * 4;
        const inGlyph = glyphs[index].some(([l,t,r,b]) => x>=l && x<=r && y>=t && y<=b);
        if (rgba[k] < 100 && inGlyph) { assert.equal(result.rgba[k+3], 255, 'remove each dark glyph core'); cores++; }
        const nearGlyph = glyphs[index].some(([l,t,r,b]) => x>=l-2 && x<=r+2 && y>=t-2 && y<=b+2);
        if (rgba[k] < 220 && !nearGlyph) { assert.equal(result.rgba[k+3], 0, 'preserve rim and neighbouring text'); preserved++; }
    }
    assert.ok(cores >= 24 && preserved >= 100);
    assert.deepEqual(rgba, original);
    assert.equal(restore(rgba,f.w,f.h,f.b,f.palette,{...f.options,vertical:false}),null);
    assert.equal(restore(rgba,f.w,f.h,f.b,f.palette,{...f.options,auxiliary:[[0,0,3,3]]}),null);
    assert.equal(restore(rgba,f.w,f.h,f.b,f.palette,{...f.options,excluded:[f.b]}),null);
    const colored=rgba.slice(); for(let i=0;i<colored.length;i+=4)colored[i+1]=Math.max(0,colored[i+1]-30);
    assert.equal(restore(colored,f.w,f.h,f.b,f.palette,f.options),null,'colored artwork is not neutral balloon paper');
}
console.log('PASS: 2 real narrow balloons, glyph erasure, rim/neighbour preservation and 8 rejection controls');
