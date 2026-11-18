#!/usr/bin/env python3
"""Compile the actual tiny reuse helper only; no font/model/native-CV/app build."""
import hashlib
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeAcceptedSourceWeightInference.swift'
TEST = Path(__file__).with_name('NativeSourceWeightOrderedReuseSmoke.swift')
CACHE = ROOT/'build/source-weight-ordered-reuse-smoke'
CACHE.mkdir(parents=True,exist_ok=True)
source = SOURCE.read_text()
helper = source.split('/// Source-only operational consumer',1)[0].replace('import CryptoKit\n','')
assert 'enum NativeSourceWeightOrderedObservationReuse' in helper
assert 'class NativeAcceptedSourceWeightInference' not in helper
assert source.index('nominal[index] = .init') < source.index('measured["expectedGlyphCounts"]')
assert 'requestID: requestID, nominal: &nominalOrdered' in source
assert 'binding: nominalBinding(context, i, candidate, requestID), factor: factor, ordered: true' in source
assert 'refineScale(context, styles, predictions, requestID: requestID, nominalOrdered: nominalOrdered)' in source
HELPER = CACHE/'ProductionReuseHelper.swift'
BINARY = CACHE/'smoke'
STAMP = CACHE/'fingerprint'
fingerprint = hashlib.sha256(source.encode()+TEST.read_bytes()+b'swift6-strict-O-v1').hexdigest()
compile_seconds = 0
if not BINARY.exists() or not STAMP.exists() or STAMP.read_text().strip()!=fingerprint:
    HELPER.write_text(helper)
    started = time.monotonic()
    subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-warnings-as-errors',
                    '-module-cache-path',str(CACHE/'module-cache'),str(HELPER),str(TEST),'-o',str(BINARY)],check=True)
    compile_seconds = time.monotonic()-started
    STAMP.write_text(fingerprint+'\n')
started = time.monotonic()
result = subprocess.run([str(BINARY)],check=True,capture_output=True,text=True)
print(result.stdout,end='')
print(json.dumps(dict(private_helper_compile_seconds=compile_seconds,test_seconds=time.monotonic()-started,
                      fingerprint=fingerprint,real_model_font_extractions=0,main_builds=0,API_calls=0)))
