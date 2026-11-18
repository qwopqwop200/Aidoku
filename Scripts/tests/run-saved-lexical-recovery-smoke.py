"""Actual native word recovery with a retained face, size and unrelated owner."""
from pathlib import Path
import hashlib,json,os,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[2]; BINARY=ROOT/'build/source-cluster-text-render/render'
def read(p):return json.loads(p.read_bytes())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
start=time.monotonic()
with tempfile.TemporaryDirectory(prefix='aidoku-retained-lexical-') as temp:
 t=Path(temp);b=t/'baseline';o=t/'updated'
 for name in ['layers','audits','owner-rasters']:(b/name).mkdir(parents=True)
 items=[]
 for oid,text,frame in [('broken','모두에게 보여버려서!',[140,40,80,260]),('unrelated','그대로',[350,60,120,150])]:
  x,y,w,h=frame
  items.append(dict(id=oid,text=text,frame=frame,fontReference=22,fill=[0,0,0],outlineWidth=1.5,outline=[255,255,255],sourceFontWeight='regular',renderBold=False,textAlignment='center',textPlacementGuide=dict(rectNormalized=[x/500,y/400,w/500,h/400],horizontal='center',vertical='center'),textExpansionPolicy=dict(allowedRectNormalized=[x/500,y/400,w/500,h/400],candidates=[[x/500,y/400,w/500,h/400]],maskCoverage=[1],backgroundRisk=[0],sourceFontPixels=22,kind='source-near-limited-expansion',sourceLineWidthScale=8)))
 request=dict(pages=[dict(page='0001',width=500,height=400,items=items,layer=str(b/'layers/0001.png'),audit=str(b/'audits/0001.json'))]);path=b/'REQUEST.json';path.write_text(json.dumps(request))
 env=dict(os.environ,AIDOKU_RENDER_OWNER_ALPHA_ROOT=str(b/'owner-rasters'),AIDOKU_BODY_FONT_COHORTS='0',AIDOKU_SOURCE_AWARE_DISPLAY_GUARD='1',AIDOKU_INITIAL_WORD_OBJECTIVE='0')
 subprocess.run([str(BINARY),str(path)],env=env,check=True)
 before={a['id']:a for a in read(b/'audits/0001.json')['items']}; old={a['id']:a for a in read(b/'owner-rasters/30303031/RECEIPT.json')['owners']}
 assert before['broken']['softWordCuts']>0,before['broken']['actualCoreTextLineStrings']
 # Same content and font; additional free width becomes available. No GT lookup.
 items[0]['textExpansionPolicy']['allowedRectNormalized']=[0,0,.6,1]
 path.write_text(json.dumps(request));subprocess.run([str(BINARY),'--refine-saved-readability',str(b),str(o)],check=True)
 after={a['id']:a for a in read(o/'audits/0001.json')['items']}; new={a['id']:a for a in read(o/'owner-rasters/30303031/RECEIPT.json')['owners']}
 assert after['broken']['softWordCuts']<before['broken']['softWordCuts'],read(o/'SAVED-TYPOGRAPHY-REPLAY.json')
 assert after['broken']['actualCoreTextLineStrings']!=before['broken']['actualCoreTextLineStrings']
 for oid in before:
  assert before[oid]['fontPixels']==after[oid]['fontPixels']
  assert before[oid]['renderFontName']==after[oid]['renderFontName']
  assert before[oid]['textSHA256']==after[oid]['textSHA256']
  assert before[oid]['utf16Expected']==after[oid]['utf16Visible']
 assert before['unrelated']==after['unrelated']
 assert old['unrelated']['frame']==new['unrelated']['frame']
 assert sha(Path(old['unrelated']['path']))==sha(Path(new['unrelated']['path']))
 print('cuts',before['broken']['softWordCuts'],'->',after['broken']['softWordCuts'])
print('PASS native lexical recovery; retained font, full text and unrelated PNG bytes preserved')
print('wallSeconds',round(time.monotonic()-start,3))
