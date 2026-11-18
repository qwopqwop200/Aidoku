"""Fresh source inference seam for host/native evidence producers.

No page identifiers, localization inventories, saved predictions or GT inputs.
The caller supplies a detected owner's original crop and live aligned posteriors.
This is the Python backend, not an iOS implementation of the frozen estimator.
"""
from argparse import Namespace
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image


MODEL_FILES = (
    'model.pkl', 'pixel-role-model.pkl', 'width-model.pkl',
    'source-fill-palette-model.pkl', 'background-palette.pkl',
    'final-background-model.pkl',
)
POLICY_FILES = (
    'SHADOW-OBSERVATION-POLICY.json', 'FINAL-BACKGROUND-POLICY.json',
    'NATIVE-GRADIENT-CONTOUR-POLICY.json', 'NATIVE-OUTER-SHELL-POLICY.json',
)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def snapshot(checkpoint):
    """Bind every active head/policy; never open prediction or evaluation files."""
    files = MODEL_FILES + POLICY_FILES
    return {name: sha((checkpoint / name).read_bytes()) for name in files}


def _run_source_inference(args):
    """Invoke the unchanged, hash-bound accepted CLI in an isolated process."""
    packed = args.estimator / 'runtime/appearance_estimation/infer_appearance.py'
    script = packed if packed.exists() else Path(__file__).resolve().with_name('infer_appearance.py')
    output = args.image.parent / 'fresh-output.json'
    env = os.environ.copy()
    # Existing accepted helpers import style_gt's RGB utilities. No labels load.
    support = str(script.parent.parent / 'style_gt')
    env['PYTHONPATH'] = os.pathsep.join(filter(None, [str(script.parent), support, env.get('PYTHONPATH')]))
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    process = subprocess.run([sys.executable, '-B', str(script), '--image', str(args.image),
                              '--mask', str(args.mask), '--context-mask', str(args.context_mask),
                              '--source-evidence', str(args.source_evidence), '--estimator', str(args.estimator),
                              '--out', str(output)], env=env, capture_output=True)
    if process.returncode:
        diagnostic = process.stderr.decode('utf-8', errors='replace')[-3000:]
        raise RuntimeError('Fresh source appearance inference failed:\n' + diagnostic)
    # This file is produced only by the invocation above in its private folder.
    return json.loads(output.read_text())


def validated_inputs(rgb, mask, rf, primary, boundary, ocr, geometry, context_mask):
    rgb = np.asarray(rgb)
    if rgb.dtype != np.uint8 or rgb.ndim != 3 or rgb.shape[2] != 3:
        raise ValueError('Source RGB must be original uint8 HxWx3 pixels')
    h, w = rgb.shape[:2]
    if min(h, w) <= 0 or h * w > 1_500_000:
        raise ValueError('Source crop exceeds live inference budget')
    arrays = {'rgb': rgb.copy()}
    for name, value in [('mask', mask), ('context', context_mask)]:
        value = np.asarray(value)
        if value.shape != (h, w) or not np.isin(value, [0, 1, 255]).all():
            raise ValueError(name + ' must be an aligned predicted binary mask')
        arrays[name] = (value > 0).astype(np.uint8)
    if not arrays['mask'].any():
        raise ValueError('Empty owner mask cannot establish source appearance')
    if np.any(arrays['mask'] > arrays['context']):
        raise ValueError('Context must include every predicted owner pixel')
    for name, value, shape in [
        ('rf', rf, (h, w, 27)), ('segPrimary', primary, (h, w)),
        ('segBoundary', boundary, (h, w)), ('ocr', ocr, (h, w, 8)),
    ]:
        value = np.asarray(value)
        if value.shape != shape or not np.isfinite(value).all() or np.any(value < 0) or np.any(value > 1.001):
            raise ValueError(name + ' must contain aligned original-source posteriors')
        # Preserve producer precision, including the champion's float16 RF inputs.
        arrays[name] = value.copy()
    if not isinstance(geometry, dict) or set(geometry) != {'polygons', 'mergedPolygon', 'fontPixels'}:
        raise ValueError('Only live polygons, mergedPolygon and fontPixels are accepted')
    geometry = copy.deepcopy(geometry)
    font = geometry['fontPixels']
    if isinstance(font, bool) or not isinstance(font, (float, int)) or not np.isfinite(font) or font <= 0:
        raise ValueError('Invalid source font estimate')
    polygons = geometry['polygons']
    if not isinstance(polygons, list) or not 1 <= len(polygons) <= 256:
        raise ValueError('Detected source polygons required')
    for index, polygon in enumerate(polygons + [geometry['mergedPolygon']]):
        points = np.asarray(polygon)
        if points.ndim != 2 or points.shape[1] != 2 or not 3 <= len(points) <= 256 or not np.isfinite(points).all():
            raise ValueError('Invalid detected source polygon')
        if (points[:, 0] < 0).any() or (points[:, 0] > w).any() or (points[:, 1] < 0).any() or (points[:, 1] > h).any():
            raise ValueError(f'Source polygon lies outside crop coordinates: crop={w}x{h}, '
                             f'polygon={index}, min={points.min(axis=0).tolist()}, '
                             f'max={points.max(axis=0).tolist()}')
    canonical(geometry)
    return arrays, geometry


