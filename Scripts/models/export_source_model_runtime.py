"""Freeze trained numeric operators; never reads query predictions or GT.

Default export: accepted font198, appearance, segmentation. Assets are binary
property lists (Foundation PropertyListDecoder), registry is JSON. Feature/graph
policies stay with callers: head metadata preserves scaler and target parameters.
Run with .venv-source-inference/bin/python. Only trusted pickle files are inputs.
"""
from __future__ import annotations
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import pickle
import plistlib
import sys
import tempfile

os.environ.setdefault('OMP_NUM_THREADS', '1')
os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'Scripts/font_size_estimation'), str(ROOT/'Scripts/appearance_estimation')]
# Match the accepted runtime's optional accelerator compatibility setup.
import optimize_appearance  # noqa: E402,F401
import numpy as np

METADATA = ('mean', 'std', 'logTarget', 'standardized', 'targetScale', 'OOFNoise', 'clip')


def plain(value):
    if isinstance(value, np.ndarray): return value.tolist()
    if isinstance(value, np.generic): return value.item()
    if isinstance(value, dict): return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)): return [plain(v) for v in value]
    return value


def groups(model):
    labels = getattr(model, 'classes_', None)
    if labels is None or (not isinstance(labels, list) and np.asarray(labels).size == 0): return []
    if isinstance(labels, list): return [np.asarray(x, dtype=float).tolist() for x in labels]
    return [np.asarray(labels, dtype=float).tolist()]


