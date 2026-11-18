#!/usr/bin/env python3
"""Run 39 native source-top controls against an already-built standard host.

Usage (after the normal host build has finished):
    python3 Scripts/tests/run-native-source-top-alignment-smoke.py
    python3 Scripts/tests/run-native-source-top-alignment-smoke.py --cache build/image-translation-host

This never invokes the host launcher, builds kernels, refreshes source snapshots,
or compiles production primaries. Missing, busy or stale input fails closed.
All generated output is confined to build/native-source-top-alignment-smoke.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'build/native-source-top-alignment-smoke'
FIXTURE = Path(__file__).with_name('NativeSourceTopAlignmentSmoke.swift')
OVERLAY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'
MAIN_NAMES = (
    'NativeTranslationRenderer+CohortTextBoxes.swift',
    'NativeTranslationRenderer+CohortTextCommit.swift',
    'NativeWidthFinalArtifactAdmission.swift',
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def record_file(path, hashes):
    require(path.is_file(), f'Missing required build input: {path}; build the standard host first')
    hashes[str(path)] = digest(path)


def verify_unchanged(hashes):
    for name, expected in hashes.items():
        path = Path(name)
        require(path.is_file() and digest(path) == expected, f'Input changed during smoke: {path}')


def inspect_snapshot(cache):
    """Bind actual standard snapshots and objects, without generating substitutes."""
    hashes = {}
    mapping_path = cache / 'output-map.json'
    stamp, executable = cache / 'fingerprint', cache / 'image-translation'
    for path in [mapping_path, stamp, executable, FIXTURE, Path(__file__).resolve()]:
        record_file(path, hashes)
    require(re.fullmatch(r'[0-9a-f]{64}', stamp.read_text().strip()) is not None,
            f'Invalid completed-build fingerprint: {stamp}')
    require(stamp.stat().st_mtime_ns >= executable.stat().st_mtime_ns,
            'Host build has no current completion stamp; finish the standard build first')
    mapping = json.loads(mapping_path.read_text())
    require(isinstance(mapping, dict), 'Invalid standard output map')
    entries = []
    for name, outputs in mapping.items():
        if not name:
            continue
        source = Path(name).resolve()
        obj = Path(outputs['object']).resolve()
        require(source.parent in [cache, cache / 'sources'] and source.suffix == '.swift',
                f'Not a standard cache source: {source}')
        require(obj.parent == cache and obj.suffix == '.o', f'Object outside selected cache: {obj}')
        for path in [source, obj]:
            record_file(path, hashes)
        require(obj.stat().st_mtime_ns >= source.stat().st_mtime_ns,
                f'Stale object for snapshot: {source}; finish the standard incremental build')
        require(executable.stat().st_mtime_ns >= obj.stat().st_mtime_ns,
                f'Host executable predates object: {obj}; finish the standard incremental link')
        entries.append((source, obj))
    require(entries, 'Empty standard output map')
    require(len({s for s, _ in entries}) == len(entries), 'Duplicate source paths in output map')
    require(len({o for _, o in entries}) == len(entries), 'Aliased objects in output map')
    by_name = {s.name: s for s, _ in entries}
    require(len(by_name) == len(entries), 'Ambiguous source basenames in standard snapshot')
    main_hashes, snapshot_hashes = {}, {}
    for name in MAIN_NAMES:
        original = OVERLAY / name
        snapshot = cache / 'sources' / name
        require(by_name.get(name) == snapshot, f'Missing compiled MAIN snapshot: {name}')
        record_file(original, hashes)
        adapted = original.read_bytes().replace(b'import UIKit', b'import AppKit')
        require(snapshot.read_bytes() == adapted,
                f'Stale MAIN snapshot: {name}; only standard UIKit-to-AppKit adaptation is allowed')
        main_hashes[name], snapshot_hashes[name] = hashes[str(original)], hashes[str(snapshot)]
    pipeline = cache / 'sources/PipelineMain.swift'
    require(by_name.get('PipelineMain.swift') == pipeline, 'Missing standard PipelineMain entry')
    require(pipeline.read_bytes() == (ROOT / 'Scripts/image-translation/PipelineMain.swift').read_bytes(),
            'PipelineMain is not the current standard host source')
    record_file(ROOT / 'Scripts/image-translation/PipelineMain.swift', hashes)
    kernel = ROOT / 'build/native-overlay-kernels-host/libAidokuOverlayKernels.a'
    for path in [kernel, ROOT / 'Scripts/overlay-kernels/native/kernels.h',
                 ROOT / 'Scripts/overlay-kernels/native/module.modulemap']:
        record_file(path, hashes)
        require(executable.stat().st_mtime_ns >= path.stat().st_mtime_ns,
                f'Host executable predates kernel input: {path}')
    return entries, pipeline, kernel, hashes, main_hashes, snapshot_hashes


def run_locked(cache):
    # Open the existing launcher lock read-only: never create/refresh host files.
    # Shared nonblocking lock refuses a current build and prevents an EX build
    # from starting until all input hashes are rechecked after this smoke.
    with (cache / 'build.lock').open('rb') as host_lock:
        try:
            fcntl.flock(host_lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError('Selected host cache is busy; rerun after the parent build completes') from error
        entries, pipeline, kernel, hashes, main_hashes, snapshot_hashes = inspect_snapshot(cache)
        require(OUTPUT != cache and not OUTPUT.is_relative_to(cache), 'Smoke output must not overlap host cache')
        OUTPUT.mkdir(parents=True, exist_ok=True)
        with (OUTPUT / 'build.lock').open('a') as own_lock:
            try:
                fcntl.flock(own_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RuntimeError('Another source-top smoke is running') from error
            return build_and_test(cache, entries, pipeline, kernel, hashes, main_hashes, snapshot_hashes)


def build_and_test(cache, entries, pipeline, kernel, hashes, main_hashes, snapshot_hashes):
    receipt_path = OUTPUT / 'receipt.json'
    receipt = {'passed': False, 'cache': str(cache), 'authority': 'ACTUAL CURRENT MAIN / standard host snapshots',
               'mainUIKitSHA256': main_hashes, 'compiledAppKitSnapshotSHA256': snapshot_hashes,
               'compiledProductionPrimaries': 0, 'compiledTestPrimaries': 1,
               'sourceAndObjectSHA256': hashes, 'kernelSHA256': hashes[str(kernel)],
               'fixtureSHA256': hashes[str(FIXTURE)], 'hostOnly': True}

    def save():
        receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')

    save()  # Never leave an older passing receipt if this invocation fails.
    try:
        raw = pipeline.read_text()
        require(len(re.findall(r'^@main\s*$', raw, re.MULTILINE)) == 1,
                'Standard PipelineMain entry annotation changed')
        raw = re.sub(r'^@main\s*$', '', raw, count=1, flags=re.MULTILINE)
        source, obj, binary = OUTPUT / 'PipelineMain.swift', OUTPUT / 'Smoke.o', OUTPUT / 'smoke'
        source.write_text(raw + '\n' + FIXTURE.read_text())
        receipt['testEntrySHA256'] = digest(source)
        sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        target = 'arm64-apple-macos15.0'  # Same target and -O as standard host launcher.
        include = ROOT / 'Scripts/overlay-kernels/native'
        compile_command = ['/usr/bin/xcrun', 'swiftc', '-frontend', '-c', '-O', '-parse-as-library',
                           '-module-name', 'ImageTranslationHost', '-target', target, '-sdk', sdk,
                           '-module-cache-path', str(OUTPUT / 'module-cache'), '-I', str(include),
                           '-I', str(ROOT / 'Vendor/NativeSourceCV/include')]
        swiftc = Path(subprocess.check_output(['/usr/bin/xcrun', '--find', 'swiftc'], text=True).strip())
        plugins = swiftc.parent.parent / 'lib/swift/host/plugins'
        if plugins.is_dir():
            compile_command += ['-plugin-path', str(plugins)]
        for path, _ in entries:
            compile_command.extend(['-primary-file', str(source)] if path == pipeline else [str(path)])
        compile_command += ['-o', str(obj)]
        link_command = ['/usr/bin/xcrun', 'swiftc', '-target', target, '-sdk', sdk]
        link_command += [str(obj if path == pipeline else cached_obj) for path, cached_obj in entries]
        link_command += [str(kernel), '-L', str(ROOT / 'build/native-source-cv-host'),
                         '-lAidokuSourceCV', '-lAidokuOpenCV', '-lAidokuFreeType', '-lc++', '-lz',
                         '-framework', 'CoreText', '-framework', 'Accelerate', '-o', str(binary)]
        receipt['commands'] = [compile_command, link_command]
        environment = dict(os.environ)
        environment['CLANG_MODULE_CACHE_PATH'] = str(OUTPUT / 'module-cache')
        environment['SWIFT_MODULECACHE_PATH'] = str(OUTPUT / 'module-cache')
        verify_unchanged(hashes)
        with (OUTPUT / 'build.log').open('w') as log:
            for stage, command in [('compileSeconds', compile_command), ('linkSeconds', link_command)]:
                started = time.monotonic()
                subprocess.run(command, cwd=ROOT, env=environment, stdout=log, stderr=log, check=True)
                receipt[stage] = time.monotonic() - started
                verify_unchanged(hashes)
                save()
        receipt['buildSeconds'] = receipt['compileSeconds'] + receipt['linkSeconds']
        receipt['binarySHA256'] = digest(binary)
        # The entrypoint calls synthetic fixtures and native graphics only, not CLI/OCR.
        started = time.monotonic()
        done = subprocess.run([str(binary)], cwd=ROOT, env=environment, text=True, capture_output=True)
        receipt['testProcessSeconds'] = time.monotonic() - started
        (OUTPUT / 'result.txt').write_text(done.stdout + done.stderr)
        require(done.returncode == 0, f'Native controls failed ({done.returncode}); see {OUTPUT / "result.txt"}')
        result = json.loads(done.stdout.strip())
        require(result == {'alignmentControls': 24, 'transactionControls': 15, 'passed': True},
                f'Unexpected control counts/result: {result}')
        verify_unchanged(hashes)
        require(digest(source) == receipt['testEntrySHA256'], 'Generated test entry changed during smoke')
        receipt.update(passed=True, controls=result, inputsUnchanged=True)
        save()
        print(json.dumps({'passed': True, **result, 'receipt': str(receipt_path),
                          'buildSeconds': receipt['buildSeconds'], 'testProcessSeconds': receipt['testProcessSeconds']}))
        return 0
    except Exception as error:
        receipt['error'] = str(error)
        save()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--cache', type=Path, default=ROOT / 'build/image-translation-host',
                        help='Completed standard host cache (read-only; never rebuilt)')
    args = parser.parse_args()
    cache = args.cache.expanduser().resolve()
    try:
        return run_locked(cache)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Source-top smoke NOT PASSED: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
