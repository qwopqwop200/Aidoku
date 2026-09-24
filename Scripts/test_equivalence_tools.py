"""Offline evidence integrity and pull destination safety regressions."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('equivalence_compare', ROOT / 'Scripts/equivalence/compare.py')
compare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compare)


class EquivalenceToolsTests(unittest.TestCase):
    def test_missing_render_is_not_equivalence(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertFalse(compare.compare_png(directory + '/a.png', directory + '/b.png', None, 0)['ok'])

    def test_empty_run_is_not_equivalence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'results.json').write_text(json.dumps({'metadata': {}, 'rows': []}))
            result = subprocess.run(['python3', str(ROOT / 'Scripts/equivalence/compare.py'),
                                     directory, directory, '--no-timing'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('OVERALL: FAIL', result.stdout)

    def test_pull_rejects_traversal_and_preserves_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / 'runs'
            destination.mkdir()
            existing = destination / 'baseline'
            existing.mkdir()
            sentinel = existing / 'results.json'
            sentinel.write_text('preserve me')
            for label in ['..', '../baseline', '/absolute', 'baseline']:
                result = subprocess.run(['bash', str(ROOT / 'Scripts/equivalence/pull.sh'),
                                         label, str(destination)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(sentinel.read_text(), 'preserve me')

    def test_pull_success_uses_requested_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'xcrun'
            fake.write_text('#!/bin/bash\nwhile [[ $# -gt 0 ]]; do\n'
                            'if [[ "$1" == --destination ]]; then mkdir -p "$2"; '
                            'echo "{}" > "$2/results.json"; exit 0; fi\nshift\ndone\nexit 1\n')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['bash', str(ROOT / 'Scripts/equivalence/pull.sh'),
                                     'baseline-1', str(root / 'runs')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / 'runs/baseline-1/results.json').read_text(), '{}\n')

    def test_layout_zero_tolerance_detects_fractional_change(self):
        self.assertFalse(compare.compare_layout({'x': 1}, {'x': 1.001}, 0)['ok'])
        self.assertTrue(compare.compare_layout({'x': 1}, {'x': 1}, 0)['ok'])


if __name__ == '__main__':
    unittest.main()
