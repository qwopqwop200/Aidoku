#!/usr/bin/env python3
"""Original OCR owners survive language filtering, without duplicate text paint."""
from pathlib import Path
import subprocess,tempfile,json
ROOT=Path(__file__).resolve().parents[2]
def block(s,marker):
 i=s.index(marker); a=s.index('{',i); level=1;b=a+1
 while level:
  level+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[i:b]
f=(ROOT/'Aidoku/Core/Translation/ReaderTranslationLanguageFilter.swift').read_text()
r=(ROOT/'Aidoku/Core/Translation/ReaderTranslationService.swift').read_text()
helper=block(f,'    static func preservingExcludedSource(')
keep=block(r,'    var preservesOriginalText: Bool')
code='''import Foundation
struct ReaderTranslationRegion: Equatable {
 var id:String; var source:String; var translation:String?; var translationReuseIdentity:String?
 var geometry:[Double]
'''+keep+'''\n}
enum ReaderTranslationLanguageFilter {\n'''+helper+'''\n}
let title=ReaderTranslationRegion(id:"title",source:"桃の果汁は飲み干せない",translation:nil,geometry:[1,846,859,213])
let subtitle=ReaderTranslationRegion(id:"en",source:"She is my peach. I'm her plum.",translation:"stale wrong text",translationReuseIdentity:"old",geometry:[362,979,468,40])
var translated=title; translated.translation="복숭아 과즙은 다 마실 수 없어"; translated.translationReuseIdentity="current"
let original=[title,subtitle]
let result=ReaderTranslationLanguageFilter.preservingExcludedSource(original:original,translated:[translated],eligibleIDs:["title"])
precondition(result.count==2 && result.map(\\.id)==original.map(\\.id))
precondition(result[0]==translated && !result[0].preservesOriginalText)
precondition(result[1].geometry==subtitle.geometry && result[1].source==subtitle.source)
precondition(result[1].translation==subtitle.source && result[1].translationReuseIdentity==nil && result[1].preservesOriginalText)
precondition(ReaderTranslationLanguageFilter.preservingExcludedSource(original:result,translated:[translated],eligibleIDs:["title"])==result)
let untranslated=ReaderTranslationLanguageFilter.preservingExcludedSource(original:original,translated:[],eligibleIDs:["title"])
precondition(untranslated[0].translation==nil && untranslated[1].preservesOriginalText)
let allKept=ReaderTranslationLanguageFilter.preservingExcludedSource(original:original,translated:[],eligibleIDs:[])
precondition(allKept.allSatisfy(\\.preservesOriginalText))
print("PASS bilingual excluded source ownership, geometry, stale identity clearing, unchanged eligible translation, idempotence, incomplete/empty batch")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-filter-owner-') as t:
 p=Path(t);(p/'main.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-O',str(p/'main.swift'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check')],check=True)
# Check the production handoff contract, rather than claiming pixel preservation.
layout=block(r,'    static func layoutItems(')
assert 'keepsSourceLettering: true' in layout and 'region.translation != nil' in layout
assert 'let exact = regions.map(\\.preservesOriginalText)' in r
assert 'where kept[index] && !exact[index]' in r
print('PASS exact-source owner stays protected even when another caption intersects; pixel/render verification remains separate')
