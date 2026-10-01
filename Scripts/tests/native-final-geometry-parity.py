#!/usr/bin/env python3
"""Frozen final upright text/plate, vertical top anchor and kept-zone geometry."""
from __future__ import annotations
import argparse,copy,importlib.util,json,math,pathlib,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2];OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';FIXTURES=ROOT/'Scripts/tests/fixtures/native-final-geometry';REFERENCE=ROOT/'Scripts/native-render-parity/reference-source'
spec=importlib.util.spec_from_file_location('comparison',ROOT/'Scripts/tests/native-outline-evidence-parity.py');comparison=importlib.util.module_from_spec(spec);spec.loader.exec_module(comparison)
def rotate(box,center,m):
    x,y,w,h=box;xs=[];ys=[]
    for px,py in [(x,y),(x+w,y),(x+w,y+h),(x,y+h)]:
        u,v=px-center[0],py-center[1];xs.append(m[0]*u+m[2]*v+m[4]+center[0]);ys.append(m[1]*u+m[3]*v+m[5]+center[1])
    return [min(xs),min(ys),max(xs)-min(xs),max(ys)-min(ys)]
def entry(id='a'):
    angle=.05;m=[math.cos(angle),math.sin(angle),-math.sin(angle),math.cos(angle),0,0]
    return dict(id=id,frame=[0,0,200,200],source=[70,85,60,30],box=[70,85,60,30],base=[[75,91,50,14]],font=20,pitch=24,stroke=1,angle=angle,upright=True,display=True,plate=dict(rect=rotate([50,75,100,50],[100,100],m),size=[100,50],matrix=m))
def finish(f):
    for r in f['entries']:
        a=r.get('angle',0);scale=r.get('scale',1);m=[math.cos(a)*scale,math.sin(a)*scale,-math.sin(a),math.cos(a),0,0];box=r['box'];r['lines']=[rotate(b,[box[0]+box[2]/2,box[1]+box[3]/2],m) for b in r['base']]
    return f

def fixtures():
    out=[]
    for index in range(21):
        e=entry();f=dict(name=f'upright-{index:02}',entries=[e],text=True,plate=True)
        if index==1:e['angle']=math.pi/43
        elif index==2:e['vertical']=True
        elif index==3:e['upright']=False
        elif index==4:e['visible']=False
        elif index==5:e.pop('plate')
        elif index==6:e['scale']=1.0101
        elif index==7:e['scale']=.9
        elif index==8:e['overflow']=True
        elif index==9:e['plate']['unsupported']=True
        elif index==10:e['plate']['clip']=[[40,10],[60,10],[50,40]]
        elif index==11:e['plate']['clip']=[[0,0],[100,0],[100,50],[0,50]]
        elif index==12:e['plate']['matrix'][4]=.011
        elif index==13:e['base']=[[40,91,100,14]];e['plate']['size']=[90,50]
        elif index==14:e['base']=[[0,91,180,14]]
        elif index==15:e['display']=False
        elif index==16:e['plate']['image']=True
        elif index==17:e['plate']['matrix']=[1.002,0,0,1,0,0]
        elif index==18:
            m=e['plate']['matrix'];det=m[0]*m[3]-m[1]*m[2];e['plate']['clip']=[[(m[3]*(x-100)-m[2]*(y-100))/det+50,(-m[1]*(x-100)+m[0]*(y-100))/det+25] for x,y in [(0,0),(200,0),(200,200),(0,200)]]
        elif index==19:
            foreign=entry('b');foreign['upright']=False;foreign['angle']=0;foreign['base']=[[72,91,4,14]];f['entries'].append(foreign)
        elif index==20:e['stroke']=18
        out.append(finish(f))
    for index in range(12):
        e=entry();e.pop('plate');e['angle']=0;e['upright']=False;e.update(sourceVertical=True,column=True,inpainted=True,source=[75,55,18,100],base=[[75,90,18,14],[75,114,18,14]])
        f=dict(name=f'anchor-{index:02}',entries=[e],anchor=True)
        if index==1:e['balloon']=True
        elif index==2:e['root']=False
        elif index==3:e['keeps']=True
        elif index==4:e['inpainted']=False
        elif index==5:e['column']=False
        elif index==6:e['source']=[75,55,70,90]
        elif index==7:e['source'][1]=-.5
        elif index==8:e['source'][1]=180
        elif index==9:f['count']=257
        elif index==10:
            foreign=entry('b');foreign.pop('plate');foreign['angle']=0;foreign['upright']=False;foreign['base']=[[75,55,18,14]];f['entries'].append(foreign)
        elif index==11:e['source'][1]=90.2
        out.append(finish(f))
    for index in range(12):
        kept=[dict(id='k',rect=[10,10,80,70],font=12)];painted=[]
        if index==1:painted=[[25,20,15,30]]
        elif index==2:painted=[[0,0,200,200]]
        elif index==3:painted=[[0,0,20,200],[70,0,100,200]]
        elif index==4:painted=[[10.2,0,.2,200],[10.7,0,.2,200]]
        elif index==5:kept[0]['font']=200
        elif index==6:kept[0].pop('font')
        elif index==7:kept=[dict(id=str(i),rect=[i,i,2,2]) for i in range(257)]
        elif index==8:kept[0]['rect']=[10,10,-1,70]
        elif index==9:painted=[[11+i,11+i,.2,.2] for i in range(70)]
        elif index==10:painted=[[500,500,1,1]]*512+[[0,0,200,200]]
        elif index==11:kept.append(dict(id='z',rect=[0,0,3,4],font=0));painted=[[2,2,5,5]]
        out.append(dict(name=f'kept-{index:02}',entries=[],kept=kept,painted=painted))
    for index in range(22):
        e=entry();e.pop('plate');e['angle']=0;e['upright']=False;e['base']=[[8,80,50,14],[8,104,50,14]]
        f=dict(name=f'contain-{index:02}',entries=[e],contain=True)
        if index==1:e['base']=[[74.8,80,50,14],[74.8,104,50,14]]
        elif index==2:e['verified']=False
        elif index==3:e['angle']=.01
        elif index==4:e['vertical']=True
        elif index==5:e['keeps']=True
        elif index==6:e['visible']=False
        elif index==7:e['transform']=False;e['scale']=.9
        elif index==8:e['writing']=False
        elif index==9:e['spans']=[.45,.55,.45,.55]
        elif index==10:e['parent']=[60,60,35,80]
        elif index==11:e['hasPlates']=True;e['covers']=[[60,60,70,80]]
        elif index==12:e['hasPlates']=True
        elif index==13:e['spans']=[.4,.6,.2,.8,.35,.65,.4,.6]
        elif index==14:e['center']=[.6,.6]
        elif index==15:e['base'].insert(0,[8,80,50,42])
        elif index==16:e['stroke']=14
        elif index==17:e['spans']=[-.1,-.1,.2,.8,.2,.8,.2,.8]
        elif index==18:f['count']=257
        elif index==19:
            foreign=entry('b');foreign.pop('plate');foreign['angle']=0;foreign['upright']=False;foreign['verified']=False;foreign['base']=[[75,80,50,14],[75,104,50,14]];f['entries'].append(foreign)
        elif index==20:e['base']=[[0,5,50,14],[0,29,50,14]]
        elif index==21:e['spans']=[.375,.625,.375,.625]
        out.append(finish(f))
    return out

