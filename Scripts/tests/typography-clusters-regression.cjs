const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const test = require('node:test');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname,
  '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayTypography.swift'), 'utf8');
const script = source.split('static let script = #"""')[1].split('"""#')[0];
const colorSource = fs.readFileSync(path.join(__dirname,
  '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourceTextColor.swift'), 'utf8');
const contrastScript = colorSource.slice(colorSource.indexOf('    const aidokuSourceColorLuminance ='),
  colorSource.indexOf('    // Outline-free display keeps chromatic source ink.'));
const api = vm.runInNewContext(script + contrastScript + ';({restoredFloor:aidokuRestoredFontFloor,captionFloor:aidokuCaptionFontFloor,attached:aidokuHasAttachedLeadingInk,balloonFonts:aidokuBalloonFontSizes,erasure:aidokuRestoredErasureCovers,residual:aidokuHasResidualLettering,artworkFonts:aidokuArtworkFontSizes,compact:aidokuCompactPanel,visible:aidokuVisiblePanelColors,adjust:aidokuAdjustInkForContrast,fonts:aidokuFontClusters,inks:aidokuInkClusters,lines:aidokuKoreanLines,fragments:aidokuKoreanFragments,improves:aidokuKoreanWrapImproves,frame:aidokuCaptionInkFrame,candidates:aidokuCohortFontCandidates,flowFits:aidokuFontFlowFits,anchor:aidokuSourceAnchorShift,backing:aidokuTextBackingRect,needsBacking:aidokuNeedsTextBacking,keepsContrast:aidokuTextBackingKeepsContrast,contrast:aidokuSourceColorContrast,flowRank:aidokuKoreanFlowRank,wordWidth:aidokuKoreanWordWidth,rows:aidokuAlignedGroups,columnRows:aidokuColumnRowLinks,pageStyles:aidokuPageStyleGroups,styleColor:aidokuStyleColorClass,reduplication:aidokuReduplicationBreak,interfaceRows:aidokuInterfaceRows,clusterTargets:aidokuFontClusterTargets,keptZones:aidokuKeptLetteringZones,subtract:aidokuSubtractRects,condensedWidth:aidokuCondensedWidth,condensedSizes:aidokuCondensedSizes,wordBound:aidokuCondensedWordBound})');
const plain = x => JSON.parse(JSON.stringify(x));
test('only a later panel with a different color needs a lettering backing', () => {
  const panels=[{rect:[0,0,50,50],color:'white'},{rect:[0,25,25,50],color:'purple'}];
  assert(api.needsBacking([10,20,30,20],0,panels));
  assert(!api.needsBacking([10,50,10,10],1,panels));
  assert(!api.needsBacking([30,10,10,10],0,panels));
  assert(!api.needsBacking([10,20,30,20],0,[panels[0],{...panels[1],color:'white'}]));
});
test('a local backing resolves cyclic panel overlap without repainting neighboring lettering', () => {
  // The white paragraph and the purple response have overlapping cards; moving
  // either whole card on top would repaint part of the other caption's backing.
  const white=[163.234375,21.953125,83.28125,51.296875];
  const purple=[147.5,51.125,40.296875,56.28125];
  const a=[165,26.90625,51.34375,38],b=[162.8577576,69.265625,20.4719849,20];
  assert(api.needsBacking(a,0,[{rect:white,color:'white'},{rect:purple,color:'purple'}]));
  const patch=plain(api.backing(a,white,[b]));
  assert(patch);assert(patch[1]+patch[3]<b[1]);assert(patch[0]>=white[0]);
  const reverse=plain(api.backing(b,purple,[a]));
  assert(reverse);assert(reverse[1]>a[1]+a[3]);
});
test('backing padding yields to adjacent text and never escapes its original panel', () => {
  assert.deepEqual(plain(api.backing([10,10,20,20],[0,0,50,50],[[31,10,8,8]])),[9,9,22,22]);
  assert.equal(api.backing([10,10,20,20],[12,0,50,50],[]),null);
  assert.equal(api.backing([10,10,20,20],[0,0,50,50],[[15,15,5,5]]),null);
});
test('panel ownership cannot replace a better contrasting visible background', () => {
  const panels=[{rect:[0,0,50,50],color:'yellow'},{rect:[0,25,25,50],color:'white'}];
  const contrast=color=>({yellow:1.05,white:1.14})[color];
  assert(!api.keepsContrast([10,20,30,20],0,panels,contrast));
  assert(api.keepsContrast([30,10,10,10],0,panels,contrast));
  assert(!api.keepsContrast([10,20,30,20],0,panels,()=>NaN));
});
test('the real yellow caption cannot lose the existing white-panel contrast', () => {
  const panels=[{rect:[80,70,50,100],color:'yellow'},{rect:[0,140,430,20],color:'white'}];
  const foreground=[248,247,39],backgrounds={yellow:[253,254,6],white:[255,255,255]};
  const contrast=color=>api.contrast(foreground,true,1,backgrounds[color]);
  assert(contrast('white')>contrast('yellow'));
  assert(!api.keepsContrast([85.9478,81.6094,35.7525,66],0,panels,contrast));
});
test('readable white-on-black and black-on-white backings keep their distinct colors', () => {
  const panels=[{rect:[0,0,50,50],color:'white'},{rect:[0,25,25,50],color:'purple'}];
  assert(api.keepsContrast([10,20,30,20],0,panels,color=>({white:21,purple:4.3})[color]));
  assert(!api.keepsContrast([10,20,30,20],0,panels,color=>({white:1,purple:4.9})[color]));
});
test('the real subscriber caption returns to its source without changing its ink extent', () => {
  const ink=[202.296875,235.96875,31.140625,51];
  const source=[223.64859,233.6626676,36.1114,57.3535639];
  const plate=[199.109375,230.65625,63.640625,63.34375];
  const heading=[200.88912,187.8405081,131.39725,47.9463656];
  const shift=api.anchor(ink,source,plate,[heading]);
  assert(shift);assert(Math.abs(shift.dx-23.8371025)<1/64);
  assert(Math.abs(shift.dy-.87069955)<1/64);
});
test('anchoring respects the frozen plate margin when a paragraph is wider than its source', () => {
  const shift=api.anchor([10,20,40,20],[50,20,10,20],[7,17,60,26],[]);
  assert.deepEqual(plain(shift),{dx:14,dy:0});
  assert.equal(api.anchor([10,20,40,20],[50,20,10,20],[7,17,46,26],[]),null);
});
test('a free destination cannot jump across another source or visible caption', () => {
  assert.equal(api.anchor([10,20,10,20],[60,20,10,20],[7,17,66,26],[[35,20,10,20]]),null);
});
test('anchoring can restore one axis when a diagonal move would hit a neighbor', () => {
  const shift=api.anchor([10,10,10,10],[30,30,10,10],[7,7,36,36],[[10,25,10,10]]);
  assert.deepEqual(plain(shift),{dx:20,dy:0});
});
test('existing overlap cannot grow and adjacent lettering does not get pulled into collision', () => {
  assert.equal(api.anchor([10,20,20,20],[25,20,20,20],[7,17,41,26],[[25,20,15,20]]),null);
  assert.equal(api.anchor([10,20,20,20],[25,20,20,20],[7,17,41,26],[[35,20,15,20]]),null);
});
test('lettering centred over another source may leave it only when the caller allows it', () => {
  const ink=[10,20,20,20],source=[60,20,20,20],plate=[7,17,80,26],covered=[[0,15,40,30]];
  assert.equal(api.anchor(ink,source,plate,covered),null);
  assert.deepEqual(plain(api.anchor(ink,source,plate,covered,true)),{dx:50,dy:0});
  // Leaving one source never allows a jump across another free caption.
  assert.equal(api.anchor(ink,source,plate,[...covered,[45,20,5,20]],true),null);
});
test('already anchored text and uncertain or clipped geometry stay unchanged', () => {
  assert.equal(api.anchor([10,20,20,20],[11,21,20,20],[7,17,30,30],[]),null);
  assert.equal(api.anchor([10,20,20,20],[50,20,20,20],[10,20,80,40],[]),null);
  assert.equal(api.anchor([10,20,20,20],[50,20,20,20],[7,17,80,40],[[NaN,0,1,1]]),null);
});
const font = (id, source, size) => ({id,source,font:size,script:'korean',vertical:false,column:true});
test('nearby sizes agree but source emphasis and small asides stay separate', () => {
  const entries=[font('a',8,8.5),font('b',8.3,8.75),font('c',8.1,8.25),
    font('heading',16,12),font('whisper',4,6)];
  const result=plain(api.fonts(entries));
  assert.equal(result.length,1);assert.equal(result[0].font,8.5);
  assert.deepEqual(result[0].members.map(e=>e.id).sort(),['a','b','c']);
  assert.deepEqual(plain(api.fonts(entries.reverse())),result);
});
test('size clusters do not chain from ordinary text into a heading', () => {
  const result=plain(api.fonts([font('a',8,8),font('b',9,9),font('c',10,10)]));
  assert.equal(result[0].members.length,2);
});
test('different fitting results still belong to the same observed source style', () => {
  const groups=plain(api.fonts([font('tight',9.5,5.5),font('normal',9.6,8.5),font('roomy',9.7,10.5)]));
  assert.equal(groups.length,1);assert.equal(groups[0].members.length,3);
  assert.equal(groups[0].font,8.75);
});
test('nearby observed inks share a medoid without blending speaker colors', () => {
  const entries=[[164,70,139],[168,73,142],[166,71,141],[238,93,5],[10,10,10],[248,248,248]]
    .map((rgb,id)=>({id,rgb,confidence:.9}));
  const groups=plain(api.inks(entries));
  assert.equal(groups.length,1);assert.equal(groups[0].members.length,3);
  assert(entries.some(e=>e.rgb.join()==groups[0].rgb.join()));
  assert.deepEqual(plain(api.inks(entries.reverse())),groups);
});
test('uncertain ink, different hues and lightness remain distinct', () => {
  assert.equal(api.inks([{id:1,rgb:[160,60,130],confidence:.3},
    {id:2,rgb:[165,65,135],confidence:.9}]).length,0);
  assert.equal(api.inks([[140,90,110],[140,110,90],[200,140,170]].map((rgb,id)=>({id,rgb,confidence:1}))).length,0);
  assert.equal(api.inks(Array.from({length:257},(_,id)=>({id,rgb:[0,0,0],confidence:1}))).length,0);
});
const measure = text => [...text].reduce((n,c)=>n+(/\s/u.test(c)?0.4:/[.!?,…]/u.test(c)?0.4:1),0);
test('long Korean words avoid stranded one-syllable fragments at the same size', () => {
  const text='그러니까 사과할 필요 없다니까!';
  const lines=plain(api.lines(text,3.1,8,measure));
  assert.equal(lines.join(''),text);
  assert(lines.every(line=>measure(line.trim())<=3.2));
  assert(!lines.some(line=>/^[가-힣][!?.]?$/u.test(line.trim())));
});
test('whole words and closing punctuation are preserved when room permits', () => {
  const text='오늘 다시 만나서 반가워.';
  const lines=plain(api.lines(text,5,6,measure));
  assert.equal(lines.join(''),text);
  assert(lines.every(line=>!/^\s*[.!?,…]/u.test(line)));
  for(const word of text.split(' '))assert(lines.some(line=>line.includes(word)));
});
test('an orphan remains an orphan when the next word shares its line', () => {
  assert.equal(api.fragments('사과하는 거야', [3]),1);
  assert.equal(api.fragments('사과하는 거야', [2]),0);
  assert.equal(api.fragments('왜 그런 거야', [2,5]),0);
  const text='정말! 왜 당신이 사과하는 거야! 사과해야 할 건 나라고!';
  const lines=plain(api.lines(text,3.6,12,measure));
  let offset=0;const cuts=lines.slice(0,-1).map(line=>offset+=line.length);
  assert.equal(api.fragments(text,cuts),0);
  assert.equal(lines.join(''),text);
});
test('explicit line breaks and impossible fits retain the normal renderer', () => {
  assert.equal(api.lines('첫째\n둘째',4,5,measure),null);
  assert.equal(api.lines('읽을 수 없는 작은 공간',1,1,measure),null);
  assert.equal(api.lines('가'.repeat(181),4,50,measure),null);
});

