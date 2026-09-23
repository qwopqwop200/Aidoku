// Stroke presence and RGB are scored independently from displayed lettering.
// Missing estimates are misses for outlined text; false strokes fail negatives.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { harness, raster, rect } = require('./source-color-test-harness.cjs');
const arg = name => process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : null;
const load = name => JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', name)));
const annotations = arg('--annotations') ? JSON.parse(fs.readFileSync(arg('--annotations'))) : load('source-color-strokes.json');
const captures = arg('--captures') ? JSON.parse(fs.readFileSync(arg('--captures'))).fixtures :
    [...load('source-color-diversity.json').fixtures, ...load('source-color-stroke-confirmation.json').fixtures];
assert.equal(new Set(annotations.fixtures.map(f=>f.id)).size, annotations.fixtures.length, 'unique annotation IDs');
assert.equal(new Set(captures.map(f=>f.id)).size, captures.length, 'unique capture IDs');
if (annotations.selection) {
    const excluded = new Set(annotations.selection.excludedEvaluationGroups);
    assert.equal(new Set(captures.map(f=>f.evaluationGroup)).size, captures.length, 'one expansion crop per work');
    for (const f of captures) {
        assert.ok(f.evaluationGroup && !excluded.has(f.evaluationGroup), 'expansion must use previously untested works');
        assert.equal(annotations.fixtures.find(label=>label.id===f.id)?.split, f.split, 'frozen work-level split');
    }
}
const h = harness(null, false, arg('--source'));
vm.runInContext('globalThis.strokePalette=typeof aidokuObservedStrokePalette === "function" ? aidokuObservedStrokePalette : null;'+
    'globalThis.glyphPalette=aidokuObservedGlyphPalette;', h.context);

if (!process.argv.includes('--measure-only')) {
    // Uniform color, frame and repeated filled artwork must not become outlines.
    for (const background of [[255,255,255], [20,35,54], [232,161,95]]) {
        for (const kind of ['flat', 'frame', 'art']) {
            const im = raster(160,100,background);
            if (kind === 'frame') {
                rect(im, 4,4,152,3,[3,3,3]); rect(im,4,93,152,3,[3,3,3]);
                rect(im,4,4,3,92,[3,3,3]); rect(im,153,4,3,92,[3,3,3]);
            }
            if (kind === 'art') for (const x of [30,65,100]) rect(im,x,30,20,40,[63,113,42]);
            const b = [10,10,140,80], modes = h.context.glyphPalette(im.data,160,100,b);
            assert.equal(h.context.strokePalette(im.data,160,100,b,modes,null,null),null,kind);
        }
    }
    const im=raster(120,80), b=[0,0,120,80], original=Buffer.from(im.data);
    const fake=[{color:[10,10,10],coverage:1,core:[],score:10}];
    for (const bounds of [null,[0,0,NaN,20],[0,0,-1,20]])
        assert.equal(h.context.strokePalette(im.data,120,80,bounds,fake,null,null),null);
    im.data[3]=0;
    assert.equal(h.context.strokePalette(im.data,120,80,b,fake,null,null),null);
    im.data[3]=255; assert.deepEqual(Buffer.from(im.data),original);
    console.log('PASS: flat surfaces, frames, solid art, malformed bounds and alpha controls');
    // A real white glyph interior may share its exterior surface color.
    // Keep the independently repeated brown outline for different OCR margins.
    const control=load('source-color-stroke-controls.json');
    const bytes=zlib.inflateSync(Buffer.from(control.rgba,'base64'));
    assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),control.pixelSHA256);
    for(const bounds of control.bounds){
        const image={complete:true,naturalWidth:control.width,naturalHeight:control.height,data:new Uint8ClampedArray(bytes)};
        const result=h.sampler(image,true).sample(bounds);
        assert.ok(result?.stroke?.length===3&&result.stroke.every((v,c)=>Math.abs(v-control.expectedStroke[c])<=16),
            `captured UIKit white-on-white lettering lost its brown outline: ${result?.stroke}`);
    }
    console.log('PASS: captured UIKit white-on-white fill with brown outline, four OCR margins');
}

