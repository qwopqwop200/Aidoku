#!/usr/bin/env python3
"""Incrementally compile the existing pixel kernels as a native Apple static library."""
import fcntl
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

TARGETS = {
    ('iphoneos', 'arm64'): 'aarch64-apple-ios',
    ('iphonesimulator', 'arm64'): 'aarch64-apple-ios-sim',
    ('iphonesimulator', 'x86_64'): 'x86_64-apple-ios',
    ('macosx', 'arm64'): 'aarch64-apple-darwin',
    ('macosx', 'x86_64'): 'x86_64-apple-darwin',
}


def build(root=None, environment=None):
    root = Path(root) if root is not None else Path(__file__).resolve().parents[3]
    environment = dict(os.environ if environment is None else environment)
    source = root / 'Scripts/overlay-kernels/kernels.rs'
    output = Path(environment.get('DERIVED_FILE_DIR', str(root / 'build/native-overlay-kernels-host')))
    rustc = environment.get('RUSTC') or shutil.which('rustc') or str(Path.home() / '.cargo/bin/rustc')
    platform_name = environment.get('PLATFORM_NAME', 'macosx')
    default_architecture = platform.machine() if platform_name == 'macosx' else 'arm64'
    architectures = list(dict.fromkeys(environment.get('ARCHS', default_architecture).split()))
    if not architectures:
        raise ValueError('ARCHS must contain at least one architecture')
    targets = []
    for architecture in architectures:
        target = TARGETS.get((platform_name, architecture))
        if target is None:
            raise ValueError(f'Unsupported native overlay kernel platform: {platform_name}/{architecture}')
        targets.append(target)
    if not shutil.which(rustc) and not Path(rustc).is_file():
        raise ValueError('Native overlay kernels need Rust: install rustup and add the Apple target for this build.')
    deployment_key = 'MACOSX_DEPLOYMENT_TARGET' if platform_name == 'macosx' else 'IPHONEOS_DEPLOYMENT_TARGET'
    environment.setdefault(deployment_key, '15.0')
    version = subprocess.check_output([rustc, '-vV'], env=environment)
    output.mkdir(parents=True, exist_ok=True)
    # CLI invocations and Xcode phases can request the same host library. Serialize
    # their fingerprint checks and atomic replacements, retaining the lock inode.
    with (output / '.native-overlay-kernels.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        libraries = []
        for target in targets:
            directory = output / 'native-overlay-kernels' / target
            directory.mkdir(parents=True, exist_ok=True)
            library = directory / 'libAidokuOverlayKernels.a'
            fingerprint = directory / 'fingerprint'
            flags = ['--target', target, '--crate-type', 'staticlib', '--crate-name', 'aidoku_overlay_kernels',
                     '-C', 'opt-level=3', '-C', 'panic=abort', '-C', 'debuginfo=0', '-C', 'codegen-units=1']
            digest = hashlib.sha256(source.read_bytes() + version + '\0'.join(flags).encode()
                                    + deployment_key.encode() + environment[deployment_key].encode()).hexdigest()
            if not library.exists() or not fingerprint.exists() or fingerprint.read_text() != digest:
                temporary = directory / 'libAidokuOverlayKernels.pending.a'
                subprocess.run([rustc, *flags, str(source), '-o', str(temporary)], check=True, env=environment)
                temporary.replace(library)
                fingerprint.write_text(digest)
                print(f'Compiled native overlay kernels: {target}', flush=True)
            libraries.append(library)
        combined = output / 'libAidokuOverlayKernels.a'
        combined_digest = hashlib.sha256(b''.join(item.read_bytes() for item in libraries)).hexdigest()
        combined_fingerprint = output / 'native-overlay-kernels-linked-fingerprint'
        if not combined.exists() or not combined_fingerprint.exists() or combined_fingerprint.read_text() != combined_digest:
            temporary = output / 'libAidokuOverlayKernels.pending.a'
            if len(libraries) == 1:
                shutil.copyfile(libraries[0], temporary)
            else:
                subprocess.run(['/usr/bin/xcrun', 'lipo', '-create', *map(str, libraries), '-output', str(temporary)],
                               check=True, env=environment)
            temporary.replace(combined)
            combined_fingerprint.write_text(combined_digest)
    return combined


if __name__ == '__main__':
    try:
        build()
    except ValueError as error:
        sys.exit(str(error))
