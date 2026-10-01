// Execute the frozen production JavaScript and capture every policy call and its real result.
const fs = require('node:fs');
const Module = require('node:module');
const path = require('node:path');
const fixtureOutput = path.resolve(process.argv[2]);
const sourceFile = path.resolve('Scripts/tests/source-color-regression.cjs');
const names = {
    recoverSourcePanel: 'aidokuRecoverSourcePanel', recoverOutlinedColor: 'aidokuRecoverOutlinedColor',
    observedSourceSurface: 'aidokuObservedSourceSurface', observedCaptionPalette: 'aidokuObservedCaptionPalette',
    recoverHaloInk: 'aidokuRecoverHaloInk', interiorCaptionSurface: 'aidokuInteriorCaptionSurface',
    observedCaptionBackground: 'aidokuObservedCaptionBackground'
};
let source = fs.readFileSync(sourceFile, 'utf8');
const shim = `globalThis.__nativeCaptionCalls = []; globalThis.__captionFunctions = {};
${Object.entries(names).map(([name, jsName]) => `{
 const original = ${jsName};
 ${jsName} = (...args) => {
   const expected = original(...args);
   __nativeCaptionCalls.push({name:${JSON.stringify(name)},args:args.map((value,index)=>index===0?Array.from(value):value),expected:expected??null});
   return expected;
 };
 __captionFunctions[${JSON.stringify(name)}] = ${jsName};
}`).join('\n')}
`;
let expression = "script[1].replace(/^    /gm, '')";
for (const jsName of Object.values(names)) expression += `.replace('const ${jsName} =', 'let ${jsName} =')`;
source = source.replace("script[1].replace(/^    /gm, '')", expression + ' + ' + JSON.stringify(shim));
source = source.replace('const production = context.sourceColor;', `const production = context.sourceColor;
 process.on('exit', () => fs.writeFileSync(${JSON.stringify(fixtureOutput)},JSON.stringify(context.__nativeCaptionCalls)));`);
const instance = new Module(sourceFile, module);
instance.filename = sourceFile;
instance.paths = module.paths;
instance._compile(source, sourceFile);

// Supplement the frozen regression calls with real deterministic caption rasters.
function raster(width, height, base, glyphColor, patterned = false) {
    const rgba = new Uint8ClampedArray(width * height * 4);
    for (let y=0;y<height;y++) for(let x=0;x<width;x++) {
        const delta = patterned ? ((x+y)%2 ? 5 : -5) : 0;
        const color=base.map(value=>Math.min(255,Math.max(0,value+delta)));
        rgba.set([...color,255],(y*width+x)*4);
    }
    for(const x0 of [16,36,56]) for(let y=18;y<38;y++) for(let x=x0;x<x0+8;x++) {
        if(x===x0||x===x0+7||y===18||y===37||y===28)rgba.set([...glyphColor,255],(y*width+x)*4);
    }
    return rgba;
}
// Tests keep the VM local; rerun only the frozen script for supplements.
const vm = require('node:vm');
const frozenPath = path.resolve('Scripts/native-render-parity/reference-source/BrowserSourceTextColor.swift');
const text = fs.readFileSync(frozenPath,'utf8').match(/static let script = """\r?\n([\s\S]*?)\r?\n    """/)[1].replace(/^    /gm,'');
const supplemental = vm.createContext({console,performance});
let script = text;
for(const jsName of Object.values(names))script=script.replace(`const ${jsName} =`,`let ${jsName} =`);
vm.runInContext(script+shim,supplemental);
for(const base of [[240,240,240],[180,190,210],[20,40,60]]) for(const foreground of [[24,52,80],[255,255,255],[160,30,80]]) {
    const width=80,height=64,rgba=raster(width,height,base,foreground),box=[12.25,8.5,56.5,47.25];
    const result={foreground,background:base,stroke:[255,255,255],confidence:{foreground:.8,background:.4,stroke:.75},widthEvidence:{samplePixels:3.5}};
    for(const [name,fn] of Object.entries(supplemental.__captionFunctions)) {
        if(name==='recoverOutlinedColor')fn(rgba,width,height,result,true,true);
        else if(name==='recoverHaloInk')fn(rgba,width,height,box);
        else fn(rgba,width,height,box,result);
    }
    supplemental.__captionFunctions.observedCaptionPalette(rgba,width,height,box,{...result,background:[255,255,255]});
    for(const value of [result, {...result,foreground:foreground.map(v=>Math.min(255,v+.25))}]) {
        supplemental.__captionFunctions.observedCaptionBackground(rgba,width,height,box,value);
    }
}
// The test runner's exit callback saves its own calls after this code; merge supplements there.
const originalWrite=fs.writeFileSync;
fs.writeFileSync=(file,data,...options)=>{
    if(path.resolve(file)===fixtureOutput) {
        const all=JSON.parse(data).concat(JSON.parse(JSON.stringify(supplemental.__nativeCaptionCalls)));
        return originalWrite.call(fs,file,JSON.stringify(all),...options);
    }
    return originalWrite.call(fs,file,data,...options);
};
