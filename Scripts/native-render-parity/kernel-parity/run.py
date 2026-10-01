#!/usr/bin/env python3
"""Compare identical native CPU and frozen WebAssembly calls and every output byte."""
import argparse
import base64
import ctypes
import hashlib
import json
import platform
import re
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path
from fixtures import ROOT, SOURCE, fixtures


def command(arguments):
    subprocess.run([str(value) for value in arguments], cwd=ROOT, check=True)


def native_results(library, abi, cases, directory):
    lib = ctypes.CDLL(str(library))
    functions = {}
    for name, definition in abi.items():
        fn = getattr(lib, name)
        fn.argtypes = [ctypes.c_void_p if kind.startswith('*') else ctypes.c_double if kind == 'f64' else ctypes.c_int32
                       for _, kind in definition['parameters']]
        fn.restype = ctypes.c_int32 if definition['returns'] else None
        functions[name] = fn
    directory.mkdir(parents=True, exist_ok=True)
    rows = {}
    for fixture in cases:
        initial = base64.b64decode(fixture['data'])
        arena = ctypes.create_string_buffer(initial, len(initial))
        base = ctypes.addressof(arena)
        returns = [functions[call['name']](*[base + value['pointer'] if isinstance(value, dict) else value for value in call['args']])
                   for call in fixture['calls']]
        output = bytes(arena)
        (directory / (fixture['id'] + '.bin')).write_bytes(output)
        rows[fixture['id']] = {'returns': returns, 'sha256': hashlib.sha256(output).hexdigest(),
                              'changedBytes': sum(a != b for a, b in zip(initial, output))}
    return rows


def read_values(output, buffer, length=16):
    kind = buffer['kind']
    fmt = {'u8': 'B', 'i32': 'i', 'f32': 'f', 'f64': 'd'}[kind]
    count = min(buffer['count'], length)
    return list(struct.unpack_from('<' + fmt * count, output, buffer['offset']))


