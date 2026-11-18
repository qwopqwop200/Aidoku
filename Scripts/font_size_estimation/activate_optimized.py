"""Activate a verified accepted operational source-font graph atomically."""
import argparse
import hashlib
import json
from pathlib import Path

from estimator import load_model
from optimized_graph import GRAPH_VERSION


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--model',type=Path,required=True)
    parser.add_argument('--verification',type=Path,required=True)
    parser.add_argument('--fresh-verification',type=Path,required=True)
    parser.add_argument('--selection',type=Path,required=True);args=parser.parse_args()
    verification=json.loads(args.verification.read_text())
    fresh=json.loads(args.fresh_verification.read_text())
    if not verification.get('passed') or not verification.get('goalCriteriaMet'):
        raise ValueError('Operational graph target verification did not pass')
    if not (fresh.get('bridgePassed') and fresh.get('requestedCoverageComplete')):
        raise ValueError('Fresh operational source adapter verification did not pass')
    bundle=load_model(args.model)
    if bundle.get('optimizedGraph',{}).get('version')!=GRAPH_VERSION:
        raise ValueError('Unexpected operational font graph')
    digest=hashlib.sha256(args.model.read_bytes()).hexdigest()
    for evidence in (verification,fresh):
        # Verification drivers may expose the pin at the top level or within
        # bundle metadata. Never accept a reported different model.
        expected=(evidence.get('modelSHA256') or evidence.get('bundle',{}).get('modelSHA256')
                  or evidence.get('bundle',{}).get('SHA256'))
        if expected and expected!=digest:raise ValueError('Verification model pin differs')
    from optimized_early import STAGES as early
    from optimized_late import STAGES as late
    value=dict(model=str(args.model.resolve()),modelSHA256=digest,featureVersion=4,
        optimizedFontGraph=GRAPH_VERSION,inferenceStages=[56,61,*early,*late],
        GTAtInference=False,GTMaskPixelsRead=False,sourceOnlyFreshInference=True,
        report=str(args.verification.resolve()),freshSourceVerification=str(args.fresh_verification.resolve()),
        operationalPlatform='macOS source host',nativeIOSExecution=False,
        note='Actual crop CLI and render bridge select this complete accepted graph; iOS-native graph execution is not certified')
    if args.selection.exists():
        backup=args.selection.with_name('PREVIOUS-ACTIVE-BEFORE-198.json')
        if not backup.exists():backup.write_bytes(args.selection.read_bytes())
    temporary=args.selection.with_suffix('.tmp');temporary.write_text(json.dumps(value,indent=2)+'\n')
    temporary.replace(args.selection)
    print(json.dumps(value),flush=True)


if __name__=='__main__':main()
