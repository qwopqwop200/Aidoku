"""Package selected trained assets; runtime never imports experiment scripts.

Run explicitly after fitting. This exporter reads accepted model parameters and
TRAIN reference banks, not query predictions or query GT sizes. Activation is a
separate verification gate, never an automatic side effect of packaging.
"""
import argparse
import gzip
import hashlib
import json
import pickle
from pathlib import Path

from optimized_graph import GRAPH_VERSION


def build_bundle(root):
    from optimized_early import bundle_models as early_models,bundle_policies as early_policies
    from optimized_late_bundle import bundle_late_models
    from optimized_measurements import bundle_measurements
    root=Path(root)
    def model(n):
        with (root/f'round{n}/model.pkl').open('rb') as stream:return pickle.load(stream)
    old=model(48)
    with (root/'round53/boost-15.pkl').open('rb') as stream:pair=pickle.load(stream)
    policy=json.loads((root/'round61/REPORT.json').read_text())['selected']
    policy={k:policy[k] for k in ('numericAffinityWeight','span','threshold','minSourceAffinity','sourceGapSlope')}
    late,late_policy=bundle_late_models(root)
    # Exporters may return (models, source-identity guards) to preserve same-
    # source reference exclusion for fresh runtime packets.
    if isinstance(late,tuple):
        late,identities=late
    else:
        identities=late.pop('sourceIdentityGroups',{})
    specification=bundle_measurements(root)
    if identities!=specification['sourceIdentityGroups']:
        raise ValueError('Font reference banks disagree on source exclusion groups')
    from optimized_source_identity import extend_source_identity_aliases
    identities=extend_source_identity_aliases(root,identities)
    specification['sourceIdentityGroups']=dict(identities)
    graph=dict(version=GRAPH_VERSION,baseModel=model(56),pairModel=pair,
               clusteringPolicy=policy,earlyModels=early_models(root),earlyPolicies=early_policies(root),
               lateModels=late,latePolicies=late_policy,
               measurementSpec=specification,sourceIdentityGroups=identities)
    return dict(featureVersion=4,physicalReferenceFonts=old['physicalReferenceFonts'],
                physicalConsensus=old['physicalConsensus'],sourceClustering={'measureSourceEvidence':True},
                optimizedGraph=graph,GTFontLabelsUsed=False,GTMaskUsed=False)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--research-root',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True);args=parser.parse_args()
    bundle=build_bundle(args.research_root)
    args.out.parent.mkdir(parents=True,exist_ok=True)
    # Public learned-reference fonts ship beside the artifact; retain system
    # font dependencies as system resources rather than copying OS assets.
    spec=bundle['optimizedGraph']['measurementSpec']
    for key in ('fonts','extendedFonts','nativeFonts'):
        for record in spec[key]:
            source=Path(record['path'])
            if str(source).startswith('/System/Library/Fonts/'):
                continue
            raw=source.read_bytes()
            if hashlib.sha256(raw).hexdigest()!=record['SHA256']:
                raise ValueError('Reference font changed during packaging')
            relative=Path('fonts')/(record['SHA256']+source.suffix)
            target=args.out.parent/relative;target.parent.mkdir(exist_ok=True)
            if not target.exists():target.write_bytes(raw)
            if hashlib.sha256(target.read_bytes()).hexdigest()!=record['SHA256']:
                raise ValueError('Packaged reference font identity differs')
            record['path']=str(relative)
            if record.get('licensePath'):
                license_data=Path(record['licensePath']).read_bytes()
                license_sha=hashlib.sha256(license_data).hexdigest()
                if record.get('licenseSHA256',license_sha)!=license_sha:
                    raise ValueError('Reference font license identity differs')
                license_relative=Path('licenses')/(license_sha+'.txt')
                license_target=args.out.parent/license_relative
                license_target.parent.mkdir(exist_ok=True)
                license_target.write_bytes(license_data)
                record['licensePath']=str(license_relative)
    for directory in ('round120/fonts','round166/fonts'):
        for license_file in (args.research_root/directory).glob('*-OFL.txt'):
            data=license_file.read_bytes();target=args.out.parent/'licenses'/(hashlib.sha256(data).hexdigest()+'.txt')
            target.parent.mkdir(exist_ok=True)
            if not target.exists():target.write_bytes(data)
    temp=args.out.with_name(args.out.name+'.tmp')
    with gzip.open(temp,'wb',compresslevel=5) as stream:pickle.dump(bundle,stream,protocol=5)
    temp.replace(args.out)
    receipt=dict(version=GRAPH_VERSION,model=str(args.out.resolve()),
                 modelSHA256=hashlib.sha256(args.out.read_bytes()).hexdigest(),bytes=args.out.stat().st_size,
                 GTQueryValuesRead=False,packagedSourceOnlyModels=True,activated=False)
    args.out.with_suffix(args.out.suffix+'.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt),flush=True)


if __name__=='__main__':main()
