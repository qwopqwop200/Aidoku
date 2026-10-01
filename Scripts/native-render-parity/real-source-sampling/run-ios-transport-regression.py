#!/usr/bin/env python3
"""Run the actual production reader on an explicitly selected existing simulator.

This source-only probe uses swiftc/simctl spawn, never Xcode or a new simulator.
Coordinate simulator ownership before invocation. Inputs are a prepared PNG and
bounded captured Canvas JSON; no whole-page WebKit read is performed here.
"""
import argparse,hashlib,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--device',required=True)
 p.add_argument('--prepared-source',type=Path,required=True)
 p.add_argument('--capture',type=Path,required=True)
 p.add_argument('--output',type=Path,required=True)
 a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
 source=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeSourceColorSamplingStage.swift'
 raw=source.read_bytes();text=raw.decode();reader=out/'NativeSourcePixelReader.swift'
 reader.write_text('import Foundation\nimport CoreGraphics\n'+text[text.index('final class NativeSourcePixelReader'):])
 sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
 binary=out/'reader-regression';target='arm64-apple-ios26.5-simulator'
 subprocess.run(['xcrun','swiftc','-sdk',sdk,'-target',target,'-swift-version','6','-parse-as-library',str(reader),str(HERE/'TransportRegression.swift'),'-o',str(binary)],check=True)
 report=out/'report.json'
 subprocess.run(['xcrun','simctl','spawn',a.device,str(binary),str(a.prepared_source.resolve()),str(a.capture.resolve()),str(report)],check=True)
 metadata={'productionReaderSHA256':hashlib.sha256(raw).hexdigest(),'preparedSourceSHA256':hashlib.sha256(a.prepared_source.read_bytes()).hexdigest(),'captureSHA256':hashlib.sha256(a.capture.read_bytes()).hexdigest(),'target':target,'sdk':sdk,'policySources':[
 'https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/cg/GraphicsContextCG.cpp',
 'https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/FloatRect.cpp'],
 'policy':'WebKit uniform reductions retain the full texture; the iOS branch aligns adjusted destination rect to device pixels. Identity Canvas transform roundedIntRect rounds origin and SIZE separately. Exact observed installed simulator output corroborates this branch.'}
 (out/'sources.json').write_text(json.dumps(metadata,indent=2));return 0
if __name__=='__main__':raise SystemExit(main())
