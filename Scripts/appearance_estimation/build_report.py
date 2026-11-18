"""Audit actual saved predictions and build a crop-only GT comparison viewer."""
import argparse
from collections import Counter
import json
from pathlib import Path
import numpy as np
from optimize_appearance import read,save,assign_splits,split,digest
from source_appearance import lab
from paint_palette_metrics import targets as fill_targets,predicted_colours
from audit_shadow_parameters import measure as shadow_parameter_metrics

HTML='''<!doctype html><meta charset="utf-8"><title>원본 스타일 추정 비교</title>
<style>body{background:#15191f;color:#eee;font:14px system-ui;margin:20px}button,select,input{font:inherit;padding:8px;background:#293441;color:white;border:1px solid #64748b}main{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-top:18px}img{max-height:72vh;max-width:100%;object-fit:contain}pre{white-space:pre-wrap;font-size:12px;background:#222c38;padding:12px}aside{display:grid;grid-template-columns:1fr 1fr;gap:8px}.tag{color:#ff9999}a{color:#8dccff}</style>
<h2>원본 crop · GT / 실제 저장된 추정값</h2><button id="prev">←</button><span id="pos"></span><button id="next">→</button>
<select id="filter"><option value="errors">오류 후보</option><option value="all">전체</option><option value="fill">글자색</option><option value="outline">외곽선</option><option value="background">배경색</option><option value="width">두께</option><option value="shadow">그림자</option></select><input id="search" placeholder="페이지 / 항목 ID">
<main><div><h3 id="id"></h3><img id="crop"><p id="issues" class="tag"></p></div><div><aside><div><h3>GT</h3><div id="gtcolors"></div><pre id="gt"></pre></div><div><h3>추정</h3><div id="predcolors"></div><pre id="pred"></pre></div></aside><pre id="metrics"></pre></div></main>
<script src="data.js"></script><script>
let rows=DATA,idx=0;const $=x=>document.getElementById(x);function apply(){let q=$('search').value,f=$('filter').value;rows=DATA.filter(r=>(!q||r.itemID.includes(q))&&(f==='all'||f==='errors'&&r.issues.length||r.issues.some(i=>i.startsWith(f))));idx=0;render()}
function swatches(id,style){let box=$(id);box.replaceChildren();for(let [label,value] of [['글자색',style.fill],['주변 배경',style.background]]){let row=document.createElement('div');row.append(document.createTextNode(label+' '));(value.colors||[value.rgb]).filter(Boolean).forEach((c,i)=>{let s=document.createElement('span');s.style.cssText='display:inline-block;width:24px;height:24px;margin:2px;border:1px solid #8b97a8';s.style.backgroundColor=`rgb(${c.join(',')})`;s.title=c.join(', ')+(value.observedContextWeights?' / '+(value.observedContextWeights[i]*100).toFixed(1)+'%':'');row.append(s)});box.append(row)}}
function render(){if(!rows.length){$('pos').textContent=' 0 ';$('crop').removeAttribute('src');return}idx=Math.max(0,Math.min(rows.length-1,idx));let r=rows[idx];$('pos').textContent=` ${idx+1}/${rows.length} `;$('id').textContent=r.itemID+' · '+r.split;$('crop').src='crops/'+r.itemID+'.png';$('gt').textContent=JSON.stringify(r.gt,null,2);$('pred').textContent=JSON.stringify(r.prediction,null,2);swatches('gtcolors',r.gt);swatches('predcolors',r.prediction);$('issues').textContent=r.issues.join(' / ');$('metrics').textContent=JSON.stringify(r.errors,null,2);location.hash=r.itemID}
$('prev').onclick=()=>{idx--;render()};$('next').onclick=()=>{idx++;render()};$('filter').onchange=apply;$('search').oninput=apply;document.onkeydown=e=>{if(document.activeElement.tagName==='INPUT')return;if(e.key==='ArrowRight'){idx++;render()}if(e.key==='ArrowLeft'){idx--;render()}};apply();</script>'''


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--gt',type=Path,required=True);parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args();rows=read(args.gt)['items'];groups=assign_splits(rows)
    if read(args.out/'SOURCE-POLICY.json')['inputGTSHA256']!=digest(args.gt):
        raise ValueError('Appearance GT changed since feature calibration')
    predictions=read(args.out/'predictions-with-width.json')['items']
    if [r['itemID'] for r in rows]!=[r['itemID'] for r in predictions]:raise ValueError('Saved prediction correspondence changed')
    cases=[]
    for r,p in zip(rows,predictions):
        errors={};issues=[]
        for field in ['fill','outline','background']:
            if field=='outline' and r[field]['present'] is not True:continue
            expected=r[field].get('colors') or ([r[field]['rgb']] if r[field].get('rgb') is not None else [])
            if expected and p[field]['rgb'] is not None:
                error=float(np.linalg.norm(lab([p[field]['rgb']])-lab(expected),axis=1).min())
                errors[field+'DeltaE']=error
                if error>10:issues.append(field+': color ΔE > 10')
        expected_fill=fill_targets(r);observed_fill=[p['fill']['rgb']]+[c['rgb'] for c in predicted_colours(p)]
        fill_delta=np.linalg.norm(lab(expected_fill)[:,None,:]-lab(observed_fill)[None,:,:],axis=2).min(1)
        errors['fillPaletteGTCoverageWithin10']=float(np.mean(fill_delta<=10))
        if np.any(fill_delta>10):issues.append('fill-palette: reference fill/substyle colour missing')
        if p['background'].get('colors'):
            expected=r['background'].get('colors') or [r['background']['rgb']]
            delta=np.linalg.norm(lab(expected)[:,None,:]-lab(p['background']['colors'])[None,:,:],axis=2).min(1)
            errors['backgroundPaletteGTCoverageWithin10']=float(np.mean(delta<=10))
            if np.any(delta>10):issues.append('background-palette: reference palette colour missing')
        for field in ['outline','shadow']:
            if r[field]['present'] is not None and r[field]['present']!=p[field]['present']:issues.append(field+': presence mismatch')
        if r['shadow']['present'] is True:
            expected=r['shadow'].get('rgb');actual=p['shadow'].get('rgb') if p['shadow']['present'] else None
            if expected is not None:
                if actual is None:issues.append('shadow: labelled colour missing')
                else:
                    distance=float(np.linalg.norm(lab([expected])[0]-lab([actual])[0]));errors['shadowColourDeltaE']=distance
                    if distance>10:issues.append('shadow: colour ΔE > 10')
            expected=r['shadow'].get('offsetPx');actual=p['shadow'].get('offsetPx') if p['shadow']['present'] else None
            if expected is not None:
                if actual is None:issues.append('shadow: labelled displacement missing')
                else:
                    distance=float(np.linalg.norm(np.asarray(expected)-np.asarray(actual)));errors['shadowOffsetErrorPx']=distance
                    if distance>2:issues.append('shadow: visible displacement error > 2 px')
        if r['outline']['present'] is True and r['outline'].get('widthRangePx'):
            lo,hi=r['outline']['widthRangePx'];v=p['outline']['widthPx'];distance=max(lo-v,v-hi,0)
            errors['widthOutsideGTRangePx']=distance
            if distance>0:issues.append('width: outside approximate GT interval')
        gt={f:r[f] for f in ['fill','outline','shadow','background','substyles']}
        # Keep physical uncertainty explicit: composite RGB cannot identify intrinsic alpha/blur.
        p['shadow']['parameterStatus']='RGB may describe observed composite and offset visible paint; intrinsic alpha/blur remain unlabelled'
        cases.append(dict(itemID=r['itemID'],split=split(r),gt=gt,prediction=p,errors=errors,issues=issues,crop=r['crop']))
    view=args.out/'review';view.mkdir(exist_ok=True);crops=view/'crops';crops.mkdir(exist_ok=True)
    for r in cases:
        path=crops/(r['itemID']+'.png')
        if not path.exists():path.symlink_to(r['crop'])
    (view/'index.html').write_text(HTML)
    (view/'data.js').write_text('const DATA='+json.dumps(cases,ensure_ascii=False,separators=(',',':'))+';\n')
    failures=[r for r in cases if r['issues']]
    save(args.out/'ERRORS.json',dict(itemCount=len(rows),errorCandidates=len(failures),
        reasonCounts=dict(Counter(i.split(':')[0] for r in failures for i in r['issues'])),items=failures))
    best=read(args.out/'BEST.json');width=read(args.out/'WIDTH-RESULTS.json')
    shadow=read(args.out/'SHADOW-PARAMETER-RESULTS.json') if (args.out/'SHADOW-PARAMETER-RESULTS.json').exists() else None
    actual={}
    for group in ['train','dev','test','all']:
        select=[r for r in cases if group=='all' or r['split']==group]
        positives=[r for r in select if r['gt']['outline']['present'] is True]
        pairs=[(r['gt']['shadow']['present'],r['prediction']['shadow']['present']) for r in select if r['gt']['shadow']['present'] is not None]
        tp=sum(a is True and bool(b) for a,b in pairs);fp=sum(a is False and bool(b) for a,b in pairs)
        fn=sum(a is True and not b for a,b in pairs);tn=sum(a is False and not b for a,b in pairs)
        presence=dict(TP=tp,FP=fp,FN=fn,TN=tn,positiveF1=2*tp/max(1,2*tp+fp+fn),
            precision=tp/max(1,tp+fp),recall=tp/max(1,tp+fn),accuracy=(tp+tn)/max(1,len(pairs)),
            balancedAccuracy=(tp/max(1,tp+fn)+tn/max(1,tn+fp))/2)
        actual[group]=dict(items=len(select),jointOutlinePresentAndColorWithin10=sum(r['prediction']['outline']['present'] and r['errors'].get('outlineDeltaE',999)<=10 for r in positives)/max(1,len(positives)),
            shadowPresence=presence,
            savedWidthMAEPx=float(np.mean([abs(r['prediction']['outline']['widthPx']-r['gt']['outline']['widthPx']) for r in positives])),
            errorCandidateItems=sum(bool(r['issues']) for r in select),
            legacyErrorCandidateItems=sum(any(not i.startswith(('background-palette:','fill-palette:')) for i in r['issues']) for r in select),
            paletteReferenceCoverageErrorItems=sum(any(i.startswith('background-palette:') for i in r['issues']) for r in select))
    final_presence={group:(shadow or {}).get('finalPresence',{}).get(group,values['shadowPresence']) for group,values in actual.items()}
    metrics={group:{**values,'shadowPresence':final_presence[group]} for group,values in best['metrics'].items()}
    final_background=read(args.out/'FINAL-BACKGROUND-RESULTS.json') if (args.out/'FINAL-BACKGROUND-RESULTS.json').exists() else None
    if final_background:
        for group,values in final_background['selected'].items():metrics[group]['background'].update(values)
    save(args.out/'REPORT.json',dict(itemCount=len(rows),GTAtInference=False,GTUnchanged=True,
        productionAppChanged=False,sourceContextMaxEachSide=.15,sourceCropAndPageGroups=groups,
        metrics=metrics,actualSavedOutput=actual,widthMetrics=width['selected'],
        backgroundPalette=read(args.out/'BACKGROUND-PALETTE-RESULTS.json') if (args.out/'BACKGROUND-PALETTE-RESULTS.json').exists() else None,
        roleConfigurations=len(read(args.out/'HISTORY.json')['iterations']),widthConfigurations=len(width['history'])-1,
        furtherRoleConfigurations=len(read(args.out/'REFINEMENT-HISTORY.json')['iterations']) if (args.out/'REFINEMENT-HISTORY.json').exists() else 0,
        sourceFillPalette=read(args.out/'SOURCE-FILL-PALETTE-RESULTS.json') if (args.out/'SOURCE-FILL-PALETTE-RESULTS.json').exists() else None,
        pixelRoleValidation=read(args.out/'PIXEL-ROLE-RESULTS.json') if (args.out/'PIXEL-ROLE-RESULTS.json').exists() else None,
        boundedSourceProfiles=read(args.out/'BOUNDED-PROFILE-RESULTS.json') if (args.out/'BOUNDED-PROFILE-RESULTS.json').exists() else None,
        fusedSourceInputs=read(args.out/'FUSION-SOURCE-POLICY.json') if (args.out/'FUSION-SOURCE-POLICY.json').exists() else None,
        trainedFusionUsage=read(args.out/'ACTUAL-FUSION-USAGE.json') if (args.out/'ACTUAL-FUSION-USAGE.json').exists() else None,
        primaryContourRecovery=read(args.out/'PRIMARY-CONTOUR-RESULTS.json') if (args.out/'PRIMARY-CONTOUR-RESULTS.json').exists() else None,
        orderedObservedLayers=read(args.out/'ORDERED-LAYER-RESULTS.json') if (args.out/'ORDERED-LAYER-RESULTS.json').exists() else None,
        nestedContourRecovery=read(args.out/'NESTED-CONTOUR-RESULTS.json') if (args.out/'NESTED-CONTOUR-RESULTS.json').exists() else None,
        observedOutlineLayers=read(args.out/'OUTLINE-LAYERS-RESULTS.json') if (args.out/'OUTLINE-LAYERS-RESULTS.json').exists() else None,
        shadowPositiveCount=sum(r['shadow']['present'] is True for r in rows),
        shadowParameterMetrics=shadow_parameter_metrics(rows,predictions),
        finalShadowPresence=final_presence,finalBackgroundRefinement=final_background,
        nativeGradientContour=read(args.out/'NATIVE-GRADIENT-CONTOUR-RESULTS.json') if (args.out/'NATIVE-GRADIENT-CONTOUR-RESULTS.json').exists() else None,
        finalSourceFillPalette=read(args.out/'NATIVE-GRADIENT-CONTOUR-RESULTS.json').get('fillPaletteMetrics',{}).get('selected') if (args.out/'NATIVE-GRADIENT-CONTOUR-RESULTS.json').exists() else None,
        nativeOuterShell=read(args.out/'NATIVE-OUTER-SHELL-RESULTS.json') if (args.out/'NATIVE-OUTER-SHELL-RESULTS.json').exists() else None,
        sourceShadowObservation=shadow,
        limitations=['Fixed GT crop/localization benchmark, not a complete native-page inference test.',
                    'Historical corpus was repeatedly inspected; no unseen-data guarantee.',
                    'Single-image intrinsic shadow alpha/blur have no identified GT and remain null.',
                    'Source colours and source pen width are separate from translated display styling.'],
        modelSHA256=digest(args.out/'model.pkl'),widthModelSHA256=digest(args.out/'width-model.pkl'),
        pixelRoleModelSHA256=digest(args.out/'pixel-role-model.pkl') if (args.out/'pixel-role-model.pkl').exists() else None,
        predictionsSHA256=digest(args.out/'predictions-with-width.json'),GTSHA256=digest(args.gt),review=str(view/'index.html')))
    print(json.dumps(actual['test']),flush=True)


if __name__=='__main__':main()
