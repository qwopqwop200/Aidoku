#!/usr/bin/env python3
"""Diagnostic primary WebKit fast paths around public neutral CF boundaries.

No app helper: CF is substituted for the original ICU mechanical iterator.
That substitution remains a hypothesis, even when bounded captured wraps match.
"""
import json,pathlib,subprocess
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[3]
OUT=ROOT/'build/native-render-parity/raw-korean-balance/normal-primary';OUT.mkdir(parents=True,exist_ok=True)
REF=HERE.parent/'reference'
def block(text,marker):
 start=text.index(marker);p=text.index('{',start)+1;depth=1
 while depth:depth+=(text[p]=='{')-(text[p]=='}');p+=1
 return text[start:p]
h=(REF/'BreakLines.h').read_text();builder=(REF/'InlineItemsBuilder.cpp').read_text();data=(REF/'BreakLines.cpp').read_text()
cls=block(h,'class BreakLines')+';'
cls=cls.replace('private:','public:')
cpp=r'''
#include <span>
#include <optional>
#include <vector>
#include <iostream>
#include <cstdint>
#include <algorithm>
#include <array>
#define WEBCORE_EXPORT
using UChar=uint16_t;using LChar=uint8_t;
constexpr UChar space=32,newlineCharacter=10,tabCharacter=9,noBreakSpace=160,zeroWidthSpace=0x200b,ideographicSpace=0x3000;
bool isASCIIDigit(UChar c){return c>='0'&&c<='9';}bool isASCIIAlpha(UChar c){return(c>='A'&&c<='Z')||(c>='a'&&c<='z');}bool isASCIIAlphanumeric(UChar c){return isASCIIAlpha(c)||isASCIIDigit(c);}
struct Prior{size_t length(){return 0;}UChar secondToLastCharacter(){return 0;}UChar lastCharacter(){return 0;}};
struct Iterator{const std::vector<size_t>&ends;std::optional<size_t>following(size_t p){auto i=std::upper_bound(ends.begin(),ends.end(),p);return i==ends.end()?std::nullopt:std::make_optional(*i);}};
struct View{const std::vector<UChar>&u;size_t length(){return u.size();}};
struct CachedLineBreakIteratorFactory{const std::vector<UChar>&u;Iterator iterator;Prior priorContext(){return{};}Iterator&get(){return iterator;}View stringView(){return{u};}};
'''+cls+'\n'
cpp+=block(h,'template<BreakLines::NoBreakSpaceBehavior nonBreakingSpaceBehavior>\ninline bool BreakLines::isBreakableSpace')+'\n'
cpp+=block(h,'template<BreakLines::LineBreakRules rules, BreakLines::NoBreakSpaceBehavior nonBreakingSpaceBehavior>\ninline BreakLines::BreakClass BreakLines::classify')+'\n'
cpp+=block(h,'template<typename CharacterType, BreakLines::LineBreakRules shortcutRules, BreakLines::WordBreakBehavior words, BreakLines::NoBreakSpaceBehavior nonBreakingSpaceBehavior>\ninline size_t BreakLines::nextBreakablePosition')+'\n'
cpp+=data[data.index('#define B'):data.index('#undef B')]+ '\n#undef B\n'
cpp+=r'''
struct RenderStyle{};struct WhitespaceContent{size_t length;bool isWordSeparator;};
struct TextUtil{static size_t findNextBreakablePosition(CachedLineBreakIteratorFactory&f,size_t p,const RenderStyle&){return BreakLines::nextBreakablePosition<UChar,BreakLines::LineBreakRules::Normal,BreakLines::WordBreakBehavior::Normal,BreakLines::NoBreakSpaceBehavior::Normal>(f,f.u,p);}};
'''
cpp+=block(builder,'template<typename CharacterType>\nstatic std::optional<WhitespaceContent> moveToNextNonWhitespacePosition')+'\n'
cpp+=block(builder,'static unsigned moveToNextBreakablePosition')+'\n'
cpp+=r'''
int main(){size_t tests;std::cin>>tests;while(tests--){size_t n,b;std::cin>>n;std::vector<UChar>u(n);for(auto&v:u){unsigned x;std::cin>>x;v=x;}std::cin>>b;std::vector<size_t>ends(b);for(auto&v:ends)std::cin>>v;CachedLineBreakIteratorFactory f{u,{ends}};RenderStyle style;size_t p=0;bool first=true;
while(p<n){if(u[p]==10)++p;else if(auto ws=moveToNextNonWhitespacePosition<UChar>(u,p,true,true,false))p+=ws->length;else p+=moveToNextBreakablePosition(p,f,style);if(!first)std::cout<<',';first=false;std::cout<<p;}std::cout<<'\n';}}
'''
(OUT/'probe.cpp').write_text(cpp)
subprocess.run(['xcrun','clang++','-std=c++20','-O2',str(OUT/'probe.cpp'),'-o',str(OUT/'probe')],check=True)
a=json.loads((ROOT/'build/native-render-parity/raw-korean-balance/opportunities/capture.json').read_text())
fixtures=[x for x in a['WKWebView'] if x['wordBreak']=='normal' and x['overflowWrap']=='normal'];inputs=[str(len(fixtures))]
for f in fixtures:
 raw=f['text'].encode('utf-16-le');units=[int.from_bytes(raw[i:i+2],'little') for i in range(0,len(raw),2)]
 cf=next(c for c in a['CFStringTokenizer'] if c['text']==f['text'] and c['locale']=='und')['ends'];f['CFends']=cf
 inputs.append(' '.join(map(str,[len(units),*units,len(cf),*cf])))
lines=subprocess.check_output([str(OUT/'probe')],input=('\n'.join(inputs)+'\n').encode()).decode().splitlines()
checks=[]
for f,line in zip(fixtures,lines):
 predicted=[int(x) for x in line.split(',')] if line else []
 checks.append(dict(text=f['text'],CFends=f['CFends'],primaryFastPathsWithCFBackend=predicted,observed=f['observedEnds'],observedNotPredicted=sorted(set(f['observedEnds'])-set(predicted)),predictedNotObserved=sorted(set(predicted)-set(f['observedEnds']))))
report=dict(cases=len(checks),observedContainment=sum(not x['observedNotPredicted'] for x in checks),checks=checks,scope='Diagnostic: actual extracted primary classifier/Latin1 table/fast-forward/builder with public CF neutral token ends substituted for ICU mechanical following. Same-bidi one raw node. Observed-end containment is not full legality proof; before-whitespace boundaries may be legal but not observed in bounded sweep.',sourceCommit='dd5fe1011df7e3438ac4889356abcab7681df46d')
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps({k:report[k] for k in ['cases','observedContainment']}))
