"""Package only selected source segmentation artifacts and exact numerical helper closure."""
import ast
import hashlib
import json
from pathlib import Path
import shutil

from pack_primary_forest import RESOURCE_DIR, publish as publish_primary_forest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SOURCE = REPO.parent / 'segmentation-improvement-20261109'
DEST = HERE / 'assets/accepted-final'
SELECTED = {
    'policy': ('oof-style-pruning/SOURCE-POLICY.json', 'SOURCE-POLICY.json', 'dbe62f855cc112ba607c0c1a62d136c3d20779181c0b5a8a025e1fb584db6be1'),
    'joint_model': ('context-full-mask/model.joblib', 'context83.joblib', 'ae3460b3037f944fe222a6645a59140fa04a2083a75f7a1eaff9f5ac3bbf8f2c'),
    'auxiliary_model': ('oof-style-pixel/model-weight8.joblib', 'style78.joblib', 'a8715aaba6ee893ec2fe773929fcfe96328e60a5a5d0bbf047f96df79d4e3a16'),
    'primary_model': ('boundary-lean/recall-full-rf-native-pixel-forest.json', 'primary-forest.json', '8f5dba949b25c2cf54359bd8e4066c6423970980a0355887c83e150d82a0e617'),
    'boundary_model': ('edge-context60-dense48-fullseed-native/boundary-forest.json', 'boundary-forest.json', '3df521613d2981c412c3c9a38878128d1450bb1016e7baaaddad5f3a0d3a36ea'),
    'primary_binary': ('boundary-lean/native-pixel-rf-segmentation', 'native-pixel-rf-segmentation', '008618ec1d92e4379708aa9d3f27fd97b6156b909baf9d40021514908848ea2e'),
    'boundary_binary': ('edge-context60-dense48-fullseed-native/native-boundary-refiner', 'native-boundary-refiner', 'ef459dbebb75a0f18ac2a13884147b77b04f03e261106b747ed1a1020a3f7f01'),
}
FUNCTIONS = {
    'audit_kernel_free_completion.py': ['component_candidates'],
    'audit_style_calibration.py': ['style_features'],
    'train_context_recovery.py': ['context_features'],
    'train_edge_boundary.py': ['edge_features'],
    'boundary_uniformity.py': ['edge_distances'],
    'boundary_uniformity_dense.py': ['rgb_gradient'],
    'apply_joint_mask_refinement.py': ['infer', 'refine_source_mask'],
}


def digest(data): return hashlib.sha256(data).hexdigest()


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    manifest = dict(schema=1, selectedPolicySHA256=SELECTED['policy'][2], sourceOnly=True,
        expectedRFModelWeightsSHA256='03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255',
        datasetIncluded=False, GTIncluded=False, savedPredictionsIncluded=False, roles={}, files={}, functions={})
    def write(name, data, role=None):
        path=DEST/name;path.parent.mkdir(parents=True, exist_ok=True);path.write_bytes(data)
        manifest['files'][name]=dict(SHA256=digest(data), bytes=len(data))
        if role: manifest['roles'][role]=name
    for role, (old, new, expected) in SELECTED.items():
        data=(SOURCE/old).read_bytes()
        if digest(data)!=expected: raise ValueError('Selected artifact changed: '+role)
        write(new, data, role)
        if role.endswith('_binary'): (DEST/new).chmod(0o755)
    # Extract exact pure function bodies; dormant training/evaluation imports are
    # not part of the operating numerical closure. Original bytes are retained.
    code = ['"""Frozen selected source-only numerical functions; generated without changing bodies."""',
            'import cv2', 'import numpy as np', 'from types import SimpleNamespace',
            'joint = SimpleNamespace(BINS=8192, RADIUS=12)',
            'RING_NAMES = ["ringLuminanceStd", "ringLuminanceRange90", "ringChromaMean", "ringRGBStd",',
            '              "ringGradientMean", "ringGradientFraction", "ringNonwhiteFraction"]',
            'EDGE_NAMES = ["rgbEdgeDistance8RelativeFont", "rgbEdgeDistance32RelativeFont",',
            '              "rgbEdgeDistance64RelativeFont", "rgbRange3", "rgbRangeMeanFontHalf"]', '']
    for filename, names in FUNCTIONS.items():
        data=(HERE/filename).read_bytes();write('frozen-helpers/'+filename, data)
        source=data.decode();tree=ast.parse(source)
        for name in names:
            node=next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name==name)
            exact=ast.get_source_segment(source,node)
            code.extend([exact, ''])
            manifest['functions'][name]=dict(source='frozen-helpers/'+filename, SHA256=digest(exact.encode()))
    write('helpers/accepted_math.py', ('\n'.join(code)+'\n').encode(), 'math_helper')
    write('helpers/compiled_point_predict.py', (HERE/'compiled_point_predict.py').read_bytes(), 'compiled_helper')
    frozen=(HERE/'native_boundary_refiner.py').read_bytes()
    if digest(frozen)!='4f368a4abdcf7bc3b9bbef468228213e3845719ab985bde69038f3aeeb9c2150':
        raise ValueError('Accepted frozen helper changed')
    write('frozen-helpers/native_boundary_refiner.py', frozen, 'frozen_boundary_helper')
    write('provenance/PRIMARY-BUILD.json', (SOURCE/'boundary-lean/NATIVE-SEGMENTATION-BUILD.json').read_bytes())
    write('provenance/BOUNDARY-BUILD.json', (SOURCE/'edge-context60-dense48-fullseed-native/NATIVE-BUILD.json').read_bytes())
    payload=(json.dumps(manifest, indent=2, sort_keys=True)+'\n').encode()
    (DEST/'MANIFEST.json').write_bytes(payload)
    publish_primary_forest(DEST / 'primary-forest.json', RESOURCE_DIR / 'primary-forest.pr62')
    print('MANIFEST_SHA256',digest(payload),'FILES',len(manifest['files']),'BYTES',sum(f['bytes'] for f in manifest['files'].values()))


if __name__=='__main__': main()
