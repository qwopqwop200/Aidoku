#!/usr/bin/env python3
"""Extract primary WebKit balance DP and compare supplied opportunities/widths.

This isolates balance policy from Unicode opportunity discovery and platform
font widths; it does not establish native CoreText versus WebKit pixel parity.
"""
import json,math,pathlib,random,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[3]
HERE=pathlib.Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/raw-korean-balance';OUT.mkdir(parents=True,exist_ok=True)
source=(HERE/'reference/InlineContentConstrainer-dd5fe1011df7e3438ac4889356abcab7681df46d.cpp').read_text()
def function(marker):
 s=source.index(marker);start=source.index('{',s);depth=1;p=start+1
 while depth:
  depth+=(source[p]=='{')-(source[p]=='}');p+=1
 return source[s:p]
cpp=r'''
#include <algorithm>
#include <cmath>
#include <iomanip>
#include <iostream>
#include <limits>
#include <optional>
#include <vector>
#include <cassert>
#define ASSERT assert
using InlineLayoutUnit=float;using LayoutUnit=float;
constexpr float textWrapPrettyStretchability=15,textWrapPrettyShrinkability=15;
template<class T>struct Vector:std::vector<T>{using std::vector<T>::vector;void append(T v){this->push_back(v);}void insert(size_t i,T v){std::vector<T>::insert(this->begin()+i,v);}void reverse(){std::reverse(this->begin(),this->end());}};
namespace WTF{bool areEssentiallyEqual(float a,float b){if(a==b)return true;float d=abs(a-b);return d/abs(a)<=std::numeric_limits<float>::epsilon()&&d/abs(b)<=std::numeric_limits<float>::epsilon();}}
struct InlineItemRange{size_t n;size_t startIndex(){return 0;}size_t endIndex(){return n;}};
enum class PreviousLineState{NoPreviousLine,EndsWithLineBreak,DoesNotEndWithLineBreak};
struct EntryBalance{float accumulatedCost=std::numeric_limits<float>::infinity();size_t previousBreakIndex=0;};
struct InlineContentConstrainer;
struct SlidingWidth{InlineContentConstrainer& c;size_t s,e;SlidingWidth(InlineContentConstrainer&c,Vector<int>&,size_t s,size_t e,bool,bool):c(c),s(s),e(e){}void advanceEndTo(size_t i){e=i;}void advanceStartTo(size_t i){s=i;}float width();};
struct InlineContentConstrainer{
 Vector<int>m_inlineItemList;Vector<Vector<float>>widths;Vector<size_t>breaks;float m_maximumLineWidthConstraint;
 float computeTextIndent(PreviousLineState){return 0;}
 Vector<size_t>computeBreakOpportunities(InlineItemRange r){Vector<size_t>x;for(size_t i=1;i<=r.n;i++)x.append(i);return x;}
 Vector<float>computeLineWidthsFromBreaks(InlineItemRange,const Vector<size_t>&x,bool){breaks=x;Vector<float>v;size_t p=0;for(auto e:x){v.append(ceil((widths[p][e]+1.f/64)*64)/64);p=e;}return v;}
 std::optional<Vector<float>>balanceRangeWithLineRequirement(InlineItemRange,float,size_t,bool);
 std::optional<Vector<float>>balanceRangeWithNoLineRequirement(InlineItemRange,float,bool);
};
float SlidingWidth::width(){return c.widths[s][e];}
float computeLineWidthFromSlidingWidth(float indent,SlidingWidth w){return ceil((indent+w.width()+1.f/64)*64)/64;}
'''
cpp+=function('static float computeRaggedness')+'\n'+function('static float computeCostBalance')+'\n'
cpp+=function('std::optional<Vector<LayoutUnit>> InlineContentConstrainer::balanceRangeWithLineRequirement')+'\n'
cpp+=function('std::optional<Vector<LayoutUnit>> InlineContentConstrainer::balanceRangeWithNoLineRequirement')+'\n'
cpp+=r'''
int main(){size_t tests;std::cin>>tests;while(tests--){size_t n,rows;float maximum,total=0;std::cin>>n>>rows>>maximum;for(size_t i=0;i<rows;i++){float w;std::cin>>w;total+=w;}
 InlineContentConstrainer c;c.m_inlineItemList=Vector<int>(n);c.m_maximumLineWidthConstraint=maximum;c.widths=Vector<Vector<float>>(n+1,Vector<float>(n+1));for(size_t s=0;s<=n;s++)for(size_t e=0;e<=n;e++)std::cin>>c.widths[s][e];
 auto result=rows<=12?c.balanceRangeWithLineRequirement({n},total/rows,rows,true):c.balanceRangeWithNoLineRequirement({n},total/rows,true);
 if(!result){std::cout<<"null\n";continue;}for(size_t i=0;i<c.breaks.size();i++){if(i)std::cout<<",";std::cout<<c.breaks[i];}std::cout<<";";for(size_t i=0;i<result->size();i++){if(i)std::cout<<",";std::cout<<std::setprecision(12)<<(*result)[i];}std::cout<<"\n";
 }}
'''
(OUT/'oracle.cpp').write_text(cpp)
subprocess.run(['xcrun','clang++','-std=c++20','-O2',str(OUT/'oracle.cpp'),'-o',str(OUT/'oracle')],check=True)
r=random.Random(260101);fixtures=[]
for i in range(240):
 n=r.randint(4,65);advance=[r.uniform(.1,19) for _ in range(n)];maximum=r.uniform(18,100)
 matrix=[[sum(advance[s:e]) if s<e else 0 for e in range(n+1)] for s in range(n+1)]
 q=lambda w:math.ceil((w+1/64)*64)/64
 original=[];start=0
 while start<n:
  end=start+1
  while end<n and q(matrix[start][end+1])<=maximum:end+=1
  original.append(q(matrix[start][end]));start=end
 if len(original)<2:continue
 fixtures.append(dict(name=f'generated-{i}',maximum=maximum,original=original,widths=matrix))
