"""Compact crop-only source-style reference viewer; images are linked, not copied."""
import argparse
import json
from pathlib import Path

HTML = r'''<!doctype html><html lang="ko"><meta charset="utf-8"><title>원본 색상·스타일 GT</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#14171c;color:#e8edf4;font:14px system-ui}header{padding:14px 20px;border-bottom:1px solid #39414e;display:flex;gap:12px;align-items:center;flex-wrap:wrap}h1{font-size:18px;margin:0}input,select,button,a{font:inherit}input,select,button{background:#232b36;color:#fff;border:1px solid #4a586c;border-radius:6px;padding:7px 10px}button{cursor:pointer}a{color:#8dc7ff}.layout{display:grid;grid-template-columns:minmax(300px,1fr) 360px;gap:18px;padding:18px}.viewport{height:76vh;overflow:auto;border:1px solid #485161;background:#343b44;display:flex;align-items:flex-start;justify-content:center;padding:12px}.imagebox{position:relative;display:inline-block;line-height:0;max-width:100%}img{display:block;max-width:100%;max-height:71vh;width:auto;height:auto}.original img{max-width:none;max-height:none}.original .imagebox{max-width:none}svg{position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none}section{background:#1e2530;border:1px solid #3d4757;border-radius:8px;padding:12px;margin-bottom:10px}h2{font-size:14px;margin:0 0 8px}.swatch{display:inline-block;width:32px;height:24px;border:1px solid #9ca5b3;vertical-align:middle;margin-right:8px;border-radius:4px}.muted{color:#a7b5c7}pre{font:12px ui-monospace;white-space:pre-wrap;line-height:1.55;margin:8px 0 0}.tag{font-size:12px;border:1px solid #75849a;border-radius:4px;padding:2px 5px;margin:3px}.info{padding:10px 20px;color:#b2c1d3;border-top:1px solid #39414e;line-height:1.6}@media(max-width:800px){.layout{grid-template-columns:1fr}.viewport{height:60vh}img{max-height:55vh}}
</style><header><h1>원본 색상·스타일 GT</h1><span id="total" class="muted"></span><input id="query" placeholder="페이지 / 항목 ID"><select id="filter"><option value="all">전체</option><option value="uncertain">불확실성 표시</option><option value="outline">외곽선 있음</option><option value="shadow">그림자 있음</option><option value="multicolor">다색·그라데이션</option></select><button id="prev">←</button><span id="position"></span><button id="next">→</button><button id="zoom">원본 배율</button><button id="anchors">앵커 표시</button><a href="../appearance-gt.json" download="appearance-gt-merged830-20261109.json">GT JSON</a></header>
<main class="layout"><div><h2 id="id"></h2><div id="viewport" class="viewport"><div class="imagebox"><img id="image"><svg id="markers"></svg></div></div><div id="source" class="muted"></div></div><aside id="details"></aside></main><footer class="info">64개 에이전트의 항목별 원본 crop 검토 · 사용자 확정 전 참고 GT · 주변 문맥은 각 방향 최대 15% · RGB는 sRGB, 두께·변위는 원본 픽셀 단위 · 물리적 두께·그림자 수치는 추정치이며 불확실성을 별도 기록</footer>
<script src="data.js"></script><script>
const data=window.APPEARANCE_GT;let list=data.items,index=0,showAnchors=false;
const $=id=>document.getElementById(id),rgb=c=>c?`rgb(${c.join(',')})`:'transparent',hex=c=>c?'#'+c.map(x=>x.toString(16).padStart(2,'0')).join('').toUpperCase():'미확정';
function element(tag,text,cls){let e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e}
function swatches(parent,colors){(colors||[]).forEach(c=>{let span=element('span',undefined,'swatch');span.style.background=rgb(c);span.title=hex(c);parent.append(span)})}
function panel(title,value,rows){let box=element('section');box.append(element('h2',title));let colors=value.colors||[value.rgb].filter(Boolean);swatches(box,colors);box.append(element('span',hex(value.rgb)));box.append(element('pre',rows.join('\n')+'\n신뢰도: '+Math.round((value.confidence||0)*100)+'%'));$('details').append(box)}
function render(){if(!list.length){$('position').textContent='0개';$('details').replaceChildren(element('section','해당 항목 없음'));$('image').removeAttribute('src');$('markers').replaceChildren();return}index=Math.max(0,Math.min(index,list.length-1));const r=list[index];$('id').textContent=r.itemID+' · '+r.cropSize.join(' × ')+' px';$('position').textContent=(index+1)+' / '+list.length;$('total').textContent=data.items.length+'개 검토';$('image').src='crops/'+r.itemID+'.png';$('image').alt=r.itemID+' 원본 crop';$('source').textContent='담당 '+r.review.reviewer+' · 원본 crop SHA '+r.cropSHA256.slice(0,16);$('details').replaceChildren();
panel('글자색',r.fill,['유형: '+r.fill.mode]);panel('외곽선',r.outline,['있음: '+r.outline.present,'두께: '+(r.outline.widthPx??'미확정')+' px','범위: '+JSON.stringify(r.outline.widthRangePx),'층: '+JSON.stringify(r.outline.layers)]);panel('그림자',r.shadow,['있음: '+r.shadow.present+' / '+r.shadow.kind,'변위: '+JSON.stringify(r.shadow.offsetPx),'블러: '+(r.shadow.blurRadiusPx??'미확정')+' px','불투명도: '+(r.shadow.opacity??'미확정')]);panel('주변 배경',r.background,['유형: '+r.background.mode]);let box=element('section');box.append(element('h2','검토 근거'));box.append(element('pre',r.review.observations));box.append(element('pre','불확실성: '+JSON.stringify(r.review.uncertainFields)));box.append(element('pre','픽셀 앵커: '+r.review.anchors.map(a=>a.role+' ['+a.xy+'] '+hex(a.rgb)).join('\n')));if(r.substyles?.length)box.append(element('pre','부분 스타일: '+JSON.stringify(r.substyles,null,2)));$('details').append(box);$('markers').setAttribute('viewBox','0 0 '+r.cropSize.join(' '));$('markers').replaceChildren();if(showAnchors)r.review.anchors.forEach(a=>{let c=document.createElementNS('http://www.w3.org/2000/svg','circle');c.setAttribute('cx',a.xy[0]);c.setAttribute('cy',a.xy[1]);c.setAttribute('r',4);c.setAttribute('fill','none');c.setAttribute('stroke','#00ffff');c.setAttribute('stroke-width','1.5');$('markers').append(c)});location.hash=r.itemID;}
function applyFilter(){let q=$('query').value.toLowerCase().trim(),f=$('filter').value;list=data.items.filter(r=>(!q||r.itemID.toLowerCase().includes(q)||r.page.includes(q))&&(f==='all'||f==='uncertain'&&r.review.uncertainFields.length||f==='outline'&&r.outline.present===true||f==='shadow'&&r.shadow.present===true||f==='multicolor'&&r.fill.mode!=='solid'));index=0;render()}
$('query').addEventListener('input',applyFilter);$('filter').addEventListener('change',applyFilter);$('prev').onclick=()=>{index--;render()};$('next').onclick=()=>{index++;render()};$('zoom').onclick=()=>$('viewport').classList.toggle('original');$('anchors').onclick=()=>{showAnchors=!showAnchors;render()};document.addEventListener('keydown',e=>{if(['INPUT','SELECT','TEXTAREA'].includes(document.activeElement.tagName))return;if(e.key==='ArrowRight'){index++;render()}if(e.key==='ArrowLeft'){index--;render()}});const wanted=location.hash.slice(1);if(wanted){const i=list.findIndex(r=>r.itemID===wanted);if(i>=0)index=i}render();
</script></html>'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    source = json.loads((root / 'appearance-gt.json').read_text())
    review = root / 'review'
    review.mkdir(exist_ok=True)
    crops = review / 'crops'
    parents = {Path(r['crop']).parent for r in source['items']}
    if len(parents) == 1:
        if not crops.exists():
            crops.symlink_to(next(iter(parents)), target_is_directory=True)
    else:
        crops.mkdir(exist_ok=True)
        for r in source['items']:
            path = crops / (r['itemID'] + '.png')
            if not path.exists():
                path.symlink_to(r['crop'])
    fields = ['itemID', 'page', 'cropSHA256', 'cropSize', 'fill', 'outline', 'shadow', 'background', 'substyles', 'review']
    payload = dict(items=[{k: r.get(k, [] if k == 'substyles' else None) for k in fields} for r in source['items']])
    (review / 'data.js').write_text('window.APPEARANCE_GT=' + json.dumps(payload, ensure_ascii=False, separators=(',', ':')) + ';\n')
    (review / 'index.html').write_text(HTML)
    print(review / 'index.html')


if __name__ == '__main__':
    main()
