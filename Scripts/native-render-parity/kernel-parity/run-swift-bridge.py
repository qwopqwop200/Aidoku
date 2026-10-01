#!/usr/bin/env python3
"""Run the app's actual Swift bridge test source against frozen WASM on the macOS host.

The sole host adaptations remove the app import and replace test-bundle resource
lookup with the same checked-in compressed fixture path. iOS runs use the
unchanged app-hosted test source and bundle lookup.
"""
import argparse
import json
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/native-render-parity/swift-kernel-bridge')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = ROOT / 'AidokuTests/Translation/NativeEngine/NativeTranslationPixelKernelBridgeTests.swift'
    resource = source.parent / 'Fixtures/native-kernel-bridge-fixtures.json.deflate'
    code = source.read_text().replace('@testable import Aidoku\n', '')
    start = code.index('        let bundle = Bundle(for: NativeKernelFixtureBundle.self)')
    end = code.index('        let compressed = try Data(contentsOf: url)', start)
    code = code[:start] + f'        let url = URL(fileURLWithPath: {json.dumps(str(resource))})\n' + code[end:]
    code += '\n@main struct HostBridgeTests { static func main() async { let status: CInt = await Testing.__swiftPMEntryPoint(); exit(status) } }\n'
    adapted_source = output / 'HostBridgeTests.swift'
    adapted_source.write_text(code)
    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    frameworks = developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
    macro = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
    executable = output / 'swift-bridge-tests'
    build_started = time.monotonic()
    native_output = output / 'native'
    subprocess.run(['python3', str(ROOT / 'Scripts/overlay-kernels/native/build.py')], check=True, cwd=ROOT,
                   env=dict(os.environ, PLATFORM_NAME='macosx', ARCHS='arm64', DERIVED_FILE_DIR=str(native_output)))
    subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-strict-concurrency=complete',
                    '-F', str(frameworks), '-load-plugin-library', str(macro),
                    '-I', str(ROOT / 'Scripts/overlay-kernels/native'),
                    str(ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationPixelKernels.swift'),
                    str(adapted_source), str(native_output / 'libAidokuOverlayKernels.a'),
                    '-Xlinker', '-rpath', '-Xlinker', str(frameworks), '-o', str(executable)], check=True, cwd=ROOT)
    build_seconds = time.monotonic() - build_started
    started = time.monotonic()
    result = subprocess.run([str(executable)], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / 'tests.log').write_text(result.stdout)
    print(result.stdout, end='')
    passed = result.returncode == 0 and 'Test run with 3 tests' in result.stdout
    report = {'passed': passed, 'platform': 'arm64 macOS Swift-to-C native static link',
              'kernels': 25, 'semanticFixtures': 83, 'tests': 3,
              'buildSeconds': build_seconds, 'testSeconds': time.monotonic() - started,
              'scope': 'All 25 production Swift wrappers, frozen-WASM return values and complete arena bytes including aliases/guards; invalid input and borrowed-buffer guards.',
              'iosAppHostedRun': 'Requires NativeTranslationPixelKernelBridgeTests in the iOS test target.'}
    (output / 'report.json').write_text(json.dumps(report, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
