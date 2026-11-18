"""Offline packaging of frozen late-stage objects (never imported by inference).

No fitting, query labels, prediction arrays, or cohort records are read. TRAIN
calibration ratios and the TRAIN page prior are pre-trained model metadata.
"""

import hashlib
import json
import pickle
from pathlib import Path

import numpy as np

from optimized_late import MODEL_FILES, STAGES


def _source_aliases(rows):
    parent = list(range(len(rows)))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    seen = {}
    for i, row in enumerate(rows):
        for key in (('source', row['sourceImageSHA256']), ('crop', row['cropSHA256'])):
            if key in seen:
                parent[root(i)] = root(seen[key])
            else:
                seen[key] = i
    components = {}
    for i in range(len(rows)):
        components.setdefault(root(i), []).append(i)
    aliases = {}
    for ids in components.values():
        canonical = min(rows[i]['sourceImageSHA256'] for i in ids)
        for i in ids:
            aliases[rows[i]['sourceImageSHA256']] = canonical
    return aliases


def bundle_late_models(research_root):
    """Return (models, policies) ready to embed in the parent graph pickle.

    REPORT selections supply frozen decoder knobs only; DEV metrics and all
    training-selection metadata are stripped. Each of four 175 expert states
    retains its model, normalization, target scale and TRAIN OOF noise.
    """
    root = Path(research_root)
    models = {}
    for key in MODEL_FILES:
        if key.isdecimal():
            models[key] = pickle.loads((root / f'round{key}' / 'model.pkl').read_bytes())
    models['style_encoder'] = pickle.loads((root / 'round188/pca.pkl').read_bytes())
    for key, path in [
        ('page_prior', 'round160/prior.npz'),
        ('style_bank', 'round194/TRAIN-BANK.npz'),
    ]:
        with np.load(root / path, allow_pickle=False) as data:
            models[key] = {key: data[key].copy() for key in data.files}
    bank = models['style_bank']
    if set(bank) != {
        'style',
        'referenceFamily',
        'measuredEm',
        'calibrationRatio',
        'quality',
        'sourceGroup',
    }:
        raise ValueError('Unexpected TRAIN style bank schema')
    hashes = bank['sourceGroup']
    if hashes.dtype.kind not in 'US' or any(
        len(str(s)) != 64 or any(c not in '0123456789abcdef' for c in str(s)) for s in hashes
    ):
        raise ValueError('TRAIN style bank must use stable source SHA256 identities')
    # Reproduce the hash-based TRAIN admission without reading labels or splits.
    if any(int(hashlib.sha256(str(s).encode()).hexdigest()[:8], 16) % 10 >= 6 for s in hashes):
        raise ValueError('Non-TRAIN source present in calibration bank')
    rows = json.loads((root / 'round35/SOURCE-ONLY-MANIFEST.json').read_text())['items']
    aliases = _source_aliases(rows)
    models['source_identity_aliases'] = {key: 'g:' + value for key, value in aliases.items()}
    models['sourceIdentityGroups'] = models['source_identity_aliases']
    bank['sourceGroup'] = np.asarray(['g:' + str(value) for value in hashes])
    policies = {}
    for stage in STAGES:
        selected = json.loads((root / f'round{stage}' / 'REPORT.json').read_text())['selected']
        if selected is None:
            raise ValueError(f'Frozen late stage {stage} has no selected policy')
        if stage == 198:
            policies[str(stage)] = selected['config']
        else:
            policies[str(stage)] = {
                k: v
                for k, v in selected.items()
                if k not in {'DEV', 'DEVMeanRelativeError', 'TRAINMeanRelativeError'}
            }
    # Round196 updates round194's whitened PCA configuration.
    config = json.loads((root / 'round194/REPORT.json').read_text())['selected']
    config = {k: v for k, v in config.items() if k != 'DEV'}
    config.update(policies['196'])
    policies['196'] = config
    return models, policies


def export_late_bundle(research_root, artifact_directory):
    """Write portable artifacts and return (models, policies) for graph packing."""
    models, policies = bundle_late_models(research_root)
    directory = Path(artifact_directory)
    directory.mkdir(parents=True, exist_ok=True)
    for key, name in MODEL_FILES.items():
        path = directory / name
        if path.suffix == '.npz':
            np.savez_compressed(path, **models[key])
        else:
            path.write_bytes(pickle.dumps(models[key], protocol=pickle.HIGHEST_PROTOCOL))
    (directory / 'late_source_aliases.json').write_text(
        json.dumps(models['source_identity_aliases'], sort_keys=True) + '\n'
    )
    (directory / 'late_policies.json').write_text(json.dumps(policies, indent=2) + '\n')
    return models, policies
