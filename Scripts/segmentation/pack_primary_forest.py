"""Build or verify the compact runtime artifact for the selected primary62 forest."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile

SOURCE_SHA256 = "8f5dba949b25c2cf54359bd8e4066c6423970980a0355887c83e150d82a0e617"
PACKED_SHA256 = "58c1074e078f706e098d04960a897ca78ec74f9928b48ebc88e1232ca44a6984"
RESOURCE_DIR = Path(__file__).resolve().parents[2] / "Aidoku/Resources/Translation/SegmentationAcceptedFinal"


def pack_primary(raw):
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError("unexpected primary forest source SHA256")
    document = json.loads(raw)
    trees = document.pop("trees")
    document["trees"] = []
    metadata = json.dumps(document, sort_keys=True, separators=(",", ":")).encode("utf-8")
    packed = bytearray(b"ADPR62\x00\x01")
    packed.extend(struct.pack("<II", len(metadata), len(trees)))
    packed.extend(metadata)
    for tree in trees:
        # Match NativePixelRFForest.packTree: preserve split nodes in original
        # order and keep only the first terminal carrying each possible vote.
        remap = []
        retained = []
        terminal_by_vote = {}
        for original_index, (feature, _, _, _, vote) in enumerate(tree):
            if feature < 0 and vote in terminal_by_vote:
                remap.append(terminal_by_vote[vote])
                continue
            index = len(retained)
            remap.append(index)
            retained.append(original_index)
            if feature < 0:
                terminal_by_vote[vote] = index

        packed.extend(struct.pack("<I", len(retained)))
        for node_index in retained:
            feature, threshold, left, right, vote = tree[node_index]
            if feature < 0:
                feature, left, right = -1 - vote, 0, 0
            else:
                left, right = remap[left], remap[right]
            packed.extend(struct.pack("<ifii", feature, threshold, left, right))

    if hashlib.sha256(packed).hexdigest() != PACKED_SHA256:
        raise ValueError("generated primary forest differs from the pinned runtime artifact")
    return packed


def publish(source, output, check=False):
    packed = pack_primary(source.read_bytes())
    if check:
        if packed != output.read_bytes():
            raise ValueError(f"stale packed primary forest: {output}")
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(packed)
            handle.flush()
            os.fchmod(handle.fileno(), 0o644)
            os.replace(temporary, output)
        finally:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=RESOURCE_DIR / "primary-forest.json")
    parser.add_argument("--output", type=Path, default=RESOURCE_DIR / "primary-forest.pr62")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    publish(args.source, args.output, args.check)
    print(f"{PACKED_SHA256}  {args.output}")