def semantic_active(fixture, output, returned):
    """Require meaningful processing, including success of restoration rather than only scratch clearing."""
    name = fixture['name']
    buffers = fixture['buffers']
    if name in {'lettering_rays', 'glyph_seed', 'stroke_first', 'bins_inside', 'outlined_components', 'columns_bins', 'columns_range',
                'caption_periodic', 'enclosed_paper', 'exemplar_fill'}:
        return returned is not None and returned > 0
    if name == 'stroke_seed': return read_values(output, buffers['stats'])[1] > 0
    if name == 'caption_mask': return read_values(output, buffers['stats'])[3] > 0
    if name == 'caption_exposed': return read_values(output, buffers['stats'])[0] > 0
    if name == 'local_components': return returned == 1 and read_values(output, buffers['stats'])[0] > 0
    if name == 'harmonic_fill':
        return any(read_values(output, buffers['links'])) and fixture['calls'][-1]['args'][4] > 0
    if name == 'glyph_index': return read_values(output, buffers['start'], 4097)[-1] == 4096
    if name == 'transpose_rgba': return any(read_values(output, buffers['dst']))
    if name == 'pixel_classes': return any(read_values(output, buffers['raw'], 4096))
    if 'out' in buffers: return any(read_values(output, buffers['out']))
    if 'ro' in buffers: return any(read_values(output, buffers['ro']))
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/native-render-parity/kernel-parity')
    parser.add_argument('--rustc', type=Path, default=Path.home() / '.cargo/bin/rustc')
    parser.add_argument('--native-library', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    abi, cases = fixtures()
    assert len(abi) == 25, f'Expected all 25 current kernels, found {len(abi)}'
    native_library = args.native_library.resolve() if args.native_library else output / 'libAidokuOverlayKernels.dylib'
    build_started = time.monotonic()
    if args.native_library is None:
        command([args.rustc, '--target', 'aarch64-apple-darwin', '--crate-type', 'cdylib', '-C', 'opt-level=3',
                 '-C', 'panic=abort', '-C', 'debuginfo=0', '-l', 'System', SOURCE, '-o', native_library])
    # Do not rebuild the oracle from the port: freeze the application's pre-port embedded WASM bytes.
    reference = ROOT / 'Scripts/native-render-parity/reference-source/BrowserSourceTextColor.swift'
    text = reference.read_text()
    block = text.split('// BEGIN aidokuPixelKernelBytes', 1)[1].split('// END aidokuPixelKernelBytes', 1)[0]
    wasm = base64.b64decode(''.join(re.findall(r"'([A-Za-z0-9+/=]*)'", block)))
    wasm_file = output / 'frozen-browser-kernels.wasm'
    wasm_file.write_bytes(wasm)
    build_seconds = time.monotonic() - build_started
    manifest = output / 'fixtures.json'
    manifest.write_text(json.dumps({'abi': abi, 'cases': cases}, separators=(',', ':')))
    started = time.monotonic()
    native = native_results(native_library, abi, cases, output / 'native')
    command([shutil.which('node') or 'node', Path(__file__).with_name('wasm-runner.mjs'), manifest, wasm_file, output / 'wasm'])
    wasm_results = {row['id']: row for row in json.loads((output / 'wasm/results.json').read_text())}
    per_kernel = {name: {'cases': 0, 'exact': 0, 'activeCases': 0, 'mismatches': []} for name in abi}
    detailed = []
    for fixture in cases:
        identifier = fixture['id']
        a = native[identifier]
        b = wasm_results[identifier]
        native_bytes = (output / 'native' / (identifier + '.bin')).read_bytes()
        wasm_bytes = (output / 'wasm' / (identifier + '.bin')).read_bytes()
        exact = a['returns'] == b['returns'] and native_bytes == wasm_bytes
        guards_valid = all(native_bytes[buffer['guardOffset']:buffer['guardOffset'] + 32] == bytes([165]) * 32
                           for buffer in fixture['buffers'].values())
        active = semantic_active(fixture, native_bytes, a['returns'][-1])
        semantic_valid = True
        if fixture['variant'].startswith('half-even'):
            buffer = fixture['buffers']['output']
            pixels = native_bytes[buffer['offset']:buffer['offset'] + 64 * 64 * 4]
            expected_byte = 240 if fixture['variant'] == 'half-even-low' else 242
            painted = [pixels[i:i + 3] for i in range(0, len(pixels), 4) if pixels[i + 3]]
            semantic_valid = bool(painted) and all(rgb == bytes([expected_byte]) * 3 for rgb in painted)
        exact = exact and semantic_valid
        row = per_kernel[fixture['name']]
        row['cases'] += 1
        row['exact'] += int(exact and guards_valid)
        row['activeCases'] += int(active)
        differences = [(i, aa, bb) for i, (aa, bb) in enumerate(zip(native_bytes, wasm_bytes)) if aa != bb]
        detail = {'id': identifier, 'exact': exact, 'guardsValid': guards_valid, 'semanticValid': semantic_valid, 'active': active, 'aliases': fixture['aliases'],
                  'nativeReturns': a['returns'], 'wasmReturns': b['returns'], 'changedBytes': a['changedBytes'],
                  'nativeSHA256': a['sha256'], 'wasmSHA256': b['sha256'], 'differingBytes': len(differences),
                  'firstDifferences': differences[:16]}
        if 'stats' in fixture['buffers']:
            detail['nativeStatistics'] = read_values(native_bytes, fixture['buffers']['stats'])
        if not exact or not guards_valid: row['mismatches'].append(identifier)
        detailed.append(detail)
    passed = all(row['cases'] == row['exact'] and row['activeCases'] > 0 for row in per_kernel.values())
    report = {'passed': passed, 'kernelCount': len(abi), 'fixtureCount': len(cases), 'perKernel': per_kernel,
              'details': detailed, 'buildSeconds': build_seconds, 'testSeconds': time.monotonic() - started,
              'platform': platform.platform(), 'nativeSourceSHA256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
              'frozenWASMSHA256': hashlib.sha256(wasm).hexdigest(),
              'nativeLibrarySHA256': hashlib.sha256(native_library.read_bytes()).hexdigest(),
              'fixtureManifestSHA256': hashlib.sha256(manifest.read_bytes()).hexdigest(), 'abi': abi,
              'comparison': 'Exact return values and complete aligned input/output/scratch arenas including all Float32 bytes and guard zones.'}
    (output / 'report.json').write_text(json.dumps(report, indent=2))
    lines = ['| Kernel | Exact cases | Active cases | Result |', '|---|---:|---:|---|']
    for name, row in per_kernel.items():
        status = 'PASS' if row['cases'] == row['exact'] and row['activeCases'] > 0 else 'FAIL'
        lines.append(f"| {name} | {row['exact']}/{row['cases']} | {row['activeCases']} | {status} |")
    (output / 'report.md').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))
    print(f"{'PASS' if passed else 'FAIL'}: {len(abi)} kernels, {len(cases)} fixtures; {output / 'report.json'}")
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
