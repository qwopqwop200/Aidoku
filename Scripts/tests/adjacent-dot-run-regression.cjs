// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserSourcePanelRestoration.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const find=new Function(source+';return aidokuAdjacentDotRun;')();
function scene({x=105,count=12,ys=null,line=false}={}){
 const w=160,h=300,p=new Uint8ClampedArray(w*h*4).fill(245);for(let i=3;i<p.length;i+=4)p[i]=255;
 for(let k=0;k<count;k++){const cy=ys?.[k]??40+k*17;for(let y=cy-4;y<=cy+4;y++)for(let xx=x-4;xx<=x+4;xx++){
  if(y<0||y>=h||!line&&(xx-x)**2+(y-cy)**2>17)continue;p.set([220,80,35,255],(y*w+xx)*4);
 }}
 return {w,h,p};
}
function marks(s,excluded=[]){return find(s.p,s.w,s.h,[50,125,35,90],50,{foreground:[220,80,35]},excluded);}
assert.equal(marks(scene()).length,12,'complete detached ellipsis must be included');
assert.equal(marks(scene({x:68})).length,0,'body glyphs are already owned by the body mask');
assert.equal(marks(scene({x:145})).length,0,'a distant pattern is unrelated');
assert.equal(marks(scene({ys:[2,19,36,53,70,87,104,121,138,155,172,189]})).length,0,'open runs must remain whole');
assert.equal(marks(scene({ys:[40,57,74,91,108,150,167,184,201,218,235,252]})).length,0,'irregular separated groups are not a run');
assert.equal(marks(scene(),[[98,130,16,30]]).length,0,'do not bridge another caption');
const wrong=scene();assert.equal(find(wrong.p,wrong.w,wrong.h,[50,125,35,90],50,{foreground:[20,40,180]}).length,0);
console.log('7 adjacent-dot ownership regressions passed');
