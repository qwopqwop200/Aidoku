#!/usr/bin/env python3
"""Exact quad outside-box source observer policy; straight pixels are shared inputs.

Its production CGImage entry reads NativeSourcePixelReader.draw, separately proven
against live WebKit Canvas in the 46-case transport/resampler harness.
"""
import pathlib,json,subprocess,random
ROOT=pathlib.Path(__file__).resolve().parents[2];HERE=pathlib.Path(__file__).resolve().parent;SRC=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';OUT=ROOT/'build/native-render-parity/slanted-quad'
NODE=r'''
const fs=require('fs'),vm=require('vm'),base=process.argv[1],fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
const source=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8'),a=source.indexOf('const quadInkOutsideBox ='),b=source.indexOf('// A slanted caption whose rectified restoration',a),body=source.slice(a,b);
const helper=fs.readFileSync(base+'/BrowserSlantedSourceRestoration.swift','utf8').split('static let script = """')[1].split('"""')[0],out=[];
for(const f of fixtures){let crop=null;const image={complete:true,naturalWidth:f.size[0],naturalHeight:f.size[1]},[x,y,width,height]=f.quad,item={x,y,width,height,rotation:f.angle,sourceFrame:f.frame};
const sourcePixelReader={read(ctx,x,y,w,h){crop=[x,y,w,h];const p=new Uint8ClampedArray(w*h*4);for(let j=0;j<h;j++)for(let i=0;i<w;i++)for(let k=0;k<4;k++)p[(j*w+i)*4+k]=f.rgba[((y+j)*f.size[0]+x+i)*4+k];return p;}};
const c=vm.createContext({sourceImage:image,cleanupContext:{},sourcePixelReader,cachedSourceSample:()=>({foreground:f.foreground,background:f.background})});vm.runInContext(helper+'\n'+body+'\nglobalThis.observe=quadInkOutsideBox;',c);
const r=c.observe(item,{x:f.card[0],y:f.card[1],width:f.card[2],height:f.card[3]});out.push({name:f.name,observation:r,crop});}
process.stdout.write(JSON.stringify(out));
'''
MAIN=r'''
import CoreGraphics
import Foundation
let fs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
func rect(_ a:[Double])->CGRect { CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
var output:[[String:Any]]=[]
for f in fs {
 let size=f["size"] as! [Double],quad=rect(f["quad"] as! [Double]),frame=rect(f["frame"] as! [Double]),angle=f["angle"] as! Double
 var result:[String:Any]=["name":f["name"]!,"observation":NSNull(),"crop":NSNull()]
 if let fg=f["foreground"] as? [Double],let bg=f["background"] as? [Double],abs(NativeTranslationSourceStylePostPolish.luminance(fg)-NativeTranslationSourceStylePostPolish.luminance(bg))*255>=24,
 let crop=NativeSlantedQuadOutsideBox.crop(quad:quad,angle:angle,imageSize:CGSize(width:size[0],height:size[1]),frame:frame) {
 let rgba=(f["rgba"] as! [NSNumber]).map { $0.uint8Value },w=Int(crop.width),h=Int(crop.height),iw=Int(size[0]);var pixels=[UInt8](repeating:0,count:w*h*4)
 for y in 0..<h {for x in 0..<w {for c in 0..<4 {pixels[(y*w+x)*4+c]=rgba[((Int(crop.minY)+y)*iw+Int(crop.minX)+x)*4+c]}}}
 result["crop"]=[crop.minX,crop.minY,crop.width,crop.height]
 if let r=NativeSlantedQuadOutsideBox.estimate(rgba:pixels,crop:crop,imageSize:CGSize(width:size[0],height:size[1]),frame:frame,quad:quad,angle:angle,card:rect(f["card"] as! [Double]),foreground:fg,background:bg) {result["observation"]=["ink":r.ink,"area":r.area]}
 }
 output.append(result)
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
'''
def main():
 OUT.mkdir(parents=True,exist_ok=True);rng=random.Random(719);fs=[]
 for i in range(40):
  bg=rng.choice([[255,255,255],[240,220,180],[125,135,160],[20,25,30]]);fg=[0,0,0] if max(bg)>100 else [255,255,255]
  rgba=[]
  for y in range(50):
   for x in range(60):
    rgb=fg if (x+y)%13==0 or (i%3==0 and x<15) else bg
    rgba+=rgb+[rng.choice([1,16,64,128,255]) if i%4==0 else 255]
  quad=[rng.choice([2,10.25,20]),rng.choice([2,15.5]),rng.choice([12,30]),rng.choice([14,20])];card=quad.copy()
  if i%5==0:card[2]*=.5
  fs.append({'name':'quad '+str(i),'size':[60,50],'frame':[0,0,60,50],'quad':quad,'card':card,'angle':rng.choice([0,.1,.3,.65,-.5]),'foreground':fg,'background':bg,'rgba':rgba})
 for key in ['foreground','background']:
  f=fs[0].copy();f['name']='nullable '+key;f[key]=None;fs.append(f)
 f=fs[0].copy();f.update(name='inseparable palette',foreground=[250,250,250],background=[245,245,245]);fs.append(f)
 for i,box in enumerate([[10.5,10.5,12,14],[10,10,12,14]]):
  f=fs[0].copy();f.update(name='inclusive card edge '+str(i),quad=box,card=[12.5,14.5,7,7],angle=.65);fs.append(f)
 (OUT/'fixtures.json').write_text(json.dumps(fs));p=SRC/'NativeSlantedQuadOutsideBox.swift'
 s=p.read_text();s=s[:s.index('    static func read(')]+'}\n';(OUT/'Observer.swift').write_text(s);(OUT/'main.swift').write_text(MAIN)
 subprocess.run(['swiftc','-swift-version','6','-O',str(OUT/'Observer.swift'),str(SRC/'NativeSlantedGeometry.swift'),str(SRC/'NativeTranslationSourceStylePostPolish.swift'),str(OUT/'main.swift'),'-o',str(OUT/'native')],check=True)
 subprocess.run([str(OUT/'native'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
 native=json.loads((OUT/'native.json').read_text());web=json.loads(subprocess.check_output(['node','-e',NODE,str(HERE/'reference-source')],input=json.dumps(fs).encode()));(OUT/'web.json').write_text(json.dumps(web))
 failures=[{'name':a['name'],'native':a,'web':b} for a,b in zip(native,web) if a!=b]
 report={'cases':len(fs),'passed':len(fs)-len(failures),'failures':failures,'scope':'Original quadInkOutsideBox crop, inclusive ownership and raw straight RGB policy. Pixel transport independently verified by 46 actual Canvas comparisons.'}
 (OUT/'report.json').write_text(json.dumps(report,indent=2));print(f"{report['passed']}/{len(fs)} exact source quad observer cases");
 if failures:print(json.dumps(failures[:2],indent=2));raise SystemExit(1)
if __name__=='__main__':main()
