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
const api = vm.runInNewContext(script + contrastScript + ';({attached:aidokuHasAttachedLeadingInk,balloonFonts:aidokuBalloonFontSizes,erasure:aidokuRestoredErasureCovers,residual:aidokuHasResidualLettering,artworkFonts:aidokuArtworkFontSizes,compact:aidokuCompactPanel,visible:aidokuVisiblePanelColors,adjust:aidokuAdjustInkForContrast,fonts:aidokuFontClusters,inks:aidokuInkClusters,lines:aidokuKoreanLines,fragments:aidokuKoreanFragments,improves:aidokuKoreanWrapImproves,frame:aidokuCaptionInkFrame,candidates:aidokuCohortFontCandidates,flowFits:aidokuFontFlowFits,anchor:aidokuSourceAnchorShift,backing:aidokuTextBackingRect,needsBacking:aidokuNeedsTextBacking,keepsContrast:aidokuTextBackingKeepsContrast,contrast:aidokuSourceColorContrast})');
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
  assert.deepEqual(plain(api.candidates(12,8,5)),[9]);
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
  for(const [ink,bg] of [[[248,247,39],[253,254,6]],[[255,255,255],[232,232,232]],[[21,3,26],[141,97,153]],[[27,25,22],[88,38,30]]]){
    const saved=[...bg],contrast=rgb=>api.contrast(rgb,true,1,bg),adjusted=plain(api.adjust(ink,contrast));
    assert(contrast(adjusted)>=4.5);assert.deepEqual(bg,saved);
    assert.notDeepEqual(adjusted,[0,0,0]);assert.notDeepEqual(adjusted,[255,255,255]);
  }
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


test('artwork fitting keeps an 8.5 point floor and at least 80 percent of each font', () => {
  for (const font of [5, 7.5, 8.5]) assert.deepEqual(plain(api.artworkFonts(font)), []);
  for (const font of [8.6, 9, 10.5, 12, 31.75]) {
    const sizes=plain(api.artworkFonts(font));
    assert(sizes.every(size=>size>=Math.max(8.5,font*.8)&&size<font));
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

test('verified balloon fits keep at least 85 percent of each font with a 7.5 point floor', () => {
  for(const font of [7.5,8.25,8.75,9.5,12,30]){
    const sizes=plain(api.balloonFonts(font));assert.equal(sizes[0],font);
    assert(sizes.every(v=>v>=Math.max(7.5,font*.85)&&v<=font));
    assert(sizes.every((v,i)=>i===0||v<sizes[i-1]));assert(sizes.length<=9);
  }
  for(const value of [5,7.49,NaN])assert.deepEqual(plain(api.balloonFonts(value)),[]);
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