test('a compact suffix remains available when the preferred suffix exhausts the line budget', () => {
  // Real expanded-comic-1700 dialogue. The previous one-state suffix search
  // rejected this four-line fit because a cheaper suffix consumed five lines.
  const text='아니 본제는 이제부터라서네';
  const lines=plain(api.lines(text,3.5,4,measure));
  assert(lines);assert(lines.length<=4);assert.equal(lines.join(''),text);
  assert(lines.every(line=>measure(line.trim())<=3.6));
});

test('each smaller line budget is evaluated independently without losing the original text', () => {
  const text='동양의 라스베가스 마카오의 카지노에 룰렛은 실재했다!!';
  for(const budget of [9,10,11,12]){
    const lines=plain(api.lines(text,3,budget,measure));
    assert(lines);assert(lines.length<=budget);assert.equal(lines.join(''),text);
    assert(lines.every(line=>measure(line.trim())<=3.1));
  }
});

test('surplus suffix line budgets preserve wrapping, spaces, and supplementary characters', () => {
  for(const text of ['오늘 다시 만나서 반가워.', '  🙂 그대의 말풍선  ', '가나다라마바사아자차카타파하']){
    const lines=plain(api.lines(text,5,Array.from(text).length,measure));
    assert(lines);assert.equal(lines.join(''),text);
    assert(lines.every(line=>measure(line.trim())<=5.1));
    assert.deepEqual(plain(api.lines(text,5,lines.length,measure)),lines);
  }
});

