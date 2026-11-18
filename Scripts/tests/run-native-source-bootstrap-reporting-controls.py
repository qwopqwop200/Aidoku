#!/usr/bin/env python3
"""Pure contract/reporting controls: synthetic diagnostics, no native build or corpus."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

RUNNER = Path(__file__).with_name('run-native-source-bootstrap-smoke.py')
MODULE = importlib.util.spec_from_file_location('source_bootstrap_smoke', RUNNER)
smoke = importlib.util.module_from_spec(MODULE)
MODULE.loader.exec_module(smoke)


def fixture(paragraph_shift=False):
    pages = []
    for pid, mode, raw in [('0001', 'commit', 1), ('0002', 'commit', 1),
                           ('0003', 'commit', 1),
                           ('0528', 'commit' if paragraph_shift else 'rollback',
                            0 if paragraph_shift else 1), ('0005', 'abstain', 0)]:
        restored = ['owner11'] if mode == 'commit' else []
        omitted = ['raw'] if raw else []
        pages.append({'id': pid, 'sourceSHA256': 'a' * 64, 'payloadSHA256': 'b' * 64,
            'expectedInputIDs': restored + omitted, 'expectedCardIDs': restored[:],
            'expectedRestoredIDs': restored[:], 'expectedOmittedIDs': omitted,
            'expectedCheckedIDs': restored[:], 'transaction': mode,
            'expectedContainment': {cid: None for cid in restored},
            'expectedUTF16Lengths': {cid: 2 for cid in restored},
            'expectedSourceOwners': {cid: [0, 0, 10, 10] for cid in restored},
            **({'expectedRejectedReasons': {'raw': 'peer-overlap'}} if mode == 'rollback' else {})})
    manifest = {'schemaVersion': 1, 'pages': pages}
    if paragraph_shift:
        manifest.update(expectedTotals={'restored': 4, 'rawRemaining': 3},
            expectedTransactionInventory={'commit': 4, 'rollback': 0, 'abstain': 1})
    return manifest


def diagnostic_row(spec):
    cards = [{'id': cid, 'inputUTF16Length': 2, 'visibleUTF16Range': [0, 2],
              'sourceOwner': [0, 0, 10, 10]} for cid in spec['expectedCardIDs']]
    diag = {'cards': cards,
        'omittedInputs': [{'id': cid, 'stage': 'text-space'} for cid in spec['expectedOmittedIDs']]}
    mode = spec['transaction']
    if mode != 'abstain':
        born = spec['expectedRestoredIDs'] if mode == 'commit' else ['raw']
        diag[smoke.TRANSACTION] = {'committed': mode == 'commit', 'maximumBirths': 2,
            'maximumAlphaPixels': 8_000_000, 'alphaPixelsCharged': 10,
            'bornIDs': born[:], 'proposedIDs': born[:], 'runtimeCheckedIDs': born[:],
            'serializedPDFMeasured': False,
            'birthAdmission': {cid: {'balloonContainment': None,
                'nilSurfaceMeansNoBalloon': False, 'incumbentTextAlpha': 'known-empty',
                'admission': {'accepted': mode == 'commit', 'clipPixels': 0, 'peerPixels': 0,
                    'modes': smoke.MODES[:], 'serializedPDFMeasured': False,
                    'occupiedAcrossModes': 1, 'reason': 'peer-overlap'}} for cid in born}}
        diag[smoke.REUSE] = {'metadataLogicalByteLimit': 4_194_304,
            'retainedMetadataLogicalBytes': 0, 'peakRetainedMetadataLogicalBytes': 0,
            'sourcePrefixOwnerLimit': 64, 'readerCacheLogicalByteLimit': 16_777_216,
            'readerCacheLiveUpperBound': 0, 'persistentCacheAdded': False,
            'sourceFilterResolutionAndColorPolicyChanged': False}
    return {'id': spec['id'], 'status': 'prepared',
        'expectedRenderCardIDs': spec['expectedInputIDs'][:], 'diagnostics': diag}


class ReportingControls(unittest.TestCase):
    def test_legacy_and_paragraph_shift_contracts_and_reports(self):
        for shifted, expected in [(False, (3, 4)), (True, (4, 3))]:
            with self.subTest(paragraph_shift=shifted):
                manifest = fixture(shifted)
                before = copy.deepcopy(manifest)
                specs = smoke.validate_manifest(manifest)
                rows = [diagnostic_row(spec) for spec in specs]
                problems = [problem for row, spec in zip(rows, specs)
                            for problem in smoke.check_diagnostics(row, spec)]
                report = smoke.inventory_report(rows, manifest, problems)
                self.assertEqual(problems, [])
                self.assertEqual((report['restored'], report['rawRemaining']), expected)
                self.assertEqual((report['expectedRestored'], report['expectedRawRemaining']), expected)
                self.assertEqual(manifest, before)

    def test_declarations_default_independently(self):
        for field in ('expectedTotals', 'expectedTransactionInventory'):
            manifest = fixture(True)
            del manifest[field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                smoke.validate_manifest(manifest)

    def test_strict_declaration_objects(self):
        for field, valid in [('expectedTotals', {'restored': 3, 'rawRemaining': 4}),
                             ('expectedTransactionInventory', {'commit': 3, 'rollback': 1, 'abstain': 1})]:
            key = next(iter(valid))
            malformed = [None, [], 0, {}, {**valid, 'typo': 0}]
            malformed += [{**valid, key: value} for value in (True, False, -1, 1.0, '3', None)]
            partial = dict(valid)
            del partial[key]
            malformed.append(partial)
            for value in malformed:
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    smoke.validate_manifest({**fixture(), field: value})

    def test_inconsistent_declarations_fail(self):
        for totals in ({'restored': 5, 'rawRemaining': 3}, {'restored': 4, 'rawRemaining': 4}):
            with self.subTest(totals=totals), self.assertRaises(ValueError):
                smoke.validate_manifest({**fixture(True), 'expectedTotals': totals})
        for inventory in ({'commit': 4, 'rollback': 1, 'abstain': 1},
                          {'commit': 3, 'rollback': 1, 'abstain': 1}):
            with self.subTest(inventory=inventory), self.assertRaises(ValueError):
                smoke.validate_manifest({**fixture(True), 'expectedTransactionInventory': inventory})

    def test_manifest_negative_controls(self):
        for mutation in ('subset', 'duplicate', 'schema-bool', 'bad-page', 'bad-id',
                         'owner-partition', 'unknown-containment', 'rollback-reason'):
            manifest = fixture()
            if mutation == 'subset':
                manifest['pages'].pop()
            elif mutation == 'duplicate':
                manifest['pages'][1]['id'] = manifest['pages'][0]['id']
            elif mutation == 'schema-bool':
                manifest['schemaVersion'] = True
            elif mutation == 'bad-page':
                manifest['pages'][0] = None
            elif mutation == 'bad-id':
                manifest['pages'][0]['id'] = []
            elif mutation == 'owner-partition':
                manifest['pages'][0]['expectedOmittedIDs'] = ['owner11']
            elif mutation == 'unknown-containment':
                manifest['pages'][0]['expectedContainment']['owner11'] = 'unknown'
            else:
                del manifest['pages'][3]['expectedRejectedReasons']
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                smoke.validate_manifest(manifest)

    def test_failed_admission_never_certifies_observed_births(self):
        manifest = fixture(True)
        rows = [diagnostic_row(spec) for spec in manifest['pages']]
        spec = manifest['pages'][3]
        rows[3]['diagnostics'][smoke.TRANSACTION]['birthAdmission']['owner11']['admission']['peerPixels'] = 1
        problems = smoke.check_diagnostics(rows[3], spec)
        self.assertIn(['0528', 'owner11:native-clip-peer-or-unmeasured'], problems)
        report = smoke.inventory_report(rows, manifest, problems)
        self.assertIsNone(report['restored'])
        self.assertIsNone(report['rawRemaining'])
        self.assertEqual(report['observedCommittedBirths'], 4)
        self.assertEqual(report['observedRawOmissions'], 3)

    def test_inventory_mismatch_fails_and_rollback_births_are_not_counted(self):
        manifest = fixture()
        rows = [diagnostic_row(spec) for spec in manifest['pages']]
        self.assertEqual(smoke.observed_inventory(rows), (3, 4))
        rows[0]['diagnostics']['cards'] = []
        problems = []
        report = smoke.inventory_report(rows, manifest, problems)
        self.assertEqual(problems, [['run', 'observed-owner-totals-mismatch']])
        self.assertIsNone(report['restored'])
        self.assertIsNone(report['rawRemaining'])
        self.assertEqual(report['observedCommittedBirths'], 2)

    def test_native_negative_controls_remain_failures(self):
        spec = fixture(True)['pages'][0]
        cases = [
            (['status'], 'failed', 'not-prepared'),
            (['diagnostics', 'omittedInputs', 0, 'stage'], 'other', 'omission-cause-changed'),
            (['diagnostics', 'cards', 0, 'visibleUTF16Range'], [0, 1], 'owner11:incomplete-input-UTF16'),
            (['diagnostics', smoke.TRANSACTION, 'maximumBirths'], 3, 'birth-or-alpha-work-budget'),
            (['diagnostics', smoke.TRANSACTION, 'serializedPDFMeasured'], True, 'wrong-native-authority'),
            (['diagnostics', smoke.TRANSACTION, 'birthAdmission', 'owner11', 'balloonContainment'],
             True, 'owner11:containment-unknown-became-pass-or-type-drift'),
            (['diagnostics', smoke.REUSE, 'readerCacheLiveUpperBound'],
             16_777_217, 'reader-cache-budget'),
            (['diagnostics', smoke.REUSE, 'persistentCacheAdded'], True, 'source-filter-color-or-cache-policy')]
        for path, value, code in cases:
            row = diagnostic_row(spec)
            target = row
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(code=code):
                self.assertIn([spec['id'], code], smoke.check_diagnostics(row, spec))

    def test_no_corpus_is_skip77(self):
        process = subprocess.run([sys.executable, '-B', str(RUNNER)], capture_output=True, text=True)
        self.assertEqual(process.returncode, 77, process.stderr)
        self.assertEqual(json.loads(process.stdout)['status'], 'SKIP')


if __name__ == '__main__':
    unittest.main()
