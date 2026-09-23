// Run with: node Scripts/tests/source-color-readability-regression.cjs
// Optional --source and --overlay paths run the same assertions against a baseline.
// Execute the production source-color helpers, initial item styling, and final
// caption pass. The DOM shim supplies fixed geometry and CSS stroke semantics;
// it does not duplicate the readability policy or simulate WebKit rasterization.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const args = process.argv.slice(2);
function option(name, fallback) {
    const index = args.indexOf(name);
    if (index < 0) return fallback;
    assert.ok(args[index + 1] && !args[index + 1].startsWith('--'), `${name} requires a value`);
    return args[index + 1];
}
const overlayDirectory = path.resolve(__dirname, '../../Aidoku/Core/Translation/NativeEngine/Overlay');
const sourcePath = option('--source', path.join(overlayDirectory, 'BrowserSourceTextColor.swift'));
const overlayPath = option('--overlay', path.join(overlayDirectory, 'BrowserOverlayView.swift'));
const source = fs.readFileSync(sourcePath, 'utf8');
const overlay = fs.readFileSync(overlayPath, 'utf8');
const typography = fs.readFileSync(path.join(overlayDirectory, 'BrowserOverlayTypography.swift'), 'utf8')
    .split('static let script = #"""')[1].split('"""#')[0];
