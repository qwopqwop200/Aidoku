"""Model-free actual production policy/domain regression, baseline/0/core-zero.

The dense reference is an EXACT asserted seam reversal of the domain-only patch,
hash-pinned to its frozen pre-optimization production source. Never compare the
applied candidate to itself. No learned asset, corpus, GT or model is loaded.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeSegmentationFinalPolicy.swift'
FROZEN_DENSE_SOURCE_SHA256 = '221cccba1d801ae6d4068b25a0c1ac4859e791352f62c5bcee7e35304ff23e82'


def reverse_once(source, old, new):
    if source.count(old) != 1:
        raise AssertionError('Production domain seam changed; review dense reference explicitly: ' + old[:100])
    return source.replace(old, new)


source = POLICY.read_text()
# The opt-in source-connected weak cleanup is separate from this unchanged
# four-member policy. Remove ONLY that declared addition before hash-pinning
# the historical dense reference; the frozen digest below still catches drift.
begin = source.index('    /// Comparison-only replacement for the style78 gate:')
end = source.index('    /// Exact eight-connected distance, matching OpenCV DIST_C including empty seeds.', begin)
reference_source = source[:begin] + source[end:]
dense = reverse_once(reference_source,
    '    /// Every member/strong/weak result is confined to base OR its outer radius.\n'
    '    static var requiredJointRadius: Int { accepted.ensembleMembers.map(\\.outerRadiusPixels).max() ?? 0 }\n\n', '')
dense = reverse_once(dense,
    '        let jointRadius = requiredJointRadius\n', '')
dense = reverse_once(dense,
    'for i in 0..<n where input.base[i] != 0 || distance[i] <= jointRadius {',
    'for i in 0..<n where input.base[i] != 0 || distance[i] <= 12 {')
dense = reverse_once(dense,
    "                    // Never read UNCOMPUTED codes outside this member's decision domain.\n"
    '                    guard base || distance[i] <= member.outerRadiusPixels else { return 0 }\n', '')
assert hashlib.sha256(dense.encode()).hexdigest() == FROZEN_DENSE_SOURCE_SHA256, 'Dense seam reversal does not match frozen baseline source'
dense = dense.replace('NativeSegmentationFinalPolicy', 'DenseSegmentationPolicy').replace('NativeSegmentationFinalStream', 'DenseSegmentationFinalStream')
with tempfile.TemporaryDirectory(prefix='aidoku-joint-domain-smoke-') as temporary:
    folder = Path(temporary)
    dense_file = folder / 'DenseSegmentationPolicy.swift'
    dense_file.write_text(dense)
    executable = folder / 'joint-domain-smoke'
    started = time.monotonic()
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(folder / 'modules'),
                    str(POLICY), str(dense_file), str(Path(__file__).with_name('NativeSegmentationJointDomainSmoke.swift')),
                    '-o', str(executable)], check=True, cwd=ROOT)
    build_seconds = time.monotonic() - started
    modes = []
    started = time.monotonic()
    for mode in (None, '0', '1'):
        environment = dict(os.environ)
        environment.pop('AIDOKU_SEGMENTATION_CORE_ZERO', None)
        if mode is not None:
            environment['AIDOKU_SEGMENTATION_CORE_ZERO'] = mode
        completed = subprocess.run([str(executable), '1' if mode == '1' else '0'], cwd=ROOT,
                                   env=environment, capture_output=True, text=True, check=True)
        result = json.loads(completed.stdout)
        assert result['passed'] and result['cases'] == 36 and result['maskAndUnprunedExact'] == 72
        assert result['weakPositionsExact'] == 36 and result['requiredInvalidCodesRejected'] >= 48
        assert result['outsideDomainCodesIgnoredBeforeNumericUse'] > 0
        modes.append(dict(environmentMode='absent' if mode is None else mode, **result))
    assert modes[0]['resultDigest'] == modes[1]['resultDigest']
    assert modes[0]['policySHA256'] == modes[1]['policySHA256'] != modes[2]['policySHA256']
    assert POLICY.read_text() == source
    print(json.dumps(dict(passed=True, modes=modes, denseReferenceSourceSHA256=FROZEN_DENSE_SOURCE_SHA256,
                          actualProductionSourceSHA256=hashlib.sha256(source.encode()).hexdigest(),
                          buildSeconds=build_seconds, testSeconds=time.monotonic() - started,
                          modelRuns=0, corpusFilesRead=0), indent=2))
