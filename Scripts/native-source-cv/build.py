#!/usr/bin/env python3
"""Incremental native bridge/feature archive for Xcode or macOS MAIN.

No downloads at app build time; bootstrap.py explicitly provisions dependencies.
Print JSON via --print-link-info for isolated host executables.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

ROOT=Path(__file__).resolve().parents[2]
VENDOR=ROOT/'Vendor/NativeSourceCV'

def build(environment=None, primitives_only=False, core_only=False):
    env=dict(os.environ if environment is None else environment)
    sdk=env.get('PLATFORM_NAME','macosx')
    archs=env.get('ARCHS',platform.machine() if sdk=='macosx' else 'arm64').split()
    out=Path(env.get('DERIVED_FILE_DIR',str(ROOT/'build/native-source-cv-host')))
    out.mkdir(parents=True,exist_ok=True)
    minimum=env.get('MACOSX_DEPLOYMENT_TARGET','13.0') if sdk=='macosx' else env.get('IPHONEOS_DEPLOYMENT_TARGET','15.0')
    sdkpath=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
    compiler=subprocess.check_output(['xcrun','--sdk',sdk,'--find','clang++'],text=True).strip()
    version=subprocess.check_output([compiler,'--version'])
    sources=[VENDOR/'NativeSourceCV.cpp']
    if not primitives_only:
        sources+=[VENDOR/'SourceFeatureBridge.mm']
        feature=ROOT/'Vendor/SourceInference'
        sources+=sorted(p for p in (feature/'Sources' if core_only else feature).rglob('*') if p.suffix in ('.cpp','.mm') and not any(x in p.relative_to(feature).parts for x in ('build','.build','Tests','tests')))
    headers=sorted(p for base in [VENDOR/'include',ROOT/'Vendor/SourceInference'] if base.exists() for p in base.rglob('*') if p.suffix in ('.h','.hpp'))
    headers+=[VENDOR/'freetype/include/ft2build.h']
    all_archives=[]
    with (out/'.source-cv.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        for arch in archs:
            key=('macos-'+arch) if sdk=='macosx' else ('ios-'+arch+('-simulator' if sdk=='iphonesimulator' else ''))
            opencv=VENDOR/'opencv2.xcframework'/key/'libopencv2.a'
            freetype=VENDOR/'FreeType.xcframework'/key/'libfreetype.a'
            if not opencv.exists() or not freetype.exists():
                raise RuntimeError(f'Missing {key} dependencies; run python3 Scripts/native-source-cv/bootstrap.py --platform {key}')
            b=out/key;b.mkdir(exist_ok=True)
            target=arch+'-apple-'+('macos'+minimum if sdk=='macosx' else 'ios'+minimum+('-simulator' if sdk=='iphonesimulator' else ''))
            flags=['-target',target,'-isysroot',sdkpath,'-std=c++17','-O2','-fvisibility=hidden','-fPIC',
                   '-I'+str(VENDOR/'include'),'-I'+str(VENDOR/'freetype/include'),'-I'+str(ROOT/'Vendor/SourceInference')]
            objects=[]
            header_digest=hashlib.sha256(b''.join(h.read_bytes() for h in headers)).digest()
            for source in sources:
                obj=b/(source.stem+'-'+hashlib.sha256(str(source).encode()).hexdigest()[:8]+'.o')
                fp=obj.with_suffix('.sha256')
                extra=['-fobjc-arc'] if source.suffix=='.mm' else []
                digest=hashlib.sha256(source.read_bytes()+header_digest+version+'\0'.join(flags+extra).encode()).hexdigest()
                if not obj.exists() or not fp.exists() or fp.read_text()!=digest:
                    subprocess.run([compiler,*flags,*extra,'-c',str(source),'-o',str(obj)],check=True)
                    fp.write_text(digest)
                    print(f'Compiled {key}: {source.relative_to(ROOT)}',flush=True)
                objects.append(obj)
            library=b/('libAidokuSourceCVPrimitives.a' if primitives_only else 'libAidokuSourceCV.a')
            digest=hashlib.sha256(b''.join(o.read_bytes() for o in objects)).hexdigest()
            fp=library.with_suffix('.sha256')
            if not library.exists() or not fp.exists() or fp.read_text()!=digest:
                subprocess.run(['xcrun','libtool','-static','-o',str(library),*map(str,objects)],check=True)
                fp.write_text(digest)
            # Keep dependencies separate for small incremental archive replacements.
            for src,name in [(opencv,'libAidokuOpenCV.a'),(freetype,'libAidokuFreeType.a')]:
                link=out/name
                if len(archs)==1:
                    if link.is_symlink() and link.resolve()==src.resolve():continue
                    if link.exists() or link.is_symlink():link.unlink()
                    link.symlink_to(src)
            all_archives.append(library)
        combined=out/('libAidokuSourceCVPrimitives.a' if primitives_only else 'libAidokuSourceCV.a')
        digest=hashlib.sha256(b''.join(p.read_bytes() for p in all_archives)).hexdigest();fp=combined.with_suffix('.sha256')
        if not combined.exists() or not fp.exists() or fp.read_text()!=digest:
            subprocess.run(['xcrun','lipo','-create',*map(str,all_archives),'-output',str(combined)],check=True);fp.write_text(digest)
        if len(archs)>1:
            for sub,name in [('opencv2.xcframework','libAidokuOpenCV.a'),('FreeType.xcframework','libAidokuFreeType.a')]:
                inputs=[]
                for arch in archs:
                    key='macos-'+arch if sdk=='macosx' else 'ios-'+arch+('-simulator' if sdk=='iphonesimulator' else '')
                    inputs.append(VENDOR/sub/key/('libopencv2.a' if sub.startswith('opencv') else 'libfreetype.a'))
                dest=out/name
                if dest.is_symlink():dest.unlink()
                subprocess.run(['xcrun','lipo','-create',*map(str,inputs),'-output',str(dest)],check=True)
    return {'library':str(combined),'include':str(VENDOR/'include'),'librarySearchPath':str(out),
            'linkFlags':['-L'+str(out),'-lAidokuSourceCVPrimitives' if primitives_only else '-lAidokuSourceCV',
                         '-lAidokuOpenCV','-lAidokuFreeType','-lc++','-lz','-framework','Foundation','-framework','CoreText',
                         '-framework','Accelerate','-framework','CoreGraphics']}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--primitives-only',action='store_true');p.add_argument('--core-only',action='store_true');p.add_argument('--print-link-info',action='store_true')
    a=p.parse_args();info=build(primitives_only=a.primitives_only,core_only=a.core_only)
    if a.print_link_info:print(json.dumps(info))