# Include a true symmetric tie and a no-solution long item.
fixtures += [dict(name='equal-tie',maximum=11,original=[10.015625]*2,widths=[[max(0,e-s)*5 for e in range(5)]for s in range(5)]),dict(name='no-solution',maximum=4,original=[6.015625]*2,widths=[[max(0,e-s)*6 for e in range(3)]for s in range(3)])]
(OUT/'fixtures.json').write_text(json.dumps(fixtures))
lines=[str(len(fixtures))]
for f in fixtures:
 lines.append(' '.join(map(str,[len(f['widths'])-1,len(f['original']),f['maximum'],*f['original'],*[x for row in f['widths'] for x in row]])))
oracle=subprocess.check_output([str(OUT/'oracle')],input=('\n'.join(lines)+'\n').encode()).decode().splitlines()
main=r'''
import Foundation
let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
var output:[[String:Any]]=[]
for f in fixtures {
 let m=f["widths"] as! [[Double]],n=m.count-1
 let result=NativeRawTextBalance.solve(originalLineWidths:(f["original"] as! [Double]).map { CGFloat($0) },maximumWidth:CGFloat(f["maximum"] as! Double),breakOffsets:Array(1...n),width:{range in
  let raw=Float(m[range.location][NSMaxRange(range)])
  return CGFloat(ceil((raw+1/64)*64)/64)
 })
 output.append(["name":f["name"]!,"breaks":result?.breakOffsets as Any? ?? NSNull(),"widths":result?.lineWidths as Any? ?? NSNull()])
}
print(String(data:try JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
'''
(OUT/'main.swift').write_text(main)
subprocess.run(['xcrun','swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeRawTextBalance.swift'),str(OUT/'main.swift'),'-o',str(OUT/'native')],check=True)
native=json.loads(subprocess.check_output([str(OUT/'native'),str(OUT/'fixtures.json')]))
errors=[]
for f,c,n in zip(fixtures,oracle,native):
 if c=='null':ok=n['breaks'] is None
 else:
  a,b=c.split(';');breaks=list(map(int,a.split(',')));widths=list(map(float,b.split(',')));ok=n['breaks']==breaks and n['widths']==widths
 if not ok:errors.append(dict(name=f['name'],cpp=c,native=n))
report=dict(cases=len(fixtures),exact=len(fixtures)-len(errors),errors=errors,scope='Actual extracted primary WebKit DP with supplied legal opportunities/float sliding widths. Excludes Unicode break discovery, native font metrics, full renderer and final image parity.',source='https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/layout/formattingContexts/inline/InlineContentConstrainer.cpp',longParagraphs=sum(len(f['original'])>12 for f in fixtures))
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report));assert not errors