test('repairing one orphan must not split otherwise intact neighboring words', () => {
  const old={lines:6,breaks:[12],hangulFragments:1,punctuationOnly:0,badStarts:[],badEnds:[]};
  assert(!api.improves({...old,breaks:[10,18,22],hangulFragments:0},old));
  assert(api.improves({...old,breaks:[10],hangulFragments:0},old));
  assert(!api.improves({...old,lines:7,hangulFragments:0},old));
  assert(!api.improves(old,old));
});

test('the original ink envelope retains the larger font padding after harmonization', () => {
  const before=plain(api.frame([[10,20,14,21],[25,20,14,21]],17.25));
  assert.deepEqual(before,{left:10,top:20,right:39,bottom:41,pad:5.175});
  const after=plain(api.frame([[14,23,10,16],[25,23,10,16]],13));
  assert(after.left>before.left&&after.right<before.right&&after.pad<before.pad);
  assert.equal(api.frame([],13),null);
});

test('a tight caption can reach an intermediate cohort size below the first five probes', () => {
  const candidates=plain(api.candidates(5.5,10.5,5));
  // A measured box fitting only 6.75pt used to retain 5.5pt: all five old
  // candidates were at least 7.5pt. The smaller valid recovery must survive.
  assert.equal(candidates.find(size=>size<=6.75),6.75);
  assert(candidates.length<=13&&candidates.every(size=>size>5.5&&size<=8.5));
  assert.equal(api.candidates(12,8,5)[0],9);
  assert.deepEqual(plain(api.candidates(8.5,8.5,5)),[]);
  assert.deepEqual(plain(api.candidates(NaN,8.5,5)),[]);
});

test('rebalanced cuts can share a font while additional splits and orphans stay bounded', () => {
  const original={breaks:[7,15],badStarts:[],badEnds:[],hangulFragments:0,punctuationOnly:0};
  assert(api.flowFits({...original,breaks:[8,17]},original));
  assert(!api.flowFits({...original,breaks:[8,17,24]},original));
  assert(!api.flowFits({...original,hangulFragments:1},original,2));
  assert(!api.flowFits({...original,badStarts:[0]},original,2));
  assert(api.flowFits({...original,breaks:[8,17,24,30]},original,2));
  assert(!api.flowFits({...original,breaks:[8,17,24,30,35]},original,2));
});

test('a real leading ellipsis does not disable Korean line planning', () => {
  for(const text of ['...혹시 모두 즐겁지 않은 거였나...', '…그래. 불쾌하게 해서 미안하다.']){
    const lines=plain(api.lines(text,5.5,6,measure));
    assert(lines);assert.equal(lines.join(''),text);
    assert(/[가-힣]/u.test(lines[0]));
    assert(lines.slice(1).every(line=>!/^\s*[.!?,…]/u.test(line)));
    assert(lines.every(line=>measure(line.trim())<=5.6));
  }
  assert.equal(api.lines('...',1,3,measure),null);
});

test('font recovery preserves the orphan-free wrapping already available at the old size', () => {
  // round3-comic-3924: growing 7.25 to 8.25pt stranded "는" in "그러는".
  // The old-size word-aware layout could already keep that word intact.
  const raw={lines:8,breaks:[6,19],badStarts:[],badEnds:[],hangulFragments:1,punctuationOnly:0};
  const reflow={...raw,lines:7,breaks:[6],hangulFragments:0};
  const bigger={...raw,breaks:[6,19]};
  assert(api.improves(reflow,raw));
  assert(api.flowFits(bigger,raw,2));
  assert(!api.flowFits(bigger,reflow,2));
});