const helpersMatch = source.match(/static let script = """\r?\n([\s\S]*?)\r?\n    """/);
assert.ok(helpersMatch, 'production source-color helpers must be present');
function between(text, start, end) {
    const left = text.indexOf(start), right = text.indexOf(end, left + start.length);
    assert.ok(left >= 0 && right > left, `production renderer block missing: ${start.trim()}`);
    return text.slice(left, right);
}
function decodeSwift(text) {
    assert.ok(!text.includes('\\('), 'Swift interpolation needs explicit decoding before execution');
    return text.replace(/\\([\\"])/g, '$1');
}
const initialStyle = decodeSwift(between(overlay,
    '        const sampled = cachedSourceSample(item);', '        root.appendChild(node);'));
const captionPass = decodeSwift(between(overlay,
    '    let readabilityPanels=0;', '    return {\n      status: \'committed\''));

// Track stroke longhands so a later width reset or shorthand removal really
// removes the outline in assertions, as it does in CSSStyleDeclaration.
function style() {
    const values = Object.create(null);
    const key = name => name.replace(/^-webkit-/, 'webkit-')
        .replace(/-([a-z])/g, (_match, letter) => letter.toUpperCase());
    const read = name => {
        if (name === 'webkitTextStroke') {
            return values.webkitTextStrokeWidth
                ? `${values.webkitTextStrokeWidth} ${values.webkitTextStrokeColor || 'currentcolor'}` : '';
        }
        return values[name] || '';
    };
    const write = (name, value) => {
        if (name === 'webkitTextStroke') {
            const match = String(value).match(/^(.*?)\s+((?:rgb|rgba)\([^)]*\)|transparent|currentcolor)$/);
            assert.ok(match, `unsupported stroke shorthand in DOM fixture: ${value}`);
            values.webkitTextStrokeWidth = match[1]; values.webkitTextStrokeColor = match[2];
        } else values[name] = String(value);
        return true;
    };
    return new Proxy({}, {
        get(_target, name) {
            if (name === 'getPropertyValue') return property => read(key(property));
            if (name === 'setProperty') return (property, value) => write(key(property), value);
            if (name === 'removeProperty') return property => {
                const name = key(property), old = read(name);
                if (name === 'webkitTextStroke') {
                    delete values.webkitTextStrokeWidth; delete values.webkitTextStrokeColor;
                } else delete values[name];
                return old;
            };
            return read(name);
        },
        set(_target, name, value) { return write(name, value); }
    });
}
function element() {
    return { dataset: {}, style: style(), attributes: {},
        setAttribute(name, value) { this.attributes[name] = value; },
        getBoundingClientRect() {
            const left = parseFloat(this.style.left), top = parseFloat(this.style.top);
            const width = parseFloat(this.style.width), height = parseFloat(this.style.height);
            return {left, top, width, height, right: left + width, bottom: top + height};
        } };
}
const context = vm.createContext({ console, performance });
vm.runInContext(decodeSwift(helpersMatch[1]) + typography + `
    globalThis.production = {
        contrast: aidokuSourceColorContrast,
        render: fixture => {
            const {item, node, root, appearance, opacity, document} = fixture;
            const fontSize = fixture.fontSize, lineHeight = fontSize * 1.2;
            const vertical = Boolean(item.vertical), wrappingScript = 'word';
            const displayedText = 'translated text', fontFamily = 'sans-serif';
            const x = 20, y = 20, width = 160, height = 60;
            const paddingTop = 0, paddingRight = 0, paddingBottom = 0, paddingLeft = 0;
            const scrollX = 0, scrollY = 0, cleanupImageGeometry = null;
            const inpaintingEnabled = Boolean(appearance?.inpaintingEnabled && appearance?.preserveSourceTextColor && appearance?.preserveSourceBackgroundColor);
            const captionTextReflows = new Map();
            const artworkFirst = false;
            const typographyEntries = [];
            const measurementHost = {remove() {}};
            const mount = {appendChild() {}};
            const typographyInkFrames = new Map(fixture.priorInk ? [[item, fixture.priorInk]] : []);
            const cleanedDenseSourceItems = new Set();
            const restoredSourcePanels = new Set(fixture.restored ? [item] : []);
            const restoredPanelGeometry = new Map(fixture.restored || fixture.restoredGeometry ? [[item, {}]] : []);
            const cachedSourceSample = () => fixture.sample;
            ${initialStyle}
            root.appendChild(node);
            if (fixture.inside) node.dataset.sourcePanelTextFit = 'inside';
            const items = [item];
            ${captionPass}
            return fixture;
        }
    };
`, context, { filename: 'production-source-readability.js' });
const production = context.production;

function render(overrides = {}) {
    const node = element(); node.dataset.aidokuRegion = '7';
    const children = [];
    const root = { dataset: {}, appendChild(child) { children.push(child); },
        querySelectorAll() { return children.filter(child => child === node); } };
    const fixture = {
        node, root, children, fontSize: 16, opacity: .84, restored: false,
        appearance: { preserveSourceTextColor: true, preserveSourceBackgroundColor: true },
        sample: { foreground: [220, 220, 220], background: [255, 255, 255], stroke: null,
            confidence: { foreground: .9, background: .9, stroke: 0 } },
        item: { id: 7, sourceColorEligible: true, lightSurface: true,
            sourceFrame: [0, 0, 400, 300], sourceBounds: [.05, .05, .4, .2] },
        document: { createElement: element, createRange() { return {
            selectNodeContents() {}, getBoundingClientRect() {
                return { left: 20, top: 20, right: 180, bottom: 80, width: 160, height: 60 };
            }
        }; } }
    };
    Object.assign(fixture, overrides);
    return production.render(fixture);
}
function rgb(node) {
    const match = node.style.color.match(/^rgb\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*\)$/);
    assert.ok(match, `finite rendered RGB expected, got ${node.style.color}`);
    return match.slice(1).map(Number);
}
function preserved(result, color) {
    assert.deepEqual(rgb(result.node), color, 'rendered text keeps the observed source RGB');
    assert.equal(result.node.dataset.sourceAppliedTextRGB, color.join(','));
    assert.equal(result.node.dataset.sourceTextColor, 'preserved');
    assert.equal(result.node.dataset.sourceTextColorAdjusted, 'false');
}
function hasEdge(node) {
    const width = node.style.webkitTextStrokeWidth;
    return Boolean(width && width !== '0px' && width !== '0' && !/^min\([^,]+,\s*0(?:\.0+)?em\)$/.test(width) &&
        node.style.webkitTextStrokeColor !== 'transparent');
}
function observedStroke(result, color) {
    assert.ok(hasEdge(result.node), 'an observed source outline must survive the final renderer pass');
    assert.equal(result.node.style.webkitTextStrokeColor, `rgb(${color.join(',')})`);
    assert.equal(result.node.style.paintOrder, 'stroke fill', 'paint the unchanged fill over the edge');
    assert.equal(result.node.dataset.sourceAppliedStrokeRGB, color.join(','));
    assert.equal(result.node.dataset.sourceStrokeColor, 'preserved');
    assert.equal(result.node.dataset.sourceTextOutline, 'true');
}
function sample(foreground, background, stroke = null, extra = {}) {
    return { foreground, background, stroke,
        confidence: { foreground: .9, background: .9, stroke: stroke ? .9 : 0 }, ...extra };
}
const tests = [];
function test(name, run) { tests.push({ name, run }); }
function noOutline(result) {
    assert.equal(result.node.style.webkitTextStrokeWidth, '0px');
    assert.equal(result.node.style.paintOrder, 'normal');
    assert.equal(result.node.dataset.sourceStrokeColor, 'none');
    assert.equal(result.node.dataset.sourceAppliedStrokeRGB, '');
    assert.equal(result.node.style.textShadow, 'none');
}
function readable(result, background) {
    assert.ok(production.contrast(rgb(result.node), true, 1, background) >= 4.5);
}
for (const color of [[10,10,10], [176,32,48], [32,48,176]]) {
    test(`readable source fill stays exact without outline: ${color}`, () => {
        const result=render({opacity:1,sample:sample(color,[255,255,255],[255,220,0])});
        preserved(result,color);noOutline(result);readable(result,[255,255,255]);
    });
}
for (const [color,background] of [[[220,220,220],[255,255,255]],[[255,255,255],[255,255,255]],[[2,2,1],[100,94,101]]]) {
    test(`preserved neutral source is not silently inverted: ${color}`, () => {
        const result=render({opacity:1,sample:sample(color,background,[255,255,255])});
        preserved(result,color);noOutline(result);
    });
}
for(const background of [false,true])for(const restored of [false,true])for(const stroke of [[255,255,255],[255,220,0],[0,0,0]]) {
    test(`no source ring with background=${background}, restored=${restored}, stroke=${stroke}`,()=>{
        const result=render({opacity:1,restored,
            appearance:{preserveSourceTextColor:true,preserveSourceBackgroundColor:background},
            sample:sample([10,10,10],[240,240,240],stroke)});
        noOutline(result);assert.equal(result.node.dataset.sourceSampledStrokeRGB,stroke.join(','));
        if(background)assert.equal(result.root.dataset.readabilityPanels,'1');
    });
}
for(const fontSize of [5,6,9,12])for(const pale of [false,true]) {
    test(`small Korean has a single fill at ${fontSize}px, pale=${pale}`,()=>{
        const result=render({fontSize,opacity:1,restored:true,
            item:{id:7,fontScript:'korean',sourceColorEligible:true,lightSurface:true},
            sample:sample(pale?[245,245,245]:[10,10,10],[240,240,240],[255,220,0],
                {widthEvidence:{relativeToGlyph:100}})});
        noOutline(result);
        assert.equal(result.root.dataset.readabilityPanels,'1');
    });
}
for(const foreground of [null,[NaN,0,0],[255,255],undefined]) {
    test(`invalid source uses clean readable fallback: ${String(foreground)}`,()=>{
        const result=render({opacity:1,sample:sample(foreground,[24,30,40],[255,0,0])});
        noOutline(result);readable(result,[24,30,40]);
        assert.equal(result.node.dataset.sourceTextColor,'fallback');
    });
}
test('missing sample keeps a readable paper caption without outline',()=>{
    const result=render({opacity:1,sample:null});noOutline(result);readable(result,[242,240,235]);
    assert.equal(result.node.dataset.captionSurface,'paper-fallback');
});
test('black-white gradient uses compact caption when no single fill can contrast everywhere',()=>{
    const result=render({opacity:1,restored:true,sample:sample([120,120,120],[240,240,240],null,
        {surface:{color:[240,240,240],vertical:true,stops:[[0,0,0],[255,255,255]]}})});
    noOutline(result);preserved(result,[120,120,120]);
    assert.equal(result.root.dataset.readabilityPanels,'1');
    assert.equal(result.node.dataset.sourceBackgroundColor,'readability-panel');
});
test('readable smooth gradient also uses a source-colored text box',()=>{
    const result=render({opacity:1,restored:true,sample:sample([10,10,10],[240,240,240],null,
        {surface:{color:[240,240,240],vertical:true,stops:[[220,220,220],[255,255,255]]}})});
    noOutline(result);assert.equal(result.root.dataset.readabilityPanels,'1');
});
for(const opacity of [0,.2,1])test(`opacity ${opacity} never introduces an outline`,()=>{
    const result=render({opacity,sample:sample([255,255,255],[255,255,255],[0,0,0])});noOutline(result);
    assert.ok(rgb(result.node).every(Number.isFinite));
    if(opacity===0)assert.equal(result.root.dataset.readabilityPanels,'0');
});
for(const enabled of [false,true,false])test(`source setting ${enabled} leaves no stroke`,()=>{
    const result=render({opacity:1,appearance:{preserveSourceTextColor:enabled,preserveSourceBackgroundColor:true}});
    noOutline(result);if(enabled)preserved(result,[220,220,220]);else readable(result,[255,255,255]);
});
for(const color of [[218,98,71],[220,91,6],[253,251,152],[225,190,205]])test(`source chroma is not darkened into brown or gray: ${color}`,()=>{
 const result=render({opacity:1,restored:true,sample:sample(color,[169,149,140],[255,255,255])});
 preserved(result,color);noOutline(result);assert.equal(result.root.dataset.readabilityPanels,'1');
});
test('white letters with orange outline flatten to the observed orange without a stroke',()=>{
 const result=render({opacity:1,sample:sample([254,254,251],[227,241,236],[220,91,6])});
 assert.deepEqual(rgb(result.node),[220,91,6]);noOutline(result);
});
test('readable white fill on a dark box is not replaced by its darker colored outline',()=>{
 const result=render({opacity:1,sample:sample([251,251,251],[11,11,11],[96,54,28])});
 preserved(result,[251,251,251]);readable(result,[11,11,11]);noOutline(result);
});
for (const color of [[220,90,6],[1,1,1]]) for (const panel of [[230,210,180],[42,38,42]]) {
 test(`spatially observed lettering color remains stable on ${panel}: ${color}`,()=>{
  const result=render({opacity:1,sample:sample([253,251,246],panel,color,
    {lettering:{color,pixels:20,bands:4,components:6}})});
  assert.deepEqual(rgb(result.node),color);noOutline(result);
 });
}
test('uncertain source backing still supplies its observed RGB instead of invented white',()=>{
 const result=render({opacity:1,sample:sample([224,95,68],[203,182,162],null,{confidence:{foreground:.75,background:.32}})});
 assert.equal(result.node.dataset.sourceAppliedBackgroundRGB,'203,182,162');
 assert.equal(result.node.dataset.captionSurface,'observed');
});
test('lettering-only palette finishes the caption pass without a missing foreground',()=>{
 const color=[38,31,47];
 const result=render({opacity:1,sample:sample(null,[230,215,240],null,{lettering:{color}})});
 assert.deepEqual(rgb(result.node),color);noOutline(result);
 assert.equal(result.node.dataset.sourceTextColorAdjusted,'false');
});
for (const enabled of [false, true]) for (const text of [false, true]) for (const background of [false, true]) {
 test(`inpainting requires both colors: enabled=${enabled}, text=${text}, background=${background}`,()=>{
  const result=render({restored:true,inside:true,sample:sample([10,10,10],[240,240,240]),
   appearance:{inpaintingEnabled:enabled,preserveSourceTextColor:text,preserveSourceBackgroundColor:background}});
  assert.equal(result.node.dataset.sourceBackgroundColor==='inpainted',enabled&&text&&background);
  if(background)assert.equal(result.root.dataset.readabilityPanels,enabled&&text?'0':'1');
 });
}
for(const restored of [false,true])test(`inpainting fallback retains readable box: restored=${restored}`,()=>{
 const result=render({restored,inside:false,sample:sample([10,10,10],[240,240,240]),
  appearance:{inpaintingEnabled:true,preserveSourceTextColor:true,preserveSourceBackgroundColor:true}});
 assert.equal(result.root.dataset.readabilityPanels,'1');
 assert.equal(result.node.dataset.sourceBackgroundColor,'readability-panel');
});
for (const erased of [false, true]) test(`long source coverage follows committed erasure: ${erased}`, () => {
 const result = render({restoredGeometry:erased,inside:false,
  item:{id:7,sourceColorEligible:true,lightSurface:true,balancedColumn:true,
   sourceFrame:[0,0,400,300],sourceBounds:[.25,.02,.05,.9]},
  appearance:{inpaintingEnabled:true,preserveSourceTextColor:true,preserveSourceBackgroundColor:true}});
 const panel=result.children.find(n=>n.attributes['data-aidoku-image-ocr-overlay']==='source-readability-panel'&&!n.dataset.sourceErasure);
 assert.ok(panel,'unreadable text still needs an opaque caption');
 assert.equal(parseFloat(panel.style.height)<80,!erased,'compact caption is used only when separate erasure is safe');
 const source=result.children.find(n=>n.dataset.sourceErasure==='true');
 assert.equal(Boolean(source),!erased,'only an unerased source needs a separate erasure plate');
 if(source){
  assert.ok(parseFloat(source.style.height)>270);
  assert.ok(parseFloat(source.style.width)<=30,'erasure retains the original margin without filling caption corners');
 }
});
for (const erased of [false, true]) test(`ordinary artwork retains its source plate: restored=${erased}`, () => {
 const result=render({restoredGeometry:erased,inside:false,
  item:{id:7,sourceColorEligible:true,lightSurface:true,
   sourceFrame:[0,0,400,300],sourceBounds:[.25,.02,.05,.9]},
  appearance:{inpaintingEnabled:true,preserveSourceTextColor:true,preserveSourceBackgroundColor:true}});
 const panel=result.children.find(n=>n.attributes['data-aidoku-image-ocr-overlay']==='source-readability-panel');
 assert.ok(parseFloat(panel.style.height)>270);
});
test('large source lettering is never left unerased to reduce a caption background', () => {
 const result=render({
  item:{id:7,sourceColorEligible:true,sourceTextOnly:false,lightSurface:true,
   sourceFrame:[0,0,400,300],sourceBounds:[.02,.02,.95,.95]},
  appearance:{inpaintingEnabled:true,preserveSourceTextColor:true,preserveSourceBackgroundColor:true}});
 const panel=result.children.find(n=>n.attributes['data-aidoku-image-ocr-overlay']==='source-readability-panel');
 assert.ok(panel);
 const rect=panel.getBoundingClientRect();
 assert.ok(rect.width>=380 && rect.height>=285);
 assert.equal(result.node.dataset.sourceArtworkPreserved,undefined);
});
for (const text of [false, true]) test(`manual palette keeps the original erasure after column movement: text=${text}`, () => {
 const result=render({item:{id:7,sourceColorEligible:true,lightSurface:true,balancedColumn:true,
   sourceErasureRGB:[248,250,249],sourceFrame:[0,0,400,300],sourceBounds:[.25,.02,.05,.9]},
  appearance:{preserveSourceTextColor:text,preserveSourceBackgroundColor:false}});
 const erasure=result.children.find(n=>n.dataset.sourceErasure==='true');
 assert.ok(erasure,'moving a column must not leave its colored source behind');
 assert.ok(parseFloat(erasure.style.left)<=100 && parseFloat(erasure.style.top)<=6);
 assert.ok(parseFloat(erasure.style.width)>=20 && parseFloat(erasure.style.height)>=270);
 assert.equal(erasure.style.backgroundColor,'rgb(248,250,249)');
});
test('font harmonization keeps the previous ink coverage and padding', () => {
 const priorInk={left:10,top:10,right:210,bottom:100,pad:5.175};
 const result=render({fontSize:13,priorInk,sample:sample([10,10,10],[255,255,255])});
 const panel=result.children.find(n=>n.attributes['data-aidoku-image-ocr-overlay']==='source-readability-panel');
 assert.ok(panel);
 const rect=panel.getBoundingClientRect();
 assert.ok(rect.left<=priorInk.left-priorInk.pad&&rect.top<=priorInk.top-priorInk.pad);
 assert.ok(rect.right>=priorInk.right+priorInk.pad&&rect.bottom>=priorInk.bottom+priorInk.pad);
});
test('typography does not add a plate to a verified transparent restoration', () => {
 const result=render({restored:true,inside:true,priorInk:{left:10,top:10,right:210,bottom:100,pad:6},
  sample:sample([10,10,10],[255,255,255]),
  appearance:{inpaintingEnabled:true,preserveSourceTextColor:true,preserveSourceBackgroundColor:true}});
 assert.equal(result.root.dataset.readabilityPanels,'0');
 assert.equal(result.node.dataset.sourceBackgroundColor,'inpainted');
});
const selected = tests.filter(value => value.name.includes(option('--filter', '')));
assert.ok(selected.length, 'no readability tests matched');
let passed = 0;
for (const { name, run } of selected) {
    try { run(); passed++; console.log(`PASS ${name}`); }
    catch (error) { console.error(`FAIL ${name}\n  ${error.message}`); }
}
console.log(`${passed}/${selected.length} source-color readability regressions passed`);
if (passed !== selected.length) process.exitCode = 1;
