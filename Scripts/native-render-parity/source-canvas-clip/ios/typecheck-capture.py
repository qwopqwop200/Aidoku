#!/usr/bin/env python3
"""Typecheck the real iOS capture helper with verbatim production paint transport.
Does not build/launch Aidoku or use a simulator. Runtime proof is the parent's
serialized actual-iOS suite; isolated SDK typechecking is not runtime evidence.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess
root = Path(__file__).resolve().parents[4]
overlay = root / 'Aidoku/Core/Translation/NativeEngine/Overlay'
parser = argparse.ArgumentParser()
parser.add_argument('--helper', type=Path, default=root / 'AidokuTests/Translation/NativeSourceCanvasPaintParityCapture.swift')
helper = parser.parse_args().helper.resolve()
out = root / 'build/native-render-parity/source-canvas-clip/ios-sdk-check' / helper.stem
out.mkdir(parents=True, exist_ok=True)
def block(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    i = brace + 1
    while depth:
        depth += (source[i] == '{') - (source[i] == '}')
        i += 1
    return source[start:i]
renderer = (overlay / 'NativeTranslationRenderer.swift').read_text()
paint = (overlay / 'NativeTranslationRenderer+PaintOrder.swift').read_text()
transport = 'import UIKit\nimport Foundation\nenum NativeTranslationRenderer {\n' + '\n'.join([
    block(renderer, '    struct SourcePatch:'),
    block(renderer, '    static func usedRect('),
    block(paint, '    static func drawSourcePatch(')]) + '\n}\n'
(out / 'Transport.swift').write_text(transport)
(out / helper.name).write_text(helper.read_text().replace('@testable import Aidoku\n', ''))
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
framework = developer / 'Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks'
macro = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
inputs = [out / 'Transport.swift', overlay / 'NativeSourceCanvasClip.swift', overlay / 'NativeSourceCanvasImageFrame.swift',
          overlay / 'NativeTranslationPDFCapture.swift', overlay / 'NativeCanvasBacking.swift',
          overlay / 'NativeTranslationRenderer+AffineCanvas.swift', out / helper.name]
resampler = overlay / 'NativeCanvasTextureResampler.swift'
if resampler.exists():
    inputs.insert(-1, resampler)
command = ['xcrun', 'swiftc', '-typecheck', '-swift-version', '6', '-strict-concurrency=complete',
           '-sdk', sdk, '-target', 'arm64-apple-ios18.0-simulator', '-F', str(framework),
           '-load-plugin-library', str(macro), *map(str, inputs)]
result = subprocess.run(command, text=True, capture_output=True, cwd=root)
(out / 'typecheck.log').write_text(result.stdout + result.stderr)
# Keep the six base fixtures exactly equal to the independent macWK controls.
src = helper.read_text()
controls_equal = None
if '    private static let originalInputs = #"""' in src:
    start = src.index('    private static let originalInputs = #"""')
    inline = src[start:].split('#"""', 1)[1].split('"""#', 1)[0]
    reference = root / 'Scripts/native-render-parity/source-canvas-clip/inputs.json'
    fixture_by_id = {f['id']: f for f in json.loads(reference.read_text())}
    controls = json.loads(inline)
    controls_equal = controls == [fixture_by_id[f['id']] for f in controls]
report = {'typecheckPassed': result.returncode == 0, 'originalSixInputsEqual': controls_equal,
          'scope': 'iOS SDK compile only; actual WK pixel captures pending root suite',
          'helperPath': str(helper), 'helperSHA256': hashlib.sha256(helper.read_bytes()).hexdigest(),
          'includedTextureResampler': resampler.exists(),
          'actualProductionSources': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                                      for p in (overlay / 'NativeTranslationRenderer.swift',
                                                overlay / 'NativeTranslationRenderer+PaintOrder.swift',
                                                overlay / 'NativeSourceCanvasClip.swift',
                                                overlay / 'NativeTranslationPDFCapture.swift',
                                                overlay / 'NativeSourceCanvasImageFrame.swift',
                                                overlay / 'NativeCanvasBacking.swift',
                                                overlay / 'NativeTranslationRenderer+AffineCanvas.swift',
                                                overlay / 'NativeCanvasTextureResampler.swift') if p.exists()}}
(out / 'report.json').write_text(json.dumps(report, indent=2))
print(result.stdout + result.stderr)
print(json.dumps(report, indent=2))
raise SystemExit(0 if result.returncode == 0 and controls_equal is not False else 1)