test('compact cards discard obsolete translated footprints while covering original source and ruby', () => {
  const old=[163.234375,21.953125,83.28125,51.296875],ink=[166.234375,28.59375,51.34375,38];
  const source=[166.24101,24.9553725,32.25,45.30351],ruby=[160,25,2,10];
  const compact=plain(api.compact(old,ink,[source,ruby],[]));
  assert(compact.frame[2]<58);assert(compact.frame[3]>51);
  assert(compact.coverage.some(r=>r[0]<=source[0]&&r[1]<=source[1]&&r[0]+r[2]>=source[0]+source[2]&&r[1]+r[3]>=source[1]+source[3]));
  assert(compact.coverage.every(r=>r[0]>=old[0]&&r[1]>=old[1]&&r[0]+r[2]<=old[0]+old[2]&&r[1]+r[3]<=old[1]+old[3]));
});
test('a separate source column and its caption share one rectangular plate', () => {
  const result=plain(api.compact([0,0,60,100],[30,40,20,20],[[3,3,5,94]],[]));
  const covers=(x,y)=>result.coverage.some(r=>x>=r[0]&&y>=r[1]&&x<=r[0]+r[2]&&y<=r[1]+r[3]);
  assert.equal(result.coverage.length,1);assert.deepEqual(result.coverage[0],result.frame);
  assert(covers(5,5));assert(covers(40,50));assert(covers(45,10));
});
test('restored source needs only final ink but neighboring lettering retains its existing background', () => {
  assert.deepEqual(plain(api.compact([0,0,100,100],[10,20,20,30],[],[])).frame,[7,17,26,36]);
  const result=plain(api.compact([0,0,100,100],[10,20,20,30],[],[[80,10,30,10]]));
  assert.equal(result.frame[0]+result.frame[2],100);
  assert(result.coverage.some(r=>r[0]<=80&&r[0]+r[2]===100&&r[1]<=10));
  assert.equal(api.compact([0,0,10,10],[20,20,5,5],[],[]),null);
  assert.equal(api.compact([0,0,10,10],[2,2,5,5],[null],[]),null);
});
test('foreground uses only visible surfaces including clipped corners and final local backings', () => {
  const white=[255,255,255],purple=[141,97,153],yellow=[253,254,6];
  const layers=[{coverage:[[0,0,50,50]],color:white},{coverage:[[0,0,10,50],[10,20,20,10]],color:purple}];
  assert.deepEqual(plain(api.visible([20,0,10,10],layers,yellow)),[white]);
  assert.deepEqual(plain(api.visible([0,0,20,10],layers,yellow)),[purple,white]);
  assert.deepEqual(plain(api.visible([0,0,20,10],[...layers,{coverage:[[0,0,20,10]],color:yellow}],white)),[yellow]);
});
test('low-contrast yellow and white ink become readable without changing their background', () => {
  // Coloured ink takes the smallest correction and keeps its hue.
  for(const [ink,bg] of [[[248,247,39],[253,254,6]]]){
    const saved=[...bg],contrast=rgb=>api.contrast(rgb,true,1,bg),adjusted=plain(api.adjust(ink,contrast));
    assert(contrast(adjusted)>=4.5);assert.deepEqual(bg,saved);
    assert.notDeepEqual(adjusted,[0,0,0]);assert.notDeepEqual(adjusted,[255,255,255]);
  }
  // Neutral ink on the wrong side of its surface would pass through the
  // surface tone: it takes the opposite extreme instead of a washed mid-gray.
  for(const [ink,bg,extreme] of [[[255,255,255],[232,232,232],[0,0,0]],[[21,3,26],[141,97,153],[255,255,255]],
      [[27,25,22],[88,38,30],[255,255,255]]]){
    const saved=[...bg],contrast=rgb=>api.contrast(rgb,true,1,bg),adjusted=plain(api.adjust(ink,contrast));
    assert(contrast(adjusted)>=4.5);assert.deepEqual(bg,saved);assert.deepEqual(adjusted,extreme);
  }
  // Large coloured type may stop at 3:1.
  const pink=[249,137,155],pale=[223,254,188],contrast=rgb=>api.contrast(rgb,true,1,pale);
  const large=plain(api.adjust(pink,contrast,3)),small=plain(api.adjust(pink,contrast));
  assert(contrast(large)>=3&&contrast(large)<contrast(small));assert(large[0]>large[2]);
});
test('readable source colors and different speaker hues remain distinct', () => {
  const magenta=[164,70,139],orange=[154,57,0],bg=[255,255,255];
  for(const ink of [magenta,orange,[255,255,255]]){
    const background=ink[0]===255?[20,20,20]:bg;
    assert.deepEqual(plain(api.adjust(ink,rgb=>api.contrast(rgb,true,1,background))),ink);
  }
});


test('slanted source effects retain a full source-glyph fringe across their writing direction', () => {
  const panel=[226.140625,73.9375,47.109375,72.1875],ink=[229.2233124,100.03125,40.943985,20];
  const source=[229.14485,76.9460237,13.57897,66.1964063],pad=3,font=9.993843;
  const fringe=font-pad;
  const guarded=[source[0]-fringe,source[1],source[2]+fringe*2,source[3]];
  const result=plain(api.compact(panel,ink,[guarded],[],pad));
  for(const [x,y] of [[249,91],[249,136]])assert(result.coverage.some(r=>x>=r[0]&&y>=r[1]&&x<=r[0]+r[2]&&y<=r[1]+r[3]));
  assert.deepEqual(result.coverage,[result.frame]);
});


test('sub-point edge erosion does not reveal a sliver of neighboring source lettering', () => {
  const panel=[331.71875,236.890625,62.046875,79];
  const result=plain(api.compact(panel,[335.383667,258.390625,54.717041,36],[[332.197522,257.790074,33.590846,38.209961]],[]));
  assert(result.coverage.some(r=>393.65>=r[0]&&393.65<=r[0]+r[2]&&275>=r[1]&&275<=r[1]+r[3]));
});
test('neighbor source erasure can outlive its displaced translation', () => {
  const result=plain(api.compact([0,0,100,100],[10,40,30,20],[],[[80,5,8,90]]));
  for(const [x,y] of [[84,10],[84,90]])assert(result.coverage.some(r=>x>=r[0]&&x<=r[0]+r[2]&&y>=r[1]&&y<=r[1]+r[3]));
  assert.deepEqual(result.coverage,[result.frame]);
});


test('artwork fitting spends a bounded share of type size while preserving tiny captions', () => {
  for (const font of [5, 6, 6.5]) assert.deepEqual(plain(api.artworkFonts(font)), []);
  for (const font of [6.6, 7.5, 8.5, 9, 10.5, 12, 31.75]) {
    const sizes=plain(api.artworkFonts(font));
    assert(sizes.every(size=>size>=Math.max(6.5,font*.65)&&size<font));
    assert(sizes.every((size,i)=>i===0||size<sizes[i-1]));
  }
  assert.deepEqual(plain(api.artworkFonts(NaN)), []);
});

test('a surviving ruby vetoes panel removal while a continuous balloon contour does not', () => {
  const w=120,h=160,safe=new Uint8Array(w*h).fill(1);
  for(let y=0;y<h;y++)safe[y*w+15]=0;
  assert.equal(api.residual(safe,w,h,[[35,20,30,115]],16),false);
  for(let y=45;y<53;y++)for(let x=70;x<76;x++)safe[y*w+x]=0;
  assert.equal(api.residual(safe,w,h,[[35,20,30,115]],16),true);
});
test('residual lettering inspection preserves uncertainty and ignores distant ink', () => {
  const safe=new Uint8Array(120*160).fill(1);safe[110]=0;safe[111]=0;
  assert.equal(api.residual(safe,120,160,[[35,30,25,100]],12),false);
  assert.equal(api.residual(null,120,160,[[35,30,25,100]],12),true);
});


