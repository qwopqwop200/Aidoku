const fs=require('node:fs'),path=require('node:path');const [root,out]=process.argv.slice(2);
const s=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserSourcePanelRestoration.swift'),'utf8');
const fn=s.slice(s.indexOf('    function aidokuEnclosedPaperFinish('),s.indexOf('    // Local exposed-paper support',s.indexOf('    function aidokuEnclosedPaperFinish(')));
const call=new Function(fn+';return aidokuEnclosedPaperFinish;')();const fixtures=[];
for(let seed=0;seed<112;seed++){
 const w=40,h=32,source=new Uint8ClampedArray(w*h*4),rgba=new Uint8ClampedArray(w*h*4),safe=new Uint8Array(w*h).fill(1);
 for(let y=0;y<h;y++)for(let x=0;x<w;x++){const k=(y*w+x)*4,v=232+(x*3+y*7+seed)%15;source.set([v,v+(seed%3),v,255],k);}
 const core=[10,8,15,16],aux=seed%7===0?[[30,7,4,6]]:[];
 const paint=(x,y,c,a=255)=>{rgba.set([...c,a],(y*w+x)*4)};
 for(let y=12;y<16;y++)for(let x=15;x<19;x++)paint(x,y,[235+x%2,239+y%2,241]);
 if(seed%8===0)for(let y=2;y<5;y++)for(let x=1;x<4;x++)paint(x,y,[244,240,236]);
 if(seed%8===1)for(let x=1;x<17;x++)paint(x,12,[242,242,242]);
 if(seed%8===2){for(let y=8;y<12;y++)for(let x=30;x<33;x++)paint(x,y,[244,244,244]);}
 if(seed%8===3){rgba.fill(0);paint(17,13,[243,243,243]);}
 if(seed%8===4){for(let y=0;y<h;y++)for(let x=0;x<w;x++)source.set([250,250,250,255],(y*w+x)*4);paint(14,12,[232,235,237]);paint(14,13,[233,234,238]);}
 if(seed%8===5){for(let y=8;y<11;y++)for(let x=20;x<24;x++)paint(x,y,[245,246,247],128);}
 const f={seed,w,h,source:Array.from(source),rgba:Array.from(rgba),safe:Array.from(safe),core,aux};
 const result=call(source,w,h,[core[0],core[1],core[0]+core[2],core[1]+core[3]],aux,{rgba:rgba.slice(),layoutSafe:safe.slice()});
 f.expected=result?{rgba:Array.from(result.rgba),safe:Array.from(result.layoutSafe),erased:result.erased}:null;fixtures.push(f);
}
fs.writeFileSync(out,JSON.stringify(fixtures));
