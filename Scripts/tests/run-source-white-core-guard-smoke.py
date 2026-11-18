"""Model-free production source-white/BW guard and diagnostic resume-fence regression."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble'
sources = ['NativeOperationalAppearance', 'NativeSourceStyleConsistency', 'NativeExplicitDisplayStrokePolicy',
           'NativeRenderedStrokeSelection', 'NativeDiskAlphaMaximum', 'NativeMandatoryDisplayStroke']
with tempfile.TemporaryDirectory(prefix='aidoku-source-white-guard-') as temporary:
    folder = Path(temporary)
    executable = folder / 'guard-smoke'
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(folder / 'modules'),
                    *[str(ENGINE / (name + '.swift')) for name in sources],
                    str(Path(__file__).with_name('NativeSourceWhiteCoreGuardSmoke.swift')),
                    '-o', str(executable)], check=True, cwd=ROOT)
    results = []
    for flag in (None, '0', '1'):
        environment = dict(os.environ)
        environment.pop('AIDOKU_SOURCE_CONTOUR_ONLY', None)
        if flag is not None:
            environment['AIDOKU_SOURCE_CONTOUR_ONLY'] = flag
        completed = subprocess.run([str(executable), '1' if flag == '1' else '0'], cwd=ROOT,
                                   env=environment, capture_output=True, text=True, check=True)
        result = json.loads(completed.stdout)
        assert result['passed'] and result['checks'] >= 25 and result['visibleBlackGuardPixels'] > 0
        results.append(result)
    assert results[0]['resumeProjectionSHA256'] == results[1]['resumeProjectionSHA256']
    assert results[1]['resumeProjectionSHA256'] != results[2]['resumeProjectionSHA256']
    host = (ROOT / 'Scripts/image-translation/PipelineMain.swift').read_text()
    assert '"sourceContourOnlyDiagnostic": NativeOperationalAppearance.sourceContourOnlyDiagnosticEnabled,' in host
    assert 'saved["resumeIdentity"] as? String == expectedResumeIdentity' in host
    print(json.dumps(dict(passed=True, modes=results, hostUsesSharedGate=True,
                          existingResumeMismatchRejectionRetained=True, modelRuns=0, corpusFilesRead=0), indent=2))
