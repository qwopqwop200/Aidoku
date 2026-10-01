import copy
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from verify_native_quality_result import EXPECTED, main, verify


def complete_tree():
    return {'testNodes': [
        {'name': suite, 'nodeType': 'Test Suite', 'result': 'Passed', 'children': [
            {'name': method + '()', 'nodeType': 'Test Case', 'result': 'Passed', 'children': [
                {'name': str(index), 'nodeType': 'Arguments', 'result': 'Passed'}
                for index in range(count)]}
            for method, count in methods.items()]}
        for suite, methods in EXPECTED.items()]}


class NativeQualityResultTests(unittest.TestCase):
    def test_complete_three_suite_matrix(self):
        result = verify(complete_tree())
        self.assertEqual(result['requiredDeclarations'], 22)
        self.assertEqual(result['requiredCaseExecutions'], 219)
        self.assertEqual(result['scenarioGroups'], 418)

    def test_suite_ownership_and_aggregate_ruby_counts(self):
        result = verify(complete_tree())
        self.assertEqual([(row['suite'], row['requiredDeclarations'], row['requiredCaseExecutions'], row['scenarioGroups'])
                          for row in result['suites']], [
            ('NativeSourceSegmentationMatrixTests', 5, 147, 147),
            ('NativeSlantedRestorationMatrixTests', 11, 53, 252),
            ('NativeSourceOwnershipMatrixTests', 6, 19, 19),
        ])

    def test_nonzero_other_tests_cannot_hide_missing_suite(self):
        tree = complete_tree()
        tree['testNodes'].pop()
        with self.assertRaisesRegex(ValueError, 'expected one executed suite'):
            verify(tree)

    def test_empty_passed_suite_fails(self):
        tree = complete_tree()
        tree['testNodes'][0]['children'].clear()
        with self.assertRaisesRegex(ValueError, 'expected one executed declaration'):
            verify(tree)

    def test_missing_parameter_case_fails(self):
        tree = complete_tree()
        tree['testNodes'][0]['children'][0]['children'].pop()
        with self.assertRaisesRegex(ValueError, 'expected 120 distinct argument cases'):
            verify(tree)

    def test_duplicate_parameter_case_fails(self):
        tree = complete_tree()
        arguments = tree['testNodes'][0]['children'][0]['children']
        arguments[1] = copy.deepcopy(arguments[0])
        with self.assertRaisesRegex(ValueError, 'expected 120 distinct argument cases'):
            verify(tree)

    def test_failed_skipped_expected_failure_child_never_passes(self):
        for status in ['Failed', 'Skipped', 'Expected Failure', None]:
            tree = complete_tree()
            tree['testNodes'][0]['children'][0]['children'][0]['result'] = status
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, 'non-passing result'):
                verify(tree)

    def test_duplicate_suite_fails(self):
        tree = complete_tree()
        tree['testNodes'].append(copy.deepcopy(tree['testNodes'][0]))
        with self.assertRaisesRegex(ValueError, 'expected one executed suite'):
            verify(tree)

    def test_cli_exports_documented_xcresult_json_and_persists_evidence(self):
        raw = json.dumps(complete_tree()).encode()
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / 'result.xcresult'
            output = Path(temporary) / 'coverage.json'
            with patch('sys.argv', ['verify_native_quality_result.py', str(bundle), '--output', str(output)]), \
                    patch('verify_native_quality_result.subprocess.check_output', return_value=raw) as export, \
                    patch('sys.stdout', new_callable=io.StringIO):
                self.assertEqual(main(), 0)
            export.assert_called_once_with(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
                                            '--path', str(bundle), '--compact'])
            self.assertEqual(output.with_suffix('.tests.json').read_bytes(), raw)
            self.assertEqual(json.loads(output.read_text()), verify(complete_tree()))

    def test_cli_export_failure_cannot_write_passing_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'coverage.json'
            with patch('sys.argv', ['verify_native_quality_result.py', 'missing.xcresult', '--output', str(output)]), \
                    patch('verify_native_quality_result.subprocess.check_output',
                          side_effect=subprocess.CalledProcessError(64, ['xcrun'])), \
                    patch('sys.stderr', new_callable=io.StringIO) as errors:
                self.assertEqual(main(), 1)
            self.assertFalse(output.exists())
            self.assertIn('Native quality execution verification failed', errors.getvalue())


if __name__ == '__main__':
    unittest.main()