function writePNG(file, width, height, rgba) {
    const crc32 = data => { let crc = 0xffffffff; for (const byte of data) {
        crc ^= byte; for (let i=0;i<8;i++) crc=(crc>>>1)^(crc&1?0xedb88320:0);
    } return (crc^0xffffffff)>>>0; };
    const chunk=(type,data)=>{const name=Buffer.from(type),length=Buffer.alloc(4),crc=Buffer.alloc(4);
        length.writeUInt32BE(data.length);crc.writeUInt32BE(crc32(Buffer.concat([name,data])));
        return Buffer.concat([length,name,data,crc]);};
    const ihdr=Buffer.alloc(13);ihdr.writeUInt32BE(width);ihdr.writeUInt32BE(height,4);ihdr[8]=8;ihdr[9]=6;
    const stride=width*4,scanlines=Buffer.alloc((stride+1)*height);
    for(let y=0;y<height;y++)rgba.copy(scanlines,y*(stride+1)+1,y*stride,(y+1)*stride);
    fs.writeFileSync(file,Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',ihdr),
        chunk('IDAT',zlib.deflateSync(scanlines)),chunk('IEND',Buffer.alloc(0))]));
}

const exportDirectory=arg('--export-replay'), manifest=[], rows=[];
if(exportDirectory)fs.mkdirSync(exportDirectory,{recursive:true});
const knownGroups=new Set(captures.filter(f=>f.split!=='independent-confirmation').map(f=>f.evaluationGroup));
for(const label of annotations.fixtures){
    if(arg('--split')&&label.split!==arg('--split'))continue;
    const f=captures.find(f=>f.id===label.id);assert.ok(f,label.id);
    if(f.split==='independent-confirmation')assert.ok(!knownGroups.has(f.evaluationGroup),'fresh work-disjoint confirmation');
    const bytes=zlib.inflateSync(Buffer.from(f.rgba,'base64'));
    const hash=()=>crypto.createHash('sha256').update(bytes).digest('hex');
    assert.equal(hash(),label.pixelSHA256);assert.equal(hash(),f.pixelSHA256);
    const image={complete:true,naturalWidth:f.width,naturalHeight:f.height,data:new Uint8ClampedArray(bytes)};
    const budget={pixels:393216,detailPixels:98304,remainingSamples:1};
    const sampler=h.sampler(image,true,'ocr',budget),result=sampler.sample(f.bounds),stroke=result?.stroke||null;
    const error=label.expectedStroke?(stroke?Math.max(...stroke.map((v,c)=>Math.abs(v-label.expectedStroke[c]))):255):(stroke?255:0);
    rows.push({...label,stroke,error,matched:error<=25,stats:{...sampler.stats},result});
    assert.ok(budget.pixels>=0&&budget.detailPixels>=0);
    assert.strictEqual(sampler.sample(f.bounds),result);
    assert.deepEqual(Buffer.from(image.data),bytes,'original image must remain unchanged');
    if(exportDirectory){
        const file='stroke-'+f.id+'.png';writePNG(path.join(exportDirectory,file),f.width,f.height,bytes);
        manifest.push({...label,image:file,bounds:f.bounds});
    }
}
const summaries={};
for(const split of [...new Set(rows.map(r=>r.split))]){
    const selected=rows.filter(r=>r.split===split&&r.scored),positive=selected.filter(r=>r.expectedStroke),negative=selected.filter(r=>!r.expectedStroke);
    const match=rs=>rs.filter(r=>r.matched).length;
    const summary={total:selected.length,matches:match(selected),outlined:positive.length,strokeMatches:match(positive),
        withoutOutline:negative.length,falseStrokes:negative.length-match(negative)};summaries[split]=summary;
    console.log(`${split}: ${summary.matches}/${summary.total}; outlined ${summary.strokeMatches}/${summary.outlined}; false strokes ${summary.falseStrokes}/${summary.withoutOutline}`);
    if(!process.argv.includes('--measure-only'))assert.ok(summary.matches/summary.total>=.8,`${split} stroke benchmark regressed`);
}
for(const r of rows.filter(r=>r.scored&&!r.matched))console.log(`MISS ${r.id}: ${r.stroke}; reference ${r.expectedStroke}; error ${r.error}`);
if(!process.argv.includes('--measure-only')&&!arg('--split')){
    const positive=rows.filter(r=>r.scored&&r.expectedStroke),negative=rows.filter(r=>r.scored&&!r.expectedStroke);
    assert.ok(positive.filter(r=>r.matched).length/positive.length>=.6,'actual outlined text must retain stroke color coverage');
    assert.ok(negative.filter(r=>!r.matched).length/negative.length<=.04,'outline-free text must not acquire false strokes');
}
if(arg('--report'))fs.writeFileSync(arg('--report'),JSON.stringify({methodology:annotations.description,summaries,rows},null,2));
if(exportDirectory){
    fs.writeFileSync(path.join(exportDirectory,'stroke-replay.json'),JSON.stringify(manifest));
    if(arg('--baseline-source')){
        const source=fs.readFileSync(arg('--baseline-source'),'utf8');
        fs.writeFileSync(path.join(exportDirectory,'stroke-baseline.js'),source.match(/static let script = """\n([\s\S]*?)\n    """/)[1]);
    }
}
