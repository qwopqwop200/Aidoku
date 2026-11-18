#!/usr/bin/env python3
"""Acquire official OpenCV slices; build only missing Apple slices + pinned FT.

Native dependencies only. Never touches app DerivedData or invokes an app build.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / 'Vendor/NativeSourceCV'
CACHE = ROOT / 'build/native-source-cv-downloads'
SHA256 = {'opencv-4.11.0.zip': '1e83edcd3e482228f5c2348a7ceafd72efd614b6578e68f610cd0898c6df95d1', 'opencv-source.tar.gz': '9a7c11f924eff5f8d8070e297b322ee68b9227e003fd600d4b8122198091665f', 'freetype.tar.gz': 'dc49de6b01a266eef4876a4dd34d9842c475d3e28ff2eff63bd2fb760ab56261'}

SPECS = {
    'ios-arm64': ('iphoneos', 'arm64', 'iOS', '15.0', None),
    'ios-x86_64-simulator': ('iphonesimulator', 'x86_64', 'iOS', '15.0', 'simulator'),
    'ios-arm64-simulator': ('iphonesimulator', 'arm64', 'iOS', '15.0', 'simulator'),
    'macos-arm64': ('macosx', 'arm64', 'Darwin', '13.0', None),
}

def run(args):
    subprocess.run(list(map(str,args)), check=True)

def acquire(platforms):
    CACHE.mkdir(parents=True, exist_ok=True)
    urls = {
        'opencv-4.11.0.zip': 'https://github.com/opencv/opencv/releases/download/4.11.0/opencv-4.11.0-ios-framework.zip',
        'opencv-source.tar.gz': 'https://github.com/opencv/opencv/archive/refs/tags/4.11.0.tar.gz',
        'freetype.tar.gz': 'https://github.com/freetype/freetype/archive/refs/tags/VER-2-14-3.tar.gz',
    }
    receipts = {}
    for name,url in urls.items():
        p=CACHE/name
        if not p.exists():
            temp=p.with_suffix('.pending')
            urllib.request.urlretrieve(url,temp); temp.replace(p)
        digest=hashlib.sha256(p.read_bytes()).hexdigest()
        if digest!=SHA256[name]:raise RuntimeError('Pinned dependency SHA256 mismatch: '+name)
        receipts[name]={'url':url,'sha256':digest,'bytes':p.stat().st_size}
    (VENDOR/'PROVENANCE.json').write_text(json.dumps(receipts,indent=2)+'\n')
    source=CACHE/'opencv-4.11.0'
    # macOS bsdtar has path and symlink protection by default. The system
    # Python on supported Xcode installations may predate tarfile filters.
    if not source.exists():
        run(['/usr/bin/tar', '-xf', CACHE/'opencv-source.tar.gz', '-C', CACHE])
    if not (VENDOR/'freetype').exists():
        run(['/usr/bin/tar', '-xf', CACHE/'freetype.tar.gz', '-C', CACHE])
        (CACHE/'freetype-VER-2-14-3').rename(VENDOR/'freetype')
    # ditto preserves framework symlinks; Python ZipFile.extract does not.
    framework=CACHE/'official/opencv2.framework'
    needs_official = not (VENDOR/'include/opencv2').exists() or any(
        key in ('ios-arm64','ios-x86_64-simulator') and not (VENDOR/'opencv2.xcframework'/key/'libopencv2.a').exists() for key in platforms)
    if needs_official and not framework.exists():
        (CACHE/'official').mkdir(exist_ok=True)
        run(['/usr/bin/ditto','-x','-k',CACHE/'opencv-4.11.0.zip',CACHE/'official'])
    headers=VENDOR/'include/opencv2'
    if not headers.exists():shutil.copytree(framework/'Headers',headers,symlinks=True)
    (VENDOR/'licenses').mkdir(exist_ok=True)
    for src,name in [(source/'LICENSE','OpenCV-LICENSE'),(VENDOR/'freetype/docs/FTL.TXT','FreeType-FTL.TXT'),(VENDOR/'freetype/docs/GPLv2.TXT','FreeType-GPLv2.TXT')]:
        shutil.copyfile(src,VENDOR/'licenses'/name)
    # Preserve OpenCV's actual bundled third-party notices for the official archive.
    if (source/'3rdparty').exists() and not (VENDOR/'licenses/opencv-third-party').exists():
        out=VENDOR/'licenses/opencv-third-party'
        for p in (source/'3rdparty').rglob('*'):
            if p.is_file() and any(s in p.name.lower() for s in ('license','copying','copyright','notice')):
                dest=out/p.relative_to(source/'3rdparty');dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
    return source,framework

def write_manifest(base,name):
    libs=[]
    for key, (sdk,arch,system,minimum,variant) in SPECS.items():
        if not (base/key/name).exists():continue
        d={'LibraryIdentifier':key,'LibraryPath':name,'HeadersPath':'Headers','SupportedArchitectures':[arch],
           'SupportedPlatform':'macos' if sdk=='macosx' else 'ios'}
        if variant:d['SupportedPlatformVariant']=variant
        libs.append(d)
    (base/'Info.plist').write_bytes(plistlib.dumps({'CFBundlePackageType':'XFWK','XCFrameworkFormatVersion':'1.0','AvailableLibraries':libs}))

def build(key,source,framework,jobs):
    sdk,arch,system,minimum,variant=SPECS[key]
    sdkpath=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
    common=['-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=OFF','-DCMAKE_OSX_ARCHITECTURES='+arch,
            '-DCMAKE_OSX_SYSROOT='+sdkpath,'-DCMAKE_OSX_DEPLOYMENT_TARGET='+minimum,
            '-DCMAKE_SYSTEM_NAME='+system,'-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY']
    out=VENDOR/'opencv2.xcframework'/key
    out.mkdir(parents=True,exist_ok=True)
    library=out/'libopencv2.a'
    if not library.exists():
        if key in ('ios-arm64','ios-x86_64-simulator'):
            run(['xcrun','lipo',framework/'opencv2','-thin',arch,'-output',library])
        else:
            b=ROOT/'build/native-source-cv-dependencies'/key/'opencv'
            flags=['-DBUILD_LIST=core,imgproc,objdetect','-DBUILD_opencv_dnn=OFF','-DBUILD_opencv_apps=OFF',
                '-DBUILD_TESTS=OFF','-DBUILD_PERF_TESTS=OFF','-DBUILD_EXAMPLES=OFF','-DBUILD_JAVA=OFF',
                '-DBUILD_opencv_python2=OFF','-DBUILD_opencv_python3=OFF','-DBUILD_opencv_objc=OFF',
                '-DWITH_OPENCL=OFF','-DWITH_IPP=OFF','-DWITH_ITT=OFF','-DWITH_PROTOBUF=OFF','-DWITH_QUIRC=OFF',
                '-DWITH_FFMPEG=OFF','-DWITH_AVFOUNDATION=OFF','-DWITH_CAP_IOS=OFF','-DWITH_VIDEOTOOLBOX=OFF',
                '-DWITH_EIGEN=OFF','-DBUILD_ZLIB=OFF','-DWITH_LAPACK=OFF','-DBUILD_DOCS=OFF','-DBUILD_opencv_world=OFF']
            run(['cmake','-S',source,'-B',b,*common,*flags])
            run(['cmake','--build',b,'--parallel',str(jobs)])
            archives=sorted((b/'lib').glob('libopencv_*.a'))
            if not archives:raise RuntimeError('No OpenCV static libraries generated')
            run(['xcrun','libtool','-static','-o',library,*archives])
    hdr=out/'Headers'
    if not hdr.exists():hdr.symlink_to('../../include',target_is_directory=True)
    write_manifest(VENDOR/'opencv2.xcframework','libopencv2.a')
    ftout=VENDOR/'FreeType.xcframework'/key
    ftout.mkdir(parents=True,exist_ok=True)
    if not (ftout/'libfreetype.a').exists():
        b=ROOT/'build/native-source-cv-dependencies'/key/'freetype'
        flags=['-DFT_DISABLE_ZLIB=TRUE','-DFT_DISABLE_BZIP2=TRUE','-DFT_DISABLE_PNG=TRUE',
               '-DFT_DISABLE_HARFBUZZ=TRUE','-DFT_DISABLE_BROTLI=TRUE']
        run(['cmake','-S',VENDOR/'freetype','-B',b,*common,*flags])
        run(['cmake','--build',b,'--parallel',str(jobs)])
        shutil.copyfile(b/'libfreetype.a',ftout/'libfreetype.a')
    if not (ftout/'Headers').exists():(ftout/'Headers').symlink_to('../../freetype/include',target_is_directory=True)
    write_manifest(VENDOR/'FreeType.xcframework','libfreetype.a')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--platform',action='append',choices=list(SPECS));p.add_argument('--jobs',type=int,default=2)
    args=p.parse_args();platforms=args.platform or list(SPECS);source,framework=acquire(platforms)
    for key in platforms:build(key,source,framework,args.jobs)
    if framework.exists():shutil.rmtree(framework.parent)
