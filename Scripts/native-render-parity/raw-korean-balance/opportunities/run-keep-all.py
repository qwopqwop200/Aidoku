#!/usr/bin/env python3
"""Extract actual WebKit keep-all scanner + item builder stepping bodies."""
import json,pathlib,random,subprocess
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[3]
OUT=ROOT/'build/native-render-parity/raw-korean-balance/keep-all';OUT.mkdir(parents=True,exist_ok=True)
REF=HERE.parent/'reference'
def extract(path,marker):
 source=path.read_text();start=source.index(marker);brace=source.index('{',start);depth=1;end=brace+1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
space=extract(REF/'BreakLines.h','template<BreakLines::NoBreakSpaceBehavior nonBreakingSpaceBehavior>\ninline bool BreakLines::isBreakableSpace')
scan=extract(REF/'BreakLines.h','template<typename CharacterType, BreakLines::NoBreakSpaceBehavior nonBreakingSpaceBehavior>\ninline size_t BreakLines::nextBreakableSpace')
whitespace=extract(REF/'InlineItemsBuilder.cpp','template<typename CharacterType>\nstatic std::optional<WhitespaceContent> moveToNextNonWhitespacePosition')
step=extract(REF/'InlineItemsBuilder.cpp','static unsigned moveToNextBreakablePosition')
cpp=r'''
#include <span>
#include <optional>
#include <vector>
#include <iostream>
#include <cstdint>
using UChar=uint16_t;
constexpr UChar space=32,newlineCharacter=10,tabCharacter=9,noBreakSpace=160,zeroWidthSpace=0x200b,ideographicSpace=0x3000;
struct BreakLines {enum class NoBreakSpaceBehavior{Normal,Break};template<NoBreakSpaceBehavior>static bool isBreakableSpace(UChar);template<class C,NoBreakSpaceBehavior>static size_t nextBreakableSpace(std::span<const C>,size_t);};
struct View {const std::vector<UChar>&u;size_t length(){return u.size();}};
struct CachedLineBreakIteratorFactory{const std::vector<UChar>&u;View stringView(){return{u};}};
struct RenderStyle{};
struct WhitespaceContent{size_t length;bool isWordSeparator;};
'''+space+'\n'+scan+r'''
struct TextUtil {static size_t findNextBreakablePosition(CachedLineBreakIteratorFactory&f,size_t p,const RenderStyle&){return BreakLines::nextBreakableSpace<UChar,BreakLines::NoBreakSpaceBehavior::Normal>(f.u,p);}};
'''+whitespace+'\n'+step+r'''
int main(){size_t tests;std::cin>>tests;while(tests--){size_t n;std::cin>>n;std::vector<UChar>u(n);for(auto&v:u){unsigned x;std::cin>>x;v=x;}CachedLineBreakIteratorFactory factory{u};RenderStyle style;size_t p=0;bool first=true;
while(p<n){size_t start=p;int kind=0;
if(u[p]==newlineCharacter){++p;kind=2;}
else if(auto ws=moveToNextNonWhitespacePosition<UChar>(u,p,true,true,false)){p+=ws->length;kind=1;}
else p+=moveToNextBreakablePosition(p,factory,style);
if(!first)std::cout<<';';first=false;std::cout<<start<<','<<p-start<<','<<kind;
}std::cout<<'\n';}}
'''
(OUT/'oracle.cpp').write_text(cpp)
subprocess.run(['xcrun','clang++','-std=c++20','-O2',str(OUT/'oracle.cpp'),'-o',str(OUT/'oracle')],check=True)
fixtures=['','드디어 선생님이 왔다','가  나',' 가 ','가\t 나','가\n나다\n','\n\n','가\u200b나다\u3000라마','\u200b가','가\u200b\u200b나','\u3000가','가\u00a0나\u202f다\u2060라','A/B—C-D 안녕･세계','👩‍👧 🇰🇷와 공녀','가\u00ad나다']
r=random.Random(260102)
alphabet=['가','나','ᄀ','ᅡ','世','界','A','/','-','。','(',')',' ','\t','\n','\u200b','\u3000','\u00a0','\u202f','\u2060','\u00ad','👩‍👧','🇰🇷']
fixtures += [''.join(r.choice(alphabet) for _ in range(r.randrange(0,90))) for _ in range(1200)]
(OUT/'fixtures.json').write_text(json.dumps(fixtures,ensure_ascii=False))
units=[list(int.from_bytes(b[i:i+2],'little') for i in range(0,len(b),2)) for b in [s.encode('utf-16-le') for s in fixtures]]
data='\n'.join([str(len(units))]+[' '.join(map(str,[len(u),*u])) for u in units])+'\n'
expected=subprocess.check_output([str(OUT/'oracle')],input=data.encode()).decode().splitlines()
main=r'''
import Foundation
let texts=try JSONDecoder().decode([String].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
let results=texts.map { text -> [String:Any] in
 let a=NativeKeepAllBreakOpportunities.analyze(text:text)
 return ["items":a.items.map{[$0.range.location,$0.range.length,$0.kind.rawValue]},
         "paragraphs":a.paragraphs.map{["range":[$0.range.location,$0.range.length],"ends":$0.softOffsets]},
         "tab":a.hasPreservedTab,"softHyphen":a.hasSoftHyphen]
}
print(String(data:try JSONSerialization.data(withJSONObject:results),encoding:.utf8)!)
'''
(OUT/'main.swift').write_text(main)
subprocess.run(['xcrun','swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeKeepAllBreakOpportunities.swift'),str(OUT/'main.swift'),'-o',str(OUT/'native')],check=True)
actual=json.loads(subprocess.check_output([str(OUT/'native'),str(OUT/'fixtures.json')]))
errors=[]
for i,(line,a) in enumerate(zip(expected,actual)):
 items=[list(map(int,entry.split(','))) for entry in line.split(';')] if line else []
 start=0;ends=[];paragraphs=[]
 for off,length,kind in items:
  if kind==2:
   paragraphs.append(dict(range=[start,off-start],ends=ends));start=off+length;ends=[]
  else:ends.append(off+length-start)
 paragraphs.append(dict(range=[start,len(units[i])-start],ends=ends))
 e=dict(items=items,paragraphs=paragraphs,tab=9 in units[i],softHyphen=173 in units[i])
 if a!=e:errors.append(dict(index=i,text=fixtures[i],expected=e,actual=a))
report=dict(cases=len(fixtures),exact=len(fixtures)-len(errors),errors=errors,scope='Exact primary extracted BreakLines keep-all scanner and InlineItemsBuilder whitespace/zero-length-step bodies, for one pre-wrap same-bidi raw text node, normal NBSP. No Unicode normal or pixel parity claim.',sourceCommit='dd5fe1011df7e3438ac4889356abcab7681df46d')
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='errors'}));assert not errors,errors[:3]
