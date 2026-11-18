"""Narrow frozen-candidate export contracts; never trains models or scans sources.

.venv-source-inference/bin/python -m unittest discover -s Scripts/models
-p test_font_weight_export.py -v
Numeric Swift parity is the exporter's explicit --verify operation.
"""
import copy
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import export_font_weight_runtime as exporter
import numpy as np


class FontWeightExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='bold-export-contract-')
        cls.out = Path(cls.temporary.name)
        cls.bundle, cls.objects, cls.docs = exporter.export_candidate(exporter.SOURCE, cls.out)
        cls.registry = json.loads((cls.out / 'registry.json').read_text())

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_all_original_heads_and_thresholds_are_preserved(self):
        self.assertEqual(len(self.objects), 5)
        tree = self.registry['metadata']['tree'][exporter.PREFIX]
        for key, original in self.docs.items():
            spec = self.registry['heads'][key]
            self.assertEqual(exporter.digest(self.out / spec['asset']), spec['sha256'])
            decoded = plistlib.loads((self.out / spec['asset']).read_bytes())
            self.assertEqual(decoded, original)
            source, portable = self.bundle, tree
            for part in key.removeprefix(exporter.PREFIX + '/').split('/')[:-1]:
                source, portable = source[part], portable[part]
            self.assertEqual(portable['threshold'], source['threshold'])
            self.assertEqual(portable['model'], {'modelID': key})
        index = json.loads((self.out / 'registry-index.json').read_text())
        self.assertEqual(index['metadataSHA256'], exporter.digest(self.out / 'registry.json'))
        self.assertEqual(exporter.digest(exporter.SOURCE), exporter.SHA)

    def test_metadata_round_trip_except_explicit_font_path_relocation(self):
        tree = copy.deepcopy(self.registry['metadata']['tree'][exporter.PREFIX])
        manifest = json.loads((self.out / 'font-asset-obligations.json').read_text())
        self.assertEqual(len(manifest['fonts']), 27)
        self.assertFalse(manifest['copiedFontBytes'])
        for font in manifest['fonts']:
            current = tree
            for part in font['metadataPath'].split('/'):
                current = current[int(part)] if isinstance(current, list) else current[part]
            self.assertEqual(current['path'], font['asset'])
            self.assertEqual(current['SHA256'], font['sha256'])
            self.assertEqual(current['weight'], font['weight'])
            self.assertFalse((self.out / current['path']).exists())
            current['path'] = font['originalPath']
        expected = exporter.base.metadata_tree(self.bundle, exporter.PREFIX)
        self.assertEqual(tree, expected)
        self.assertFalse(self.registry['productionActivated'])
        self.assertFalse(self.registry['nativeFeatureExtractionComplete'])
        self.assertNotIn('/Users/', json.dumps(self.registry))
        files = [p for p in self.out.rglob('*') if p.is_file()]
        self.assertTrue(all(p.suffix in ('.json', '.plist') for p in files))

    def test_unapproved_evaluation_metadata_is_rejected(self):
        for path in ('', 'orderedInkPolicy', 'body'):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, 'Unapproved metadata'):
                exporter.portable_metadata({'rowIDs': ['forbidden']}, path)
        with self.assertRaisesRegex(ValueError, 'Unapproved metadata array'):
            exporter.portable_metadata([0, 1], 'threshold')

    def test_sha_gate_precedes_unpickle_and_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'untrusted.pkl'
            source.write_bytes(b'not a pickle')
            with patch.object(exporter.base, 'load', side_effect=AssertionError('must not unpickle')):
                with self.assertRaisesRegex(ValueError, 'SHA mismatch'):
                    exporter.export_candidate(source, root / 'out')
            self.assertFalse((root / 'out').exists())

    def test_failed_cli_attempt_invalidates_previous_pass_receipts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'invalid.pkl'
            source.write_bytes(b'invalid')
            for receipt in ('PARITY.json', 'STUDY.json'):
                (root / receipt).write_text('{"passed":true}')
            with patch('sys.argv', ['export', '--source', str(source), '--out', str(root)]):
                with self.assertRaisesRegex(ValueError, 'SHA mismatch'):
                    exporter.main()
            for receipt in ('PARITY.json', 'STUDY.json'):
                self.assertFalse((root / receipt).exists())

    def test_probe_generation_is_deterministic_and_contains_missing_values(self):
        for doc in self.docs.values():
            finite, missing = exporter.probe_rows(doc)
            again, _ = exporter.probe_rows(doc)
            np.testing.assert_array_equal(finite, again)
            self.assertEqual(finite.shape, (51, doc['featureCount']))
            self.assertTrue(np.isfinite(finite).all())
            self.assertTrue(np.isnan(missing[0]).all())
            self.assertEqual(len(missing), 5)


if __name__ == '__main__':
    unittest.main()
