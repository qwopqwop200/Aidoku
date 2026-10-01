#!/usr/bin/env python3
"""Independent frozen-JavaScript vs native forced-donor/certified-plane differential."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
NODE = r'''
const fs=require('fs'),vm=require('vm');
const quality=fs.readFileSync(process.argv[1],'utf8');
const surface=fs.readFileSync(process.argv[2],'utf8');
const functionStart=surface.indexOf('        function aidokuSourceSurfaceQuality(');
const functionEnd=surface.indexOf('        // Restoration may recover',functionStart);
const script=quality.slice(quality.indexOf('    static let script = """')+'    static let script = """'.length,quality.lastIndexOf('    """'));
const scope=vm.createContext({});
vm.runInContext(surface.slice(functionStart,functionEnd)+script+`;globalThis.run=(v)=>{
const o={sourceForeground:v.foreground,glyphSize:v.glyphSize||0,excludedMask:v.blocked,diagnostic:true};
const result=v.operation==='certified'?aidokuCertifiedSurfaceFill(v.rgba,v.width,v.height,v.mask,v.blocked||new Uint8Array(v.mask.length),o):aidokuForcedDonorFill(v.rgba,v.width,v.height,v.mask,o);
if(!result)return {missing:true};
return {rgba:result.rgba?Array.from(result.rgba):null,method:result.method,failure:aidokuForcedDonorFill.lastFailure||'',residualMask:aidokuForcedDonorFill.lastResidualMask?Array.from(aidokuForcedDonorFill.lastResidualMask):null,quality:result.quality};};`,scope);
const input=JSON.parse(fs.readFileSync(0,'utf8'));process.stdout.write(JSON.stringify(scope.run(input)));
'''

def fixtures():
    out=[]
    for name,operation in [('flat','donor'),('gradient','donor'),('edge','donor'),('residual','donor'),
                           ('white-halo','donor'),('wide-mask','donor'),('no-donors','donor'),
                           ('float-ties','donor'),('certified-flat','certified'),
                           ('certified-gradient','certified'),('certified-texture','certified')]:
        w=h=64; rgba=[];mask=[0]*(w*h)
        for y in range(h):
            for x in range(w):
                color=[180,210,230]
                if 'gradient' in name:color=[min(255,120+x+y),160+y,180+x]
                if name=='edge':color=[40,65,90] if x<32 else [200,220,235]
                if name=='float-ties':color=[101+(x&1),153+(y&1),199+((x+y)&1)]
                if name=='certified-flat':color=[225,225,225]
                if name=='certified-texture':color=[110,170,190] if (x+y)%2 else [230,220,250]
                if name=='white-halo' and 25<=x<39 and 25<=y<39:color=[255,255,255]
                if 29<=x<35 and 29<=y<35:mask[y*w+x]=1;color=[20,30,40]
                if name=='residual' and 37<=x<39 and 29<=y<35:color=[20,30,40]
                if name=='wide-mask' and 5<=x<59 and 5<=y<59:mask[y*w+x]=1
                if name=='no-donors':mask[y*w+x]=1
                rgba.extend(color+[255])
        out.append((name,{'rgba':rgba,'width':w,'height':h,'mask':mask,'foreground':[20,30,40],
                          'glyphSize':24,'operation':operation}))
    return out

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,default=ROOT/'build/native-residual-proof-host/check')
    parser.add_argument('--output',type=Path,default=ROOT/'build/native-residual-proof-host/differential.json')
    args=parser.parse_args();reports=[]
    for name,data in fixtures():
        raw=json.dumps(data).encode()
        reference=json.loads(subprocess.check_output(['node','-e',NODE,str(ROOT/'Scripts/native-render-parity/reference-source/BrowserForcedInpaintQuality.swift'),str(ROOT/'Scripts/native-render-parity/reference-source/BrowserSourcePanelRestoration.swift')],input=raw))
        native=json.loads(subprocess.check_output([str(args.binary)],input=raw))
        differences=[]
        for key in ('missing','rgba','method','failure','residualMask'):
            if reference.get(key)!=native.get(key):differences.append(key)
        for key,value in reference.get('quality',{}).items():
            if native.get('quality',{}).get(key)!=value:differences.append('quality.'+key)
        reports.append({'id':name,'exact':not differences,'differences':differences,'method':reference.get('method'),
                        'failure':reference.get('failure'),'differentBytes':sum(a!=b for a,b in zip(reference.get('rgba') or [],native.get('rgba') or []))})
        print(name, 'EXACT' if not differences else 'MISMATCH', ','.join(differences))
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps({'gate':'exact-output-and-proof','fixtures':reports,'passed':all(r['exact'] for r in reports)},indent=2)+'\n')
    return 0 if all(r['exact'] for r in reports) else 1

if __name__=='__main__':raise SystemExit(main())
