#!/usr/bin/env python3
"""Package only public accepted font bytes + OFL; never copy system fonts."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil

ROOT=Path(__file__).resolve().parents[2]
RESEARCH=ROOT.parent/'font-size-estimation-20261110'
DEST=ROOT/'Aidoku/Resources/Translation/SourceReferenceFonts.bundle'

def package():
    previous=json.loads((DEST/'manifest.json').read_text()) if (DEST/'manifest.json').exists() else {}
    (DEST/'fonts').mkdir(parents=True,exist_ok=True)
    (DEST/'licenses').mkdir(exist_ok=True)
    manifest={'systemFonts':[
        {'path':'ctfont://HiraginoSans-W3','postScriptName':'HiraginoSans-W3'},
        {'path':'ctfont://HiraginoSans-W6','postScriptName':'HiraginoSans-W6'},
        {'path':'ctfont://HiraMaruPro-W4','postScriptName':'HiraMaruPro-W4'},
        {'path':'ctfont://HiraMinProN-W3','postScriptName':'HiraMinProN-W3'}], 'publicFonts':[]}
    native={Path(r['path']).name:r for r in json.loads((RESEARCH/'round166/FONTS.json').read_text())['fonts']}
    families={'BIZUDPGothic-Regular':'bizudpgothic','KiwiMaru-Regular':'kiwimaru',
              'YuseiMagic-Regular':'yuseimagic','ZenAntiqueSoft-Regular':'zenantiquesoft'}
    for stage in ('round120','round166'):
        directory=RESEARCH/stage/'fonts'
        for source in (sorted(directory.glob('*.ttf')) if stage=='round120' else [directory/name for name in native]):
            raw=source.read_bytes();sha=hashlib.sha256(raw).hexdigest()
            record=dict(native.get(source.name,{}))
            if record.get('SHA256',sha)!=sha:raise ValueError('Accepted public font SHA differs: '+source.name)
            path='fonts/'+sha+'.ttf';(DEST/path).write_bytes(raw)
            family=families.get(source.stem)
            licenseSource=Path(record['licensePath']) if record.get('licensePath') else directory/(family+'-OFL.txt')
            licenseData=licenseSource.read_bytes();licenseSHA=hashlib.sha256(licenseData).hexdigest()
            if record.get('licenseSHA256',licenseSHA)!=licenseSHA:raise ValueError('Public font license SHA differs')
            licensePath='licenses/'+licenseSHA+'.txt';(DEST/licensePath).write_bytes(licenseData)
            record.update(path=path,SHA256=sha,faceIndex=0,licensePath=licensePath,licenseSHA256=licenseSHA,originalFilename=source.name)
            if family:record['sourceURL']='https://github.com/google/fonts/tree/main/ofl/'+family
            manifest['publicFonts'].append(record)
    # Accepted weight references are independently pinned public assets. Keep
    # their verified bytes/licenses when rebuilding the original font package.
    known={record['SHA256'] for record in manifest['publicFonts']}
    for record in previous.get('publicFonts',[]):
        if record['SHA256'] in known:continue
        if hashlib.sha256((DEST/record['path']).read_bytes()).hexdigest()!=record['SHA256']:
            raise ValueError('Existing accepted public font SHA differs')
        if hashlib.sha256((DEST/record['licensePath']).read_bytes()).hexdigest()!=record['licenseSHA256']:
            raise ValueError('Existing accepted public font license SHA differs')
        manifest['publicFonts'].append(record);known.add(record['SHA256'])
    names={record['postScriptName'] for record in manifest['systemFonts']}
    for record in previous.get('systemFonts',[]):
        if record['postScriptName'] not in names:
            manifest['systemFonts'].append(record);names.add(record['postScriptName'])
    shutil.copytree(ROOT/'Vendor/NativeSourceCV/licenses',DEST/'licenses/NativeSourceCV',dirs_exist_ok=True)
    shutil.copyfile(ROOT/'Vendor/NativeSourceCV/PROVENANCE.json',DEST/'licenses/NativeSourceCV/PROVENANCE.json')
    (DEST/'manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
    (DEST/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.aidoku.source-reference-fonts',
        'CFBundleName':'SourceReferenceFonts','CFBundlePackageType':'BNDL','CFBundleVersion':'1'}))
    return manifest

if __name__=='__main__':
    manifest=package();print(f"Packaged {len(manifest['publicFonts'])} byte-pinned public reference fonts; no system font bytes copied")
