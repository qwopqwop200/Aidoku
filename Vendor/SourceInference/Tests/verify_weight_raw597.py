#!/usr/bin/env python3
"""Private host raw-only/generic/Python parity; no models, GT or shared builds."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'Scripts/tests/source-weight-numeric'))
from parity import cases, weight, default_font_paths
import numpy as np


def run(output):
    vendor = ROOT / 'Vendor/NativeSourceCV'
    source = ROOT / 'Vendor/SourceInference'
    fonts = default_font_paths()
    spec = dict(fonts=fonts, extendedFonts=fonts + fonts, nativeFonts=fonts)
    packets = []
    expected = []
    for index, (name, rgb, _, prior, _, own) in enumerate(cases()):
        h, w = rgb.shape[:2]
        bbox = [2.1, 2.3, w - 4.2, h - 4.6] if min(h, w) > 40 and index % 2 else [0, 0, w, h]
        text = ['日あA', 'か\u3099 Ａ\n日', '', 'A\u0301\tあ\u200d'][index % 4]
        style = {'fill': {'rgb': [24, 80, 210]}, 'background': {'rgb': [240, 230, 220]},
                 'outline': {'present': True, 'widthPx': 1.7, 'rgb': [0, 0, 0]}}
        reference = weight.measure(rgb, bbox, prior, text)
        for ownership in (own, np.ones((h, w), np.uint8)):
            expected.append(reference)
            packets.append(dict(width=w, height=h, rgb=base64.b64encode(rgb.tobytes()).decode(),
                ownership=base64.b64encode((ownership * (255 if index % 2 else 1)).tobytes()).decode(),
                bbox=bbox, prior=prior, text=text, sourceEm=prior * 1.37, style=style,
                measurementSpec=spec, native156=[999.] * 156))
    with tempfile.TemporaryDirectory(prefix='aidoku-raw597-bridge-') as folder:
        folder = Path(folder)
        binary = folder / 'check'
        files = [source / 'Tests/FontWeightRaw597Main.mm', source / 'FontWeightFeatures.mm',
                 source / 'FontTemplateFeatures.mm', source / 'FontWeightPhysical.mm',
                 source / 'FontWeightBands.mm', source / 'FontWeightBandSource.mm',
                 source / 'Sources/SourceCoreFeatures.cpp', source / 'Sources/SourceWeightFeatures.cpp',
                 vendor / 'NativeSourceCV.cpp']
        cmd = ['xcrun', 'clang++', '-std=c++17', '-O2', '-fobjc-arc',
               '-I' + str(vendor / 'include'), '-I' + str(vendor / 'freetype/include'), *map(str, files),
               str(vendor / 'opencv2.xcframework/macos-arm64/libopencv2.a'),
               str(vendor / 'FreeType.xcframework/macos-arm64/libfreetype.a'), '-lz']
        for framework in ['Foundation', 'CoreText', 'CoreGraphics', 'Accelerate', 'CoreVideo', 'AVFoundation', 'CoreMedia', 'OpenCL']:
            cmd += ['-framework', framework]
        start = time.monotonic()
        subprocess.run(cmd + ['-o', str(binary)], check=True)
        build_seconds = time.monotonic() - start
        inp, out = folder / 'input.json', folder / 'output.json'
        inp.write_text(json.dumps(packets))
        start = time.monotonic()
        subprocess.run([str(binary), str(inp), str(out)], check=True)
        runtime_seconds = time.monotonic() - start
        actual = json.loads(out.read_text())
        error = 0.
        for i, (reference, result) in enumerate(zip(expected, actual)):
            raw = np.asarray(result['raw597'], np.float64)
            assert raw.shape == (597,) and np.isfinite(raw).all() and (raw[:6] == 0).all()
            error = max(error, float(np.max(abs(raw - reference))))
            np.testing.assert_allclose(raw, reference, atol=1e-7, rtol=1e-7)
            if i % 2:
                assert result == actual[i - 1], 'raw597 must not depend on actual ownership'
        assert len(actual) == len(expected)
    report = dict(schema='dedicated-raw597-required-admission-and-numeric-parity-v1', cases=len(actual),
        genericRaw597Exact=True, maximumPythonAbsoluteDifference=error, requiredRejectionParityControlsPerCase=22,
        validSourceEmStyleInvarianceControlsPerCase=2, validOwnershipInvariancePairs=len(actual)//2,
        pinnedFontIdentityRejectionControls=2,
        unsupportedOptionalRejectionsPerCase=4, isolatedBuildSeconds=build_seconds, nativeSeconds=runtime_seconds,
        hostOnly=True, coreNNCalls=0, modelLoads=0, sharedBuilds=0,
        genericPathChanged=False, fontAdmission='unchanged pinned4/8/4; only baseline4 numerically rasterized')
    if output:
        if output.exists(): raise FileExistsError(output)
        output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    run(args.output)
