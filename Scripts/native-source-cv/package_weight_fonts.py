"""Copy only accepted byte-pinned public weight references with existing OFL."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[2]
DEST=ROOT/'Aidoku/Resources/Translation/SourceReferenceFonts.bundle'
EXPECTED='fc68d62720f2b874d9af46d5e525efebcbb388ec45b24feb503f3a1005e756fc'


def package():
    study=ROOT.parent/'font-weight-estimation-20261111'
    exported=study/'native-export'
    if json.loads((exported/'STUDY.json').read_text())['sourceSHA256']!=EXPECTED:
        raise ValueError('Unexpected frozen weight reference source')
    manifest_path=DEST/'manifest.json';manifest=json.loads(manifest_path.read_text())
    known={r['SHA256'] for r in manifest['publicFonts']}
    obligations=json.loads((exported/'font-asset-obligations.json').read_text())['fonts']
    copied=[]
    for record in obligations:
        sha=record['sha256'];source=Path(record['originalPath'])
        if sha in known:continue
        if source.suffix!='.ttf' or str(source).startswith('/System/'):
            raise ValueError('Only accepted public TTF reference bytes may be packaged')
        raw=source.read_bytes()
        if hashlib.sha256(raw).hexdigest()!=sha:raise ValueError('Weight font bytes differ')
        family=next((f for f in ('MPLUSRounded1c','ZenMaruGothic','NotoSerifJP','NotoSansJP','BIZUDPGothic') if source.name.startswith(f)),None)
        if family is None:raise ValueError('Explicit public font license is missing')
        license_source=study/'reference-bank/fonts'/(family+'-OFL.txt')
        license_data=license_source.read_bytes();license_sha=hashlib.sha256(license_data).hexdigest()
        font_path='fonts/'+sha+'.ttf';license_path='licenses/'+license_sha+'.txt'
        (DEST/font_path).write_bytes(raw);(DEST/license_path).write_bytes(license_data)
        manifest['publicFonts'].append(dict(path=font_path,SHA256=sha,licensePath=license_path,
            licenseSHA256=license_sha,faceIndex=0,originalFilename=source.name,
            sourceProvenance=source.relative_to(ROOT.parent).as_posix() if source.is_relative_to(ROOT.parent) else source.name,purpose='accepted-source-weight-reference'))
        known.add(sha);copied.append(dict(path=font_path,bytes=len(raw)))
    names={r['postScriptName'] for r in manifest['systemFonts']}
    for name in ('HiraginoSans-W9','HiraMinProN-W6'):
        if name not in names:manifest['systemFonts'].append(dict(path='ctfont://'+name,postScriptName=name))
    manifest_path.write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
    for record in manifest['publicFonts']:
        if hashlib.sha256((DEST/record['path']).read_bytes()).hexdigest()!=record['SHA256']:
            raise ValueError('Packaged public font changed')
        if hashlib.sha256((DEST/record['licensePath']).read_bytes()).hexdigest()!=record['licenseSHA256']:
            raise ValueError('Packaged public license changed')
    return dict(copied=copied,publicFonts=len(known),systemFontBytesCopied=False)


if __name__=='__main__':print(json.dumps(package()))
