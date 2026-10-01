"""Read-only public detached mask source, raw GPU, PNG and immutable route audit."""
from pathlib import Path
import argparse, hashlib, json, struct, zlib
ROOT=Path(__file__).resolve().parents[4]
BASE=ROOT/"build/native-render-parity"
SHA="47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d"
W,H=960,480;ROI=(405,21,273,363)
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def compare(a,b):
    assert len(a)==len(b) and len(a)%4==0
    changed=maximum=0;channels=[{}, {}, {}, {}]
    for i in range(0,len(a),4):
        delta=[a[i+c]-b[i+c] for c in range(4)]
        changed+=any(delta);maximum=max(maximum,*map(abs,delta))
        for c,d in enumerate(delta):
            if d: channels[c][str(d)]=channels[c].get(str(d),0)+1
    return {"exactRGBA":changed==0,"changedPixels":changed,"maxChannelDelta":maximum,"changedChannelDeltasRGBA":channels}
def crop(path):
    b=path.read_bytes();assert len(b)==W*H*4
    x,y,w,h=ROI;return b"".join(b[(j*W+x)*4:(j*W+x+w)*4] for j in range(y,y+h))
def png(path):
    b=path.read_bytes();assert b[:8]==b"\x89PNG\r\n\x1a\n"
    off=8;compressed=[];chunks=[]
    while off<len(b):
        length=struct.unpack(">I",b[off:off+4])[0];kind=b[off+4:off+8];data=b[off+8:off+8+length]
        checksum=struct.unpack(">I",b[off+8+length:off+12+length])[0]
        assert zlib.crc32(kind+data)&0xffffffff==checksum
        chunks.append(kind.decode())
        if kind==b"IHDR": w,h,depth,color,compression,filtering,interlace=struct.unpack(">IIBBBBB",data)
        if kind==b"IDAT": compressed.append(data)
        off+=length+12
    assert depth==8 and color in (2,6) and compression==filtering==interlace==0
    n=4 if color==6 else 3;stride=w*n;raw=zlib.decompress(b"".join(compressed));assert len(raw)==(stride+1)*h
    prev=bytearray(stride);rgba=bytearray();i=0
    def paeth(a,b,c):
        p=a+b-c;da,db,dc=abs(p-a),abs(p-b),abs(p-c)
        return a if da<=db and da<=dc else b if db<=dc else c
    for y in range(h):
        mode=raw[i];i+=1;row=bytearray(raw[i:i+stride]);i+=stride;assert 0<=mode<=4
        for x in range(stride):
            a=row[x-n] if x>=n else 0;b0=prev[x];c=prev[x-n] if x>=n else 0
            value=(0,a,b0,(a+b0)//2,paeth(a,b0,c))[mode]
            row[x]=(row[x]+value)&255
        if n==4: rgba.extend(row)
        else:
            for x in range(0,stride,3): rgba.extend(row[x:x+3]);rgba.append(255)
        prev=row
    # Canonical captures are PMA; decode PNG independently as unassociated RGB,
    # then apply exact half-up8bit premultiplication. No color transform: sRGB.
    assert "sRGB" in chunks and "iCCP" not in chunks and "CgBI" not in chunks
    straight=bytes(rgba)
    for i in range(0,len(rgba),4):
        a=rgba[i+3]
        for c in range(3): rgba[i+c]=(rgba[i+c]*a+127)//255
    return {"size":[w,h],"colorType":color,"chunks":chunks,"crcValid":True},straight,bytes(rgba)

parser=argparse.ArgumentParser()
parser.add_argument("--snapshot",type=Path,required=True)
parser.add_argument("--out",type=Path,required=True)
args=parser.parse_args(); args.out.mkdir(parents=True,exist_ok=True)
source=args.snapshot/"immutable-source.png"
assert sha(source)==SHA
sourcePNG,_,decoded=png(source)
assert decoded==(args.snapshot/"immutable-source.rgba").read_bytes()
producer=BASE/"verify-source-canvas-producer-build53-snapshot"
assert decoded==(producer/"immutable-actual44-mask0.rgba").read_bytes()
doc=json.loads((args.snapshot/"report.json").read_text())
records=[]
for background in ["transparent","opaque"]:
    names=[record["name"] for record in doc.get("reports",[]) if record.get("background")==background]
    folder=args.snapshot/(names[0] if names else background+"-public-detached-metal")
    r={"background":background,"folder":str(folder),"availableFiles":sorted(p.name for p in folder.iterdir()) if folder.exists() else []}
    for name in ["attempt","capture-raw","capture","failure","delegate-draw-contexts","native-draw-contexts"]:
        p=folder/(name+".json")
        if p.exists(): r[name]=json.loads(p.read_text())
    sourceRGBA=folder/"source-realized.rgba"
    r["sameSourceRGBA"]=sourceRGBA.exists() and sourceRGBA.read_bytes()==decoded
    if (folder/"source-realized.png").exists():
        m,_,bytesPNG=png(folder/"source-realized.png")
        r["sourcePNG"]={"metadata":m,"sameCanonicalSource":bytesPNG==decoded}
    raw=folder/"capture.rgba"
    if raw.exists():
        b=raw.read_bytes(); r["rawSHA256"]=sha(raw); r["rawByteCount"]=len(b)
        r["blankRGBA"]=not any(b)
        r["nonzeroBytes"]=sum(x!=0 for x in b)
        r["visibleAlphaPixels"]=sum(b[i]!=0 for i in range(3,len(b),4))
        if len(b)==W*H*4:
            p=folder/"capture.png"
            if p.exists():
                m,_,encoded=png(p);r["capturePNG"]={"metadata":m,"vsRawGPU":compare(encoded,b)}
            paths={"producer53A":producer/background/"A-draw-before.rgba",
                "producer53B":producer/background/"B-draw-after.rgba",
                "producer53C":producer/background/"C-put-before.rgba",
                "layer56linear":BASE/"verify-canvas-layer-build56-snapshot"/(background+"-linear")/"capture.rgba",
                "layer56trilinear":BASE/"verify-canvas-layer-build56-snapshot"/(background+"-trilinear")/"capture.rgba",
                "realization55":BASE/"verify-canvas-realization-build55-snapshot"/(background+"-ci-normal-read-before-display")/"capture.rgba"}
            r["fullPageComparisons"]={name:compare(b,p.read_bytes()) for name,p in paths.items()}
            roi=crop(raw);r["maskROIComparisons"]={name:compare(roi,crop(p)) for name,p in paths.items()}
            # Pure observation control: do not rewrite the captured bytes or output PNG.
            flipped=b"".join(b[y*W*4:(y+1)*W*4] for y in range(H-1,-1,-1))
            r["verticalRowOrderObservationVsProducerA"]={"raw":compare(b,paths["producer53A"].read_bytes()),
                "countercomparisonReversedRows":compare(flipped,paths["producer53A"].read_bytes()),
                "captureWasModified":False}
            x,y,w,h=ROI
            frameReversed=bytearray(b)
            for row in range(h):
                start=((y+h-1-row)*W+x)*4; destination=((y+row)*W+x)*4
                frameReversed[destination:destination+w*4]=b[start:start+w*4]
            r["sourceFrameRowOrientationCountercomparison"]={
                "scope":"Reverse only fixed source-frame rows as an observation; no PNG or capture rewritten; no fitted offset.",
                "comparisons":{name:compare(frameReversed,path.read_bytes()) for name,path in paths.items()},
                "captureWasModified":False}
    records.append(r)
report={"snapshot":str(args.snapshot),"originalPNGHash":SHA,"sourcePNG":sourcePNG,
    "sourceRGBAHash":hashlib.sha256(decoded).hexdigest(),"sourceSameAsImmutable53":True,
    "captureControls":doc,"records":records,"pixelParityAsserted":False,
    "paintingPresenceEstablished": all("blankRGBA" in r and not r["blankRGBA"] for r in records),
    "commandCompletionIsPaintingProof":False,
    "limits":["A diagnostic command-completion result is separate from pixel equality.",
        "Texture row orientation is observed independently, with no capture rewriting.",
        "No private API, source modification, minification fitting or inferred backend identity."]}
(args.out/"comparison.json").write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({"report":str(args.out/"comparison.json"),"records":len(records),"captured":sum('rawByteCount' in r for r in records)}))