test('certified erasure releases source-only plate area without changing translated ink or neighbors', () => {
  const w=100,h=140,safe=new Uint8Array(w*h).fill(1),footprint=[20,10,60,120];
  // A tall source has been erased, but a short translated caption still needs
  // backing. Preserve a neighboring source strip independently of this proof.
  assert(api.erasure(safe,w,h,[footprint],12,[[25,15,50,110]]));
  const panel=[0,0,w,h],ink=[25,55,50,25],neighbor=[5,5,8,110];
  const old=plain(api.compact(panel,ink,[footprint],[neighbor]));
  const next=plain(api.compact(panel,ink,[],[neighbor]));
  const covers=(p,x,y)=>p.coverage.some(r=>x>=r[0]&&x<=r[0]+r[2]&&y>=r[1]&&y<=r[1]+r[3]);
  assert(covers(old,50,15));assert(next.frame[3]<=old.frame[3]);
  for(const point of [[25,55],[75,80],[8,10],[8,110]])assert(covers(next,...point));
  assert.deepEqual(next.coverage,[next.frame]);
});
test('erasure certificate rejects clipped source fringes and ruby outside the main source', () => {
  const w=100,h=140,safe=new Uint8Array(w*h).fill(1);
  assert(!api.erasure(safe,w,h,[[-.01,10,40,100]],12,[[20,15,30,90]]));
  assert(!api.erasure(safe,w,h,[[60,10,40.01,100]],12,[[20,15,30,90]]));
  assert(!api.erasure(safe,w,h,[[20,110,40,30.01]],12,[[20,15,30,90]]));
  assert(!api.erasure(safe,w,h,[[20,10,40,100],[95,40,10,10]],12,[[20,15,30,90]]));
  for(let y=30;y<37;y++)for(let x=66;x<71;x++)safe[y*w+x]=0;
  assert(!api.erasure(safe,w,h,[[20,10,60,100]],12,[[20,15,30,90]]));
});
test('a preserved continuous contour is compatible with erasure but missing masks are not', () => {
  const w=100,h=140,safe=new Uint8Array(w*h).fill(1);
  for(let y=0;y<h;y++)safe[y*w+65]=0;
  assert(api.erasure(safe,w,h,[[20,10,60,100]],12,[[20,15,30,90]]));
  for(const invalid of [null,new Uint8Array(10)])assert(!api.erasure(invalid,w,h,[[20,10,60,100]],12,[[20,15,30,90]]));
  assert(!api.erasure(safe,w,h,[],12,[[20,15,30,90]]));
  assert(!api.erasure(safe,w,h,[[20,10,0,100]],12,[[20,15,30,90]]));
  assert(!api.erasure(new Uint8Array(513*513),513,513,[[20,10,60,100]],12,[[20,15,30,90]]));
});

test('bold source ink attached to a long rule cannot masquerade as a clean core', () => {
  const w=100,h=140,safe=new Uint8Array(w*h).fill(1),core=[20,10,40,100];
  for(let y=0;y<h;y++)safe[y*w+59]=0;
  for(let y=20;y<35;y++)for(let x=48;x<60;x++)safe[y*w+x]=0;
  assert(!api.residual(safe,w,h,[core],12));
  assert(!api.erasure(safe,w,h,[[10,5,60,110]],12,[core]));
});

test('real bold heading keeps its erasure plate when the final D survives reconstruction', () => {
  const zlib=require('node:zlib');
  const f=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/panel-erasure-connected-ink.json')));
  const source=fs.readFileSync(path.join(__dirname,
    '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift'),'utf8')
    .match(/static let script = """\n([\s\S]*?)\n    """/)[1];
  const restore=new Function(source+';return aidokuRestoreSourcePanel;')();
  const pixels=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64')));
  const out=restore(pixels,f.w,f.h,f.b,f.palette,{readabilityGate:true,vertical:false});
  assert(out);assert(out.erased>0);assert.equal(out.preservedPixels,0);assert.equal(out.preservedCore,0);
  assert(!api.residual(out.layoutSafe,f.w,f.h,f.regions,f.glyph));
  assert(!api.erasure(out.layoutSafe,f.w,f.h,f.regions,f.glyph,[f.b]));
});

test('verified balloon fits cover their full 65 percent interval without shrinking tiny type', () => {
  for(const font of [6.5,7.5,8.25,8.75,9.5,12,30]){
    const sizes=plain(api.balloonFonts(font));assert.equal(sizes[0],font);
    assert(sizes.every(v=>v>=Math.max(6.5,font*.65)&&v<=font));
    assert(sizes.every((v,i)=>i===0||v<sizes[i-1]));assert(sizes.length<=9);
  }
  for(const value of [0,-1,NaN,Infinity])assert.deepEqual(plain(api.balloonFonts(value)),[]);
  for(const font of [5,5.75,6.49])assert.deepEqual(plain(api.balloonFonts(font)),[font],
    'small captions may rewrap at their existing size, never shrink further');
});
test('narrow balloon reflow can add a word break without creating isolated Korean fragments', () => {
  const base={breaks:[4],badStarts:[],badEnds:[],hangulFragments:0,punctuationOnly:0};
  assert(api.flowFits({...base,breaks:[3,5]},base,1));
  assert(!api.flowFits({...base,breaks:[3,5],hangulFragments:1},base,1));
  assert(!api.flowFits({...base,punctuationOnly:1},base,1));
  assert(!api.flowFits({...base,breaks:[2,3,5]},base,1));
});


test('clipped leading lettering attached to artwork keeps its erasure coverage', () => {
  const f=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-erasure-leading-fringe.json')));
  const safe=new Uint8Array(require('node:zlib').inflateSync(Buffer.from(f.safe,'base64')));
  assert.equal(require('node:crypto').createHash('sha256').update(safe).digest('hex'),f.sha256);
  assert(api.attached(safe,f.w,f.h,f.core,f.glyph));
});

