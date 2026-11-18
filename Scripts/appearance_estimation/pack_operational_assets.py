"""Pack accepted appearance models and their frozen source helper closure.

Only policy path keys are relocated. Every original expected helper/model SHA
is retained and checked; no GT, saved predictions or source images are copied.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil

from operational_appearance import MODEL_FILES, POLICY_FILES


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pack(checkpoint, destination, scripts):
    checkpoint=Path(checkpoint).resolve();destination=Path(destination).resolve();scripts=Path(scripts).resolve()
    if destination.exists():raise ValueError('Refusing to overwrite a sealed operational asset package')
    runtime=destination/'runtime'
    source=scripts/'appearance_estimation'
    sealed=source/'assets/accepted/runtime'
    def module_location(path):
        # Segmentation can advance independently of the accepted appearance graph.
        # Its frozen helpers retain their package names when building a new copy.
        return path.relative_to(sealed) if path.is_relative_to(sealed) else path.relative_to(scripts)
    policy_path=source/'NATIVE-PRIMARY-QUALITY-POLICY.json'
    policy=json.loads(policy_path.read_text())
    required={}
    for name,expected in policy['helperSHA256'].items():
        path=(source/name).resolve()
        if not path.is_relative_to(scripts) or sha(path)!=expected:
            raise ValueError('Accepted helper bytes differ: '+str(path))
        required[path]=expected
    for name in ('infer_appearance.py','source_native_primary_quality.py'):
        path=source/name;required[path]=sha(path)
    locations={module_location(path) for path in required}
    # Resolve local Python imports transitively. Only source files enter closure.
    pending=list(required)
    roots=[source,scripts/'segmentation',scripts/'style_gt']
    while pending:
        path=pending.pop()
        if path.suffix!='.py':continue
        for node in ast.walk(ast.parse(path.read_text())):
            names=([node.module.split('.')[0]] if isinstance(node,ast.ImportFrom) and node.module else
                   [a.name.split('.')[0] for a in node.names] if isinstance(node,ast.Import) else [])
            for name in names:
                for root in roots:
                    candidate=root/(name+'.py')
                    location=module_location(candidate)
                    if candidate.exists() and location not in locations:
                        required[candidate]=sha(candidate);pending.append(candidate)
                        locations.add(location)
    destination.mkdir(parents=True)
    try:
        files={}
        for name in MODEL_FILES+POLICY_FILES:
            shutil.copyfile(checkpoint/name,destination/name);files[name]=sha(checkpoint/name)
        for path,expected in required.items():
            target=runtime/module_location(path);target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(path,target)
            if sha(target)!=expected:raise ValueError('Packed helper changed')
            files[str(target.relative_to(destination))]=expected
        local=runtime/'appearance_estimation';local.mkdir(parents=True,exist_ok=True)
        model=source/'native-primary-quality-model.pkl'
        if sha(model)!=policy['modelSHA256']:raise ValueError('Native primary model differs')
        shutil.copyfile(model,local/model.name);files[str((local/model.name).relative_to(destination))]=sha(model)
        relocated={}
        for name,expected in policy['helperSHA256'].items():
            original=(source/name).resolve()
            packed=runtime/module_location(original)
            relocated[os.path.relpath(packed,local)]=expected
        policy['helperSHA256']=relocated
        relocated_path=local/policy_path.name
        relocated_path.write_text(json.dumps(policy,sort_keys=True,indent=2)+'\n')
        files[str(relocated_path.relative_to(destination))]=sha(relocated_path)
        for name,expected in files.items():
            if sha(destination/name)!=expected:raise ValueError('Package integrity failure')
        manifest=dict(schema=1,sourceOnly=True,GTAtInference=False,cachedPredictionsIncluded=False,
            originalNativePrimaryPolicySHA256=sha(policy_path),
            relocation='Only helperSHA256 path keys changed; all expected content hashes unchanged',files=files)
        (destination/'PACKAGE.json').write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n')
        return manifest
    except BaseException:
        shutil.rmtree(destination)
        raise


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    manifest=pack(args.checkpoint,args.out,Path(__file__).resolve().parents[1])
    print(json.dumps(dict(files=len(manifest['files']),bytes=sum((args.out/p).stat().st_size for p in manifest['files']))))


if __name__=='__main__':main()