def export_model(model, metadata=None):
    name = type(model).__name__
    cg = groups(model)
    doc = dict(schema=1, kind='', featureCount=int(getattr(model, 'n_features_in_', 0)),
               classes=cg[0] if len(cg)==1 else [], classGroups=cg, metadata=plain(metadata or {}),
               components=[], weights=[], forests=[], symmetricTrees=[], numericTrees=[], treeOutputs=[], coefficients=[],
               intercept=[], mean=[], scale=1., bias=[], link='identity')
    if name=='BackgroundBlend':
        if not 0 <= model.weight <= 1: raise ValueError('Invalid blend weight')
        if not np.array_equal(model.original.classes_,model.candidate.classes_): raise ValueError('Blend class ordering')
        doc.update(kind='blend',components=[export_model(model.original),export_model(model.candidate)],
                   weights=[1-float(model.weight),float(model.weight)])
    elif name.startswith(('ExtraTrees', 'RandomForest')):
        classification = name.endswith('Classifier')
        noutputs = sum(map(len, cg)) if classification else int(model.n_outputs_)
        # Existing NativeAppearanceForest has a 32-value bound: retain its exact
        # operators in disjoint output slices, including multioutput classifiers.
        for start in range(0, noutputs, 32):
            trees=[]
            for estimator in model.estimators_:
                t=estimator.tree_; nodes=[]
                for i in range(t.node_count):
                    leaf=t.children_left[i] < 0
                    values=[]
                    if leaf:
                        if classification:
                            for j, labels in enumerate(cg):
                                v=np.asarray(t.value[i,j,:len(labels)],dtype=float)
                                values.extend((v/max(float(v.sum()),1e-300)).tolist())
                        else: values=np.ravel(t.value[i]).astype(float).tolist()
                    # Existing primitive sizes result from root.values even at an internal node.
                    if i==0 and not leaf: values=[0.]*noutputs
                    nodes.append(dict(feature=int(t.feature[i]), threshold=float(t.threshold[i]),
                        left=int(t.children_left[i]), right=int(t.children_right[i]),
                        missingLeft=bool(t.missing_go_to_left[i]) if hasattr(t,'missing_go_to_left') else False,
                        leaf=bool(leaf), values=values[start:start+32]))
                trees.append(nodes)
            doc['forests'].append(dict(kind='forest-probability' if classification else 'forest-regression',
                features=doc['featureCount'], classes=[], baseline=[], trees=trees,
                outputs=[0]*len(trees), float32Input=True))
        doc['kind']='forest'
    elif name.startswith('HistGradientBoosting'):
        if np.any(getattr(model,'is_categorical_',False)):
            raise ValueError('Categorical HGB is not a numeric source head')
        baseline=np.ravel(model._baseline_prediction).astype(float).tolist()
        for start in range(0,len(baseline),32):
            trees=[]; outputs=[]
            for stage in model._predictors:
                for output,predictor in enumerate(stage):
                    if not start<=output<start+32: continue
                    nodes=[]
                    for n in predictor.nodes:
                        if n['is_categorical']: raise ValueError('Categorical HGB split')
                        nodes.append(dict(feature=int(n['feature_idx']),threshold=float(n['num_threshold']),
                            left=int(n['left']),right=int(n['right']),missingLeft=bool(n['missing_go_to_left']),
                            leaf=bool(n['is_leaf']),values=[float(n['value'])]))
                    trees.append(nodes); outputs.append(output-start)
            # HGB multiclass must softmax across ALL output chunks, so use raw regression primitives.
            doc['forests'].append(dict(kind='histogram-regression',features=doc['featureCount'],classes=[],
                baseline=baseline[start:start+32],trees=trees,outputs=outputs,float32Input=False))
        doc['kind']='forest'
        if cg: doc['link']='sigmoid' if len(baseline)==1 else 'softmax'
        elif type(model._loss).__name__ in ('HalfPoissonLoss','HalfGammaLoss'): doc['link']='exp'
    elif name.startswith('CatBoost'):
        with tempfile.NamedTemporaryFile(suffix='.json') as f:
            model.save_model(f.name,format='json'); cat=json.loads(Path(f.name).read_text())
        if cat.get('features_info',{}).get('categorical_features'): raise ValueError('Categorical CatBoost')
        doc.update(kind='catboost',featureCount=len(model.feature_names_),scale=float(cat['scale_and_bias'][0]),
                   bias=list(map(float,cat['scale_and_bias'][1])))
        infos={f['feature_index']:f for f in cat['features_info']['float_features']}
        for tree in cat['oblivious_trees']:
            features=[]; borders=[]; nan=[]
            for split in tree.get('splits') or []:
                if split['split_type']!='FloatFeature': raise ValueError('Non-numeric CatBoost split')
                info=infos[split['float_feature_index']]
                features.append(int(info['flat_feature_index'])); borders.append(float(split['border']))
                nan.append(info['nan_value_treatment']=='AsTrue')
            leaves=np.asarray(tree['leaf_values']).reshape(-1,len(doc['bias'])).tolist()
            doc['symmetricTrees'].append(dict(features=features,borders=borders,nanRight=nan,leaves=leaves))
        if cg: doc['link']='sigmoid' if len(doc['bias'])==1 else 'softmax'
    elif name.startswith('LGBM'):
        dump=model.booster_.dump_model(); objective=dump['objective'].split()[0]
        if dump.get('average_output'): raise ValueError('Averaged LightGBM needs separate semantics')
        if objective not in ('multiclass','binary','regression','regression_l1','huber','quantile','poisson','gamma','tweedie'):
            raise ValueError('Unsupported LightGBM objective: '+objective)
        width=int(dump['num_tree_per_iteration'])
        doc.update(kind='lightgbm',bias=[0.]*width)
        doc['link']='softmax' if objective=='multiclass' else ('sigmoid' if objective=='binary' else
                    ('exp' if objective in ('poisson','gamma','tweedie') else 'identity'))
        for index,tree in enumerate(dump['tree_info']):
            nodes=[]
            def visit(n):
                i=len(nodes); nodes.append(None)
                node=dict(feature=0,threshold=0.,left=0,right=0,missingLeft=False,missingZero=False,missingNaN=False)
                if 'leaf_value' in n: node['value']=float(n['leaf_value'])
                else:
                    if n['decision_type']!='<=': raise ValueError('Categorical LightGBM split')
                    node.update(feature=int(n['split_feature']),threshold=float(n['threshold']),
                        missingLeft=bool(n['default_left']),missingZero=n['missing_type']=='Zero',
                        missingNaN=n['missing_type']=='NaN',left=visit(n['left_child']),right=visit(n['right_child']))
                nodes[i]=node; return i
            visit(tree['tree_structure']); doc['numericTrees'].append(nodes); doc['treeOutputs'].append(index%width)
    elif name in ('Ridge','HuberRegressor','QuantileRegressor','LinearRegression'):
        coef=np.atleast_2d(model.coef_).astype(float)
        doc.update(kind='linear',coefficients=coef.tolist(),intercept=np.atleast_1d(model.intercept_).astype(float).tolist())
    elif name=='PCA':
        coef=model.components_.astype(float)
        if model.whiten: coef=coef/np.maximum(np.sqrt(model.explained_variance_),np.finfo(float).eps)[:,None]
        doc.update(kind='pca',coefficients=coef.tolist(),intercept=[0.]*len(coef),mean=model.mean_.astype(float).tolist())
        doc['metadata'].update(components=plain(model.components_),pcaMean=plain(model.mean_),
                               explainedVariance=plain(model.explained_variance_),whiten=bool(model.whiten))
    elif name=='StandardScaler':
        count=doc['featureCount']
        doc.update(kind='scaler',mean=plain(model.mean_) if model.with_mean else [0.]*count,
                   coefficients=[plain(model.scale_) if model.with_std else [1.]*count])
    else: raise ValueError('Unsupported trained operator: '+name)
    if any(not np.isfinite(n['threshold']) for f in doc['forests'] for t in f['trees'] for n in t if not n['leaf']):
        doc['infiniteThresholds']=True
    if not doc['featureCount']: raise ValueError('Empty feature schema: '+name)
    return doc