test('smooth leading contours do not restore oversized panels', () => {
  const w=100,h=120,core=[[20,20,30,80]],glyph=14;
  for(const edge of [y=>65,y=>60+y*.08,y=>58+(y-60)**2*.0015,y=>66+Math.sin(y/30)*5]){
    const safe=new Uint8Array(w*h).fill(1);
    for(let y=0;y<h;y++)for(let x=Math.ceil(edge(y));x<w;x++)safe[y*w+x]=0;
    assert(!api.attached(safe,w,h,core,glyph));
  }
});


test('two equally styled captions use both central sizes rather than only the roomy card', () => {
  const groups=plain(api.fonts([font('tight',18,12.75),font('roomy',18.5,21.5)]));
  assert.equal(groups[0].font,17.25);
  assert.equal(groups[0].members.length,2);
  assert.deepEqual(plain(api.fonts(groups[0].members.slice().reverse())),groups);
  assert.equal(api.fonts([font('valid',10,9),font('invalid',10,Infinity)]).length,0);
});

test('failed shrink targets retain closer measured candidates within the existing probe limit', () => {
  const sizes=plain(api.candidates(12.75,11.25,5));
  assert.equal(sizes[0],11.25);
  assert.equal(sizes.find(size=>size>=12),12);
  assert(sizes.every((size,i)=>size>=12.75*.75&&size<12.75&&(i===0||size>sizes[i-1])));
  assert(api.candidates(100,5,5).length<=13);
});


test('final caption fitting preserves small type and the user readability floor', () => {
  for(const font of [5,6.5,7.5,8.5])assert.equal(api.captionFloor(font,5),font);
  assert.equal(api.captionFloor(10,5),8.5);
  assert.equal(api.captionFloor(20,5),16);
  assert.equal(api.captionFloor(10,9.5),9.5);
  assert.equal(api.captionFloor(NaN,5),null);
  assert.equal(api.captionFloor(10,0),null);
});


test('cohort harmonization cannot make already small captions less readable', () => {
  for(const size of [5,6.5,7.25,7.5])assert.deepEqual(plain(api.candidates(size,5,5)),[]);
  assert.equal(api.candidates(8,6.5,5)[0],7.5);
});


test('large balloon lettering reaches the permitted floor within nine probes', () => {
  for(const font of [10.25,14,30,101.3]){
    const sizes=plain(api.balloonFonts(font,5));
    assert.equal(sizes[0],font);
    assert.equal(sizes.at(-1),Math.ceil(api.restoredFloor(font,5)*4)/4);
    assert(sizes.length<=9);
    assert(sizes.every((v,i)=>i===0||v<sizes[i-1]));
  }
  assert(plain(api.balloonFonts(10,8)).every(v=>v>=8));
  assert.deepEqual(plain(api.balloonFonts(5,6)),[]);
  assert.deepEqual(plain(api.artworkFonts(7,7.5)),[]);
  assert.deepEqual(plain(api.balloonFonts(10,NaN)),[]);
});


test('restoration can shrink more only when recovering the original artwork surface', () => {
  assert.equal(api.captionFloor(10.5,5),8.5);
  // Legibility floor: 8pt or 75% of the original, never above the original.
  assert.equal(api.restoredFloor(10.5,5),8);
  for(const font of [5,5.75,6.5,7.75])assert.equal(api.restoredFloor(font,5),font);
  assert.equal(api.restoredFloor(20,5),15);
  assert.equal(api.restoredFloor(10,9.5),9.5);
  assert.equal(api.restoredFloor(NaN,5),null);
  assert.equal(api.restoredFloor(10,0),null);
  assert(plain(api.balloonFonts(10.5,5)).some(size=>size<api.captionFloor(10.5,5)));
});
test('growth width repair ranks stranded syllables above split words and holds the longest word', () => {
  const profile=(breaks,fragments=0,punctuation=0)=>({breaks:Array(breaks).fill(0),hangulFragments:fragments,
    punctuationOnly:punctuation,badStarts:[],badEnds:[]});
  assert.equal(api.flowRank(profile(0)),0);
  assert(api.flowRank(profile(2))<api.flowRank(profile(0,1)));
  assert(api.flowRank(profile(1))<api.flowRank(profile(1,0,1)));
  // Ten pixels per character, -0.012em tracking between characters, 1 px slack.
  const width=api.wordWidth('케이크도 먹어버리자',10,part=>Array.from(part).length*10);
  assert.equal(Math.round(width*1000)/1000,50-4*.12+1);
  assert.equal(api.wordWidth('',10,part=>part.length),0);
});


test('side-by-side vertical source columns link on their shared top, centre or bottom line', () => {
  const col=(x,y,w,h,glyph,extra={})=>({x,y,w,h,glyph,script:'korean',vertical:true,...extra});
  // Two balloons of one row (comic-7964): top-aligned columns, gap under three glyphs.
  const top=plain(api.columnRows([col(100,50,40,120,12),col(170,50,30,80,12.5)]));
  assert.equal(top.length,1);assert.equal(top[0].edge,0);assert.equal(top[0].axis,'y');assert.equal(top[0].gap,30);
  // Same-height columns tie: the top line wins (a vertical column starts at its top).
  assert.equal(api.columnRows([col(0,0,20,100,10),col(30,0,20,100,10)])[0].edge,0);
  // Centred and bottom-aligned columns keep that line.
  assert.equal(api.columnRows([col(0,20,20,60,10),col(30,0,20,100,10)])[0].edge,.5);
  assert.equal(api.columnRows([col(0,40,20,60,10),col(30,0,20,100,10)])[0].edge,1);
  // Unaligned lines, distant columns, other sizes, scripts, styles or horizontal sources never link.
  assert.equal(api.columnRows([col(0,15,20,60,10),col(30,0,20,100,10)]).length,0);
  assert.equal(api.columnRows([col(0,0,20,100,10),col(60,0,20,100,10)]).length,0);
  assert.equal(api.columnRows([col(0,0,20,100,10),col(30,0,20,100,13)]).length,0);
  assert.equal(api.columnRows([col(0,0,20,100,10),col(30,0,20,100,10,{script:'latin'})]).length,0);
  assert.equal(api.columnRows([col(0,0,20,100,10),col(30,0,20,100,10,{style:'5,5,3'})]).length,0);
  assert.equal(api.columnRows([col(0,0,20,100,10),col(30,0,20,100,10,{vertical:false})]).length,0);
  // A column stacked below another is not a row; a fragment inside a column is not a neighbour.
  assert.equal(api.columnRows([col(0,0,20,100,10),col(0,110,20,100,10)]).length,0);
  assert.equal(api.columnRows([col(0,0,20,100,10),col(2,0,16,100,10)]).length,0);
  assert.deepEqual(plain(api.columnRows([null,col(0,0,20,100,10),col(30,0,NaN,100,10)])),[]);
  assert.deepEqual(plain(api.columnRows([])),[]);
});

