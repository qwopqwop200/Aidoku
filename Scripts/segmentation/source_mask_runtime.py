"""Accepted final segmentation inference from source arrays, with no page lookup.

Native producers supply primary/boundary posteriors, raw source extraction,
frozen completed boundary mask, and full-query RF evidence for the SAME crop.
This module does not load a manifest, target, cached mask or classifier packet.
"""
from pathlib import Path
import json
import subprocess
import cv2
import joblib
import numpy as np

from accepted_assets import asset, helper, sha, EXPECTED_RF_WEIGHTS

_math = helper('math_helper')
component_candidates = _math.component_candidates
style_features = _math.style_features
context_features = _math.context_features
edge_features = _math.edge_features
refine_source_mask = _math.refine_source_mask
CompiledPointPredictor = helper('compiled_helper').CompiledPointPredictor

POLICY_SHA = 'dbe62f855cc112ba607c0c1a62d136c3d20779181c0b5a8a025e1fb584db6be1'
JOINT_SHA = 'ae3460b3037f944fe222a6645a59140fa04a2083a75f7a1eaff9f5ac3bbf8f2c'
AUX_SHA = 'a8715aaba6ee893ec2fe773929fcfe96328e60a5a5d0bbf047f96df79d4e3a16'


def quantize(probabilities):
    odds = np.log(np.maximum(probabilities, 1e-12)) - np.log(np.maximum(1 - probabilities, 1e-12))
    return np.clip(np.floor((odds + 24) * 8192 / 48), 0, 8191).astype(np.uint16)


def source_matrix(rgb, primary, native, coarse_rf, full_rf, font):
    """The exact frozen 60-feature edge-context contract on live source arrays."""
    colors = rgb.astype(np.float32) / 255
    light = colors[:, :, 0] * .2126 + colors[:, :, 1] * .7152 + colors[:, :, 2] * .0722
    p = primary
    planes = [p, (native > 0).astype(np.float32), *[colors[:, :, c] for c in range(3)],
              light, colors.max(2) - colors.min(2), *[coarse_rf[:, :, c] for c in range(4)]]
    neighborhoods = {}

    def neighborhood(size):
        if size not in neighborhoods:
            neighborhoods[size] = (
                cv2.dilate(p, np.ones((size, size), np.uint8)),
                cv2.boxFilter(p, -1, (size, size), borderType=cv2.BORDER_REPLICATE),
                cv2.boxFilter(light, -1, (size, size), borderType=cv2.BORDER_REPLICATE))
        return neighborhoods[size]

    for size in [3, 5, 9]:
        maximum, mean, light_mean = neighborhood(size)
        planes.extend([maximum, mean, light - light_mean])
    distances = [cv2.distanceTransform((p < threshold).astype(np.uint8), cv2.DIST_L1, 3)
                 for threshold in [.25, .5]]
    planes.extend(np.minimum(distance, 8) / 8 for distance in distances)
    size = max(3, min(65, int(round(font * .25)) | 1))
    maximum, mean, light_mean = neighborhood(size)
    variance = np.maximum(0, cv2.boxFilter(light * light, -1, (size, size),
        borderType=cv2.BORDER_REPLICATE) - light_mean * light_mean)
    planes.extend([maximum, mean, light - light_mean, np.sqrt(variance)])
    planes.extend(np.minimum(distance / font, 1) for distance in distances)
    planes.extend(full_rf[:, :, c] for c in range(27))
    matrix = np.stack(planes, axis=2).reshape(-1, 55).astype(np.float32)
    # Each edge threshold uses the same exact RGB morphology; only its seeds differ.
    kernel = np.ones((3, 3), np.uint8)
    gradient = np.max(cv2.dilate(rgb, kernel, borderType=cv2.BORDER_REPLICATE) -
        cv2.erode(rgb, kernel, borderType=cv2.BORDER_REPLICATE), axis=2)
    edge = []
    for threshold in [8, 32, 64]:
        seeds = gradient >= threshold
        distance = np.minimum(cv2.distanceTransform((~seeds).astype(np.uint8), cv2.DIST_L1, 3),
            65534).astype(np.int32) if seeds.any() else np.full(seeds.shape, 65534, np.int32)
        edge.append(np.minimum(distance.astype(np.float64) / font, 1).astype(np.float32))
    normalized = gradient.astype(np.float32) / np.float32(255)
    half = max(3, min(257, int(round(font * .5)) | 1))
    edge.extend([normalized, cv2.boxFilter(normalized, -1, (half, half), borderType=cv2.BORDER_REPLICATE)])
    return np.column_stack([matrix, np.stack(edge, axis=2).reshape(-1, 5)])


