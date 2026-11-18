"""Register byte-identical frozen weight heads; never activate partial inference."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT.parent/'font-weight-estimation-20261111/native-export'
DEST=ROOT/'Aidoku/Resources/Translation/SourceModels'
FONTS=ROOT/'Aidoku/Resources/Translation/SourceReferenceFonts.bundle'
PREFIX='font-weight/complete-complementary'
EXPECTED='fc68d62720f2b874d9af46d5e525efebcbb388ec45b24feb503f3a1005e756fc'


def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def atomic_json(path,value):
    temporary=path.with_suffix(path.suffix+'.tmp')
    temporary.write_text(json.dumps(value,ensure_ascii=False,separators=(',',':'),allow_nan=False)+'\n')
    temporary.replace(path)


def activation_evidence():
    study=ROOT.parent/'font-weight-estimation-20261111'
    paths=[study/'operational-glyph-full830/VERIFICATION.json',study/'native-source-pipeline-parity.log',
           study/'current-evidence-probe/LIVE-MAIN-VERIFICATION.json',study/'NATIVE-MAIN-WEIGHT-BUILD.json',
           study/'NATIVE-IOS-WEIGHT-FOCUSED.json']
    full,native,live,main,ios=[json.loads(p.read_text()) for p in paths]
    if (not all(p['passed'] for p in [full,native,live,main,ios]) or full['pages']!=830
            or full['requiredGT']!=3834 or full['retainedOutputOwners']!=3834
            or any(full[key] for key in ['missing','classificationErrors','renderRequestErrors','styleFallbacks'])
            or not native['actualNativeHeads'] or not native['actualNativeMeasurements']
            or native['GTAtInference'] or native['errors'] or native['owners']<34
            or live['GTAtInference'] or live['owners']<34
            or ios.get('requiredSuite')!='NativeSourceWeightIntegrationTests'
            or ios['summary']['result']!='Passed' or ios['summary']['passedTests']<=0
            or any(ios['summary'][key] for key in ['failedTests','skippedTests','expectedFailures'])):
        raise ValueError('Source weight activation lacks complete current proofs')
    for source in main['sources']:
        if digest(source['path'])!=source['SHA256']:raise ValueError('Main source differs from compiled proof')
    if digest(main['binary'])!=main['binarySHA256']:raise ValueError('Main binary differs from compiled proof')
    return [dict(path=str(p.relative_to(ROOT.parent)),SHA256=digest(p)) for p in paths]


def package(*, activate=None):
    if activate is None:
        existing=DEST/'font-weight-metadata.json'
        activate=existing.exists() and json.loads(existing.read_text()).get('productionActivated') is True
    parity=json.loads((SOURCE/'PARITY.json').read_text())
    if parity['sourceSHA256']!=EXPECTED or not parity['passed'] or parity['modelTrainingPerformed']:
        raise ValueError('Frozen native weight export lacks accepted parity')
    extra=json.loads((SOURCE/'registry.json').read_text())
    registry_path=DEST/'registry.json';index_path=DEST/'registry-index.json'
    registry=json.loads(registry_path.read_text());index=json.loads(index_path.read_text())
    before=dict(registrySHA256=digest(registry_path),indexSHA256=digest(index_path),heads=len(registry['heads']))
    old_heads=dict(registry['heads']);old_tree=dict(registry['metadata']['tree'])
    tree=extra['metadata']['tree'][PREFIX]
    def rebase(value):
        if isinstance(value,dict):
            if {'path','SHA256'}<=value.keys():
                path='fonts/'+value['SHA256']+'.ttf'
                if digest(FONTS/path)!=value['SHA256']:raise ValueError('Pinned native weight reference missing')
                value['path']=path
                value['faceIndex']=value.get('faceIndex') or 0
            for child in value.values():rebase(child)
        elif isinstance(value,list):
            for child in value:rebase(child)
    rebase(tree)
    for identity,record in extra['heads'].items():
        if not identity.startswith(PREFIX+'/') or record['sourceModelSHA256']!=EXPECTED:
            raise ValueError('Unexpected native weight head identity')
        path=Path(record['asset'])
        if path.is_absolute() or '..' in path.parts or digest(SOURCE/path)!=record['sha256']:
            raise ValueError('Changed frozen native weight numeric asset')
        if identity in old_heads and old_heads[identity]!=record:
            raise ValueError('Existing registered weight head differs')
    if len(extra['heads'])!=5:raise ValueError('Incomplete frozen weight heads')
    for identity,record in extra['heads'].items():
        target=DEST/record['asset'];target.parent.mkdir(exist_ok=True)
        if not target.exists() or digest(target)!=record['sha256']:shutil.copyfile(SOURCE/record['asset'],target)
        registry['heads'][identity]=record;index['heads'][identity]=record
    registry['metadata']['tree'][PREFIX]=tree
    registry.setdefault('sourceArtifacts',{})[PREFIX]=EXPECTED
    index.setdefault('sourceArtifacts',{})[PREFIX]=EXPECTED
    activation=activation_evidence() if activate else []
    metadata=dict(schema=1,sourceOnly=True,GTAtInference=False,productionActivated=bool(activate),
                  metadata=dict(tree={PREFIX:tree}))
    if activation:metadata['activationEvidence']=activation
    metadata_path=DEST/'font-weight-metadata.json';atomic_json(metadata_path,metadata)
    index.setdefault('metadataAssets',{})['fontWeight']=dict(asset=metadata_path.name,sha256=digest(metadata_path))
    for key,value in old_heads.items():
        if registry['heads'][key]!=value:raise ValueError('Unrelated source head changed')
    for key,value in old_tree.items():
        if key!=PREFIX and registry['metadata']['tree'][key]!=value:raise ValueError('Unrelated source metadata changed')
    atomic_json(registry_path,registry)
    index['metadataSHA256']=digest(registry_path)
    atomic_json(index_path,index)
    return dict(passed=True,before=before,after=dict(registrySHA256=digest(registry_path),indexSHA256=digest(index_path),heads=len(registry['heads'])),
        registeredWeightHeads=5,sourceModelSHA256=EXPECTED,productionWeightActivated=bool(activate),
        unrelatedHeadsPreserved=True,unrelatedMetadataPreserved=True,modelTrainingPerformed=False)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--activate',action='store_true',default=None,help='Require current source/native/iOS proofs and activate the complete path; otherwise preserve validated activation')
    args=parser.parse_args()
    print(json.dumps(package(activate=args.activate)))
