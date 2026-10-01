// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
// Production contrast and source-outline guards; no DOM or rasterizer emulation.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserSourceTextColor.swift'), 'utf8');
const script = source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const context = vm.createContext({});
vm.runInContext(script + '\nglobalThis.api={darkPair:aidokuDarkSurfaceSourceOutline,outline:aidokuReadableSourceOutline,adjust:aidokuAdjustInkForContrast,contrast:aidokuSourceColorContrast,lum:aidokuSourceColorLuminance};', context);
const { outline, adjust, contrast, lum } = context.api;
const plain = value => JSON.parse(JSON.stringify(value));
const sample = {foreground:[245,245,245],stroke:[24,24,24],confidence:{stroke:.8}};
const result = outline(sample, sample.foreground, [.80,.95], 24);
assert.ok(result, 'observed dark outline can retain pale source fill on a verified light surface');
assert.deepEqual(plain(result.foreground), sample.foreground);
assert.deepEqual(plain(result.stroke), sample.stroke);
assert.ok(result.minimumContrast >= 4.5);
assert.equal(result.width, 24 * .035);
assert.equal(result.expansion, result.width / 2);
assert.ok(outline(sample, sample.foreground, [.80,.95], 100).width <= 1.15);
assert.equal(outline(sample, sample.foreground, [.01,.03], 24), null, 'already readable fill needs no added outline');
assert.equal(outline(sample, sample.foreground, [0,1], 24), null, 'a mixed art surface is not made safe by an outline');
assert.equal(outline(sample, sample.foreground, [.8,.95], 11), null, 'small counters must not be swallowed');
assert.equal(outline({...sample,confidence:{stroke:.54}},sample.foreground,[.8,.95],24),null);
assert.equal(outline({...sample,stroke:[230,230,230]},sample.foreground,[.8,.95],24),null);
assert.equal(outline(sample,sample.foreground,[.95,.8],24),null);
assert.equal(outline(sample,sample.foreground,[NaN,.8],24),null);
assert.equal(outline(sample,sample.foreground,null,24),null);
// A dark glyph whose white edge provides all contrast needs a visible outer
// band at phone CSS sizes. Stroke-first painting leaves the core unchanged.
const dark = {foreground:[14,14,14],stroke:[251,251,250],confidence:{stroke:.9},
    widthEvidence:{relativeToGlyph:.04545}};
for (const size of [12,16,24,48]) {
    const visible = outline(dark,dark.foreground,[0,.01],size);
    assert.ok(visible.expansion>=1,'dark-on-dark source must not rely on a subpixel white hairline');
    assert.ok(visible.width<=Math.min(3.5,size*.2),'outline stays bounded relative to text');
    assert.deepEqual(plain(visible.foreground),dark.foreground);
    assert.ok(visible.minimumContrast>=4.5);
}
assert.equal(outline({...dark,stroke:null},dark.foreground,[0,.01],24),null,
    'a black background alone cannot invent an outline');
const nativeDarkFixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/dark-source-outline.json'))).fixtures;
for(const fixture of nativeDarkFixtures){
    const {sample,ring,fontSize}=fixture;
    const kept=context.api.darkPair(sample,ring,fontSize);
    assert.ok(kept,'actual dark source outline retains its own native roles');
    assert.deepEqual(plain(kept.foreground),[0,0,0]);
    assert.ok(kept.stroke.every(v=>v>=225));
    assert.ok(kept.width>=2&&kept.width<=Math.max(2,fontSize*.25));
    assert.equal(context.api.darkPair({...sample,sourceInk:{...sample.sourceInk,foreground:[248,248,248]}},ring,fontSize),null,
        'bare white source text cannot be turned into a hollow glyph');
    assert.equal(context.api.darkPair(sample,{...ring,kind:'paper'},fontSize),null);
    assert.equal(context.api.darkPair(sample,{...ring,uniform:.2},fontSize),null);
    assert.equal(context.api.darkPair(sample,{...ring,hug:.8},fontSize),null);
    assert.equal(context.api.darkPair({...sample,captionBackground:[220,220,220]},ring,fontSize),null);
    const missing={background:[1,1,1],confidence:{background:1}};
    assert.equal(context.api.darkPair(missing,ring,fontSize),null,'a missing palette cannot invent source roles');
    assert.ok(context.api.darkPair(missing,ring,fontSize,true),'native ring can recover a certified source position');
    assert.equal(context.api.darkPair(missing,{...ring,reached:.5},fontSize,true),null);
    assert.equal(context.api.darkPair(missing,{...ring,surface:[0,0,0,0]},fontSize,true),null);

}
const pale = [210,200,190], background = [117,117,117];
const measure = rgb => contrast(rgb,true,1,background);
assert.ok(measure(pale)<4.5);
const corrected = plain(adjust(pale,measure));
assert.ok(measure(corrected)>=4.5);
assert.ok(corrected.every((v,i)=>v>=pale[i]),'choose the small correction toward white, not a much larger dark inversion');
assert.ok(corrected[0]>=corrected[1]&&corrected[1]>=corrected[2],'retain warm channel order');
const readable = [120,0,20];
assert.deepEqual(plain(adjust(readable, rgb=>contrast(rgb,true,1,[250,250,250]))),readable);
const ink = [220,100,120];
const correctedRed = plain(adjust(ink,rgb=>contrast(rgb,true,1,[245,245,245])));
assert.ok(contrast(correctedRed,true,1,[245,245,245])>=4.5);
assert.ok(correctedRed[0]>correctedRed[2]&&correctedRed[2]>correctedRed[1]);
console.log('PASS source color outline recovery: verified outline, bounded width, unsafe surface rejection, minimum color correction');
