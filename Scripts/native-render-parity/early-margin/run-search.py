import hashlib,json,subprocess,sys,re
from pathlib import Path
R=Path(__file__).resolve().parents[3];H=Path(__file__).resolve().parent;O=R/'build/native-render-parity/early-balloon-search';O.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(H.parent/'forced-source-policy'));from run import difference
s=(R/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyPostPolish.swift').read_text()
methods=[]
for name in ['quarterFloor','restoredFontFloor','balloonFontSizes','emergencyBalloonFontSizes']:
 pattern=r'    (?:private )?static func '+name+r'\([^\n]*?(?:\{[^\n]*?\}|\{[\s\S]*?\n    })'
 m=re.search(pattern,s);assert m,name;methods.append(m.group())
fonts=O/'Fonts.swift';fonts.write_text('import Foundation\nimport CoreGraphics\nenum NativeBalloonFontsHost {\n'+'\n'.join(methods)+'\n}')
subprocess.run(['xcrun','swiftc','-O','-swift-version','6',str(fonts),str(R/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeEarlyBalloonSearch.swift'),str(H/'SearchProbe.swift'),'-o',str(O/'probe')],check=True)
subprocess.run(['python3',str(H/'search-fixtures.py'),str(O/'fixtures.json')],check=True);subprocess.run(['node',str(H/'capture-search.cjs'),str(R),str(O/'expected.json'),str(O/'fixtures.json')],check=True);subprocess.run([str(O/'probe'),str(O/'fixtures.json'),str(O/'actual.json')],check=True)
e=json.loads((O/'expected.json').read_text());a=json.loads((O/'actual.json').read_text());bad=[]
for old,new in zip(e,a):
 if old['frames'] is not None:old['frames'].sort(key=lambda x:x[0])
 d=difference(old,new)
 if d:bad.append(dict(id=old['id'],mismatch=d))
r=dict(passed=not bad,fixtures=len(a),exact=len(a)-len(bad),positive=sum(x['accepted'] for x in a),mismatches=bad,scope='Unchanged frozen font-size/fitAt/normal+offset search policy with supplied independent layout/profile callbacks. Compares every layout attempt, exact chosen font/rank repair/emergency and center-frame replay cache; no CoreText/DOM glyph equivalence claim. Clear grid113exact separately, actual clear search movement callback proof pending.')
(O/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps(r,indent=2));raise SystemExit(bool(bad))