def collect(value, prefix, result=None, objects=None, metadata=None):
    result={} if result is None else result
    if hasattr(value,'predict') or hasattr(value,'predict_proba') or hasattr(value,'transform'):
        result[prefix]=export_model(value,metadata)
        if objects is not None: objects[prefix]=value
    elif isinstance(value,dict):
        context={k:plain(value[k]) for k in METADATA if k in value}
        for key,child in value.items(): collect(child,prefix+'/'+str(key),result,objects,context)
    elif isinstance(value,(list,tuple)):
        for key,child in enumerate(value): collect(child,prefix+'/'+str(key),result,objects,metadata)
    return result


TENSOR_MIN_ELEMENTS = 1_000_000
TENSOR_DTYPES = {('f', 2): 'f16', ('f', 4): 'f32', ('f', 8): 'f64',
                 ('i', 1): 'i8', ('i', 2): 'i16', ('i', 4): 'i32', ('i', 8): 'i64',
                 ('u', 1): 'u8', ('u', 2): 'u16', ('u', 4): 'u32', ('u', 8): 'u64'}


def metadata_tree(value, prefix, directory=None):
    """Mirror source metadata; only million-element numeric ndarrays become tensors.

    Tensor payloads are C-order, little-endian, preserving original numerical
    dtype and bits. Records remain records at native decode, never NSNumber lists.
    """
    if hasattr(value, 'predict') or hasattr(value, 'predict_proba') or hasattr(value, 'transform'):
        return {'modelID': prefix}
    if isinstance(value, dict):
        return {str(key): metadata_tree(child, prefix+'/'+str(key), directory) for key, child in value.items()}
    if isinstance(value, (list, tuple)):
        return [metadata_tree(child, prefix+'/'+str(key), directory) for key, child in enumerate(value)]
    if isinstance(value, np.ndarray):
        if value.size >= TENSOR_MIN_ELEMENTS and np.issubdtype(value.dtype, np.number):
            dtype=TENSOR_DTYPES.get((value.dtype.kind, value.dtype.itemsize))
            if dtype is None: raise ValueError('Unsupported large tensor dtype at '+prefix+': '+str(value.dtype))
            if directory is None: raise ValueError('Tensor output directory required at '+prefix)
            array=np.ascontiguousarray(value,dtype=value.dtype.newbyteorder('<'))
            payload=memoryview(array).cast('B')
            sha=hashlib.sha256(payload).hexdigest()
            relative='tensors/'+sha+'.bin'
            target=Path(directory)/relative; target.parent.mkdir(parents=True,exist_ok=True)
            if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest()!=sha:
                temporary=target.with_suffix('.bin.tmp')
                with temporary.open('wb') as stream: stream.write(payload)
                temporary.replace(target)
            return dict(tensorAsset=relative,shape=list(value.shape),dtype=dtype,sha256=sha)
        return metadata_tree(value.tolist(), prefix, directory)
    if isinstance(value, np.generic):
        return metadata_tree(value.item(), prefix, directory)
    if isinstance(value, Path): return str(value)
    if value is None or isinstance(value, (str, int, float, bool)): return value
    raise ValueError('Unsupported source metadata at '+prefix+': '+type(value).__name__)


def source_paths():
    yield 'font198', ROOT/'Scripts/font_size_estimation/assets/accepted198/model.pkl.gz'
    for p in sorted((ROOT/'Scripts/appearance_estimation/assets/accepted').glob('*.pkl')):
        yield 'appearance/'+p.stem,p
    yield 'appearance/native-primary-quality-model',ROOT/'Scripts/appearance_estimation/native-primary-quality-model.pkl'
    for name in ('context83','style78'):
        yield 'segmentation/'+name,ROOT/f'Scripts/segmentation/assets/accepted-final/{name}.joblib'


