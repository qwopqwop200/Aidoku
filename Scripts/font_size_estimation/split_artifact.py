"""Read a packaged artifact that may be stored as `<name>.part-NN` chunks.

GitHub rejects blobs over 100 MB and public forks cannot upload LFS objects,
so large trusted model bundles are committed as ordered byte chunks. The
logical file is the concatenation of the chunks; identity checks hash it.
"""
from pathlib import Path


def chunk_paths(path):
    path = Path(path)
    return sorted(path.parent.glob(path.name + '.part-*'))


def exists(path):
    return Path(path).exists() or bool(chunk_paths(path))


def read_bytes(path):
    path = Path(path)
    if path.exists():
        return path.read_bytes()
    parts = chunk_paths(path)
    if not parts:
        raise FileNotFoundError(path)
    return b''.join(part.read_bytes() for part in parts)
