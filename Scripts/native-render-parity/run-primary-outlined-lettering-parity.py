#!/usr/bin/env python3
"""Actual primary source outline paint policy versus its frozen JavaScript body.

Typed ring evidence is an input here; the independent ring/scan pixel harnesses
verify that evidence. This tests all paint mutations and diagnostic dictionaries.
"""
import copy,hashlib,json,pathlib,random,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[2];HERE=pathlib.Path(__file__).resolve().parent
SRC=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';OUT=ROOT/'build/native-render-parity/primary-outlined-lettering'
NODE=r'''
const fs=require('fs'),vm=require('vm'),base=process.argv[1],fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
const source=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8'),start=source.indexOf('const ink=node.dataset.sourceAppliedTextRGB?.split',source.indexOf('let ringPixels=393216,ringStyled=')),end=source.indexOf('ringStyled++;',start)+'ringStyled++;'.length;
if(start<0||end<start)throw Error('frozen outline body missing');
const body=source.slice(start,end),colourSource=fs.readFileSync(base+'/BrowserSourceTextColor.swift','utf8').split('static let script = """')[1].split('"""')[0];
const c=vm.createContext({performance:{now:()=>0}});vm.runInContext(colourSource,c);
vm.runInContext(`globalThis.run=f=>{
 const state=f.state,result={...f.ring},sample=state.sample||{},item={id:f.name,sourceSample:sample};
 const node={dataset:{},style:{fontSize:String(state.font??10),webkitTextStrokeWidth:String(state.strokeWidth||0),webkitTextStrokeColor:'initial'}};
 if(state.foreground)node.dataset.sourceAppliedTextRGB=state.foreground.join(',');
 if(state.stroke)node.dataset.sourceAppliedStrokeRGB=state.stroke.join(',');
 if(state.sourceContrastBefore!==undefined)node.dataset.sourceContrastBefore=String(state.sourceContrastBefore);
 if(state.slantedSurfaceLuminance)node.dataset.slantedSurfaceLuminance=JSON.stringify(state.slantedSurfaceLuminance);
 const plateRGB=state.plate||null,owner={style:{backgroundColor:plateRGB?'rgb('+plateRGB.join(',')+')':''},querySelectorAll:()=>({length:state.plateIsAlone===false?2:1})};
 const panelsO=[owner],inksO=(state.overlappingInks||[]).map(rgb=>[{dataset:rgb?{sourceAppliedTextRGB:rgb.join(',')}:{ }},{}]),backingsO=[];
 const restored=!!state.restored,slanted=!!state.slanted,missingColumnRing=!!state.missingColumnRing;
 const validO=rgb=>Array.isArray(rgb)&&rgb.length===3&&rgb.every(v=>Number.isFinite(v)&&v>=0&&v<=255),gapO=(a,b)=>Math.max(...a.map((x,i)=>Math.abs(x-b[i]))),spreadO=rgb=>Math.max(...rgb)-Math.min(...rgb);
 const pairO=(a,b)=>{let x=aidokuSourceColorLuminance(a),y=aidokuSourceColorLuminance(b);return (Math.max(x,y)+.05)/(Math.min(x,y)+.05);};
 const sampledStrokeO=()=>validO(sample.stroke)&&(sample.confidence?.stroke||0)>=.55;
 const aidokuPlateMeets=()=>true;
 result.structure=()=>f.ring.structure;
 if(result.surface)result.surface={...result.surface,reads:(rgb,ratio)=>{const y=aidokuSourceColorLuminance(rgb),v=f.ring.surface.luminances;return v.filter(l=>(Math.max(l,y)+.05)/(Math.min(l,y)+.05)>=ratio).length/v.length;}};
 let rolesMilliseconds=0,ringStyled=0;
 for(const once of [1]){${body}}
 const record=JSON.parse(node.dataset.outlinedLettering),changed=ringStyled>0,stroke=node.style.webkitTextStrokeColor;
 const rgbText=t=>t.match(/[0-9.]+/g).map(Number);
 return {name:f.name,fill:changed?rgbText(node.style.color):null,stroke:stroke!=='initial'&&stroke!=='transparent'?rgbText(stroke):null,
 strokeWidth:stroke!=='initial'&&stroke!=='transparent'?parseFloat(node.style.webkitTextStrokeWidth):null,
 background:record.plateTo||null,clearsStroke:stroke==='transparent',record,rejection:node.dataset.outlinedLetteringReject||null};
};`,c);
process.stdout.write(JSON.stringify(fixtures.map(f=>c.run(f))));
'''
def fixtures():
 fs=[];rng=random.Random(20260930)
 base={'ring':{'core':[10,10,10],'outline':[240,240,240],'uniform':.9,'hug':.95,'width':.08,'boxRing':.2,'reached':.95,'exterior':.1,'kind':'outline','structure':{'band':.85,'deep':.1,'fillN':80,'ringN':90},'surface':{'rgb':[160,160,160],'flat':True,'close':.95,'luminances':[.3,.31,.32]}},'state':{'font':14,'foreground':[128,128,128],'strokeWidth':0,'plate':[160,160,160],'sample':{'foreground':[10,10,10],'stroke':[240,240,240],'confidence':{'stroke':.9}}}}
 def add(name,ring=None,state=None):
  f=copy.deepcopy(base);f['name']=name;f['ring'].update(ring or {});f['state'].update(state or {});fs.append(f);return f
 add('sampled light outline')
 add('source pair already drawn',state={'foreground':[10,10,10],'stroke':[240,240,240],'strokeWidth':2})
 add('restored flat gold brown',ring={'core':[242,195,30],'outline':[60,25,5],'surface':{'rgb':[245,245,245],'flat':True,'close':1,'luminances':[.91,.93]}},state={'restored':True,'sample':{'foreground':[242,195,30],'stroke':[60,25,5],'confidence':{'stroke':.9}}})
 add('restored varying surface',state={'restored':True},ring={'surface':{'rgb':[10,10,10],'flat':False,'close':.3,'luminances':[.01,.02,.03,.04]}})
 add('restored non reading varying surface',state={'restored':True},ring={'surface':{'rgb':[200,200,200],'flat':False,'close':.3,'luminances':[.6,.7,.8]}})
 add('unsampled missing column ownership',state={'restored':True,'missingColumnRing':True,'sample':{'foreground':[10,10,10]}})
 add('unsampled ring unowned',state={'restored':True,'sample':{}})
 add('bad ring roles',state={'foreground':[0,0,0],'sample':{'foreground':[240,240,240]}},ring={'structure':{'band':.2,'deep':.5,'fillN':15,'ringN':10}})
 add('vanishing ink role recovery',state={'foreground':[160,160,160],'sample':{'foreground':[240,240,240]}},ring={'structure':{'band':.2,'deep':.5,'fillN':15,'ringN':10}})
 add('carried real stroke refuses roles',state={'foreground':[230,230,230],'stroke':[5,5,5],'strokeWidth':2,'plate':[245,245,245],'sample':{'foreground':[240,240,240],'widthEvidence':{'samplePixels':3,'relativeToGlyph':.2}}},ring={'structure':{'band':.2,'deep':.5,'fillN':15,'ringN':10}})
 add('wide paper halo',ring={'kind':'paper','width':.25,'boxRing':.7},state={'plate':[10,10,10],'foreground':[10,10,10]})
 add('halo shared plate refusal',ring={'kind':'paper','width':.25,'boxRing':.7},state={'plate':[10,10,10],'foreground':[10,10,10],'plateIsAlone':False})
 add('halo other ink refusal',ring={'kind':'paper','width':.25,'boxRing':.7},state={'plate':[10,10,10],'foreground':[10,10,10],'overlappingInks':[[240,240,240]]})
 add('surface plate stroke cleared',ring={'kind':'paper','surface':{'rgb':[240,240,240],'flat':True,'close':1,'luminances':[.85]}},state={'plate':[5,5,5],'strokeWidth':2})
 add('surface plate other ink missing',state={'plate':[5,5,5],'overlappingInks':[None]})
 add('dark core on dark art',ring={'surface':{'rgb':[5,5,5],'flat':True,'close':1,'luminances':[.001]}},state={'plate':[5,5,5]})
 add('outline alone fills dark art',ring={'surface':{'rgb':[5,5,5],'flat':True,'close':1,'luminances':[.001]}},state={'font':8,'plate':[5,5,5]})
 add('slanted colored fill correction',ring={'core':[80,25,125],'outline':[0,0,0],'boxRing':None,'surface':{'rgb':[125,125,125],'flat':False,'close':.8,'luminances':[.1,.3,.5]}},state={'font':24,'foreground':[200,200,200],'plate':[200,200,200],'restored':True,'slanted':True,'sample':{'foreground':[80,25,125]},'slantedSurfaceLuminance':[.01,.8]})
 add('slanted sampled edge correction',ring={'core':[255,255,255],'outline':[60,60,60],'boxRing':None,'surface':{'rgb':[15,130,160],'flat':True,'close':.8,'luminances':[.005,.01]}},state={'font':12,'foreground':[80,25,125],'plate':[0,0,0],'restored':True,'slanted':True,'sample':{'foreground':[255,255,255],'stroke':[60,60,60],'confidence':{'stroke':.8}},'slantedSurfaceLuminance':[.3,.6]})
 add('large hollow type',ring={'core':[245,245,245],'outline':[10,10,10],'surface':None},state={'font':24,'plate':[245,245,245],'sample':{'foreground':[245,245,245],'stroke':[10,10,10],'confidence':{'stroke':.9}}})
 add('raised pale edge on gray wash',ring={'core':[0,0,0],'outline':[130,130,130],'surface':None},state={'plate':[75,75,75],'sample':{'foreground':[0,0,0],'stroke':[130,130,130],'confidence':{'stroke':.9}}})
 add('colored fill replacing neutral',ring={'kind':'paper','core':[180,20,30],'outline':[245,245,245],'surface':None},state={'plate':[255,255,255],'sample':{'foreground':[180,20,30]}})
 add('colored lost source ink',ring={'kind':'paper','core':[65,95,15],'outline':[245,245,245],'surface':None},state={'plate':[255,255,255],'sourceContrastBefore':1.1,'sample':{'foreground':[65,95,15]}})
 add('small font rejects framed pair',state={'font':7})
 add('missing display ink',state={'foreground':None})
 colours=[[0,0,0],[255,255,255],[125,125,125],[60,60,60],[200,200,200],[215,155,30],[80,25,125],[15,130,160],[150,30,40]]
 for i in range(2000):
  core,outline,plate,ink=[rng.choice(colours) for _ in range(4)];sample={'foreground':rng.choice([core,outline]),'confidence':{'stroke':rng.choice([.4,.8])}}
  if rng.random()<.7:sample['stroke']=outline
  if rng.random()<.3:sample['widthEvidence']={'samplePixels':rng.choice([1,3]),'relativeToGlyph':rng.choice([.1,.2])}
  surface=None if rng.random()<.15 else {'rgb':rng.choice(colours),'flat':rng.random()<.6,'close':.8,'luminances':rng.choice([[.005,.01],[.7,.8],[.1,.3,.5],[.01,.3,.8]])}
  add('matrix '+str(i),ring={'core':core,'outline':outline,'kind':rng.choice(['outline','paper']),'width':rng.choice([.05,.15,.3]),'hug':rng.choice([.75,.95]),'uniform':rng.choice([.55,.9]),'boxRing':rng.choice([None,.2,.7]),'exterior':rng.choice([None,.1]),'surface':surface,'structure':{'band':rng.choice([.2,.9]),'deep':rng.choice([.1,.4]),'fillN':rng.choice([20,80]),'ringN':90}},state={'foreground':ink,'plate':plate,'font':rng.choice([8,12,24]),'sample':sample,'strokeWidth':rng.choice([0,2]),'stroke':rng.choice(colours),'restored':rng.random()<.5,'slanted':rng.random()<.5,'missingColumnRing':rng.random()<.3,'plateIsAlone':rng.random()<.9,'overlappingInks':[] if rng.random()<.8 else [rng.choice(colours)],'slantedSurfaceLuminance':rng.choice([[.01,.04],[.1,.3],[.3,.6],[.01,.8]]),'sourceContrastBefore':rng.choice([1.1,3])})
 return fs

