const fs=require('fs');
const cases=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
// WebKit parses CSS numeric lengths as Float32 before its 1/64 LayoutUnit
// resolution. A centred scale transform follows those resolved lengths.
const unit=v=>Math.trunc(Math.fround(v)*64)/64;
const out=cases.map(c=>{const x=unit(c.x),w=unit(c.width),p=c.padding.map(unit);
  return [x+w*(1-c.scale)/2,unit(c.y),w*c.scale,unit(c.height),p[0],p[1]*c.scale,p[2],p[3]*c.scale];});
fs.writeFileSync(process.argv[3],JSON.stringify(out));
