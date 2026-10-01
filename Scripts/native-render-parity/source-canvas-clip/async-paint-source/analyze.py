"""Independent immutable source/raw/PNG/context audit for four async paint controls."""
from pathlib import Path
import argparse,hashlib,json,struct,zlib
ROOT=Path(__file__).resolve().parents[4];BASE=ROOT/"build/native-render-parity"
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

parser=argparse.ArgumentParser();parser.add_argument("--snapshot",type=Path,required=True);parser.add_argument("--out",type=Path,required=True)
args=parser.parse_args();args.out.mkdir(parents=True,exist_ok=True)
assert sha(args.snapshot/"immutable-source.png")==SHA
sm,_,source=png(args.snapshot/"immutable-source.png");assert source==(args.snapshot/"immutable-source.rgba").read_bytes()
producer=BASE/"verify-source-canvas-producer-build53-snapshot";assert source==(producer/"immutable-actual44-mask0.rgba").read_bytes()
doc=json.loads((args.snapshot/"report.json").read_text());records=[]
for r in doc["reports"]:
    folder=args.snapshot/r["name"];sourceMeta,_,sample=png(folder/"source-realized.png")
    assert source==sample==(folder/"source-realized.rgba").read_bytes()
    cm,_,capture=png(folder/"capture.png");raw=(folder/"capture.rgba").read_bytes()
    contexts=json.loads((folder/"native-draw-contexts.json").read_text())
    refs={mode:producer/r["background"]/(mode+".rgba") for mode in ["A-draw-before","B-draw-after","C-put-before"]}
    records.append({"name":r["name"],"requestedFlag":r["requestedDrawsAsynchronously"],"actualFlag":r["actualDrawsAsynchronously"],
        "sourceSameAsImmutable53":True,"sourcePNG":sourceMeta,"capturePNG":cm,"captureSHA256":sha(folder/"capture.rgba"),
        "PNGDecodeVsRawPMA":compare(capture,raw),"fullPageComparisons":{name:compare(raw,path.read_bytes()) for name,path in refs.items()},
        "contexts":contexts,"onscreenCallbacks":r.get("onscreenDisplayInvocationCount",r.get("preparedDrawInvocationCount")),"captureCallbacks":r["capturePhaseDrawInvocationCount"],
        "routeClassification":r["routeClassification"],"reportedControlValid":r["controlValid"]})
report={"snapshot":str(args.snapshot),"sourcePNGOriginalHash":SHA,"sourceCanonicalRGBAHash":hashlib.sha256(source).hexdigest(),
    "sourceIndependentPNGDecodePassed":True,"captureControls":doc,"records":records,
    "limits":["Exact observation for original source/geometry on actual iOS26.5 simulator; not all-image/all-OS proof.",
        "No runtime private backend identity inferred; public flag is the sole tested intervention.","Frozen53A/C versusB timing references remain distinct; no WK regeneration or tolerance."]}
(args.out/"comparison.json").write_text(json.dumps(report,indent=2)+'\n')
for r in records:
    print(r["name"],{k:[v["changedPixels"],v["maxChannelDelta"]] for k,v in r["fullPageComparisons"].items()},"PNG",r["PNGDecodeVsRawPMA"]["changedPixels"],"callbacks",r["onscreenCallbacks"],r["captureCallbacks"])
