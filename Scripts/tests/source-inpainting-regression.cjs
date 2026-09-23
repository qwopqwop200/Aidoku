// Production reconstruction, with known-background oracles and captured corpus crops.
// node Scripts/tests/source-inpainting-regression.cjs [--source path/to/BrowserSourcePanelRestoration.swift]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const at = process.argv.indexOf('--source');
const file = at < 0 ? path.resolve(__dirname, '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift') : process.argv[at + 1];
const script = fs.readFileSync(file, 'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore = new Function(script + ';return aidokuRestoreSourcePanel;')();
let passed = 0;
function test(name, run) { run(); passed++; console.log('PASS ' + name); }
function scene(background, foreground, count = 4) {
    const w = 180, h = 100, rgba = new Uint8ClampedArray(w * h * 4), ink = [];
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) rgba.set([...background(x, y), 255], (y * w + x) * 4);
    const clean = rgba.slice();
    for (let k = 0; k < count; k++) for (let y = 36; y < 63; y++) for (let x = 32 + k * 30; x < 50 + k * 30; x++) {
        if (x >= 36 + k * 30 && y >= 41 && y < 58) continue;
        const i = y * w + x; rgba.set([...foreground, 255], i * 4); ink.push(i);
    }
    return { w, h, rgba, clean, ink, b: [29, 32, count * 30 - 8, 36] };
}
function oracle(s, palette, tolerance = 4) {
    const before = s.rgba.slice(), out = restore(s.rgba, s.w, s.h, s.b, palette, { readabilityGate: true });
    assert.ok(out, 'source lettering should be restored');
    assert.deepEqual(s.rgba, before, 'input is immutable');
    let error = 0, samples = 0;
    for (const i of s.ink) {
        assert.equal(out.rgba[i * 4 + 3], 255, 'all owned ink is erased');
        for (let c = 0; c < 3; c++) { error += Math.abs(out.rgba[i * 4 + c] - s.clean[i * 4 + c]); samples++; }
    }
    assert.ok(error / samples <= tolerance, `reconstruction MAE ${error / samples}`);
    for (let i = 0; i < s.w * s.h; i++) {
        const x = i % s.w, y = Math.floor(i / s.w);
        if (x < 12 || x >= s.w - 12 || y < 12 || y >= s.h - 12) assert.equal(out.rgba[i * 4 + 3], 0, 'outside context stays untouched');
    }
    return out;
}
for (const [name, bg, fg] of [
    ['dark dialog / white text', [30, 36, 48], [250, 250, 250]],
    ['colored UI / pale text', [204, 92, 131], [255, 247, 235]],
    ['colored ink / pastel', [245, 229, 174], [116, 51, 62]],
    ['low contrast gray text', [255, 255, 255], [185, 185, 185]],
]) test(name + ' with unavailable display palette', () => oracle(scene(() => bg, fg), null));
test('two-character caption with unavailable palette', () => oracle(scene(() => [228, 241, 246], [15, 48, 83], 2), null));
test('curved colored gradient uses local reconstruction', () => {
    const bg = (x, y) => [220 + 26 * Math.cos(x / 26), 202 + 22 * Math.sin(y / 24), 166 + 30 * Math.sin(x / 31)];
    oracle(scene(bg, [12, 18, 21]), { foreground: [12, 18, 21], background: [220, 220, 190], confidence: { foreground: 1 } }, 8);
});
test('high frequency texture does not masquerade as a smooth surface', () => {
    const s = scene((x, y) => (x + y) % 2 ? [145, 202, 236] : [249, 144, 192], [4, 5, 7]);
    assert.equal(restore(s.rgba, s.w, s.h, s.b, { foreground: [4, 5, 7], background: [220, 200, 220] }, { readabilityGate: true }), null);
});
test('frame-connected art is never erased by palette recovery', () => {
    const s = scene(() => [244, 234, 210], [20, 45, 70]);
    for (let y = 0; y < s.h; y++) s.rgba.set([20, 45, 70, 255], (y * s.w + 156) * 4);
    const out = oracle(s, null);
    for (let y = 0; y < s.h; y++) assert.equal(out.rgba[(y * s.w + 156) * 4 + 3], 0);
});
test('transparent input and oversized work remain rejected', () => {
    const s = scene(() => [244, 234, 210], [20, 45, 70]); s.rgba[3] = 128;
    assert.equal(restore(s.rgba, s.w, s.h, s.b, null, { readabilityGate: true }), null);
    assert.equal(restore(new Uint8ClampedArray(513 * 513 * 4), 513, 513, [24, 24, 100, 100], null, { readabilityGate: true }), null);
});
for (const vertical of [false, true]) for (const [bg, fg] of [
    [[236, 222, 192], [116, 42, 62]], [[255, 255, 255], [8, 8, 8]],
    [[30, 36, 48], [245, 245, 245]],
]) test(`owned ruby pixel recall / vertical=${vertical} / ink=${fg}`, () => {
    const s = scene(() => bg, fg), ruby = [], neighbor = [];
    const paint = (x, y, list) => { const i = y*s.w+x; s.rgba.set([...fg, 255], i*4); list.push(i); };
    // Several full strokes and isolated one-pixel marks all have OCR ownership.
    const auxiliary = vertical ? [148, 30, 9, 38] : [32, 14, 112, 9];
    for (let k = 0; k < 3; k++) {
        const x = vertical ? 150 : 35+k*34, y = vertical ? 34+k*11 : 16;
        for (let yy=y; yy<y+3; yy++) for (let xx=x; xx<x+2; xx++) paint(xx, yy, ruby);
        paint(x+4, y+5, ruby);
    }
    // The same ink outside the annotation must survive, including its frame.
    for (let y=0; y<s.h; y++) paint(172, y, neighbor);
    const before=s.rgba.slice();
    const out=restore(s.rgba,s.w,s.h,s.b,{foreground:fg,background:bg,confidence:{foreground:1}},
        {readabilityGate:true,vertical,auxiliary:[auxiliary]});
    assert.ok(out);
    for (const i of [...s.ink,...ruby]) {
        assert.equal(out.rgba[i*4+3],255,'every annotated body/ruby pixel is covered');
        assert.ok(bg.every((v,c)=>Math.abs(v-out.rgba[i*4+c])<=2),'reconstruction matches known background');
    }
    for (const i of neighbor) assert.equal(out.rgba[i*4+3],0,'unowned ink stays untouched');
    assert.deepEqual(s.rgba,before);
});
test('native-resolution crop between old and new limits preserves fine strokes', () => {
    const w=440,h=420,p=new Uint8ClampedArray(w*h*4),ink=[];
    for(let i=0;i<w*h;i++)p.set([236,224,207,255],i*4);
    for(let k=0;k<5;k++)for(let y=48+k*58;y<73+k*58;y++)for(let x=210;x<230;x++){
        if(x>213&&y>51+k*58&&y<70+k*58)continue;
        const i=y*w+x;p.set([30,30,30,255],i*4);ink.push(i);
    }
    const result=restore(p,w,h,[204,40,32,295],{foreground:[30,30,30],background:[236,224,207]},
        {readabilityGate:true,vertical:true});
    assert.ok(result,'retain native detail instead of rejecting a 184800-pixel crop');
    for(const i of ink){
        assert.equal(result.rgba[i*4+3],255);
        assert.ok([236,224,207].every((v,c)=>Math.abs(v-result.rgba[i*4+c])<=2));
    }
});
test('faint ruby without a dark core is erased only with a clear annotated surround', () => {
    const s=scene(()=>[245,235,220],[25,25,25]),ruby=[];
    for(let k=0;k<4;k++)for(let y=15;y<20;y++)for(let x=35+k*25;x<37+k*25;x++){
        const i=y*s.w+x;s.rgba.set([179,172,161,255],i*4);ruby.push(i);
    }
    const palette={foreground:[25,25,25],background:[245,235,220]};
    const out=restore(s.rgba,s.w,s.h,s.b,palette,{readabilityGate:true,auxiliary:[[32,13,85,10]]});
    assert.ok(out);
    for(const i of ruby){assert.equal(out.rgba[i*4+3],255);assert.ok([245,235,220].every((v,c)=>Math.abs(v-out.rgba[i*4+c])<=2));}
    const unowned=restore(s.rgba,s.w,s.h,s.b,palette,{readabilityGate:true});
    assert.ok(unowned);
    for(const i of ruby)assert.equal(unowned.rgba[i*4+3],0,'faint unannotated artwork is not recruited');
    // A connected neighboring frame disqualifies the clear surround.
    for(let y=0;y<s.h;y++)for(let x=30;x<34;x++)s.rgba.set([25,25,25,255],(y*s.w+x)*4);
    const art=restore(s.rgba,s.w,s.h,s.b,palette,{readabilityGate:true,auxiliary:[[32,13,85,10]]});
    if(art)for(let y=0;y<s.h;y++)assert.equal(art.rgba[(y*s.w+31)*4+3],0);
});
const fixtures = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-diverse.json')));
for (const f of fixtures) test('captured ' + f.name + '/' + f.id, () => {
    const rgba = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64'))), before = rgba.slice();
    const out = restore(rgba, f.w, f.h, f.b, f.palette, { readabilityGate: true, vertical: f.vertical, sampleScale: f.scale, auxiliary: f.auxiliary || [] });
    assert.ok(out, 'captured source supports restoration');
    assert.deepEqual(rgba, before);
    assert.ok(out.erased > 0 && out.erased < f.w * f.h);
    assert.ok(out.surfaceQuality.safe);
    if (f.palette?.foreground) {
        let checked = 0;
        for (let y = Math.floor(f.b[1]); y < Math.ceil(f.b[1] + f.b[3]); y++)
            for (let x = Math.floor(f.b[0]); x < Math.ceil(f.b[0] + f.b[2]); x++) {
                const p = (y * f.w + x) * 4, ink = f.palette.foreground;
                if (!ink.every((v, c) => Math.abs(v - rgba[p + c]) <= 16)) continue;
                checked++;
                assert.equal(out.rgba[p + 3], 255, 'captured source ink is covered completely');
                assert.ok(Math.max(...ink.map((v, c) => Math.abs(v - out.rgba[p + c]))) > 32,
                    'reconstructed pixels do not retain the source ink');
            }
        assert.ok(checked > 0);
    }
    for (let x = 0; x < f.w; x++) {
        assert.equal(out.rgba[x * 4 + 3], 0);
        assert.equal(out.rgba[((f.h - 1) * f.w + x) * 4 + 3], 0);
    }
});
const capturedRuby=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-captured-ruby.json')));
for(const f of capturedRuby)test('captured annotated ruby / '+f.name+'/'+f.id,()=>{
    const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
    const out=restore(rgba,f.w,f.h,f.b,f.palette,{readabilityGate:true,vertical:f.vertical,auxiliary:f.auxiliary,sampleScale:f.scale});
    assert.ok(out);const indices=new Set();let probes=0;
    for(const b of f.auxiliary)for(let y=Math.floor(b[1]);y<Math.ceil(b[1]+b[3]);y++)for(let x=Math.floor(b[0]);x<Math.ceil(b[0]+b[2]);x++)indices.add(y*f.w+x);
    for(const i of indices){
        const p=i*4,fg=f.palette.foreground,bg=f.palette.background;
        if(Math.max(...fg.map((v,c)=>Math.abs(v-rgba[p+c])))>24||Math.max(...bg.map((v,c)=>Math.abs(v-rgba[p+c])))<40)continue;
        probes++;assert.equal(out.rgba[p+3],255,'annotated observed ruby ink is covered');
        assert.ok(Math.max(...fg.map((v,c)=>Math.abs(v-out.rgba[p+c])))>=32,'source ink is absent from reconstructed pixels');
    }
    assert.equal(probes,f.expectedRubyPixels);assert.deepEqual(rgba,before);
});
const rubyOracles=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-ruby.json'))).cases;
for(const f of rubyOracles)test('raster glyph pixel oracle / '+f.name,()=>{
    const decode=s=>new Uint8ClampedArray(zlib.inflateSync(Buffer.from(s,'base64')));
    const rgba=decode(f.rgba),clean=decode(f.clean),labels=decode(f.labels),art=decode(f.art),before=rgba.slice();
    const out=restore(rgba,f.w,f.h,f.b,f.palette,{readabilityGate:true,vertical:f.vertical,auxiliary:f.auxiliary});
    assert.ok(out);let body=0,ruby=0;
    for(let i=0;i<labels.length;i++){
        if(art[i])assert.equal(out.rgba[i*4+3],0,'frame artwork survives');
        // Ignore near-invisible raster fringes when counting observable ink.
        if(!labels[i]||Math.max(...[0,1,2].map(c=>Math.abs(rgba[i*4+c]-clean[i*4+c])))<12)continue;
        if(labels[i]===2)ruby++;else body++;
        assert.equal(out.rgba[i*4+3],255,'every observable body and ruby pixel is covered');
        for(let c=0;c<3;c++)assert.ok(Math.abs(out.rgba[i*4+c]-clean[i*4+c])<=2,'known background is accurately reconstructed');
    }
    assert.ok(body>2000&&ruby>100);assert.deepEqual(rgba,before);
});
const fadedOracles=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-faded-body.json'))).cases;
const haloOracles=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-halo.json'))).cases;
for(const f of [...fadedOracles,...haloOracles])test('faded body and outline pixel oracle / '+f.name,()=>{
    const decode=s=>new Uint8ClampedArray(zlib.inflateSync(Buffer.from(s,'base64')));
    const rgba=decode(f.rgba),clean=decode(f.clean),labels=decode(f.labels),art=decode(f.art),before=rgba.slice();
    const out=restore(rgba,f.w,f.h,f.b,f.palette,{readabilityGate:true,vertical:f.vertical});
    assert.ok(out);let faint=0;
    for(let i=0;i<labels.length;i++){
        if(art[i])assert.equal(out.rgba[i*4+3],0,'unowned frame is preserved');
        if(!labels[i]||Math.max(...[0,1,2].map(c=>Math.abs(rgba[i*4+c]-clean[i*4+c])))<12)continue;
        if(labels[i]===2)faint++;
        assert.equal(out.rgba[i*4+3],255,'observed letters and outlines cannot survive successful restoration');
        for(let c=0;c<3;c++)assert.ok(Math.abs(out.rgba[i*4+c]-clean[i*4+c])<=2,'flat and gradient backgrounds are recovered');
    }
    assert.ok(faint>500);assert.deepEqual(rgba,before);
});
const residualCaptures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-captured-residuals.json')));
for(const f of residualCaptures)test('captured faded source residue / '+f.name+'/'+f.id,()=>{
    const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
    const out=restore(rgba,f.w,f.h,f.b,f.palette,{readabilityGate:true,vertical:f.vertical,sampleScale:f.scale,auxiliary:f.auxiliary});
    assert.ok(out);assert.ok(f.probePixels.length>1000);
    for(const i of f.probePixels){
        assert.equal(out.rgba[i*4+3],255,'captured visible source ink must be covered');
        const rgb=Array.from(out.rgba.subarray(i*4,i*4+3));
        assert.ok(f.polarity==='dark-on-light'?Math.min(...rgb)>=240:Math.max(...rgb)<=45,'observed source residue is absent');
    }
    assert.deepEqual(rgba,before);
});
test('captured faint balloon contours crossing the OCR rectangle stay untouched',()=>{
    const f=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-crossing-art.json')));
    const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64')));
    const out=restore(rgba,f.w,f.h,f.b,f.palette,{readabilityGate:true,vertical:f.vertical});
    assert.ok(out);assert.ok(f.artProbePixels.length>50);
    for(const i of f.artProbePixels)assert.equal(out.rgba[i*4+3],0,'faint contour is not a clipped glyph');
});
test('faded body ownership requires a clear surrounding ring',()=>{
    const f=fadedOracles[0],decode=s=>new Uint8ClampedArray(zlib.inflateSync(Buffer.from(s,'base64')));
    const rgba=decode(f.rgba),labels=decode(f.labels),[x,y,w,h]=f.b;
    // A connected frame intersects the ownership ring. Its faint extensions
    // share the text hue but do not become new glyph seeds.
    for(let xx=Math.floor(x)-2;xx<=Math.ceil(x+w)+1;xx++)for(const yy of [Math.floor(y)-2,Math.ceil(y+h)+1])
        rgba.set([...f.palette.foreground,255],(yy*f.w+xx)*4);
    const out=restore(rgba,f.w,f.h,f.b,f.palette,{readabilityGate:true});
    if(out)for(let i=0;i<labels.length;i++){
        if(labels[i]===2&&i%f.w>x+w-40)assert.equal(out.rgba[i*4+3],0,'uncorroborated faint component remains protected');
    }
});
const speckles = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-faint-speckle.json')));
for (const f of speckles) test('faint paper speckle keeps layout safe / ' + f.name + '/' + f.id, () => {
    const rgba = new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64'))), before = rgba.slice();
    const out = restore(rgba, f.w, f.h, f.b, f.palette,
        { readabilityGate: true, vertical: f.vertical, sampleScale: f.scale, auxiliary: f.auxiliary || [] });
    assert.ok(out);
    assert.deepEqual(rgba, before);
    for (const i of f.safePixels) assert.equal(out.layoutSafe[i], 1, 'faint isolated noise is not a new drawing obstacle');
});
const overlay = fs.readFileSync(path.resolve(__dirname, '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'), 'utf8');
const budgetScript = overlay.slice(overlay.indexOf('const cleanupCacheState ='), overlay.indexOf('const appendSourceCleanup ='));
function budgetHarness(items, globalState = {}, source = {}) {
    const sourceImage = Object.assign({complete:true,naturalWidth:3000,naturalHeight:3000,src:'fixture',addEventListener(){}},source);
    let reads=0,calls=0;
    const env={globalThis:globalState,sourceImage,items,appearance:{inpaintingEnabled:true,preserveSourceTextColor:true,preserveSourceBackgroundColor:true},
        opacity:1,cleanupImageGeometry:{frame:[0,0,430,430]},scrollX:0,scrollY:0,
        cachedSourceSample(){return {foreground:[20,20,20],background:[240,240,240]};},
        aidokuRestoreSourcePanel(p,w,h){calls++;return {rgba:new Uint8ClampedArray(w*h*4),layoutSafe:new Uint8Array(w*h),erased:1};},
        aidokuCleanupClip(){return 'none';},root:{dataset:{},appendChild(){}},document:{createElement(){const canvas={style:{},setAttribute(){}};
            canvas.getContext=()=>({drawImage(){},getImageData(){reads+=canvas.width*canvas.height;return {data:new Uint8ClampedArray(canvas.width*canvas.height*4)};},
                createImageData(w,h){return {data:new Uint8ClampedArray(w*h*4)};},putImageData(){}});return canvas;}}};
    const run=new Function('env',`with(env){${budgetScript};return {appendRestoredSourcePanel,storeCleanup,cache:cleanupCache,
        audit:panelRestorationAudit,get spent(){return panelRestorationPixelLimit-panelRestorationBudget;}};}`)(env);
    return {run,get reads(){return reads;},get calls(){return calls;}};
}
test('page allowance retains native detail for later regions and remains bounded',()=>{
    const items=Array.from({length:80},(_,i)=>({id:i,sourcePanelRestorationEligible:true,sourceColorEligible:true,
        sourceBounds:[.05+(i%10)*.09,.05+Math.floor(i/10)*.09,.028,.028]}));
    const h=budgetHarness(items);
    for(const item of items)assert.equal(h.run.appendRestoredSourcePanel(item),true);
    assert.equal(h.run.audit.length,80);
    assert.ok(h.run.audit.every(a=>a.scale===1),'late regions keep native fine strokes');
    assert.ok(h.reads>393216&&h.reads<=1572864,'larger allowance is actually spent within the page cap');
    assert.equal(h.reads,h.run.spent);
    assert.ok(h.run.cache.bytes>4*1024*1024&&h.run.cache.bytes<=16*1024*1024,'real retained buffers use the larger cache');
    const crowded=budgetHarness([...items,...items,...items]);
    for(const item of [...items,...items,...items])crowded.run.appendRestoredSourcePanel(item);
    assert.ok(crowded.reads<=1572864);
});
test('larger cleanup cache evicts by bytes and releases the previous page',()=>{
    const state={},h=budgetHarness([],state),pixels=220000;
    for(let i=0;i<40;i++)h.run.storeCleanup(String(i),{restored:{rgba:new Uint8ClampedArray(pixels*4),layoutSafe:new Uint8Array(pixels)},luminance:new Uint8Array(pixels)},pixels);
    assert.ok(h.run.cache.entries.size<40);
    assert.ok(!h.run.cache.entries.has('0')&&h.run.cache.entries.has('39'));
    assert.equal(h.run.cache.bytes,[...h.run.cache.entries.values()].reduce((n,e)=>n+e.restored.rgba.byteLength+e.restored.layoutSafe.byteLength+e.luminance.byteLength,0));
    assert.ok(h.run.cache.bytes<=16*1024*1024);
    budgetHarness([],state,{src:'next-page'});
    assert.equal(h.run.cache.bytes,0);assert.equal(h.run.cache.entries.size,0);
});
const mixedInkCaptures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-mixed-ink.json')));
for(const f of mixedInkCaptures)test('captured independently colored source lettering / '+f.name,()=>{
    const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
    const out=restore(rgba,f.w,f.h,f.b,f.palette,{readabilityGate:true,vertical:f.vertical,sampleScale:f.scale,auxiliary:f.auxiliary});
    assert.ok(out);assert.deepEqual(rgba,before);
    for(const i of f.inkIndices){
        assert.equal(out.rgba[i*4+3],255,'second observed ink must be erased');
        assert.ok(Math.max(...(f.expectedInk||f.palette.lettering.color).map((v,c)=>Math.abs(v-out.rgba[i*4+c])))>40,'no source-colored residue');
    }
    for(const i of f.artIndices)assert.equal(out.rgba[i*4+3],0,'matching-color peripheral contour stays untouched');
    if(f.haloIndices){
        const bright=f.haloIndices.filter(i=>{const p=out.rgba[i*4+3]?out.rgba:rgba;return Math.min(p[i*4],p[i*4+1],p[i*4+2])>=250;}).length;
        assert.ok(bright<=f.maxBrightResidual,`${bright} white source silhouettes remain`);
    }
});
const chromaCaptures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-chroma-fragments.json')));
for(const f of chromaCaptures)test('captured saturated JPEG islands do not strand owned outlines / '+f.name,()=>{
    const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
    const out=restore(rgba,f.w,f.h,f.b,f.palette,f.options);assert.ok(out);assert.deepEqual(rgba,before);
    let remaining=0,ink=0;
    for(let y=Math.ceil(f.b[1]);y<f.b[1]+f.b[3];y++)for(let x=Math.ceil(f.b[0]);x<f.b[0]+f.b[2];x++){
        const i=y*f.w+x;
        if(Math.min(rgba[i*4],rgba[i*4+1],rgba[i*4+2])<=235)continue;
        ink++;if(!out.rgba[i*4+3])remaining++;
    }
    assert.ok(ink>13000);assert.ok(remaining<=f.baselineRemainingWhite*(1-f.minimumReduction),`${remaining} visible outline pixels remain`);
    // The red decorative ribbon is adjacent to the same text and must survive.
    assert.ok(f.artIndices.length>100);
    for(const i of f.artIndices)assert.equal(out.rgba[i*4+3],0,'decorative ribbon remains intact');
});
for(const role of ['verified','single-band','single-component','exterior-art'])test('secondary ink evidence / '+role,()=>{
    const w=240,h=120,rgba=new Uint8ClampedArray(w*h*4),second=[],bg=[244,234,210],purple=[125,65,155];
    for(let i=0;i<w*h;i++)rgba.set([...bg,255],i*4);
    for(let k=0;k<6;k++)for(let y=40;y<70;y++)for(let x=30+k*30;x<48+k*30;x++){
        if(x>34+k*30&&y>44&&y<65)continue;
        const i=y*w+x;rgba.set([...(k<3?[12,12,12]:purple),255],i*4);if(k>=3)second.push(i);
    }
    for(let y=0;y<h;y++)rgba.set([...purple,255],(y*w+232)*4);
    const evidence={color:purple,bands:role==='single-band'?1:3,components:role==='single-component'?1:3,support:.05,exterior:role==='exterior-art'?.2:0};
    const before=rgba.slice(),out=restore(rgba,w,h,[25,30,185,50],{foreground:[12,12,12],background:bg,confidence:{foreground:1},lettering:evidence},{readabilityGate:true});
    assert.ok(out);assert.deepEqual(rgba,before);
    assert.equal(second.filter(i=>out.rgba[i*4+3]).length,role==='verified'?second.length:0);
    if(role==='verified')for(const i of second)for(let c=0;c<3;c++)assert.ok(Math.abs(out.rgba[i*4+c]-bg[c])<=1);
    for(let y=0;y<h;y++)assert.equal(out.rgba[(y*w+232)*4+3],0);
});