def attach_policies(registry):
    """Source runtime policies are graph metadata, never prediction tables."""
    from operational_appearance import POLICY_FILES
    tree=registry['metadata']['tree']
    tree['appearance/policies']={}
    for name in POLICY_FILES:
        path=ROOT/'Scripts/appearance_estimation/assets/accepted'/name
        tree['appearance/policies'][name]=json.loads(path.read_text())
        registry['sourceArtifacts']['appearance/policy/'+name]=hashlib.sha256(path.read_bytes()).hexdigest()
    path=ROOT/'Scripts/appearance_estimation/NATIVE-PRIMARY-QUALITY-POLICY.json'
    tree['appearance/policies'][path.name]=json.loads(path.read_text())
    registry['sourceArtifacts']['appearance/policy/'+path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
    path=ROOT/'Scripts/segmentation/assets/accepted-final/SOURCE-POLICY.json'
    tree['segmentation/policy']=json.loads(path.read_text())
    registry['sourceArtifacts']['segmentation/policy']=hashlib.sha256(path.read_bytes()).hexdigest()


def write_registry(registry, directory):
    attach_policies(registry)
    # Full recursive metadata is available to graph exporters. Learned-head-only
    # consumers use a small index and avoid decoding the large TRAIN banks.
    index={k:v for k,v in registry.items() if k!='metadata'}
    full=directory/'registry.json'
    temporary=directory/'registry.json.tmp'
    temporary.write_text(json.dumps(registry,separators=(',',':'),allow_nan=False)+'\n')
    temporary.replace(full)
    index.update(metadataAsset='registry.json',metadataSHA256=hashlib.sha256(full.read_bytes()).hexdigest())
    appearance=dict(schema=1,sourceOnly=True,GTAtInference=False,
        metadata={'tree':{k:v for k,v in registry['metadata']['tree'].items() if k.startswith('appearance/')}},
        sourceArtifacts={k:v for k,v in registry['sourceArtifacts'].items() if k.startswith('appearance/')})
    subset=directory/'appearance-metadata.json'
    temporary=directory/'appearance-metadata.json.tmp'
    temporary.write_text(json.dumps(appearance,separators=(',',':'),allow_nan=False)+'\n')
    temporary.replace(subset)
    index['metadataAssets']={'appearance':dict(asset=subset.name,sha256=hashlib.sha256(subset.read_bytes()).hexdigest())}
    temporary=directory/'registry-index.json.tmp'
    temporary.write_text(json.dumps(index,separators=(',',':'),allow_nan=False)+'\n')
    temporary.replace(directory/'registry-index.json')



def load(path):
    if path.suffix=='.gz':
        sys.path.insert(0,str(ROOT/'Scripts/font_size_estimation'))
        from split_artifact import read_bytes
        return pickle.loads(gzip.decompress(read_bytes(path)))
    import joblib
    return joblib.load(path)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=ROOT/'Aidoku/Resources/Translation/SourceModels')
    parser.add_argument('--expected-font198-sha',help='Parent-approved repacked bundle SHA; otherwise provenance stays pending')
    parser.add_argument('--source',action='append',help='Explicit id=trusted-pickle-path; overrides defaults')
    args=parser.parse_args(); args.out.mkdir(parents=True,exist_ok=True)
    registry=dict(schema=1,sourceOnly=True,GTAtInference=False,heads={},sourceArtifacts={},
                  provenanceStatus='pending-parent-font198-repack',metadata={'tree':{}})
    paths=[(s.split('=',1)[0],Path(s.split('=',1)[1])) for s in args.source] if args.source else source_paths()
    for prefix,path in paths:
        digest=hashlib.sha256(path.read_bytes()).hexdigest()
        if prefix=='font198' and args.expected_font198_sha:
            if digest!=args.expected_font198_sha: raise ValueError('Parent font198 SHA does not match current bundle')
            registry['provenanceStatus']='verified-parent-font198-repack'
        registry['sourceArtifacts'][prefix]=digest
        original=load(path)
        heads=collect(original,prefix)
        registry['metadata']['tree'][prefix]=metadata_tree(original,prefix,args.out)
        for key,head in heads.items():
            raw=plistlib.dumps(head,fmt=plistlib.FMT_BINARY,sort_keys=False)
            sha=hashlib.sha256(raw).hexdigest(); asset='heads/'+sha+'.plist'
            target=args.out/asset; target.parent.mkdir(exist_ok=True)
            target.write_bytes(raw)
            registry['heads'][key]=dict(asset=asset,sha256=sha,kind=head['kind'],featureCount=head['featureCount'],
                                       sourceModelSHA256=digest)
            print(key,head['kind'],head['featureCount'],len(raw),flush=True)
    write_registry(registry,args.out)
    print('registry:',args.out/'registry.json',flush=True)


if __name__=='__main__': main()
