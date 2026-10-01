const fs=require('fs'),input=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const source=fs.readFileSync(process.argv[4],'utf8');
let code=source.slice(source.indexOf('// Reflow roomy paragraphs within their existing card'),source.indexOf('        const hasReference = reference && Number.isFinite(reference.fontSize)'));
code=code.replaceAll('\\\\','\\');
const run=new Function('i',`const item={allowsAutomaticFontRecovery:i.automaticRecovery,smallTextReference:i.hasReference?{fontSize:8}:null,sourceVertical:i.sourceVertical};
const displayedText=i.text,fontSize=i.font,vertical=i.vertical,wrappingScript=i.script,lineHeightRatio=i.lineHeightRatio;
const width=i.usableWidth,height=i.usableHeight,paddingTop=0,paddingRight=0,paddingBottom=0,paddingLeft=0;
let paragraphRecoveryProbeBudget=i.probe,refinementCharacterBudget=i.refinement,readableRefinementBudget=i.readable;
const node={dataset:{}},items=[],trace=[];
const fitMeasuredFont=()=>{trace.push('fit');return i.fittedFont;};
const lineProfile=()=>{trace.push('profile');return i.lines===null?null:{lines:i.lines};};
${code}
return {proposal:reference?.paragraphRecovery?{font:reference.fontSize,additionalLines:reference.additionalLines,maximum:refinementMaximum}:null,
probe:paragraphRecoveryProbeBudget,trace};`);
fs.writeFileSync(process.argv[3],JSON.stringify(input.map(run)));