test('same-row and same-column captions form one style group with their shared axis', () => {
  const box=(x,y,w,h,glyph,extra={})=>({x,y,w,h,glyph,script:'korean',vertical:false,...extra});
  // UI button row: one line, similar glyphs, small gaps.
  const row=plain(api.rows([box(10,100,30,10,8),box(45,100,20,10,8.5),box(70,101,25,9,8),box(10,300,60,10,8)]));
  assert.equal(row.length,1);
  assert.deepEqual(row[0].members,[0,1,2]);
  assert(row[0].links.every(l=>l.axis==='y'));
  // Left-aligned caption stack (diverse2-1314): one column, start edge.
  const stack=plain(api.rows([box(50,40,200,40,17),box(50,95,160,80,17.5),box(50,190,210,40,17)]));
  assert.equal(stack.length,1);
  assert(stack[0].links.some(l=>l.axis==='x'&&l.edge===0));
  // A split OCR fragment inside its sentence box shares only the size.
  const nested=plain(api.rows([box(0,0,100,20,18),box(60,8,20,12,17)]));
  assert.equal(nested.length,1);assert.equal(nested[0].links[0].edge,null);
  // Different lettering styles, orientations or distant rows never join.
  assert.equal(api.rows([box(0,0,40,10,8),box(45,0,40,14,12)]).length,0);
  assert.equal(api.rows([box(0,0,40,10,8),box(45,0,40,10,8,{vertical:true})]).length,0);
  assert.equal(api.rows([box(0,0,40,10,8),box(45,0,40,10,8,{script:'latin'})]).length,0);
  assert.equal(api.rows([box(0,0,40,10,8),box(45,0,40,10,8,{style:'5,5,3'})]).length,0);
  assert.equal(api.rows([box(0,0,40,10,8),box(200,0,40,10,8)]).length,0);
  assert.equal(api.rows([box(0,0,40,10,8),box(0,60,40,10,8)]).length,0);
  // Chains cannot bridge a 1.3x spread in glyph size.
  const chain=plain(api.rows([box(0,0,20,10,8),box(25,0,20,10,9.6),box(50,0,20,10,11.5)]));
  assert(chain.every(g=>Math.max(...g.members.map(i=>[8,9.6,11.5][i]))/Math.min(...g.members.map(i=>[8,9.6,11.5][i]))<=1.3));
  assert.deepEqual(plain(api.rows([])),[]);
  assert.deepEqual(plain(api.rows([box(0,0,NaN,10,8),box(45,0,20,10,8)])),[]);
});


test('page style groups share one target size per source lettering style', () => {
  const r=(glyph,font,key='v|dark||light|')=>({glyph,font,key});
  // Four same-style balloons: the target is the typical size of the members
  // that fit well (lower median of the larger half), not the small ones.
  const four=plain(api.pageStyles([r(12,8.25),r(12.4,7.5),r(12.6,10.5),r(12.2,12)]));
  assert.equal(four.length,1);
  assert.deepEqual(four[0].members.slice().sort(),[0,1,2,3]);
  assert.equal(four[0].font,10.5);
  // Two members: the larger one sets the size.
  assert.equal(plain(api.pageStyles([r(20,11),r(21,16)]))[0].font,16);
  // One roomy outlier among small members never sets the target.
  assert.equal(plain(api.pageStyles([r(10,7),r(10,7.5),r(10,14)]))[0].font,7.5);
  // Different style keys (fill, outline or ground colour) never join.
  assert.equal(api.pageStyles([r(12,8),r(12,12,'v|light|outline|dark|')]).length,0);
  assert.equal(api.pageStyles([r(12,8),r(12,12,'h|dark||light|')]).length,0);
  // Complete-link: no chain bridges more than the glyph tolerance.
  const chain=plain(api.pageStyles([r(10,8),r(11.2,9),r(12.6,10)]));
  const glyphs=[10,11.2,12.6];
  assert(chain.every(g=>Math.max(...g.members.map(i=>glyphs[i]))/Math.min(...g.members.map(i=>glyphs[i]))<=1.15));
  assert(plain(api.pageStyles([r(10,8),r(12,9)],1.25)).length===1);
  assert.deepEqual(plain(api.pageStyles([])),[]);
  assert.deepEqual(plain(api.pageStyles([r(NaN,8),r(12,9)])),[]);
  assert.equal(api.styleColor([3,3,3]),'dark');
  assert.equal(api.styleColor([250,250,250]),'light');
  assert.equal(api.styleColor([128,128,128]),'mid');
  assert.equal(api.styleColor([220,40,40]),'h0');
  assert.equal(api.styleColor([]),'?');
});

test('breaks between repeats of a short unit are not split words', () => {
  const at=(text,left)=>api.reduplication(text,left.length);
  assert.equal(at('아아아아','아아'),true);
  assert.equal(at('으아아아악','으아아'),true);
  assert.equal(at('두근두근','두근'),true);
  assert.equal(at('하하하하','하하'),true);
  assert.equal(at('으아아아악!!','으아아'),true);
  // Inside a sentence (or next to other letters) the run stays one word.
  assert.equal(at('야아아아아아아! 뭔가 아픈 게','야아아아아'),false);
  assert.equal(at('아아아아 A','아아'),false);
  // Real word splits and stranded syllables still count.
  assert.equal(at('아아아아','아'),false);
  assert.equal(at('하하하하','하하하'),false);
  assert.equal(at('포테이토칩이','포테이'),false);
  assert.equal(at('다다음','다'),false);
  assert.equal(at('두근두근','두근두'),false);
  assert.equal(at('AAAA','AA'),false);
  assert.equal(api.reduplication('',0),false);
});

