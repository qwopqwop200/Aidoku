"""Source-only, relative colour pair features. No identity, labels or raw RGB inputs to HGB."""
import numpy as np
from source_appearance import lab

CANDIDATES = ('native', 'core1shift0', 'core1.5shift0')

def candidates(native, core):
    return [native, core['outputs']['core1.0-shift0.0'], core['outputs']['core1.5-shift0.0']]

def number(v):
    return float(v) if isinstance(v, (int, float, bool)) and np.isfinite(v) else np.nan

def pair_features(prediction, options, index):
    result = {}
    def put(name, value): result[name] = number(value)
    def count(name, value): put(name, np.log1p(max(0, value)) if np.isfinite(number(value)) else None)
    current = lab([prediction['fill']['rgb']])[0]
    chosen = options[index]
    candidate = lab([chosen['nativeRGB'] or prediction['fill']['rgb']])[0]
    background = lab([prediction['background']['rgb']])[0]
    outline = lab([prediction['outline']['rgb']])[0] if prediction['outline'].get('rgb') is not None else np.full(3,np.nan)
    for name,a,b in [('candidate_current',candidate,current),('candidate_bg',candidate,background),
                     ('current_bg',current,background),('candidate_outline',candidate,outline),
                     ('current_outline',current,outline),('outline_bg',outline,background)]:
        for channel,value in zip(('L','a','b'),a-b): put(name+'_'+channel,value)
        put(name+'_norm',np.linalg.norm(a-b))
    for role in ('fill','outline','background'):
        field=prediction[role]
        for key in ('confidence','probability'):
            put(role+'_'+key,field.get(key))
        scores=[number(v) for v in field.get('candidateScores',[]) if np.isfinite(number(v))]
        put(role+'_max_candidate_score',max(scores) if scores else None)
    put('outline_present',prediction['outline']['present'])
    evidence=prediction.get('pixelRoleEvidence',{})
    samples=number(evidence.get('samples'))
    count('role_samples_log',samples)
    for role in ('fill','outline','background'):
        e=evidence.get('roles',{}).get(role,{})
        put('role_'+role+'_mean_probability',e.get('meanProbability'))
        count('role_'+role+'_confident_log',e.get('confidentSamples'))
        put('role_'+role+'_confident_fraction',number(e.get('confidentSamples'))/samples if samples>0 else None)
        colours=e.get('observedColours',[])
        count('role_'+role+'_colour_count_log',len(colours))
        masses=[number(v.get('observedMass')) for v in colours if np.isfinite(number(v.get('observedMass')))]
        put('role_'+role+'_max_mass',max(masses) if masses else None)
        for label,point in [('current',current),('candidate',candidate)]:
            put('role_'+role+'_'+label+'_min_distance',float(np.linalg.norm(lab([v['rgb'] for v in colours])-point,axis=1).min()) if colours else None)
    native=options[0]['evidence']; own=chosen['evidence']; component=number(native.get('componentPixels'))
    count('native_components_log',native.get('components'))
    count('native_component_pixels_log',component)
    bounds=native.get('bounds')
    put('native_component_bbox_fraction',component/(bounds[2]*bounds[3]) if bounds and bounds[2]*bounds[3]>0 else None)
    for name,e in [('chosen',own),('native',native),('core1',options[1]['evidence']),('core1_5',options[2]['evidence'])]:
        pixels=number(e.get('corePixels',e.get('componentPixels')))
        count(name+'_pixels_log',pixels)
        put(name+'_component_fraction',pixels/component if component>0 else None)
        count(name+'_unique_log',e.get('medoid',{}).get('uniqueRGB'))
        put(name+'_unique_fraction',number(e.get('medoid',{}).get('uniqueRGB'))/pixels if pixels>0 else None)
    put('chosen_margin',own.get('coreMarginPx',0))
    put('native_max_depth',options[1]['evidence'].get('maximumNativeDepthPx',options[2]['evidence'].get('maximumNativeDepthPx')))
    for j,name in enumerate(CANDIDATES):
        put('type_'+name,j==index)
        put('available_'+name,options[j]['nativeRGB'] is not None)
        point=lab([options[j]['nativeRGB']])[0] if options[j]['nativeRGB'] is not None else np.full(3,np.nan)
        put('agreement_distance_'+name,np.linalg.norm(candidate-point))
    available=[v['nativeRGB'] for v in options if v['nativeRGB'] is not None]
    put('agreement_exact_count',sum(v==chosen['nativeRGB'] for v in available))
    put('available_count',len(available))
    assert len(result)<100
    return result

def matrix(predictions, all_options):
    records=[pair_features(p,opts,j) for p,opts in zip(predictions,all_options) for j in range(3)]
    names=list(records[0])
    assert all(list(r)==names for r in records)
    return np.asarray([[r[n] for n in names] for r in records],dtype=np.float64),names

def choose(scores, available, gate):
    """Current is zero; first candidate wins exact ties, no per-item exceptions."""
    values=np.where(available,scores,-np.inf)
    best=values.argmax(axis=1)
    improvement=values[np.arange(len(best)),best]
    return np.where(improvement>=gate,best+1,0)