def main():
 OUT.mkdir(parents=True,exist_ok=True);fs=fixtures();(OUT/'fixtures.json').write_text(json.dumps(fs))
 names=['NativeTranslationPixelKernels','NativeSourceColorSampler','NativeSourceOutlineEvidence','NativePrimaryOutlinedLettering'];snapshot=OUT/'source';snapshot.mkdir(exist_ok=True);paths=[];digest=hashlib.sha256()
 for n in names:
  p=SRC/(n+'.swift');raw=p.read_bytes();target=snapshot/p.name;target.write_bytes(raw);paths.append(str(target));digest.update(raw)
 lib=ROOT/'build/native-overlay-kernels-host/libAidokuOverlayKernels.a';digest.update(str(lib.stat().st_mtime_ns).encode());raw=(HERE/'PrimaryOutlinedLetteringParityMain.swift').read_bytes();(OUT/'main.swift').write_bytes(raw);digest.update(raw)
 cache=OUT/'build-hash';binary=OUT/'native'
 if not binary.exists() or not cache.exists() or cache.read_text()!=digest.hexdigest():
  subprocess.run(['swiftc','-swift-version','6','-O','-I',str(ROOT/'Scripts/overlay-kernels/native'),*paths,str(OUT/'main.swift'),str(lib),'-o',str(binary)],check=True);cache.write_text(digest.hexdigest())
 subprocess.run([str(binary),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
 browser=json.loads(subprocess.check_output(['node','-e',NODE,str(HERE/'reference-source')],input=json.dumps(fs).encode()));(OUT/'browser.json').write_text(json.dumps(browser));native=json.loads((OUT/'native.json').read_text())
 failures=[{'name':a['name'],'native':a,'browser':b} for a,b in zip(native,browser) if a!=b]
 actions=sorted({b['record']['action'] for b in browser});required={'none','kept','halo-plate','surface-plate','raised-outline','hollow','outline','outline-as-fill','fill','restored-outline'};assert set(actions)==required,(actions,required);assert any('slantedPair' in b['record'] for b in browser);assert any(b['clearsStroke'] for b in browser);assert any(b['rejection']=='sampled-ink-is-ring' for b in browser);report={'fixtures':len(fs),'passed':len(fs)-len(failures),'failed':failures,'actions':actions,'scope':'Actual primary paint decision full mutations and descriptor proof, independently frozen JavaScript; source ring pixels separately tested'}
 (OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({'fixtures':len(fs),'passed':report['passed'],'failed':[x['name'] for x in failures][:15],'actions':actions}));raise SystemExit(bool(failures))
if __name__=='__main__':main()
