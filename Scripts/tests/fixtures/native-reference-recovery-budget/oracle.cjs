const fs=require('fs');
const cases=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const source=fs.readFileSync(process.argv[4],'utf8');
if(!source.includes('let refinementCharacterBudget = 16384;')||!source.includes('Math.min(2048, Math.max(0, refinementCharacterBudget - emergencyCharacters))'))throw Error('Frozen initial allocation changed');
const expected=cases.map(c=>{
 let refinementCharacterBudget=16384;
 const emergencyCharacters=c.initial.reduce((total,item)=>total+(item.fontSize!==null&&item.fontSize<8&&item.length<=512?item.length:0),0);
 let readableRefinementBudget=Math.min(2048,Math.max(0,refinementCharacterBudget-emergencyCharacters));
 const initialReadable=readableRefinementBudget;
 const steps=[...c.initial,...c.dynamic].map(reference=>{
   const hasReference=Number.isFinite(reference.fontSize)&&reference.paddingIsValid;
   const emergency=reference.fontSize<8;
   const canProfile=hasReference&&reference.length<=512&&reference.length<=refinementCharacterBudget&&(emergency||reference.length<=readableRefinementBudget);
   if(canProfile){refinementCharacterBudget-=reference.length;if(!emergency)readableRefinementBudget-=reference.length;}
   return {admitted:canProfile,refinement:refinementCharacterBudget,readable:readableRefinementBudget};
 });
 return {initialReadable,steps};
});
fs.writeFileSync(process.argv[3],JSON.stringify(expected));
