#!/usr/bin/env python3
"""Actual numeric provider + mock model constructors; no app/CoreML/data inference."""
import hashlib
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT/'build/raw-required-head-provider-smoke'
SOURCES = [ROOT/'Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRRawGeometryModelBundle.swift',
           Path(__file__).with_name('NativeOCRRawRequiredHeadProviderSmoke.swift')]
CACHE.mkdir(parents=True,exist_ok=True)
BINARY = CACHE/'smoke'
STAMP = CACHE/'fingerprint'
fingerprint = hashlib.sha256(b''.join(p.read_bytes() for p in SOURCES)+b'swift6-strict-O-v1').hexdigest()
compile_seconds = 0
if not BINARY.is_file() or not STAMP.is_file() or STAMP.read_text().strip()!=fingerprint:
    started = time.monotonic()
    subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',
                    '-warnings-as-errors','-module-cache-path',str(CACHE/'module-cache'),
                    *map(str,SOURCES),'-o',str(BINARY)],check=True)
    compile_seconds = time.monotonic()-started
    STAMP.write_text(fingerprint+'\n')
started = time.monotonic()
result = subprocess.run([str(BINARY)],check=True,capture_output=True,text=True)
print(result.stdout,end='')
print(json.dumps(dict(private_mock_compile_seconds=compile_seconds,test_seconds=time.monotonic()-started,
                      fingerprint=fingerprint,app_builds=0,model_inference=0,API_calls=0)))
