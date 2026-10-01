#!/usr/bin/env python3
"""Incrementally compile the existing pixel kernels as a native Apple static library."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
source = root / 'Scripts/overlay-kernels/kernels.rs'
output = Path(os.environ.get('DERIVED_FILE_DIR', str(root / 'build/native-overlay-kernels-host')))
rustc = os.environ.get('RUSTC') or shutil.which('rustc') or str(Path.home() / '.cargo/bin/rustc')
platform = os.environ.get('PLATFORM_NAME', 'macosx')
architectures = os.environ.get('ARCHS', 'arm64').split()
targets = {
    ('iphoneos', 'arm64'): 'aarch64-apple-ios',
    ('iphonesimulator', 'arm64'): 'aarch64-apple-ios-sim',
    ('iphonesimulator', 'x86_64'): 'x86_64-apple-ios',
    ('macosx', 'arm64'): 'aarch64-apple-darwin',
    ('macosx', 'x86_64'): 'x86_64-apple-darwin',
}
if not shutil.which(rustc) and not Path(rustc).is_file():
    sys.exit('Native overlay kernels need Rust: install rustup and add aarch64-apple-ios/aarch64-apple-ios-sim targets.')
version = subprocess.check_output([rustc, '-vV'])
output.mkdir(parents=True, exist_ok=True)
libraries = []
for architecture in architectures:
    target = targets.get((platform, architecture))
    if not target:
        sys.exit(f'Unsupported native overlay kernel platform: {platform}/{architecture}')
    directory = output / 'native-overlay-kernels' / target
    directory.mkdir(parents=True, exist_ok=True)
    library = directory / 'libAidokuOverlayKernels.a'
    fingerprint = directory / 'fingerprint'
    flags = ['--target', target, '--crate-type', 'staticlib', '--crate-name', 'aidoku_overlay_kernels',
             '-C', 'opt-level=3', '-C', 'panic=abort', '-C', 'debuginfo=0', '-C', 'codegen-units=1']
    digest = hashlib.sha256(source.read_bytes() + version + '\0'.join(flags).encode()
                            + os.environ.get('IPHONEOS_DEPLOYMENT_TARGET', '15.0').encode()).hexdigest()
    if not library.exists() or not fingerprint.exists() or fingerprint.read_text() != digest:
        temporary = directory / 'libAidokuOverlayKernels.pending.a'
        subprocess.run([rustc, *flags, str(source), '-o', str(temporary)], check=True,
                       env=dict(os.environ, IPHONEOS_DEPLOYMENT_TARGET=os.environ.get('IPHONEOS_DEPLOYMENT_TARGET', '15.0')))
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
        subprocess.run(['/usr/bin/xcrun', 'lipo', '-create', *map(str, libraries), '-output', str(temporary)], check=True)
    temporary.replace(combined)
    combined_fingerprint.write_text(combined_digest)