class SourceMaskRuntime:
    def __init__(self, policy_path=None, joint_model_path=None, auxiliary_model_path=None, *, native_command=None):
        policy_path = asset('policy') if policy_path is None else policy_path
        joint_model_path = asset('joint_model') if joint_model_path is None else joint_model_path
        auxiliary_model_path = asset('auxiliary_model') if auxiliary_model_path is None else auxiliary_model_path
        # Explicit artifact arguments, no inference-time path resolution by page.
        for path, expected in [(policy_path, POLICY_SHA), (joint_model_path, JOINT_SHA),
                               (auxiliary_model_path, AUX_SHA)]:
            if sha(Path(path)) != expected:
                raise ValueError('Accepted segmentation artifact changed')
        self.native_command = native_command
        self.policy = json.loads(Path(policy_path).read_text())['policy']
        self.joint = CompiledPointPredictor(joblib.load(joint_model_path))
        self.auxiliary = CompiledPointPredictor(joblib.load(auxiliary_model_path))
        if (self.joint.feature_count, self.auxiliary.feature_count) != (83, 78):
            raise ValueError('Accepted feature contracts changed')

    def predict(self, *, rgb, primary, boundary, native, completed, coarse_rf, full_rf, font, affinity):
        h, w = primary.shape
        if not (0 < w * h <= 1_500_000 and rgb.dtype == np.uint8 and rgb.shape == (h, w, 3)
                and native.shape == (h, w) and completed.shape == (h, w) and boundary.shape == (h, w)
                and coarse_rf.shape == (h, w, 4) and full_rf.shape == (h, w, 27)
                and np.isfinite(font) and font > 0 and len(affinity) == 5 and np.isfinite(affinity).all()):
            raise ValueError('Invalid source crop contract')
        for values in (primary, boundary, coarse_rf, full_rf):
            if values.dtype != np.float32 or not np.isfinite(values).all() or values.min() < 0 or values.max() > 1:
                raise ValueError('Invalid source probabilities')
        base = component_candidates(completed.astype(np.uint8))['fillHoles'] > 0
        distance = cv2.distanceTransform((~base).astype(np.uint8), cv2.DIST_C, 3).astype(np.int32)
        group = (primary >= .5).astype(np.uint8) + (boundary >= .3).astype(np.uint8)
        edge = source_matrix(rgb, primary, native, coarse_rf, full_rf, max(1., font))
        matrix, _ = context_features(np.column_stack([edge, boundary.ravel()]), base, font)
        positions = np.flatnonzero((base | (distance <= 12)).ravel())
        codes = np.full(base.size, 65535, np.uint16)
        codes[positions] = quantize(self.joint.probabilities(matrix, positions))
        codes = codes.reshape(base.shape)
        values = style_features(rgb, base, distance, primary, boundary, font, dict(affinityScores=list(affinity)))
        mask = refine_source_mask(base, distance, group, codes, self.policy, values, font, rgb, (primary, boundary))
        gate = self.policy['auxiliaryPixelGate']
        strength = np.minimum(64, np.ceil(np.maximum(primary, boundary) * 64 - 1e-6)).astype(np.int32)
        positions = np.flatnonzero(((mask > 0) & (strength <= gate['maximumSourceStrengthCode'])).ravel())
        # The auxiliary style intentionally uses RAW native extraction and p,p.
        raw_base = native > 0
        raw_distance = cv2.distanceTransform((~raw_base).astype(np.uint8), cv2.DIST_C, 3)
        aux_style = style_features(rgb, raw_base, raw_distance, primary, primary, font,
                                   dict(affinityScores=list(affinity))).astype(np.float32)
        auxiliary_features = np.column_stack([edge, np.broadcast_to(aux_style, (base.size, 18))])
        auxiliary = np.full(base.size, 65535, np.uint16)
        auxiliary[positions] = quantize(self.auxiliary.probabilities(auxiliary_features, positions))
        remove = positions[auxiliary[positions] < gate['thresholdCode']]
        mask.ravel()[remove] = 0
        if self.native_command is not None:
            packet = dict(width=w, height=h, base=(base.astype(np.uint8) * 255).ravel().tolist(),
                primary=primary.ravel().tolist(), boundary=boundary.ravel().tolist(),
                jointCodes=codes.ravel().tolist(), style=values.tolist(),
                auxiliaryCodes=auxiliary.tolist())
            result = subprocess.run(self.native_command, input=json.dumps(packet) + '\n', text=True,
                                    capture_output=True, check=True)
            answer = json.loads(result.stdout)
            if answer['policySHA256'] != POLICY_SHA or answer['GTRead'] is not False:
                raise ValueError('Native final policy identity differs')
            actual = np.asarray(answer['mask'], np.uint8).reshape(h, w)
            if not np.array_equal(actual, mask):
                raise ValueError('Native final segmentation differs from source policy')
            mask = actual
        return mask, dict(policySHA256=POLICY_SHA, GTRead=False, storedMaskRead=False,
                          finalPolicyEngine='native-swift' if self.native_command is not None else 'python-source',
                          jointPixels=int(np.count_nonzero(base | (distance <= 12))),
                          auxiliaryPixels=len(positions), auxiliaryRemoved=len(remove)), dict(
                              base=base, jointCodes=codes, style=values, auxiliaryCodes=auxiliary.reshape(base.shape))


