#!/usr/bin/env python3
"""Compile the current production pure predictor, not an experiment copy."""
import hashlib
import argparse
import json
from pathlib import Path
import subprocess
import time

REPO = Path(__file__).resolve().parents[2]


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--source',type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    production=REPO/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationRenderer+TextBoxes.swift'
    original = args.source or production
    fixture = REPO/'Scripts/tests/NativeOwnerExteriorBudgetSmoke.swift'
    text = original.read_text()
    start = text.index('enum NativeOwnerExteriorBGPrediction {')
    predictor = 'import Foundation\nimport CoreGraphics\n'+text[start:]
    output = args.output or REPO/'build/owner-exterior-budget-smoke'; output.mkdir(exist_ok=True,parents=True)
    generated = output/'ProductionOwnerExterior.swift'
    if not generated.exists() or generated.read_text() != predictor:
        generated.write_text(predictor)
    fingerprint = hashlib.sha256(predictor.encode()+fixture.read_bytes()).hexdigest()
    stamp = output/'fingerprint'; binary = output/'smoke'; build_seconds = 0
    if not stamp.exists() or stamp.read_text()!=fingerprint or not binary.exists():
        began = time.monotonic()
        subprocess.run(['xcrun','swiftc','-parse-as-library','-O',str(generated),str(fixture),'-o',str(binary)],check=True)
        build_seconds = time.monotonic()-began; stamp.write_text(fingerprint)
    began = time.monotonic(); result = subprocess.run([str(binary)],capture_output=True,text=True)
    (output/'last.stderr').write_text(result.stderr)
    if result.returncode:raise RuntimeError('Native source regression failed; preserved last.stderr')
    report = json.loads(result.stdout)
    if report['knownRGBQueries'] <= 0:raise RuntimeError('No known RGB checks executed')
    report.update(buildSeconds=build_seconds,testSeconds=time.monotonic()-began,
        productionSourceSHA256=hashlib.sha256(original.read_bytes()).hexdigest(),
        authority='authored flat source RGB and malformed geometry controls, not actual-page RGB accuracy',phoneMeasured=False,
        productionSourceTested=original.resolve()==production.resolve())
    (output/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))


if __name__=='__main__':main()
