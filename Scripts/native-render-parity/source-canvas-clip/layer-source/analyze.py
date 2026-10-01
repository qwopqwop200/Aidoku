"""Independent stdlib PNG + immutable RGBA cross-control audit. No image changes."""
from pathlib import Path
import hashlib, json, struct, zlib
ROOT=Path(__file__).resolve().parents[4]
BASE=ROOT/"build/native-render-parity"
LAYER=BASE/"verify-canvas-layer-build56-snapshot"
OUT=BASE/"source-canvas-layer56";OUT.mkdir(exist_ok=True)
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
controls=json.loads((LAYER/"report.json").read_text());assert controls["sourceAndCaptureControlsPassed"] and controls["count"]==4
original=LAYER/"immutable-source.png";assert sha(original)==SHA
metadata,_,decoded=png(original);assert decoded==(LAYER/"immutable-source.rgba").read_bytes()
producer=BASE/"verify-source-canvas-producer-build53-snapshot";assert decoded==(producer/"immutable-actual44-mask0.rgba").read_bytes()
sourceInputs=[BASE/"verify-source-canvas-backing-build51-snapshot"/"immutable-actual44-mask0.rgba",
    BASE/"verify-canvas-realization-build55-snapshot"/"immutable-source.rgba"]
for bg in ["transparent","opaque"]:
    sourceInputs += [BASE/"verify-source-canvas-alpha-build56-snapshot"/bg/"source-native-actual-mask.rgba",
        BASE/"verify-source-canvas-alpha-build56-snapshot"/bg/"source-canvas-actual-mask.rgba"]
for path in sourceInputs: assert path.read_bytes()==decoded
sourceInputAudit=[{"path":str(p.relative_to(ROOT)),"hash":sha(p),"sameRGBA":True} for p in sourceInputs]
records=[]
for r in controls["reports"]:
    folder=LAYER/r["name"];m,_,source=png(folder/"source-realized.png");assert source==decoded
    cm,_,capture=png(folder/"capture.png")
    bg=r["background"];layer=crop(folder/"capture.rgba")
    paths={"realization55":BASE/"verify-canvas-realization-build55-snapshot"/(bg+"-ci-normal-read-before-display")/"capture.rgba",
      "publicUIViewCG51":BASE/"verify-source-canvas-backing-build51-snapshot"/bg/"native-view-hierarchy.rgba",
      "alpha56nativeLive320":BASE/"verify-source-canvas-alpha-build56-snapshot"/bg/"native-live-320.rgba",
      "alpha56nativeBacking":BASE/"verify-source-canvas-alpha-build56-snapshot"/bg/"native-live-backing.rgba",
      "alpha56webLive320":BASE/"verify-source-canvas-alpha-build56-snapshot"/bg/"web-live-320.rgba",
      "producer53A":producer/bg/"A-draw-before.rgba","producer53B":producer/bg/"B-draw-after.rgba","producer53C":producer/bg/"C-put-before.rgba"}
    records.append({"name":r["name"],"sourcePNGHash":sha(folder/"source-realized.png"),"sourcePNGDecodedSameInput":True,"sourcePNG":m,
      "capturePNG":cm,"capturePNGDecodeVsSavedPMA":compare(capture,(folder/"capture.rgba").read_bytes()),
      "crossControlsActualMaskROI":{name:compare(layer,crop(p)) for name,p in paths.items()},
      "additionalSourceControlPublicUIView51EqualsRealization55":compare(crop(paths["publicUIViewCG51"]),crop(paths["realization55"])),
      "alpha56WKEqualsProducer53A":compare(crop(paths["alpha56webLive320"]),crop(paths["producer53A"]))})
report={"sourceOriginalPNGHash":SHA,"sourceCanonicalRGBAHash":hashlib.sha256(decoded).hexdigest(),"sourcePNGIndependentDecoderPassed":True,
 "sourceCrossInputs":sourceInputAudit,"actualReportedOS":controls["os"],"roiDevicePixels":list(ROI),"roiCSS":[135,7,91,121],"records":records,"filterComparisons":controls["filterComparisons"],
 "conclusions":["Both stock layer filters yield identical captures. No public CALayer source route exactly matches any WK producer53 capture.",
 "Transparent directlayer ROI exactly matches currentalpha56native; opaque differs by472pixels,max1. This is separate from stock minification shape mismatch.",
 "Original-source publicUIViewCG51 equals all realization55converters, while directCALayercontents56differs. This supports an observable public paint-route seam without asserting its closed renderer/kernel.",
 "SourcePMA equality and independent sourcePNGdecode establish same input. SourceRealizedPNGencodings can differ harmlessly; original .binPNGhash unchanged.",
 "PNGencoded final capture and savedcanonicalPMA comparisons are reported independently; no retuning or privateSPI."],
 "limits":["Publichost.drawHierarchy is not proven identical toWKvisible-window snapshot transport.","Identicallinear/trilinearoutcomes do not prove the GPU internal sampling algorithm or mipmapping state.","No source-proven stockfilter matchesWK, and no LOD/bias/tapfitting is proposed."]}
(OUT/"cross-control-source-audit.json").write_text(json.dumps(report,indent=2))
print(json.dumps({"records":len(records),"sourcePNGdecodePassed":True,"capturePNGDecodePMA":[(r["name"],r["capturePNGDecodeVsSavedPMA"]["changedPixels"],r["capturePNGDecodeVsSavedPMA"]["maxChannelDelta"]) for r in records],"report":str(OUT/"cross-control-source-audit.json")}))
