#!/usr/bin/env python3
"""Compile the current native dictionary storage paths with ASan and UBSan."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
root = repo / 'Vendor/HoshiDicts'
flags = ['-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer']
with tempfile.TemporaryDirectory(prefix='aidoku-hoshi-storage-build-') as temporary:
    out = pathlib.Path(temporary)
    objects = []
    c_files = sorted((root / 'external/libdeflate/lib').glob('*.c'))
    c_files += [root / f'external/libdeflate/lib/{arch}/cpu_features.c' for arch in ['arm', 'x86']]
    for index, source in enumerate(c_files):
        obj = out / f'{index}.o'
        subprocess.run(['xcrun', 'clang', *flags, '-I' + str(root / 'external/libdeflate'),
                        '-c', str(source), '-o', str(obj)], check=True)
        objects.append(str(obj))
    sources = [repo / 'Scripts/tests/hoshi-storage-regression.cpp']
    sources += [root / f'src/{name}.cpp' for name in ['hash/hash', 'hash/bloom', 'memory/memory', 'zip/zip']]
    executable = out / 'regression'
    subprocess.run(['xcrun', 'clang++', '-std=c++23', *flags,
                    '-I' + str(root / 'src'), '-I' + str(root / 'external/libdeflate'),
                    '-I' + str(root / 'external/xxHash'), *map(str, sources), *objects,
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
