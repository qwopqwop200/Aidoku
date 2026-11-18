import subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
BASE=ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble'
NAMES=['SourceNativeInput','NativeAppearanceForest','NativeFrozenSourceModel','NativeFrozenTensor','NativeAppearanceNumeric',
'NativeAppearanceImageOperations','NativeOpenCVImageOperations','NativeAppearancePhysicalImage','NativeAppearanceSourceFeatures209',
'NativeAppearancePixelFeatures71','NativeAppearanceEuclideanDistance','NativeAppearanceModelHeads','NativeAppearanceNestedOutline','NativeAppearanceNormalProfiles']
SOURCES=[BASE/(x+'.swift') for x in NAMES]+sorted(BASE.glob('NativeAppearanceLateGradient*.swift'))+[Path(__file__).parent/'FeatureContextShim.swift']
if __name__=='__main__':
 import sys
 sdk=sys.argv[1] if len(sys.argv)>1 else 'macosx'
 target={'macosx':'arm64-apple-macos13.0','iphoneos':'arm64-apple-ios15.0','iphonesimulator':'arm64-apple-ios15.0-simulator'}[sdk]
 sdkpath=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
 subprocess.run(['xcrun','--sdk',sdk,'swiftc','-typecheck','-target',target,'-sdk',sdkpath,'-Xcc','-fmodule-map-file='+str(ROOT/'Vendor/NativeSourceCV/include/module.modulemap'),*map(str,SOURCES)],check=True)