for(const role of ['repeated','single-component','exterior-art','unconfirmed'])test('native secondary candidate ownership / '+role,()=>{
    const w=240,h=120,rgba=new Uint8ClampedArray(w*h*4),bg=[244,234,210],purple=[125,65,155],second=[];
    for(let i=0;i<w*h;i++)rgba.set([...bg,255],i*4);
    for(let k=0;k<6;k++)for(let y=40;y<70;y++)for(let x=30+k*30;x<48+k*30;x++){
        if(x>34+k*30&&y>44&&y<65)continue;
        const i=y*w+x;rgba.set([...(k<3?[12,12,12]:purple),255],i*4);if(k>=3)second.push(i);
    }
    if(role==='single-component')for(let x=120;x<198;x++)rgba.set([...purple,255],(45*w+x)*4);
    if(role==='exterior-art')for(let y=0;y<20;y++)for(let x=0;x<w;x++)rgba.set([...purple,255],(y*w+x)*4);
    const palette={foreground:[12,12,12],background:bg,confidence:{foreground:1},
        sourceInk:{stroke:purple,confidence:{stroke:role==='unconfirmed'?.3:.9}}};
    const before=rgba.slice(),out=restore(rgba,w,h,[25,30,185,50],palette,{readabilityGate:true});
    assert.ok(out);assert.deepEqual(rgba,before);
    assert.equal(second.filter(i=>out.rgba[i*4+3]).length,role==='repeated'?second.length:0);
});

