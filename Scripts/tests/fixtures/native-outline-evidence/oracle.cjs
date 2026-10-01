const fs=require('fs'),vm=require('vm'),base=process.argv[3];
const view=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8'),typ=fs.readFileSync(base+'/BrowserOverlayTypography.swift','utf8'),col=fs.readFileSync(base+'/BrowserSourceTextColor.swift','utf8');
const colors=col.slice(col.indexOf('    const aidokuSourceColorLuminance ='),col.indexOf('    // Keep an already readable color.'));
const helpers=view.slice(view.indexOf('      const validO=rgb=>'),view.indexOf('      const nodesO=',view.indexOf('      const validO=rgb=>')));
const enclosed=typ.slice(typ.indexOf('    const aidokuEnclosedCaptionOutline ='),typ.indexOf('    const aidokuChromaticOutlineMinimum ='));
const c={};vm.createContext(c);vm.runInContext(colors+helpers+enclosed+'\nglobalThis.ringPair=ringPair;globalThis.enclosed=aidokuEnclosedCaptionOutline;',c);
const outputs=JSON.parse(fs.readFileSync(process.argv[2])).map(f=>{
 const p=new Uint8ClampedArray(f.rgba),r=c.ringPair(p,f.width,f.height,f.box,f.glyph,f.candidates);
 let ring=null;if(r&&!r.reject)ring={core:r.core,outline:r.outline,uniform:r.uniform,hug:r.hug,width:r.width,boxRing:r.boxRing,reached:r.reached,exterior:r.exterior,kind:r.kind,structure:r.structure(),surface:r.surface?{rgb:r.surface.rgb,flat:r.surface.flat,close:r.surface.close,reads:[[0,0,0],[255,255,255],[120,80,180]].map(rgb=>r.surface.reads(rgb,4.5))}:null};
 return {name:f.name,ring,reject:r?.reject||null,enclosed:c.enclosed(p,f.width,f.height,f.box,f.glyph,f.ink,f.neutral||false)};
});fs.writeFileSync(process.argv[4],JSON.stringify(outputs));