def run(directory,reference):
    directory.mkdir(parents=True,exist_ok=True);inputs=directory/'input.json';inputs.write_text(json.dumps(fixtures()));source=directory/'main.swift';shutil.copyfile(FIXTURES/'main.swift',source);executable=directory/'native-final-geometry'
    subprocess.run(['xcrun','swiftc',str(OVERLAY/'NativeTranslationFinalGeometry.swift'),str(OVERLAY/'NativeBalloonTextContainment.swift'),str(source),'-o',str(executable)],check=True)
    native,browser=directory/'native.json',directory/'browser.json';subprocess.run([str(executable),str(inputs),str(native)],check=True);subprocess.run(['node',str(FIXTURES/'oracle.cjs'),str(inputs),str(reference),str(browser)],check=True)
    actual,expected=json.loads(native.read_text()),json.loads(browser.read_text());differences=[]
    for a,b in zip(actual,expected,strict=True):
        fields=[k for k in a if not comparison.same(a[k],b[k])];print(f"{a['name']}: {'DIFFERENT '+', '.join(fields) if fields else 'EXACT'}")
        if fields:differences.append(dict(name=a['name'],fields=fields))
    report=dict(exact=not differences,fixtures=len(actual),uprightAccepted=sum(s['textUpright'] for a in actual for s in a['states']),plateAccepted=sum(bool(s['plate'] and s['plate']['upright']) for a in actual for s in a['states']),anchorAccepted=sum(s['anchored'] for a in actual for s in a['states']),containmentAccepted=sum(bool(s['fit']) for a in actual for s in a['containment']),containmentReduced=sum(bool(s['fit'] and s['fit'][3]<s['fit'][2]) for a in actual for s in a['containment']),scope='Frozen final geometry and final balloon containment policies with shared deterministic Range-equivalent metrics; platform glyph raster and full image parity excluded.',differences=differences)
    (directory/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    if differences:raise SystemExit('Final geometry policy parity failed; inspect saved output.')
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reference-overlay',type=pathlib.Path,default=REFERENCE);p.add_argument('--output-dir',type=pathlib.Path);a=p.parse_args()
    if a.output_dir:run(a.output_dir.resolve(),a.reference_overlay.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='aidoku-native-final-geometry-') as d:run(pathlib.Path(d),a.reference_overlay.resolve())
if __name__=='__main__':main()