test('joint source ink follows the inverted ruby restoration polarity',()=>{
    const w=240,h=120,rgba=new Uint8ClampedArray(w*h*4),bg=[11,21,45],primary=[243,243,243],second=[130,190,100],ink=[];
    for(let i=0;i<w*h;i++)rgba.set([...bg,255],i*4);
    for(let k=0;k<6;k++)for(let y=40;y<70;y++)for(let x=30+k*30;x<48+k*30;x++){
        if(x>34+k*30&&y>44&&y<65)continue;
        const i=y*w+x;rgba.set([...(k<3?primary:second),255],i*4);ink.push(i);
    }
    const palette={foreground:primary,background:bg,confidence:{foreground:1},
        lettering:{color:second,bands:3,components:3,support:.05,exterior:0}};
    const out=restore(rgba,w,h,[25,30,185,50],palette,{readabilityGate:true,auxiliary:[[26,25,4,3]]});assert.ok(out);
    for(const i of ink){assert.equal(out.rgba[i*4+3],255);for(let c=0;c<3;c++)assert.ok(Math.abs(out.rgba[i*4+c]-bg[c])<=1);}
});

const resamplingCaptures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-resampling.json')));
for(const f of resamplingCaptures)test('separate layer downsampling does not expose erased outline / '+f.name+'/'+f.id,()=>{
    const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
    const out=restore(rgba,f.w,f.h,f.b,f.palette,f.options);assert.ok(out);assert.deepEqual(rgba,before);
    let artifacts=0,blocks=0;
    for(let dy=0;dy<2;dy++)for(let dx=0;dx<2;dx++)for(let y=dy;y+1<f.h;y+=2)for(let x=dx;x+1<f.w;x+=2){
        let alpha=0,letter=false;const src=[0,0,0],patch=[0,0,0],ideal=[0,0,0];
        for(let yy=y;yy<=y+1;yy++)for(let xx=x;xx<=x+1;xx++){
            const p=(yy*f.w+xx)*4,a=out.rgba[p+3]/255;alpha+=a/4;
            if(Math.min(rgba[p],rgba[p+1],rgba[p+2])>230)letter=true;
            for(let c=0;c<3;c++){
                src[c]+=rgba[p+c]/4;patch[c]+=out.rgba[p+c]*a/4;
                ideal[c]+=(rgba[p+c]*(1-a)+out.rgba[p+c]*a)/4;
            }
        }
        if(!letter)continue;blocks++;
        const error=Math.max(...ideal.map((v,c)=>Math.abs(v-(patch[c]+src[c]*(1-alpha)))));
        if(error>8)artifacts++;
    }
    assert.ok(blocks>100);assert.ok(artifacts<=f.maxArtifactBlocks,`${artifacts} source-outline resampling artifacts`);
});

