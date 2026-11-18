#!/usr/bin/env python3
"""Observation-only Swift rules versus original unmodified Python functions."""
import copy
import hashlib
import json
import math
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import time
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[3]
ORACLE=ROOT/'Scripts/font_weight_estimation'
sys.path.insert(0,str(ORACLE))
import numpy as np
import directional_ink_rules as directional
import reference_ink_rules as reference
import soft_ink_rules as soft
import ordered_ink_rules as ordered
from font_context_soft import regular_glyph_agreement


def encode(v):
    if isinstance(v,dict):return {k:encode(x) for k,x in v.items()}
    if isinstance(v,(list,tuple,np.ndarray)):return [encode(x) for x in v]
    if isinstance(v,(float,np.floating)):
        if not math.isfinite(v):return {'__float__':'nan' if math.isnan(v) else 'inf' if v>0 else '-inf'}
        return {'__double__':struct.pack('>d',float(v)).hex()}
    if isinstance(v,np.generic):return v.item()
    return v


def run():
    source=ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeSourceWeightImagePolicy.swift'
    files=[ORACLE/f for f in ['directional_ink_rules.py','reference_ink_rules.py','soft_ink_rules.py','ordered_ink_rules.py','font_context_soft.py','features.py']]
    files += [source.with_name('NativeSourceWeightGraph.swift')]
    def digests():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    before=digests();records=[];expected=[];names=[];coverage={};errors=0
    def evaluate(r):
        op=r['op'];p=r.get('policy',{});o=r.get('observation',{});prior=r.get('prior',{})
        if op=='directional':return dict(classifications=directional.classify_page(r['observations'],r['predictions'],p).tolist(),predictions=directional.apply_page(r['observations'],r['predictions'],p))
        if op=='referenceWord':return reference.word_passes(r['word'],p)
        if op=='reference':return reference.apply(o,prior,p)
        if op=='softWord':return soft.word_passes(r['word'],p)
        if op=='softProposes':return soft.proposes(o,r['confidence'],p)
        if op=='soft':return soft.apply(o,prior,p)
        if op=='orderedProposes':return ordered.proposes(o,r['confidence'],p)
        if op=='ordered':return ordered.apply(o,prior,p)
        if op=='agreement':return regular_glyph_agreement(o,r['counts'],p)
        if op=='outline':return ordered.outline_witness(r['style'],p)
        if op=='counts':return ordered.expected_counts(r['members'])
        raise AssertionError(op)
    def add(name,op,**r):
        nonlocal errors
        r=dict(r,op=op)
        try:
            with np.errstate(all='ignore'):want=evaluate(r)
        except Exception as error:want={'error':type(error).__name__};errors+=1
        records.append(copy.deepcopy(r));expected.append(encode(want));names.append(name)
        coverage[op]=coverage.get(op,0)+1
        return want
    prior=dict(sourceWeight='regular',renderBold=False,renderWeight='regular',requiresTranslationSpanAlignment=False,
               translatedStyleRuns=[dict(start=0,length=2,weight='bold')],polarityRescueScore=.3,registeredInkRescueApplied=True,
               directionalInkRescueApplied=True,softInkRescueApplied=True,orderedInkRescueApplied=True,
               sourceSoftGlyphConfirmationMeasured=True,sourceSoftGlyphConflictVetoApplied=True,
               arbitraryNested=dict(a=[1,False,None,'kept']))
    rp=dict(minimumFit=.8,minimumNormalMargin=.025,minimumStrokeFraction=.25,maximumFractionSpread=1.,minimumWordAgreement=1.,
            minimumRegisteredFraction=.2,minimumRegisteredSupport=.95,existingScoreField='none')
    rw=dict(matchedReferenceWeight=700.,templateFit=.8,normalTemplateMargin=.025,weightFraction=.25,fractionSpread=1.,
            registeredStrokeProfile=dict(usable=True,medianWeightFraction=.2,correspondingSourceSupport=.95))
    sp=dict(minimumExistingScore=.15,minimumFit=.8,minimumNormalMargin=.025,minimumSoftFraction=.15,minimumSourceSupport=.95)
    sw=dict(usable=True,matchedWeight=700.,templateFit=.8,normalTemplateMargin=.025,medianWeightFraction=.15,correspondingSourceSupport=.95)
    gp=dict(minimumExistingScore=.1,minimumWordFit=.8,minimumWordMargin=.1,minimumIndependentGlyphs=2,minimumGlyphFit=.75,
            minimumKnownSupport=.95,minimumMeanGlyphMargin=.025,requireWitnessedOutline=True,minimumOutlineProbability=.9,minimumPaintSeparation=35.)
    glyph=dict(templateFit=.75,referenceKnownSupport=.95,heavyMargin=.025)
    ow=dict(templateFit=.8,normalTemplateMargin=.1,matchedWeight=700.,orderedGlyphs=dict(glyphs=[dict(glyph),dict(glyph)]))
    oo=dict(words=[ow],expectedGlyphCounts=[2],outlineWitnessed=True)
    dp=dict(direction='verticalStems',mode='color',quantile=2,minimumWidthEm=.18,minimumDirectionContrast=1.75,
            minimumPageRelative=1.25,existingScoreField='none',minimumDirectionalRays=512)
    def obs(v,count=600,components=2,other=.08):
        return dict(color=dict(components=components,groups={name:dict(count=count,quantiles=[x,x,x,x])
                    for name,x in [('verticalStems',v),('horizontalStems',other),('diagonalStems',other*1.1)]}))
    # Actual multirow context: mixed supplies a control but can never promote;
    # baseline bold is excluded from controls irrespective of its width.
    observations=[obs(.3),obs(.1),obs(.2),obs(5.)]
    predictions=[prior,dict(prior),dict(prior,sourceWeight='mixed'),dict(prior,sourceWeight='bold')]
    got=add('directional-context','directional',observations=observations,predictions=predictions,policy=dp)
    assert got['classifications']==[True,False,False,False]
    single=add('directional-single','directional',observations=[observations[0]],predictions=[prior],policy=dp)
    assert single['classifications']==[False]
    for order in [[3,2,1,0],[1,0,3,2]]:add('directional-permutation-'+str(order),'directional',observations=[observations[i] for i in order],predictions=[predictions[i] for i in order],policy=dp)
    for component in [0,1,2,3]:
        for count in [0,15,16,511,512]:
            add('directional-support-'+str((component,count)),'directional',observations=[obs(.3,count,component),obs(.08)],predictions=[prior,prior],policy=dp)
    for key,value in [('minimumWidthEm',.18),('minimumDirectionContrast',1.75),('minimumPageRelative',1.25),('minimumDirectionalRays',600)]:
        for bound in [np.nextafter(value,-np.inf).item(),value,np.nextafter(value,np.inf).item()]:
            p=dict(dp);p[key]=bound
            add('directional-bound-'+key+'-'+repr(bound),'directional',observations=[obs(.3),obs(.1)],predictions=[prior,prior],policy=p)
    for field in ['none','polarityRescueScore','missingScore']:
        for score in [0.,.15,np.nextafter(.15,0).item(),np.nan,np.inf]:
            p=dict(dp,existingScoreField=field,minimumExistingScore=.15)
            add('directional-score-'+field+'-'+str(score),'directional',observations=[obs(.3),obs(.1)],predictions=[dict(prior,polarityRescueScore=score),prior],policy=p)
    for value in [0.,-1.,np.nan,np.inf,-np.inf]:
        add('directional-nonfinite-control-'+str(value),'directional',observations=[obs(.3),obs(value),obs(.1)],predictions=[prior]*3,policy=dp)
        add('directional-nonfinite-other-'+str(value),'directional',observations=[obs(.3,other=value),obs(.1)],predictions=[prior]*2,policy=dp)
    for q in [0,1,3,-1,-4,4,-5]:add('directional-q-'+str(q),'directional',observations=[obs(.3),obs(.1)],predictions=[prior]*2,policy=dict(dp,quantile=q))
    add('directional-empty','directional',observations=[],predictions=[],policy=dp)
    add('directional-mismatch','directional',observations=[obs(.3)],predictions=[],policy=dp)
    add('directional-missing-group','directional',observations=[{}],predictions=[prior],policy=dp)
    # Apply outputs preserve arbitrary prior keys, reset only their own flag,
    # and replace the five render-policy fields only when actually promoting.
    for label in ['regular','bold','mixed','unknown']:
        row=dict(prior,sourceWeight=label)
        add('reference-label-'+label,'reference',observation=dict(words=[rw]),prior=row,policy=rp)
        add('soft-label-'+label,'soft',observation=dict(words=[sw],expectedWordCount=1),prior=row,policy=sp)
        add('ordered-label-'+label,'ordered',observation=oo,prior=row,policy=gp)
    for op,word,p,keys in [('referenceWord',rw,rp,['matchedReferenceWeight','templateFit','normalTemplateMargin','weightFraction','fractionSpread']),
                           ('softWord',sw,sp,['matchedWeight','templateFit','normalTemplateMargin','medianWeightFraction','correspondingSourceSupport'])]:
        add(op+'-pass',op,word=word,policy=p)
        for key in keys:
            for value in [None,'MISSING',np.nan,np.inf,-np.inf,0.,str(word[key])]:
                w=copy.deepcopy(word)
                if value=='MISSING':w.pop(key)
                else:w[key]=value
                add(op+'-'+key+'-'+str(value),op,word=w,policy=p)
            value=word[key]
            for boundary in [np.nextafter(value,-np.inf).item(),value,np.nextafter(value,np.inf).item()]:
                w=copy.deepcopy(word);w[key]=boundary;add(op+'-gate-'+key+'-'+repr(boundary),op,word=w,policy=p)
    for evidence in [{},dict(usable=False),dict(usable=True),dict(usable=True,medianWeightFraction=np.nan,correspondingSourceSupport=1.),
                     dict(usable=True,medianWeightFraction=.2,correspondingSourceSupport=.95),None]:
        add('reference-registered-'+str(evidence),'referenceWord',word=dict(rw,registeredStrokeProfile=evidence),policy=rp)
    for minimum in [None,'ABSENT']:
        p=dict(rp)
        if minimum=='ABSENT':p.pop('minimumRegisteredFraction')
        else:p['minimumRegisteredFraction']=None
        w=dict(rw);w.pop('registeredStrokeProfile');add('reference-no-registered-'+str(minimum),'referenceWord',word=w,policy=p)
    for agreement in [0.,.5,1.]:
        bad=dict(rw,templateFit=.1)
        add('reference-word-agreement-'+str(agreement),'reference',observation=dict(words=[rw,bad]),prior=prior,policy=dict(rp,minimumWordAgreement=agreement))
    for word_list in [[],[{}],[rw],None]:
        add('reference-words-'+str(word_list),'reference',observation=dict(words=word_list),prior=prior,policy=rp)
    for score in ['none','polarityRescueScore','absent']:
        for value in [0.,.3,np.nan,np.inf]:
            add('reference-score-'+score+'-'+str(value),'reference',observation=dict(words=[rw]),prior=dict(prior,polarityRescueScore=value),
                policy=dict(rp,existingScoreField=score,minimumExistingScore=.3))
    for expected_count in [0,1,2,None,'MISSING']:
        o=dict(words=[sw])
        if expected_count!='MISSING':o['expectedWordCount']=expected_count
        for confidence in [.15,np.nextafter(.15,0).item(),np.nan,np.inf]:
            add('soft-count-score-'+str(expected_count)+'-'+str(confidence),'softProposes',observation=o,confidence=confidence,policy=sp)
    for o in [{},dict(words=[]),dict(words=None),dict(words=[dict(usable=False)],expectedWordCount=1),dict(words=[sw,dict(sw,templateFit=0)],expectedWordCount=2)]:
        add('soft-empty-partial-'+str(o),'soft',observation=o,prior=prior,policy=sp)
    # Nonregular apply short circuits malformed observation/confidence metadata.
    for op,p in [('soft',sp),('ordered',gp)]:add(op+'-bold-short-circuit',op,observation=dict(words=[None]),prior=dict(prior,sourceWeight='bold',polarityRescueScore=None),policy={})
    for kind in ['orderedProposes','agreement']:
        def go(name,o,p=gp,counts=None):
            if kind=='orderedProposes':add(kind+'/'+name,kind,observation=o,confidence=.3,policy=p)
            else:add(kind+'/'+name,kind,observation=o,counts=counts if counts is not None else o.get('expectedGlyphCounts',[]),policy=p)
        nominal=copy.deepcopy(oo)
        if kind=='agreement':
            for g in nominal['words'][0]['orderedGlyphs']['glyphs']:g['heavyMargin']=-.025
        go('pass',nominal)
        for field,floor in [('templateFit',.75),('referenceKnownSupport',.95),('heavyMargin',0.)]:
            for v in ['MISSING',None,np.nan,np.inf,-np.inf,np.nextafter(floor,-np.inf).item(),floor,np.nextafter(floor,np.inf).item()]:
                o=copy.deepcopy(nominal)
                if v=='MISSING':o['words'][0]['orderedGlyphs']['glyphs'][0].pop(field)
                else:o['words'][0]['orderedGlyphs']['glyphs'][0][field]=v
                go(field+'-'+str(v),o)
        for count in [0,1,2,3]:
            o=copy.deepcopy(nominal);o['expectedGlyphCounts']=[count];go('count-'+str(count),o)
        for glyphs in [[],[glyph],None]:
            o=copy.deepcopy(nominal);o['words'][0]['orderedGlyphs']['glyphs']=glyphs;go('glyph-list-'+str(glyphs),o)
        for field in ['orderedGlyphs','words']:
            o=copy.deepcopy(nominal)
            if field=='words':o.pop('words')
            else:o['words'][0].pop(field)
            go('missing-'+field,o)
        o=copy.deepcopy(nominal);o['words'].append(copy.deepcopy(o['words'][0]));o['expectedGlyphCounts']=[2,2];go('multiword',o)
        o['words'][1]['orderedGlyphs']['glyphs'][0]['heavyMargin']=0;go('second-word-disagrees',o)
    for field,value in [('templateFit',.8),('normalTemplateMargin',.1),('matchedWeight',700.)]:
        for v in [np.nextafter(value,-np.inf).item(),value,np.nextafter(value,np.inf).item(),None,np.nan,'MISSING']:
            o=copy.deepcopy(oo)
            if v=='MISSING':o['words'][0].pop(field)
            else:o['words'][0][field]=v
            add('ordered-word-'+field+'-'+str(v),'ordered',observation=o,prior=prior,policy=gp)
    for witness in [True,False,None,'MISSING']:
        o=copy.deepcopy(oo)
        if witness=='MISSING':o.pop('outlineWitnessed')
        else:o['outlineWitnessed']=witness
        add('ordered-outline-'+str(witness),'ordered',observation=o,prior=prior,policy=gp)
    # Independent regular agreement deliberately ignores word-level shape/weight
    # and outline witness: only complete, reliable negative glyph margins veto.
    o=copy.deepcopy(oo);o['words'][0].update(templateFit=0,matchedWeight=900);o['outlineWitnessed']=False
    for g in o['words'][0]['orderedGlyphs']['glyphs']:g['heavyMargin']=-1e-12
    assert add('agreement-independent','agreement',observation=o,counts=[2],policy=gp)
    for confidence in [np.nextafter(.1,0).item(),.1,np.nan,np.inf]:add('ordered-confidence-'+str(confidence),'orderedProposes',observation=oo,confidence=confidence,policy=gp)
    style=dict(outline=dict(present=True,probability=.9,rgb=[0.,0.,0.]),background=dict(rgb=[255.,255.,255.]),fill=dict(rgb=[35.,0.,0.]))
    for value in [np.nextafter(.9,0).item(),.9,np.nextafter(.9,1).item(),np.nan,np.inf,None]:
        st=copy.deepcopy(style);st['outline']['probability']=value;add('outline-probability-'+str(value),'outline',style=st,policy=gp)
    for distance in [np.nextafter(35.,0).item(),35.,np.nextafter(35.,np.inf).item()]:
        st=copy.deepcopy(style);st['fill']['rgb']=[distance,0.,0.];add('outline-separation-'+repr(distance),'outline',style=st,policy=gp)
    for part in ['outline','background','fill']:
        for rgb in [None,[],[0,0],[0,0,np.nan],[0,0,'bad']]:
            st=copy.deepcopy(style);st[part]['rgb']=rgb;add('outline-'+part+'-'+str(rgb),'outline',style=st,policy=gp)
    for st in [{},dict(outline=dict(present=False)),dict(outline=dict(present=True,probability=.8))]:add('outline-missing-'+str(st),'outline',style=st,policy=gp)
    for texts in [[],['あぬ漢語A2!?'],['か\u3099ガがé\u0301'],['𝟙Ⅰ² ½🙂'],['\u0301\u200d!?'],['한글가'],['ab']*8]:
        add('counts-'+str(texts),'counts',members=[dict(text=t) for t in texts])
    # Missing policy keys must error only when Python actually evaluates them.
    for op,p,kw in [('referenceWord',rp,dict(word=rw)),('softWord',sp,dict(word=sw)),('orderedProposes',gp,dict(observation=oo,confidence=.3))]:
        for field in p:
            q=dict(p);q.pop(field);add('missing-policy-'+op+'-'+field,op,policy=q,**kw)
    # Python short circuits before touching malformed later words/glyphs.
    add('soft-later-malformed-word','softProposes',observation=dict(words=[dict(usable=False),None],expectedWordCount=2),confidence=.3,policy=sp)
    for op in ['orderedProposes','agreement']:
        o=copy.deepcopy(oo);o['words'].append(None);o['expectedGlyphCounts']=[2,2]
        o['words'][0]['orderedGlyphs']['glyphs'][0]['templateFit']=0
        args=dict(observation=o,policy=gp)
        if op=='agreement':args['counts']=[2,2]
        else:args['confidence']=.3
        add(op+'-later-malformed-word',op,**args)
        o=copy.deepcopy(oo);o['words'][0]['orderedGlyphs']['glyphs']=[dict(glyph,templateFit=0),None]
        args['observation']=o
        if op=='agreement':args['counts']=[2]
        add(op+'-later-malformed-glyph',op,**args)
    for value in [None,'bad',[],{}]:
        st=copy.deepcopy(style);st['outline'].update(present=False,probability=value)
        add('outline-absent-invalid-probability-'+str(value),'outline',style=st,policy={})
    for label in [None,True,0]:
        for op,p,o in [('reference',rp,dict(words=[rw])),('soft',sp,dict(words=[sw],expectedWordCount=1)),('ordered',gp,oo)]:
            add(op+'-nonstring-source-label-'+str(label),op,observation=o,prior=dict(prior,sourceWeight=label),policy=p)
        add('directional-nonstring-source-label-'+str(label),'directional',observations=[obs(.3),obs(.1)],predictions=[dict(prior,sourceWeight=label),prior],policy=dp)
    for value in ['nan','inf','-inf',' 0.8 ']:
        add('reference-explicit-float-string-'+value,'referenceWord',word=dict(rw,templateFit=value),policy=rp)
    add('ordered-count-null','orderedProposes',observation=dict(oo,expectedGlyphCounts=[None]),confidence=.3,policy=gp)
    # Deterministic varied actual rule inputs, not a mirrored implementation.
    rng=np.random.default_rng(2241)
    for i in range(40):
        w=copy.deepcopy(sw);w.update(templateFit=float(rng.choice([.7,.8,.9])),medianWeightFraction=float(rng.choice([.1,.15,.3])),usable=bool(i%4))
        add('varied-soft-'+str(i),'soft',observation=dict(words=[w],expectedWordCount=1),prior=dict(prior,sourceWeight=['regular','bold','mixed'][i%3]),policy=sp)
        o=copy.deepcopy(oo)
        for g in o['words'][0]['orderedGlyphs']['glyphs']:g['heavyMargin']=float(rng.choice([-.1,0,.01,.025,.1]))
        add('varied-ordered-'+str(i),'ordered',observation=o,prior=prior,policy=gp)
        add('varied-agreement-'+str(i),'agreement',observation=o,counts=[2],policy=gp)
    with tempfile.TemporaryDirectory(prefix='aidoku-weight-image-policy-') as temp:
        temp=Path(temp);binary=temp/'policy';start=time.monotonic()
        subprocess.run(['xcrun','swiftc','-O','-swift-version','5','-module-cache-path',str(temp/'modules'),str(source),
                        str(Path(__file__).with_name('Main.swift')),'-o',str(binary)],check=True)
        build=time.monotonic()-start
        (temp/'input.json').write_text(json.dumps(encode(records),allow_nan=False,ensure_ascii=False))
        start=time.monotonic();subprocess.run([str(binary),str(temp/'input.json'),str(temp/'output.json')],check=True)
        duration=time.monotonic()-start;actual=json.loads((temp/'output.json').read_text())
    assert len(actual)==len(expected),(len(actual),len(expected))
    for name,want,got in zip(names,expected,actual):
        if isinstance(want,dict) and 'error' in want:assert isinstance(got,dict) and got.get('error'),(name,want,got)
        else:assert got==want,(name,want,got)
    assert before==digests(),'Existing oracle/graph files changed'
    print(json.dumps(dict(cases=len(records),by_operation=coverage,python_error_cases=errors,exact_decisions_and_rows=True,
                         build_seconds=build,swift_seconds=duration,oracle_sha256=before),indent=2))

if __name__=='__main__':run()