class SourceMaskProducer:
    """Fresh native classifiers + accepted final policy on arbitrary source arrays.

    No corpus root, item key, manifest or stored observations are consumed.
    Existing native executables are authenticated, never rebuilt implicitly.
    """
    def __init__(self, *, primary_model=None, boundary_model=None, primary_binary=None, boundary_binary=None, final_runtime=None):
        primary_model = asset('primary_model') if primary_model is None else primary_model
        boundary_model = asset('boundary_model') if boundary_model is None else boundary_model
        primary_binary = asset('primary_binary') if primary_binary is None else primary_binary
        boundary_binary = asset('boundary_binary') if boundary_binary is None else boundary_binary
        expected = [('primary_model', primary_model, '8f5dba949b25c2cf54359bd8e4066c6423970980a0355887c83e150d82a0e617'),
                    ('boundary_model', boundary_model, '3df521613d2981c412c3c9a38878128d1450bb1016e7baaaddad5f3a0d3a36ea'),
                    ('primary_binary', primary_binary, '008618ec1d92e4379708aa9d3f27fd97b6156b909baf9d40021514908848ea2e'),
                    ('boundary_binary', boundary_binary, 'ef459dbebb75a0f18ac2a13884147b77b04f03e261106b747ed1a1020a3f7f01')]
        for name, path, digest in expected:
            if sha(Path(path)) != digest:
                raise ValueError('Selected native segmentation artifact changed: ' + name)
            setattr(self, name, str(Path(path).absolute()))
        self.final = final_runtime if final_runtime is not None else SourceMaskRuntime()

    def predict(self, *, rgb, polygons, font, coarse_rf, full_rf, affinity, rf_model_weights_sha256):
        if rf_model_weights_sha256 != EXPECTED_RF_WEIGHTS:
            raise ValueError('Selected segmentation requires authenticated auxiliary high-resolution RF weights')
        import tempfile
        if rgb.dtype != np.uint8 or rgb.ndim != 3 or rgb.shape[2] != 3 or not polygons:
            raise ValueError('Invalid live source RGB/geometry')
        h, w, _ = rgb.shape
        if not 0 < w * h <= 1_500_000:
            raise ValueError('Live source crop exceeds inference budget')
        with tempfile.TemporaryDirectory(prefix='aidoku-live-segmentation-') as folder:
            root = Path(folder)
            def path(name): return str(root / name)
            rgb.tofile(path('source.rgb')); coarse_rf.tofile(path('coarse.f32')); full_rf.tofile(path('full.f32'))
            first = dict(rgb=path('source.rgb'), width=w, height=h, polygons=polygons, fontPixels=font,
                coarseRF=path('coarse.f32'), fullRF=path('full.f32'), output=path('primary-mask.u8'),
                captureProbabilities=path('primary.f32'), captureNativeBase=path('native.u8'))
            def invoke(binary, model, request):
                result = subprocess.run([binary, model], input=json.dumps(request) + '\n',
                    text=True, capture_output=True, check=True)
                return json.loads(result.stdout)
            primary_audit = invoke(self.primary_binary, self.primary_model, first)
            second = dict(rgb=path('source.rgb'), width=w, height=h, fontPixels=font,
                primary=path('primary.f32'), nativeMask=path('native.u8'), coarseRF=path('coarse.f32'),
                fullRF=path('full.f32'), output=path('completed.u8'), constrainExpansion=True,
                probabilityOutput=path('boundary.f32'))
            boundary_audit = invoke(self.boundary_binary, self.boundary_model, second)
            p = np.fromfile(path('primary.f32'), np.float32).reshape(h, w)
            q = np.fromfile(path('boundary.f32'), np.float32).reshape(h, w)
            native = np.fromfile(path('native.u8'), np.uint8).reshape(h, w)
            completed = np.fromfile(path('completed.u8'), np.uint8).reshape(h, w)
            mask, audit, trace = self.final.predict(rgb=rgb, primary=p, boundary=q, native=native,
                completed=completed, coarse_rf=coarse_rf, full_rf=full_rf, font=font, affinity=affinity)
        audit.update(primaryClassifiersFresh=True, boundaryClassifierFresh=True,
                     primaryAudit=primary_audit, boundaryAudit=boundary_audit)
        return mask, audit, dict(primary=p, boundary=q, rawNative=native, completed=completed,
                                observationValid=np.ones((h,w), bool), **trace)