test('interface rows are short one-line labels on one line at the page edge', () => {
  const frame=[0,0,400,225];
  const label=(x,text,y=214,glyph=7)=>({x,y,w:Math.max(12,text.length*8),h:9,glyph,text,vertical:false});
  const menu=['뒤로','기록','스킵','자동','저장'].map((t,i)=>label(100+i*40,t));
  assert.deepEqual(plain(api.interfaceRows(menu,frame)),[[0,1,2,3,4]]);
  // Two labels are not a row; a mid-page row is ordinary lettering.
  assert.deepEqual(plain(api.interfaceRows(menu.slice(0,2),frame)),[]);
  assert.deepEqual(plain(api.interfaceRows(menu.map(b=>({...b,y:110})),frame)),[]);
  // Sentences (terminal punctuation) and vertical captions never join.
  assert.deepEqual(plain(api.interfaceRows([label(100,'그래.'),label(140,'뭐?'),label(180,'응!')],frame)),[]);
  assert.deepEqual(plain(api.interfaceRows(menu.map(b=>({...b,vertical:true})),frame)),[]);
  // One widely spaced merged line of short labels is a row; a dense dialogue line is not.
  const merged={x:100,y:214,w:190,h:9,glyph:8,text:'뒤로 역사 스킵 자동 저장 옵션',vertical:false};
  assert.deepEqual(plain(api.interfaceRows([merged],frame)),[[0]]);
  assert.deepEqual(plain(api.interfaceRows([{...merged,w:90,text:'자 그럼 이제 가 볼까 우리'}],frame)),[]);
  // Distant labels with very different glyphs are separate.
  assert.deepEqual(plain(api.interfaceRows([...menu.slice(0,2),label(300,'설정',214,12)],frame)),[]);
  assert.deepEqual(plain(api.interfaceRows(menu,[0,0,0,0])),[]);
});

test('kept lettering keeps the page clusters of the remaining captions (diverse2-2011, diverse2-2307)', () => {
  // CUP NOODLE labels kept as printed: without them the dialogue re-clusters
  // with the smaller third balloon and drops 9.75 -> 8.75.
  const e=(id,source,font)=>({id,source,font,script:'korean',vertical:false,column:false});
  const dialogue=[e('10',11.708869,11.75),e('11',9.780160,7.75),e('12',9.616151,8.75)];
  const byId=m=>Object.fromEntries([...m].map(([k,v])=>[k.id,v]));
  assert.deepEqual(byId(api.clusterTargets(dialogue)),{10:8.75,11:8.75,12:8.75});
  const labels=[{...e('kept-3',11.584303,11.584303*.9)},{...e('kept-4',10.742534,10.742534*.9)}];
  assert.deepEqual(byId(api.clusterTargets(dialogue,labels)),{10:9.75,11:9.75,12:9.75});
  // A kept notice never lowers a target and gives none to a caption `raisable` rejects.
  const pair=[e('1',33.367805,10.5),e('2',35.170786,12)];
  assert.deepEqual(byId(api.clusterTargets(pair,[e('kept-3',29.937822,29.937822*.9)])),{1:12,2:12});
  assert.deepEqual(byId(api.clusterTargets(pair,[e('kept-3',29.937822,5)])),{1:11.25,2:11.25});
  assert.deepEqual(byId(api.clusterTargets(pair,[e('kept-3',29.937822,29.937822*.9)],entry=>entry.id!=='2')),{1:12,2:11.25});
  // A kept-only cohort raises a lone caption, never shrinks it.
  assert.deepEqual(byId(api.clusterTargets([e('5',20,12)],[e('kept-6',21,18.9)])),{5:15.5});
  assert.deepEqual(byId(api.clusterTargets([e('5',20,19)],[e('kept-6',21,9)])),{});
  assert.equal(api.clusterTargets(dialogue,[]).size,3);
});
test('kept lettering zones: box plus a small halo, minus painted source boxes', () => {
  const zones=plain(api.keptZones([{id:'kept-1',x:10,y:10,width:40,height:10,sourceFontSize:10}],[[0,18,100,30]]));
  // 1.5 px halo (15% of the glyph); the painted caption below keeps its own box.
  assert.deepEqual(zones,[{left:8.5,top:8.5,right:51.5,bottom:18,id:'kept-1'}]);
  const inside=plain(api.keptZones([{id:'kept-2',x:20,y:20,width:10,height:10,sourceFontSize:null}],[[0,0,100,100]]));
  assert.deepEqual(inside,[]);
  const around=plain(api.keptZones([{id:'kept-3',x:0,y:0,width:30,height:30,sourceFontSize:30}],[[10,10,10,10]]));
  assert.equal(around.length,4);
  assert.equal(around.reduce((n,z)=>n+(z.right-z.left)*(z.bottom-z.top),0),36*36-100);
  assert.deepEqual(plain(api.subtract([{left:0,top:0,right:10,bottom:10}],{left:20,top:0,right:30,bottom:10})),
    [{left:0,top:0,right:10,bottom:10}]);
});
test('condensed width stays at 90 % and only tries clearly larger sizes up to the target', () => {
  assert.equal(api.condensedWidth, .9);
  assert.deepEqual(plain(api.condensedSizes(10,20)),[12.5,11.5,11]);
  // The target bounds every size; sizes below 1.06x are not worth condensing.
  assert.deepEqual(plain(api.condensedSizes(10,11.2)),[11]);
  assert.deepEqual(plain(api.condensedSizes(10,10.5)),[]);
  assert.deepEqual(plain(api.condensedSizes(0,20)),[]);
  for(const size of api.condensedSizes(13.25,30))assert(size>=13.25*1.06&&size<=13.25*1.25);
});
test('condensing is only for word-bound measures: overflowing at full width, fitting at 90 %', () => {
  assert.equal(api.wordBound(100,95), true);
  assert.equal(api.wordBound(100,90), true);
  // Fits at full width: not word-bound.
  assert.equal(api.wordBound(90,95), false);
  assert.equal(api.wordBound(95,95), false);
  // Too long even condensed.
  assert.equal(api.wordBound(100,89), false);
});