class OperationalAppearance:
    """Immutable checkpoint selection; every invocation recomputes all heads."""

    def __init__(self, estimator=None):
        root = (Path(estimator) if estimator is not None else Path(__file__).resolve().parent/'assets/accepted').resolve()
        active = root / 'ACTIVE-ESTIMATOR.json'
        if active.exists():
            location = Path(json.loads(active.read_text())['checkpoint'])
            root = (root / location).resolve() if not location.is_absolute() else location.resolve()
        self.checkpoint = root
        manifest = root/'PACKAGE.json'
        if manifest.exists():
            package = json.loads(manifest.read_text())
            for name, expected in package['files'].items():
                path=(root/name).resolve()
                if not path.is_relative_to(root) or sha(path.read_bytes()) != expected:
                    raise ValueError('Packed appearance runtime artifact changed: '+name)
        self.identities = snapshot(root)
        self.checkpoint_identity = sha(canonical(self.identities))

    def estimate(self, *, rgb, mask, rf, primary, boundary, ocr, geometry,
                 context_mask, rf_model_weights_sha256):
        arrays, geometry = validated_inputs(rgb, mask, rf, primary, boundary, ocr, geometry, context_mask)
        if snapshot(self.checkpoint) != self.identities:
            raise ValueError('Active appearance artifacts changed; create a new runtime')
        if (not isinstance(rf_model_weights_sha256, str) or len(rf_model_weights_sha256) != 64
                or any(c not in '0123456789abcdef' for c in rf_model_weights_sha256)):
            raise ValueError('Live RF model weights identity required')
        # Private transient transport only. No predictions are read from disk.
        with tempfile.TemporaryDirectory(prefix='aidoku-live-appearance-') as folder:
            folder = Path(folder)
            image, mask_path = folder / 'source.png', folder / 'mask.png'
            context, evidence = folder / 'context.png', folder / 'evidence.npz'
            Image.fromarray(arrays['rgb']).save(image)
            Image.fromarray(arrays['mask'] * 255).save(mask_path)
            Image.fromarray(arrays['context'] * 255).save(context)
            np.savez(evidence, **{k: arrays[k] for k in ('rf', 'segPrimary', 'segBoundary', 'ocr')},
                     sourceRGBSHA256=np.array(sha(image.read_bytes())),
                     predictedMaskSHA256=np.array(sha(mask_path.read_bytes())),
                     rfModelWeightsSHA256=np.array(rf_model_weights_sha256),
                     geometryJSON=np.array(canonical(geometry).decode()))
            args = Namespace(image=image, mask=mask_path, estimator=self.checkpoint, model=None,
                             pixel_role_model=None, source_fill_palette_model=None, width_model=None,
                             final_background_model=None, background_palette_model=None, geometry=None,
                             source_evidence=evidence, source_shadow_observation=False, context_mask=context)
            prediction = _run_source_inference(args)
        if snapshot(self.checkpoint) != self.identities:
            raise ValueError('Appearance artifacts changed during inference; discard result')
        binding = {name + 'SHA256': sha(value.tobytes(order='C')) for name, value in arrays.items()}
        binding.update(geometrySHA256=sha(canonical(geometry)),
                       rfModelWeightsSHA256=rf_model_weights_sha256,
                       checkpointSHA256=self.checkpoint_identity)
        return dict(schema='aidoku-live-source-appearance-v1', binding=binding,
                    width=arrays['rgb'].shape[1], height=arrays['rgb'].shape[0],
                    geometry=geometry, prediction=prediction, sourceOnly=True,
                    freshInference=True, GTAtInference=False, cachedPredictionsRead=False)


def main():
    """Host process boundary: only explicitly supplied live source payloads."""
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('image', 'mask', 'context-mask', 'source-evidence', 'estimator', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists():
        raise ValueError('Fresh inference output must not already exist')
    runtime = OperationalAppearance(args.estimator)
    with np.load(args.source_evidence, allow_pickle=False) as evidence:
        if str(evidence['sourceRGBSHA256'].item()) != sha(args.image.read_bytes()):
            raise ValueError('Live evidence source RGB identity mismatch')
        if str(evidence['predictedMaskSHA256'].item()) != sha(args.mask.read_bytes()):
            raise ValueError('Live evidence predicted-mask identity mismatch')
        with Image.open(args.image) as image:
            rgb = np.asarray(image.convert('RGB')).copy()
        with Image.open(args.mask) as image:
            mask = np.asarray(image).copy()
        with Image.open(args.context_mask) as image:
            context = np.asarray(image).copy()
        result = runtime.estimate(rgb=rgb, mask=mask, context_mask=context,
                                  rf=evidence['rf'], primary=evidence['segPrimary'],
                                  boundary=evidence['segBoundary'], ocr=evidence['ocr'],
                                  geometry=json.loads(str(evidence['geometryJSON'].item())),
                                  rf_model_weights_sha256=str(evidence['rfModelWeightsSHA256'].item()))
    # No output exists until inference and both checkpoint checks have succeeded.
    payload = json.dumps(result, sort_keys=True, allow_nan=False)
    with args.out.open('x') as handle:
        handle.write(payload)


if __name__ == '__main__':
    main()
