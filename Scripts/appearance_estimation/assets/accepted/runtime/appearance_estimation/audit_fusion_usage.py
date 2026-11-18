"""Inspect trained split variables: prove raw evidence reaches decisions, not merely metadata."""
import argparse
from collections import Counter
from pathlib import Path
import pickle
import numpy as np
from optimize_appearance import read,save,digest


def category(name):
    name=name.lower()
    if '.rf' in name:return 'RF masks/instance affinities/bbox confidence'
    if '.seg' in name:return 'soft segmentation probabilities'
    if 'bbox' in name:return 'individual/merged bbox geometry'
    if '.ocr' in name:return 'OCR detector/recognition/token confidence'
    return 'source RGB/colour topology/other geometry'


def split_features(estimator):
    if hasattr(estimator,'component_estimators'):
        return np.concatenate([split_features(component) for component in estimator.component_estimators])
    if hasattr(estimator,'estimators_'):
        indices=np.concatenate([tree.tree_.feature for tree in estimator.estimators_])
        return indices[indices>=0]
    return np.concatenate([tree.nodes['feature_idx'][~tree.nodes['is_leaf'].astype(bool)] for stage in estimator._predictors for tree in stage])


def main():
    ap=argparse.ArgumentParser()
    for k in ['model','packet','out']:ap.add_argument('--'+k,type=Path,required=True)
    args=ap.parse_args();packet=read(args.packet)['packet']
    names=[f'legacyFeature{i}' for i in range(packet['baseFeatureCount'])]+packet['fusionFeatureNames'];count=len(names)
    with args.model.open('rb') as f:model=pickle.load(f)
    schemas=dict(fill=names,outline=names+[f'fillPair{i}' for i in range(6)]+['fill.'+n for n in names])
    schemas['background']=names if not model.get('conditionedBackground') else names+[
        f'fillPair{i}' for i in range(6)]+[f'outlinePair{i}' for i in range(6)]+['fill.'+n for n in names]+['outline.'+n for n in names]+['isFillCandidate','isOutlineCandidate']
    summary=['fill.'+n for n in names]+['outline.'+n for n in names]+['background.'+n for n in names]+[f'pair{i}' for i in range(18)]+['maskFraction']
    schemas.update(outlinePresence=summary,shadowPresence=summary);report={}
    for role,columns in schemas.items():
        estimator=model[role]
        if len(columns)!=estimator.n_features_in_:raise ValueError(role+' feature schema mismatch')
        counts=Counter()
        features=split_features(estimator)
        for i in features:counts[category(columns[int(i)])]+=1
        report[role]=dict(featureCount=len(columns),splitCounts=dict(counts),totalSplits=int(len(features)))
    save(args.out,dict(models=report,modelSHA256=digest(args.model),featureVersion=packet['version'],GTAtInference=False,
        scope='Actual trained tree split features, not causal accuracy attribution or mere declared input availability'))
    print(report,flush=True)


if __name__=='__main__':main()
