"""Pair finite native secondary-band observations with their source estimator."""
import hashlib
import math
from pathlib import Path

VERSION = 'source-visible-secondary-shell-policy-v1'
MODEL_NAMES = ('model.pkl', 'pixel-role-model.pkl', 'width-model.pkl',
               'background-palette.pkl', 'source-fill-palette-model.pkl',
               'final-background-model.pkl')
HELPERS = ('source_outer_shell_policy.py', 'source_outer_shell.py',
           'source_outer_shell_geometry.py', 'source_gradient_contour.py',
           'source_gradient_core.py', 'native_gradient_contour.py',
           'source_bright_ring.py', 'pixel_role_estimation.py',
           'paint_feature_context.py', 'source_appearance.py')
PRIMARY_POLICY = 'NATIVE-GRADIENT-CONTOUR-POLICY.json'


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def helper_hashes():
    return {name: digest(Path(__file__).with_name(name)) for name in HELPERS}


def make_policy(folder, threshold):
    folder = Path(folder)
    threshold = float(threshold)
    if not math.isfinite(threshold) or threshold < 0:
        raise ValueError('Invalid TRAIN null-coherence threshold')
    return dict(enabled=True, version=VERSION, minimumExcessCoherence=threshold,
                helperSHA256=helper_hashes(),
                modelIdentities={name: digest(folder / name) for name in MODEL_NAMES},
                sourcePrimaryPolicySHA256=digest(folder / PRIMARY_POLICY),
                GTAtInference=False, stage='After final source primary RGB observation',
                semantics='Visible native ordered bands only; unobserved directions remain censored. Nominal scalar width and earlier style heads are preserved.')


def validate_policy(policy, identities, primary_policy_hash):
    if not policy.get('enabled') or policy.get('version') != VERSION:
        raise ValueError('Native outer-shell policy/version mismatch')
    threshold = policy.get('minimumExcessCoherence')
    if not isinstance(threshold, (int, float)) or not math.isfinite(threshold) or threshold < 0:
        raise ValueError('Invalid native outer-shell threshold')
    if policy.get('helperSHA256') != helper_hashes():
        raise ValueError('Native outer-shell source implementation changed')
    if set(identities) != set(MODEL_NAMES) or policy.get('modelIdentities') != identities:
        raise ValueError('Native outer-shell model pairing mismatch')
    if policy.get('sourcePrimaryPolicySHA256') != primary_policy_hash:
        raise ValueError('Native outer-shell primary source policy changed')
