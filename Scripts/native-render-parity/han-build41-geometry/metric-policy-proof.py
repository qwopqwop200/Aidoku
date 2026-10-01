"""Literal pinned WebKit iOS normalization block vs staged Swift, no app edits."""
from pathlib import Path
import hashlib, json, subprocess
ROOT=Path(__file__).resolve().parents[3]
S=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/han-build41-geometry/metric-policy'
OUT.mkdir(parents=True,exist_ok=True)
source=ROOT/'build/native-render-parity/han-build41-geometry/primary-source/FontCoreText-pinned.cpp'
text=source.read_text()
block=text[text.index('    CGFloat adjustment = shouldUseAdjustment'):text.index('    m_shouldNotBeUsedForArabic')]
block=block.replace('shouldUseAdjustment(getCTFont())','adjusted').replace('CGFloat','double')
cpp='''#include <cmath>
#include <iomanip>
#include <iostream>
using std::ceil; using std::ceilf;
int main() { double ascent,descent,lineGap,right,pitch; bool adjusted;
 while(std::cin>>ascent>>descent>>lineGap>>adjusted>>right>>pitch) {
 const float kLineHeightAdjustment=.15f;
'''+block+'''
 float a=ascent,d=descent;
 int ia=std::max(int(lroundf(a)),0),id=lroundf(d),h=ia+id,ideo=h-h/2;
 float layoutA=floorf(float(ideo)+(floorf(float(pitch))-h)/2);
 float textRight=float(right)-layoutA+ideo;
 float cross=(textRight-ia)-((a+d)/2-a);
 std::cout<<std::setprecision(17)<<a<<" "<<d<<" "<<lineGap<<" "<<lineSpacing<<" "<<cross<<"\\n";
 } }
'''
(OUT/'Reference.cpp').write_text(cpp)
subprocess.run(['xcrun','clang++','-std=c++17','-O2',str(OUT/'Reference.cpp'),'-o',str(OUT/'reference')],check=True)
subprocess.run(['xcrun','swiftc','-O','-swift-version','6',str(S/'NativeVerticalGlyphOrigins.staged.swift'),str(S/'MetricPolicyProbe.swift'),'-o',str(OUT/'probe')],check=True)
rows=[]
for a,d,l in [(21.2,6.8,0),(9.45,2.1,0),(17.7,4.3,1.25),(15,4,0),(10.9999998,3.0000001,.2),(0,0,0)]:
 for family in ['PingFang SC','Hiragino Sans','Times','hELvEtIcA','.Helvetica NeueUI','Courier']:
  for pitch in [10.5,24,25]:
   rows.append(dict(ascent=a,descent=d,leading=l,family=family,right=74,pitch=pitch))
stdin=''.join(f'{r["ascent"]} {r["descent"]} {r["leading"]} {int(r["family"].lower() in ["times","helvetica",".helvetica neueui"])} {r["right"]} {r["pitch"]}\n' for r in rows)
ref=subprocess.run([str(OUT/'reference')],input=stdin,text=True,capture_output=True,check=True).stdout
actual=json.loads(subprocess.run([str(OUT/'probe')],input=json.dumps(rows),text=True,capture_output=True,check=True).stdout)
keys=['ascent','descent','leading','spacing','baseline']; failures=[]
for i,(line,row) in enumerate(zip(ref.splitlines(),actual)):
 expected=dict(zip(keys,map(float,line.split())))
 if expected!=row: failures.append(dict(index=i,input=rows[i],expected=expected,actual=row))
report=dict(cases=len(rows),exact=len(rows)-len(failures),failures=failures,sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),normalizationBlock=block,scope='iOS primary-metric policy C++ extraction vs Swift; no new iOS execution or font draw claim')
(OUT/'report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(dict(cases=len(rows),exact=report['exact'],failures=failures),indent=2))
assert not failures
