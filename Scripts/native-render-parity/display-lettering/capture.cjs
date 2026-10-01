const fs=require('fs'),path=require('path'),[root,out]=process.argv.slice(2);
const s=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const sl=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserSlantedSourceRestoration.swift'),'utf8');
const pull=sl.slice(sl.indexOf('    function aidokuPushPull('),sl.indexOf('    // Is point p inside',sl.indexOf('    function aidokuPushPull(')));
const funcs=s.slice(s.indexOf('      const displayMask='),s.indexOf('      const nodesD=',s.indexOf('      const displayMask=')));
const policy=new Function('f',pull+funcs+`const p=Uint8ClampedArray.from(f.rgba);let r=f.kind==='colour'?displayMask(p,f.w,f.h,f.box,f.glyph,f.surface,f.text):displayMaskBW(p,f.w,f.h,f.box,f.glyph,f.borders);if(r.output)r.output=Array.from(r.output);return r;`);
const fixtures=[];
for(let seed=0;seed<128;seed++){
 const w=88,h=72,glyph=seed%9===0?24:36,rgba=Array(w*h*4).fill(255),kind=seed<48?'colour':'bw',mode=seed%16;
 let background=kind==='colour'?[205,207,212]:[130,130,130],fill=kind==='colour'?[214,27,164]:[15,15,15],outline=kind==='colour'?[25,25,25]:[240,240,240];
 if(mode===1){background=[35,35,35];fill=kind==='colour'?[34,180,212]:[240,240,240];outline=[10,10,10];}
 if(mode===2)background=[248,248,248];
 if(mode===3)background=[170,180,198];
 if(mode===4)outline=background.slice();
 for(let y=0;y<h;y++)for(let x=0;x<w;x++){
  let c=background.slice();
  if(mode===5)c=c.map(v=>Math.max(0,Math.min(255,v+(x%8<4?-28:28))));
  if(mode===6)c=c.map(v=>Math.min(255,Math.max(0,v+x*.45-y*.25)));
  if(mode===7)c=c.map(v=>Math.min(255,Math.max(0,v+(((x*13+y*17)%19)-9)*3)));
  if(mode===8)c=(x<44?[45,45,45]:[220,220,220]);
  if(mode===12)c=Array(3).fill(110+((Math.imul(x+seed,1103515245)^Math.imul(y+7,214013))>>>0)%35);
  if(mode===13)c=Array(3).fill(112+((x*x+y*y+x*y+seed)%31));
  if(mode===14)c=c.map((v,i)=>v+(i===0?9:i===2?-9:0));
  if(mode===15)c=Array(3).fill(110+((x%6<2&&y%6<2)?32:0));
  rgba.splice((y*w+x)*4,3,...c);
 }
 const letters=[];
 for(let offset of [20,48]){
  for(let y=22;y<48;y++)for(let x=offset;x<offset+17;x++)if(x<offset+6||x>=offset+11||y>=32&&y<38)letters.push([x,y]);
 }
 const band=mode===9?1:3;
 for(const [x,y] of letters)for(let yy=y-band;yy<=y+band;yy++)for(let xx=x-band;xx<=x+band;xx++)if(xx>=0&&xx<w&&yy>=0&&yy<h)rgba.splice((yy*w+xx)*4,3,...outline);
 for(const [x,y] of letters)rgba.splice((y*w+x)*4,3,...fill);
 if(mode===10)for(let x=0;x<30;x++)for(let y=34;y<37;y++)rgba.splice((y*w+x)*4,3,20,20,20);
 if(mode===11)for(let y=40;y<47;y++)for(let x=74;x<80;x++)rgba.splice((y*w+x)*4,3,...fill);
 const f={seed,kind,w,h,box:[6.25,8.5,75.5,55],glyph,rgba:Array.from(Uint8ClampedArray.from(rgba)),borders:[false,false,false,false],surface:mode===2?background:null,text:null};
 f.expected=policy(f);fixtures.push(f);
}
fs.writeFileSync(out,JSON.stringify(fixtures));console.log(JSON.stringify({cases:fixtures.length,positive:fixtures.filter(f=>f.expected.output).length,colour:fixtures.filter(f=>f.kind==='colour'&&f.expected.output).length,bw:fixtures.filter(f=>f.kind==='bw'&&f.expected.output).length}));