const uncertainSurfaces=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-surface-retry.json')));
for(const f of uncertainSurfaces)test('uncertain white caption surface is not consumed by wider fringe / '+f.name,()=>{
    const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
    assert.equal(restore(rgba,f.w,f.h,f.b,f.palette,{readabilityGate:true,vertical:f.vertical,sampleScale:f.scale,auxiliary:f.auxiliary}),null);
    assert.deepEqual(rgba,before);
});

const codecIslands=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-codec-islands.json')));
for(const f of codecIslands){
    test('measured outlined glyphs recover codec fragments / '+f.name,()=>{
        const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
        const out=restore(rgba,f.w,f.h,f.b,f.palette,f.options);assert.ok(out);assert.deepEqual(rgba,before);
        let remaining=0;
        for(let y=Math.ceil(f.b[1]);y<f.b[1]+f.b[3];y++)for(let x=Math.ceil(f.b[0]);x<f.b[0]+f.b[2];x++){
            const i=y*f.w+x;if(Math.min(rgba[i*4],rgba[i*4+1],rgba[i*4+2])>235&&!out.rgba[i*4+3])remaining++;
        }
        assert.ok(remaining<=f.maximumRemainingWhite,`${remaining} outline pixels remain`);
        for(const i of f.artIndices)assert.equal(out.rgba[i*4+3],0,'colored decorative ribbon stays untouched');
    });
    for(const control of ['different-hue-detail','connected-to-exterior'])test('codec recovery preserves '+control,()=>{
        const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),art=[];
        if(control==='different-hue-detail')for(let y=37;y<39;y++)for(let x=174;x<176;x++){
            const i=y*f.w+x;rgba.set([225,40,120,255],i*4);art.push(i);
        }
        else for(let y=0;y<=43;y++){const i=y*f.w+174;rgba.set([110,130,220,255],i*4);art.push(i);}
        const before=rgba.slice(),out=restore(rgba,f.w,f.h,f.b,f.palette,f.options);assert.deepEqual(rgba,before);
        if(out)for(const i of art)assert.equal(out.rgba[i*4+3],0,'unowned artwork must survive');
    });
}
const donorCapture=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-diffusion-donors.json')));
for(const f of donorCapture)test('faster diffusion cannot spread drawing donors / '+f.name+'/'+f.id,()=>{
    const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64')));
    const out=restore(rgba,f.w,f.h,f.b,f.palette,{readabilityGate:true,vertical:f.vertical,sampleScale:f.scale,auxiliary:f.auxiliary});assert.ok(out);
    const dark=f.paperIndices.filter(i=>{const pixels=out.rgba[i*4+3]?out.rgba:rgba;return Math.min(pixels[i*4],pixels[i*4+1],pixels[i*4+2])<235;}).length;
    assert.ok(dark<=f.maxDarkPaperPixels,`${dark} originally white pixels pick up dark donor color`);
});
for(const [kind,span,limit] of [['saddle',70,.4],['saddle',100,.5],['cross',70,.18],['cross',100,.22],['lighting',40,.45],['lighting',70,.75],['lighting',100,1.1]])
    test(`smooth source-background reconstruction / ${kind}/${span}`,()=>{
        const w=256,h=192,rgba=new Uint8ClampedArray(w*h*4),ink=[];
        for(let y=0;y<h;y++)for(let x=0;x<w;x++){
            const u=(x-w/2)/w,v=(y-h/2)/h;
            const d=kind==='saddle'?u*u-v*v:kind==='cross'?u*v:Math.exp(-u*u*10-v*v*6)*.4;
            for(let c=0;c<3;c++)rgba[(y*w+x)*4+c]=185+span*d*(c===0?1:c===1?.8:.65);rgba[(y*w+x)*4+3]=255;
        }
        const clean=rgba.slice();
        for(let k=0;k<4;k++)for(let y=60;y<132;y++)for(let x=36+k*49;x<62+k*49;x++){
            if(x>41+k*49&&y>67&&y<124)continue;
            const i=y*w+x;rgba.set([20,20,20,255],i*4);ink.push(i);
        }
        const out=restore(rgba,w,h,[30,54,180,84],{foreground:[20,20,20],background:[185,185,185],confidence:{foreground:1}},{readabilityGate:true});assert.ok(out);
        let error=0;
        for(const i of ink){assert.equal(out.rgba[i*4+3],255);for(let c=0;c<3;c++)error+=Math.abs(out.rgba[i*4+c]-clean[i*4+c]);}
        assert.ok(error/(ink.length*3)<=limit,`background MAE ${error/(ink.length*3)}`);
    });


