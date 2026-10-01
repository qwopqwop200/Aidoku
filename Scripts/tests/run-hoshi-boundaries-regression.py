#!/usr/bin/env python3
"""Build and execute all three maintained Hoshi boundary probes, sequentially.

Uses current vendored Hoshi sources and the exact Zstd revision in Package.resolved.
Compiler objects are reused from build/hoshi-boundaries-host; assertions, ASan and
UBSan remain enabled at -O2. No Homebrew library, global dictionary or test skip is
used. The first run may fetch the pinned Zstd source if no matching SwiftPM checkout
is available. Runtime fixtures are confined to a fresh temporary directory.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
HOSHI = ROOT / 'Vendor/HoshiDicts'
CACHE = ROOT / 'build/hoshi-boundaries-host'
PROBES = ('hoshi-source-boundaries', 'hoshi-reader-boundaries', 'hoshi-c-api-regression')
FLAGS = ['-O2', '-g', '-UNDEBUG', '-fsanitize=address,undefined',
         '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']


def output(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs).strip()


def package_pin():
    resolved = ROOT / 'Aidoku.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    pins = json.loads(resolved.read_text())['pins']
    return next(pin for pin in pins if pin['identity'] == 'zstd')


def matching_checkout(path, revision):
    if not (path / '.git').exists() or not (path / 'lib/zstd.h').is_file():
        return False
    try:
        return (output(['git', '-C', str(path), 'rev-parse', 'HEAD']) == revision
                and not output(['git', '-C', str(path), 'status', '--porcelain', '--untracked-files=all', '--', 'lib']))
    except subprocess.CalledProcessError:
        return False


def zstd_checkout(explicit=None):
    pin = package_pin()
    revision = pin['state']['revision']
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Invalid pinned Zstd revision')
    if explicit is not None:
        candidate = explicit.expanduser().resolve()
        if not matching_checkout(candidate, revision):
            raise ValueError('--zstd-source must be an unchanged checkout of the exact Package.resolved revision')
        return candidate, revision
    candidates = [ROOT / 'build/simulator-fast-release/SourcePackages/checkouts/zstd',
                  ROOT / 'Vendor/HoshiDicts/.build/checkouts/zstd',
                  CACHE / 'dependencies' / ('zstd-' + revision[:12])]
    for candidate in candidates:
        if matching_checkout(candidate, revision):
            return candidate, revision
    candidate = candidates[-1]
    candidate.mkdir(parents=True, exist_ok=True)
    subprocess.run(['git', 'init', '--quiet', str(candidate)], check=True)
    subprocess.run(['git', '-C', str(candidate), 'fetch', '--depth', '1', pin['location'], revision], check=True)
    subprocess.run(['git', '-C', str(candidate), 'checkout', '--detach', revision], check=True)
    if not matching_checkout(candidate, revision):
        raise ValueError('Fetched Zstd source did not match its pinned clean checkout')
    return candidate, revision


def source_digest(zstd):
    digest = hashlib.sha256()
    extensions = {'.h', '.hpp', '.inl', '.inc', '.c', '.cpp', '.S'}
    for label, root in [('hoshi', HOSHI), ('zstd', zstd / 'lib')]:
        for path in sorted(root.rglob('*')):
            if path.is_file() and path.suffix in extensions and '.build' not in path.parts:
                digest.update((label + '/' + str(path.relative_to(root))).encode())
                digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


class Builder:
    def __init__(self, sdk, zstd, environment):
        self.environment = environment
        self.compilers = {name: output(['/usr/bin/xcrun', '--find', name]) for name in ('clang', 'clang++')}
        self.version = output([self.compilers['clang++'], '--version'])
        self.flags = [*FLAGS, '-isysroot', sdk, '-mmacosx-version-min=15.0']
        paths = ['include', 'src', 'external/libdeflate', 'external/libdeflate/lib',
                 'external/utfcpp/source', 'external/glaze/include', 'external/xxHash',
                 'external/unordered_dense/include', 'external/utf8proc']
        self.includes = ['-I' + str(HOSHI / path) for path in paths] + ['-I' + str(zstd / 'lib')]
        self.closure = source_digest(zstd)
        self.compiled = 0
        self.reused = 0
        self.object_digests = {}
        (CACHE / 'objects').mkdir(exist_ok=True)

    def object(self, source):
        compiler = self.compilers['clang++' if source.suffix == '.cpp' else 'clang']
        language = ['-std=c++23', '-Wno-missing-braces'] if source.suffix == '.cpp' else ['-std=gnu11'] if source.suffix == '.c' else []
        name = hashlib.sha256(str(source).encode()).hexdigest()[:24]
        target = CACHE / 'objects' / (name + '.o')
        stamp = target.with_suffix('.sha256')
        command = [compiler, *language, *self.flags, *self.includes, '-c', str(source), '-o', str(target)]
        digest = hashlib.sha256((self.closure + self.version + platform.machine()
                                 + json.dumps(command)).encode() + source.read_bytes()).hexdigest()
        if target.exists() and stamp.exists() and stamp.read_text() == digest:
            self.reused += 1
        else:
            pending = target.with_suffix('.pending.o')
            command[-1] = str(pending)
            subprocess.run(command, check=True, env=self.environment)
            pending.replace(target)
            stamp.write_text(digest)
            self.compiled += 1
        self.object_digests[target] = digest
        return target

    def executable(self, name, objects):
        target = CACHE / name
        stamp = CACHE / (name + '.sha256')
        command = [self.compilers['clang++'], *self.flags, *map(str, objects), '-o', str(target)]
        digest = hashlib.sha256((self.version + json.dumps(command)
                                 + ''.join(self.object_digests[path] for path in objects)).encode()).hexdigest()
        if not target.exists() or not stamp.exists() or stamp.read_text() != digest:
            command[-1] = str(target) + '.pending'
            subprocess.run(command, check=True, env=self.environment)
            Path(command[-1]).replace(target)
            stamp.write_text(digest)
        return target


def native_library_sources(zstd):
    sources = sorted((HOSHI / 'src').rglob('*.cpp'))
    sources += sorted((HOSHI / 'external/libdeflate/lib').rglob('*.c'))
    sources += [HOSHI / 'external/utf8proc/utf8proc.c']
    for folder in ('common', 'compress', 'decompress', 'dictBuilder'):
        sources += sorted((zstd / 'lib' / folder).glob('*.c'))
        sources += sorted((zstd / 'lib' / folder).glob('*.S'))
    if not sources or any(not source.is_file() for source in sources):
        raise ValueError('The native dependency source closure is incomplete')
    return sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zstd-source', type=Path, help='Existing clean source checkout matching the project pin')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('This maintained host runner requires the macOS Xcode toolchain')
    CACHE.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    records = []
    with (CACHE / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        (CACHE / 'results.json').write_text(json.dumps({
            'status': 'running', 'passedProbes': 0, 'executedProbes': 0, 'expectedProbes': 3,
        }, indent=2) + '\n')
        # Avoid implicit compiler include/library injection; these probes use the
        # same checked-in native source closure on every machine.
        environment = {key: value for key, value in os.environ.items() if key not in {
            'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH',
            'OBJC_INCLUDE_PATH', 'LIBRARY_PATH', 'SDKROOT'}}
        zstd, revision = zstd_checkout(args.zstd_source)
        sdk = output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'])
        builder = Builder(sdk, zstd, environment)
        with tempfile.TemporaryDirectory(prefix='aidoku-hoshi-boundaries-') as temporary:
            run_environment = environment | {'TMPDIR': temporary,
                'ASAN_OPTIONS': 'halt_on_error=1:abort_on_error=1',
                'UBSAN_OPTIONS': 'halt_on_error=1:print_stacktrace=1'}
            for name in PROBES:
                source = ROOT / 'Scripts/tests' / (name + '.cpp')
                text = source.read_text()
                assertion_sites = len(re.findall(r'\bassert\s*\(', text))
                if assertion_sites == 0 or not re.search(r'\bint\s+main\s*\(', text):
                    raise ValueError(f'{name} has no executable assertion probe')
                if re.search(r'^\s*#\s*define\s+NDEBUG\b', text, re.M):
                    raise ValueError(f'{name} disables its assertions')
                build_start = time.monotonic()
                objects = [builder.object(source)]
                if name == 'hoshi-c-api-regression':
                    objects += [builder.object(path) for path in native_library_sources(zstd)]
                executable = builder.executable(name, objects)
                build_seconds = time.monotonic() - build_start
                test_start = time.monotonic()
                result = subprocess.run([str(executable)], cwd=temporary, env=run_environment, check=False)
                record = {'name': name, 'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
                          'assertionSites': assertion_sites, 'exitCode': result.returncode,
                          'buildSeconds': build_seconds, 'testSeconds': time.monotonic() - test_start}
                records.append(record)
                print(json.dumps(record), flush=True)
        report = {'status': 'passed' if len(records) == 3 and all(item['exitCode'] == 0 for item in records) else 'failed',
                  'passedProbes': sum(item['exitCode'] == 0 for item in records),
                  'executedProbes': len(records), 'expectedProbes': len(PROBES),
                  'assertionsEnabled': True, 'optimization': '-O2', 'sanitizers': ['address', 'undefined'],
                  'compiledObjects': builder.compiled, 'reusedObjects': builder.reused,
                  'zstdRevision': revision, 'sourceClosureSHA256': builder.closure,
                  'wallSeconds': time.monotonic() - started, 'probes': records}
        (CACHE / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
        if report['executedProbes'] != 3 or report['passedProbes'] != 3:
            print('FAIL: all three Hoshi assertion probes must execute and pass', flush=True)
            return 1
        print(f"PASS: 3 Hoshi boundary probes; compiled {builder.compiled}, reused {builder.reused} objects; "
              f"{report['wallSeconds']:.2f}s; assertions + ASan/UBSan enabled", flush=True)
        return 0


if __name__ == '__main__':
    raise SystemExit(main())
