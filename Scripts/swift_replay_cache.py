"""Stable single-file Swift build outputs for native grouping replay checks."""
import json
from pathlib import Path
import subprocess


def write_if_changed(path: Path, data: bytes):
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)


def compile_replay(cache: Path, sources: list[Path], main: str, binary: Path):
    cache.mkdir(parents=True, exist_ok=True)
    main_path = cache / 'main.swift'
    write_if_changed(main_path, main.encode())
    objects = cache / 'objects'
    objects.mkdir(exist_ok=True)
    mapping = {'': {'swift-dependencies': str(objects / 'module.swiftdeps')}}
    for path in [*sources, main_path]:
        mapping[str(path)] = {
            'object': str(objects / (path.stem + '.o')),
            'swift-dependencies': str(objects / (path.stem + '.swiftdeps')),
            'dependencies': str(objects / (path.stem + '.d')),
        }
    output_map = cache / 'output-file-map.json'
    write_if_changed(output_map, json.dumps(mapping, sort_keys=True).encode())
    subprocess.run(['xcrun', 'swiftc', '-O', '-incremental', '-enable-batch-mode', '-j2', '-emit-dependencies',
                    '-module-name', 'AidokuGroupingReplay', '-output-file-map', str(output_map),
                    *map(str, sources), str(main_path), '-o', str(binary)], check=True)
