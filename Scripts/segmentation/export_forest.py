#!/usr/bin/env python3
"""Export calibrated pixel trees without OpenCV or evaluation labels at runtime."""
import argparse
import json
import numpy as np

from evaluate_gt import DEFAULT_OUT, read, save, sha


def flatten(tree, features):
    nodes = tree['nodes']
    flat = []

    def visit(index, depth):
        node = nodes[index]
        if node['depth'] != depth:
            raise ValueError('Invalid tree depth')
        here = len(flat)
        flat.append(None)
        if not node.get('splits'):
            value = int(node['value'])
            if value not in [0, 1]:
                raise ValueError('Unexpected class label')
            flat[here] = dict(feature=-1, threshold=0, left=-1, right=-1, positive=value)
            return index + 1, here
        split, = node['splits']
        if set(split) - {'var', 'quality', 'le'} or not 0 <= split['var'] < features:
            raise ValueError('Unsupported tree split')
        end, left = visit(index + 1, depth + 1)
        end, right = visit(end, depth + 1)
        flat[here] = dict(feature=split['var'], threshold=float(np.float32(split['le'])),
                          left=left, right=right, positive=-1)
        return end, here

    end, _ = visit(0, 0)
    if end != len(nodes):
        raise ValueError('Unvisited tree nodes')
    return flat


def collapse_constant_branches(nodes):
    """Exact binary-vote simplification, not statistical model pruning.

    OpenCV can split a node even when all descendant class votes are equal.
    Such a subtree returns the same vote for every possible source feature.
    """
    constant=[-1]*len(nodes)
    for i in range(len(nodes)-1,-1,-1):
        n=nodes[i]
        if n['feature']<0:constant[i]=n['positive']
        elif constant[n['left']]>=0 and constant[n['left']]==constant[n['right']]:
            constant[i]=constant[n['left']]
    result=[]
    def emit(i):
        here=len(result);result.append(None)
        if constant[i]>=0:
            result[here]=dict(feature=-1,threshold=0,left=-1,right=-1,positive=constant[i])
        else:
            n=nodes[i];left=emit(n['left']);right=emit(n['right'])
            result[here]=dict(n,left=left,right=right)
        return here
    emit(0)
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=__import__('pathlib').Path, default=DEFAULT_OUT)
    p.add_argument('--full-rf', action='store_true')
    p.add_argument('--recall-first', action='store_true')
    p.add_argument('--calibration-report', type=__import__('pathlib').Path)
    args = p.parse_args()
    prefix = 'full-rf-' if args.full_rf else ''
    source = args.out / f'{prefix}pixel-fusion-model.json'
    model = read(source)['opencv_ml_rtrees']
    if model['class_labels'] != [0, 1] or any(model['var_type'][:model['var_count']]):
        raise ValueError('Unsupported forest label/feature contract')
    if args.recall_first and not args.full_rf:
        p.error('--recall-first requires --full-rf')
    calibration = args.calibration_report or args.out / ('RECALL-COMPLETION-SEARCH.json' if args.recall_first
                                                        else f'{prefix}DEV-THRESHOLD-SEARCH.json')
    report=read(calibration)
    chosen = report['selected']
    if chosen is None:
        raise ValueError('No validated recall-preserving threshold')
    if (report.get('seedChromaBand','all')!='all' or chosen.get('connectedWeak') or
            'localVotes' in chosen or 'farFontScale' in chosen):
        raise ValueError('Research policy has no matching native completion implementation')
    training = read(args.out / f'{prefix}PIXEL-MODEL-TRAINING.json')
    if training.get('nativeExportSupported') is False:
        raise ValueError('Research feature variant requires a validated native implementation before export')
    output_prefix = 'recall-full-rf-' if args.recall_first else prefix
    completion = {k:chosen[k] for k in ['radiusFontScale', 'minimumRadiusPixels',
                                       'maximumRadiusPixels']} if args.recall_first else None
    if completion is not None:
        completion['unionNative'] = chosen.get('unionNative',False)
        if 'weakThreshold' in chosen:completion['weakThreshold']=chosen['weakThreshold']
        for key in ['kernel','fringeThreshold']:
            if key in chosen:completion[key]=chosen[key]
    flat=[flatten(t,model['var_count']) for t in model['trees']]
    pruned=[collapse_constant_branches(t) for t in flat]
    document=dict(schema=1,
        featureCount=model['var_count'], featureNames=training['featureNames'],
        threshold=chosen.get('strongThreshold',chosen.get('threshold')), trees=pruned,
        exactConstantBranchPruning=True,sourceNodeCount=sum(map(len,flat)),runtimeNodeCount=sum(map(len,pruned)),
        sourceModelSHA256=sha(source), runtimeTargetInputs=False, completion=completion,
        sourceFeatureVariant='pixel-full-rf-v2' if args.full_rf else 'pixel-coarse-rf-v1')
    encoded=json.dumps(document,separators=(',',':')).encode()
    if len(encoded)>32*1_048_576:
        # Identical trees/thresholds, fewer repeated JSON field names. Do not
        # prune a calibrated forest merely to fit the native byte budget.
        document['trees']=[[[n[k] for k in ['feature','threshold','left','right','positive']] for n in t]
                           for t in document['trees']]
        document['treeEncoding']='feature-threshold-left-right-positive'
        encoded=json.dumps(document,separators=(',',':')).encode()
    if len(encoded)>32*1_048_576 or sum(len(t) for t in document['trees'])>1_000_000:
        raise ValueError('Export exceeds the native model byte/node budget; reduce forest complexity')
    destination=args.out/f'{output_prefix}native-pixel-forest.json'
    temporary=destination.with_suffix('.json.tmp');temporary.write_bytes(encoded);temporary.replace(destination)


if __name__ == '__main__':
    main()
