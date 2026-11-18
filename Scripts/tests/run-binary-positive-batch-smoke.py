"""Model-free synthetic regression compiling actual production evaluator sources."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble'
SOURCES = [ENGINE / 'NativeAppearanceForest.swift', ENGINE / 'NativeFrozenSourceModel.swift']
if 'func preparedPositiveProbabilities()' not in SOURCES[1].read_text():
    raise SystemExit('Approved binary batch patch is not applied; do not test a candidate as production')
before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
with tempfile.TemporaryDirectory(prefix='aidoku-binary-positive-batch-smoke-') as temporary:
    folder = Path(temporary)
    executable = folder / 'batch-smoke'
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(folder / 'modules'),
                    *map(str, SOURCES), str(Path(__file__).with_name('NativeBinaryPositiveBatchSmoke.swift')),
                    '-o', str(executable)], check=True, cwd=ROOT)
    completed = subprocess.run([str(executable)], cwd=ROOT, capture_output=True, text=True, check=True)
    result = json.loads(completed.stdout)
    assert result['passed'] and result['exactProbabilityComparisons'] >= 70
    assert result['rejections'] >= 31 and result['unsupportedValidFallbackCases'] == 3
    assert result['learnedModelsRead'] == result['corpusFilesRead'] == 0
    assert before == {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
    print(json.dumps(dict(passed=True, result=result, productionSourceSHA256=before,
                          candidateSourcesCompiled=False, learnedModelRuns=0, corpusFilesRead=0), indent=2))
