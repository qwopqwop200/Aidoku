const fs = require('fs'), Module = require('module'), path = require('path');
const sourceFile = path.resolve('Scripts/tests/source-color-regression.cjs');
let source = fs.readFileSync(sourceFile,'utf8');
const shim = String.raw`
 const __originalSourceEstimate=aidokuEstimateSourceColors;
 globalThis.__capturedEstimates=[];
 aidokuEstimateSourceColors=(rgba,width,height,surface=null,exterior=null,seed=null,minDistance=60,observed=null,ownership=null)=>{
 const result=__originalSourceEstimate(rgba,width,height,surface,exterior,seed,minDistance,observed,ownership);
 __capturedEstimates.push({rgba:rgba?Array.from(rgba):[],width,height,surface,exterior,seed,minDistance,ownership:ownership?Array.from(ownership):null,expected:JSON.parse(JSON.stringify(result))});return result;};
`;
source = source.replace("script[1].replace(/^    /gm, '')", "script[1].replace(/^    /gm, '').replace('const aidokuEstimateSourceColors =','let aidokuEstimateSourceColors =') + " + JSON.stringify(shim));
source=source.replace('const production = context.sourceColor;',"const production = context.sourceColor;process.on('exit',()=>fs.writeFileSync(process.env.AIDOKU_POLICY_FIXTURES,JSON.stringify(context.__capturedEstimates)));");
const moduleInstance = new Module(sourceFile, module);moduleInstance.filename=sourceFile;moduleInstance.paths=module.paths;moduleInstance._compile(source,sourceFile);
