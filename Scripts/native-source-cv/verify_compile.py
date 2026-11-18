#!/usr/bin/env python3
"""Focused SDK compile/link checks only; no app build, clean, or shared caches."""
import json
import os
from pathlib import Path
import subprocess
import time

ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-source-cv-downloads'

def run(args,log,env=None):
    start=time.monotonic()
    with log.open('w') as output:
        subprocess.run(list(map(str,args)),cwd=ROOT,stdout=output,stderr=subprocess.STDOUT,env=env,check=True)
    return round(time.monotonic()-start,3)

if __name__=='__main__':
    OUT.mkdir(parents=True,exist_ok=True)
    report={}
    sources=[ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble'/name for name in
        ['NativeAppearanceImageOperations.swift','NativeOpenCVImageOperations.swift','NativeSourceFontResolver.swift']]
    for name,sdk,target in [('host','macosx','arm64-apple-macos13.0'),('device','iphoneos','arm64-apple-ios15.0'),
                            ('simulator','iphonesimulator','arm64-apple-ios15.0-simulator')]:
        directory=ROOT/('build/native-source-cv-host' if name=='host' else 'build/native-source-cv-check-'+name)
        env=dict(os.environ,PLATFORM_NAME=sdk,ARCHS='arm64',DERIVED_FILE_DIR=str(directory))
        result={}
        result['incrementalCompileSeconds']=run(['python3',HERE/'build.py'],OUT/(name+'-compile.log'),env)
        sdkpath=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
        result['swiftTypecheckSeconds']=run(['xcrun','--sdk',sdk,'swiftc','-typecheck','-target',target,'-sdk',sdkpath,
            '-Xcc','-fmodule-map-file='+str(ROOT/'Vendor/NativeSourceCV/include/module.modulemap'),*sources,HERE/'CompileCheck.swift'],
            OUT/(name+'-swift-final.log'))
        result['linkSeconds']=run(['xcrun','--sdk',sdk,'clang++','-target',target,'-isysroot',sdkpath,'-std=c++17','-fobjc-arc',
            '-I'+str(ROOT/'Vendor/NativeSourceCV/include'),HERE/'CompileCheck.mm','-L'+str(directory),
            '-lAidokuSourceCV','-lAidokuOpenCV','-lAidokuFreeType','-lz','-lc++',
            '-framework','Foundation','-framework','CoreText','-framework','CoreGraphics','-framework','Accelerate',
            '-o',OUT/('link-'+name)],OUT/(name+'-link.log'))
        if name=='host':
            run([OUT/('link-'+name)],OUT/'host-error-path.log');result['errorPathSmoke']='passed'
        report[name]=result
    (OUT/'final-check-results.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
