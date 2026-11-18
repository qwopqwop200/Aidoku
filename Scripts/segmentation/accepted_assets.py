"""Authenticated, cleanup-safe selected segmentation assets. No experiment fallbacks."""
from functools import lru_cache
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys

ASSET_DIRECTORY = Path(__file__).resolve().parent / 'assets/accepted-final'
MANIFEST_SHA256 = '8d60d0b7009437903885737ff9333d70e63d7ccbaafa9a68c1e96a3a934cda04'
EXPECTED_RF_WEIGHTS = '03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255'


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


@lru_cache(maxsize=1)
def manifest():
    path = ASSET_DIRECTORY / 'MANIFEST.json'
    if sha(path) != MANIFEST_SHA256:
        raise ValueError('Accepted segmentation manifest changed')
    result = json.loads(path.read_text())
    if result['expectedRFModelWeightsSHA256'] != EXPECTED_RF_WEIGHTS:
        raise ValueError('Selected high-resolution RF provenance changed')
    return result


def asset(role):
    data = manifest(); relative = data['roles'][role]
    path = (ASSET_DIRECTORY / relative).resolve()
    path.relative_to(ASSET_DIRECTORY.resolve())
    if sha(path) != data['files'][relative]['SHA256']:
        raise ValueError('Accepted segmentation asset changed: ' + role)
    return path


@lru_cache(maxsize=2)
def helper(role):
    path = asset(role)
    # Compiled-code caches stay outside the immutable selected asset package.
    cache = Path(__file__).resolve().parents[2] / 'build/source-segmentation-numba'
    cache.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault('NUMBA_CACHE_DIR', str(cache))
    name = '_aidoku_accepted_segmentation_' + role
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module
