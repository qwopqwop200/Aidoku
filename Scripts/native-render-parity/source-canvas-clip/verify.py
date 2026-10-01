from pathlib import Path
from pypdf import PdfReader
from pypdf.generic import ContentStream
from PIL import Image
import base64,io,json,hashlib
HERE=Path(__file__).resolve().parents[3];OUT=HERE/'build/native-render-parity/source-canvas-clip'
provenance=json.loads((OUT/'provenance.json').read_text())
assert hashlib.sha256((HERE/provenance['frozenPath']).read_bytes()).hexdigest()==provenance['frozenSHA256']
manifest=json.loads((OUT/'native-compile-manifest.json').read_text())
for path,digest in manifest['hashes'].items():
 assert hashlib.sha256((HERE/path).read_bytes()).hexdigest()==digest,(path,'compiled source changed')
web=json.loads((OUT/'web.json').read_text());native=json.loads((OUT/'native.json').read_text());by_color={tuple(c['color']):c['id'] for c in web};pdf=PdfReader(OUT/'web.pdf');page=pdf.pages[0];height=float(page.mediabox.height)
images=page['/Resources']['/XObject'];stack=[];clip=None;rect=None;actual={}
for operands,operator in ContentStream(page.get_contents(),pdf).operations:
 if operator==b'q':stack.append(clip)
 elif operator==b'Q':clip=stack.pop()
 elif operator==b're':rect=[float(n) for n in operands]
 elif operator==b'W':clip=rect
 elif operator==b'Do':
  image=images[operands[0]].get_object();color=tuple(image.get_data()[:3]);id=by_color[color]
  actual[id]=None if clip is None else [clip[0],height-clip[1]-clip[3],clip[2],clip[3]]
records=[];maximum=0
for w,n in zip(web,native):
 assert w['id']==n['id']
 image=Image.open(io.BytesIO(base64.b64decode(w['mask']['png'].split(',')[1]))).convert('RGBA')
 assert image.size==(20,20) and set(image.getdata())=={tuple(w['color']+[255])}
 assert set(w['mask'])=={'frame','opacity','png'},'Frozen export mask contract gained clip metadata'
 observed=actual.get(w['id']);expected=n['live'];empty=expected is not None and (expected[2]<=0 or expected[3]<=0)
 if empty:assert observed is None or observed[2]<=0 or observed[3]<=0
 elif expected is None:assert observed is None
 else:
  assert observed is not None
  error=max(abs(a-b) for a,b in zip(observed,expected));maximum=max(maximum,error)
  assert error<=0.0001,(w['id'],expected,observed,error)
 records.append(dict(id=w['id'],dom=w['used'],requested=w['requested'],nativeLive=expected,pdfLive=observed,maskUnclipped=True))
report=dict(passed=True,cases=len(records),deviceScale=web[0]['deviceScale'],maximumPDFSerializedCoordinateDifference=maximum,pdfNumericTolerance=0.0001,
 scope='Actual WK canvas clip-path PDF operators compared to native display-only helper. PDF serialization limits coordinate precision; no final raster or generic image draw-frame equality claimed. All raw PNG masks remain uniform unclipped20x20; frozen saved masks have only DOM frame/opacity/png. DeviceScale2 actual controls; other scales follow the same parameterized policy but are not independently browser-captured.',
 casesDetail=records,nativeCompileManifest=manifest,frozenOracle=provenance,sourceSHA256={str(p.relative_to(HERE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [HERE/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeSourceCanvasClip.swift',HERE/'Scripts/native-render-parity/source-canvas-clip/capture.swift',HERE/'Scripts/native-render-parity/source-canvas-clip/probe.swift',OUT/'web.json',OUT/'web.pdf',OUT/'native.json']})
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:report[k] for k in ['passed','cases','deviceScale','maximumPDFSerializedCoordinateDifference','pdfNumericTolerance']},indent=2))