for(const mode of ['plain','ruby','art'])test('one-pixel body fringe is bounded and protects '+mode,()=>{
    const w=256,h=160,rgba=new Uint8ClampedArray(w*h*4),background=[242,238,226],foreground=[20,20,20];
    for(let i=0;i<w*h;i++)rgba.set([...background,255],i*4);
    for(let k=0;k<4;k++)for(let y=66;y<95;y++)for(let x=55+k*42;x<69+k*42;x++){
        if(x>58+k*42&&y>70&&y<90)continue;rgba.set([...foreground,255],(y*w+x)*4);
    }
    // A faint three-column tail starts just outside the old twelve-pixel mask.
    // Exactly its nearest column may be reconstructed; the farther two cannot.
    for(let x=40;x<=42;x++)for(let y=72;y<88;y++)rgba.set([236,232,220,255],(y*w+x)*4);
    if(mode==='art')for(let y=0;y<h;y++)rgba.set([...foreground,255],(y*w+42)*4);
    const before=rgba.slice(),out=restore(rgba,w,h,[50,61,155,39],
        {foreground,background,confidence:{foreground:1}},
        {readabilityGate:true,auxiliary:mode==='ruby'?[[40,72,3,16]]:[]});
    assert.ok(out);assert.deepEqual(rgba,before);
    for(let y=72;y<88;y++){
        for(const x of [40,41])assert.equal(out.rgba[(y*w+x)*4+3],0,'extra ring must not propagate again');
        const i=y*w+42;assert.equal(out.rgba[i*4+3],mode==='plain'?255:0,'only the plain-background body fringe may gain one pixel');
        if(mode==='plain')for(let c=0;c<3;c++)assert.ok(Math.abs(out.rgba[i*4+c]-background[c])<=2,'matches known clean paper');
    }
});
const onePixelCases=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-one-pixel.json'))).cases;
for(const f of onePixelCases)test('real one-pixel expansion footprint / '+f.name+'/'+f.id,()=>{
    const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
    const old=zlib.inflateSync(Buffer.from(f.baselineMask,'base64'));
    const out=restore(rgba,f.w,f.h,f.b,f.palette,{readabilityGate:true,vertical:f.vertical,sampleScale:f.scale,auxiliary:f.auxiliary});
    assert.ok(out);assert.deepEqual(rgba,before);
    for(let i=0;i<f.w*f.h;i++){
        if(old[i]||!out.rgba[i*4+3]||[0,1,2].every(c=>Math.abs(rgba[i*4+c]-out.rgba[i*4+c])<=1))continue;
        const x=i%f.w,y=i/f.w|0;let adjacent=false;
        for(let yy=Math.max(0,y-1);yy<=Math.min(f.h-1,y+1);yy++)
            for(let xx=Math.max(0,x-1);xx<=Math.min(f.w-1,x+1);xx++)if(old[yy*f.w+xx])adjacent=true;
        assert.ok(adjacent,'new erasure stays within one pixel of the original mask');
        assert.ok(!f.auxiliary.some(r=>x>=r[0]-21&&x<=r[0]+r[2]+21&&y>=r[1]-21&&y<=r[1]+r[3]+21),
            'preserve the entire existing ruby halo');
    }
});

console.log(`${passed} reconstruction checks passed`);
