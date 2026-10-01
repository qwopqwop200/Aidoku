"""Regression checks for complete execution, deadlines and source rebuild policy."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

import test_quick


def passed_summary():
    return dict(result='Passed', totalTestCount=1, passedTests=1, failedTests=0,
                skippedTests=0, expectedFailures=0, testFailures=[])


def passed_tree(*suites):
    return {'testNodes': [
        {'name': name, 'nodeType': 'Test Suite', 'result': 'Passed', 'children': [
            {'name': 'checksBehavior()', 'nodeType': 'Test Case', 'result': 'Passed'}]}
        for name in suites]}


class QuickIOSRunnerTests(unittest.TestCase):
    def run_ios(self, extra=(), output=b'Test run with 1 test passed after 0.12 seconds\n',
                selection=('--ios', 'ExampleTests'), summary=None, exit_code=0, tree=None, tree_error=None):
        commands, timeouts, exports = [], [], []
        selected = selection[1:] if selection[0] == '--ios' else ()
        tree = passed_tree(*selected) if tree is None else tree
        summary = passed_summary() if summary is None else summary

        def start(command, **kwargs):
            commands.append(command)
            kwargs['stdout'].write(output)

            class Process:
                def wait(self, timeout=None):
                    timeouts.append(timeout)
                    return exit_code

            return Process()

        def result_json(_bundle, *arguments):
            exports.append(arguments)
            if arguments == ('test-results', 'summary'):
                return summary
            if arguments == ('test-results', 'tests'):
                if tree_error:
                    raise tree_error
                return tree
            self.assertEqual(arguments, ('log', '--type', 'build'))
            return {'duration': 0.25}

        with tempfile.TemporaryDirectory() as directory:
            argv = ['test_quick.py', *selection, '--device', 'example',
                    '--derived-data', str(Path(directory) / 'cache'),
                    '--result-bundle', str(Path(directory) / 'results.xcresult'), *extra]
            with patch('sys.argv', argv), patch.object(test_quick.subprocess, 'Popen', side_effect=start):
                with patch.object(test_quick, 'xcresult_json', side_effect=result_json):
                    with contextlib.redirect_stdout(io.StringIO()):
                        code = test_quick.main()
            report = json.loads((Path(directory) / 'results.summary.json').read_text())
            self.assertEqual(report['summary'], summary)
            self.assertEqual(report['buildActivitySeconds'], 0.25)
            tree_path = Path(directory) / 'results.tests.json'
            if selected:
                self.assertEqual(report['selectionEvidence']['requestedSuites'], list(selected))
                self.assertIn(('test-results', 'tests'), exports)
                if tree_error is None:
                    self.assertEqual(json.loads(tree_path.read_text()), tree)
            else:
                self.assertIsNone(report['selectionEvidence'])
                self.assertNotIn(('test-results', 'tests'), exports)
                self.assertFalse(tree_path.exists())
        return code, commands, timeouts

    def test_ios_compilation_and_tests_have_no_default_deadline(self):
        code, commands, timeouts = self.run_ios()
        self.assertEqual(code, 0)
        self.assertEqual(timeouts, [None])
        self.assertEqual(commands[0][1], 'test')
        self.assertIn('ONLY_ACTIVE_ARCH=YES', commands[0])
        self.assertIn('SWIFT_COMPILATION_MODE=singlefile', commands[0])

    def test_fast_ios_uses_default_plan_without_narrowing_it(self):
        code, commands, timeouts = self.run_ios(selection=('--fast-ios',))
        self.assertEqual(code, 0)
        command = commands[0]
        self.assertEqual(command[command.index('-testPlan') + 1], 'AidokuFast')
        self.assertEqual(command[command.index('-configuration') + 1], 'Release')
        self.assertFalse(any(arg.startswith('-only-testing:') for arg in command))
        self.assertEqual(timeouts, [None])

    def test_full_ios_uses_complete_plan_optimized_single_simulator_and_no_deadline(self):
        code, commands, timeouts = self.run_ios(selection=('--full-ios',))
        self.assertEqual(code, 0)
        command = commands[0]
        self.assertEqual(command[command.index('-testPlan') + 1], 'AidokuFull')
        self.assertEqual(command[command.index('-configuration') + 1], 'Release')
        self.assertIn('SWIFT_OPTIMIZATION_LEVEL=-O', command)
        self.assertIn('CODE_SIGNING_ALLOWED=YES', command)
        self.assertIn('CODE_SIGNING_REQUIRED=YES', command)
        self.assertIn('CODE_SIGN_IDENTITY=-', command)
        self.assertFalse(any(arg.startswith(('-only-testing:', '-skip-testing:')) for arg in command))
        self.assertEqual(command[command.index('-parallel-testing-enabled') + 1], 'NO')
        self.assertEqual(command[command.index('-maximum-concurrent-test-simulator-destinations') + 1], '1')
        self.assertEqual(timeouts, [None])

    def test_explicit_suite_can_run_outside_fast_plan(self):
        code, commands, _ = self.run_ios()
        self.assertEqual(code, 0)
        command = commands[0]
        self.assertEqual(command[command.index('-testPlan') + 1], 'AidokuFull')
        self.assertIn('-only-testing:AidokuTests/ExampleTests', command)

    def test_multiple_bare_suites_are_each_selected(self):
        code, commands, _ = self.run_ios(selection=('--ios', 'FirstTests', 'SecondTests'))
        self.assertEqual(code, 0)
        self.assertEqual([arg for arg in commands[0] if arg.startswith('-only-testing:')],
                         ['-only-testing:AidokuTests/FirstTests', '-only-testing:AidokuTests/SecondTests'])

    def test_missing_suite_cannot_hide_behind_another_passing_suite(self):
        code, _, _ = self.run_ios(selection=('--ios', 'FirstTests', 'TypoTests'),
                                  tree=passed_tree('FirstTests'))
        self.assertNotEqual(code, 0)
        problem = test_quick.selected_suite_execution_error(passed_tree('FirstTests'), ['FirstTests', 'TypoTests'])
        self.assertIn("'TypoTests'", problem)
        self.assertIn('found 0', problem)

    def test_empty_suite_cannot_hide_behind_another_passing_suite(self):
        tree = passed_tree('FirstTests', 'EmptyTests')
        tree['testNodes'][1]['children'] = []
        self.assertNotEqual(self.run_ios(selection=('--ios', 'FirstTests', 'EmptyTests'), tree=tree)[0], 0)

    def test_nonpassing_parameter_execution_cannot_hide_in_passed_suite(self):
        for status in ('Skipped', 'Failed', 'Expected Failure', None):
            tree = passed_tree('ExampleTests')
            tree['testNodes'][0]['children'][0]['children'] = [
                {'name': '1', 'nodeType': 'Arguments', 'result': status}]
            with self.subTest(status=status):
                self.assertNotEqual(self.run_ios(tree=tree)[0], 0)

    def test_nested_suites_and_parameter_cases_follow_actual_tree_schema(self):
        tree = passed_tree('ExampleTests')
        tree['testNodes'][0]['children'][0]['children'] = [
            {'name': '1', 'nodeType': 'Arguments', 'result': 'Passed'},
            {'name': '2', 'nodeType': 'Arguments', 'result': 'Passed'}]
        tree = {'testNodes': [{'name': 'AidokuTests', 'nodeType': 'Test Plan',
                              'children': tree['testNodes']}]}
        self.assertEqual(self.run_ios(tree=tree)[0], 0)

    def test_duplicate_suite_and_malformed_tree_fail_closed(self):
        for tree in (passed_tree('ExampleTests', 'ExampleTests'), {},
                     {'testNodes': ['not a node']},
                     {'testNodes': [{'children': 'not a list'}]}):
            with self.subTest(tree=tree):
                self.assertNotEqual(self.run_ios(tree=tree)[0], 0)

    def test_missing_test_tree_export_fails_selected_scope(self):
        error = subprocess.CalledProcessError(64, ['xcrun'])
        self.assertNotEqual(self.run_ios(tree_error=error)[0], 0)

    def test_duplicate_requested_names_do_not_require_duplicate_executions(self):
        self.assertEqual(self.run_ios(selection=('--ios', 'ExampleTests', 'ExampleTests'),
                                      tree=passed_tree('ExampleTests'))[0], 0)

    def test_method_selectors_fail_before_build_even_when_another_suite_would_run(self):
        for selector in ('ExampleTests/testValue', 'ExampleTests/testValue()',
                         'AidokuTests/ExampleTests', 'testValue()'):
            with self.subTest(selector=selector), tempfile.TemporaryDirectory() as directory:
                cache = Path(directory) / 'cache'
                bundle = Path(directory) / 'results.xcresult'
                argv = ['test_quick.py', '--ios', 'ValidTests', selector, '--device', 'example',
                        '--derived-data', str(cache), '--result-bundle', str(bundle)]
                error = io.StringIO()
                with patch('sys.argv', argv), patch.object(test_quick.subprocess, 'Popen') as start:
                    with contextlib.redirect_stderr(error), self.assertRaises(SystemExit) as raised:
                        test_quick.main()
                self.assertEqual(raised.exception.code, 2)
                self.assertIn('--ios accepts bare suite names only', error.getvalue())
                self.assertIn('run the whole affected suite', error.getvalue())
                start.assert_not_called()
                self.assertFalse(cache.exists())
                self.assertFalse(bundle.exists())

    def test_explicit_deadline_can_exceed_former_limit(self):
        code, _, timeouts = self.run_ios(['--seconds', '120'])
        self.assertEqual(code, 0)
        self.assertGreater(timeouts[0], 55)
        self.assertLessEqual(timeouts[0], 120)

    def test_xcresult_execution_count_is_required_even_when_log_claims_success(self):
        summary = passed_summary()
        summary.update(totalTestCount=0, passedTests=0)
        code, _, _ = self.run_ios(summary=summary)
        self.assertNotEqual(code, 0)

    def test_xcresult_skips_and_expected_failures_are_not_passes(self):
        for field in ('skippedTests', 'expectedFailures', 'failedTests'):
            with self.subTest(field=field):
                summary = passed_summary()
                summary.update({field: 1, 'totalTestCount': 2})
                self.assertNotEqual(self.run_ios(summary=summary)[0], 0)

    def test_missing_result_counts_and_xcode_failure_are_not_passes(self):
        self.assertNotEqual(self.run_ios(summary={'result': 'Passed'})[0], 0)
        self.assertNotEqual(self.run_ios(exit_code=65)[0], 0)

    def test_success_does_not_depend_on_swift_testing_console_format(self):
        self.assertEqual(self.run_ios(output=b'** TEST SUCCEEDED **\n')[0], 0)

    def test_dynamic_case_counts_are_not_added_to_declaration_counts(self):
        summary = passed_summary()
        summary['devicesAndConfigurations'] = [{'passedTests': 64}]
        self.assertEqual(self.run_ios(summary=summary)[0], 0)
        summary['devicesAndConfigurations'][0]['skippedTests'] = 1
        self.assertNotEqual(self.run_ios(summary=summary)[0], 0)


class QuickHostRunnerTests(unittest.TestCase):
    def run_host(self, full=False, statuses=(0, 0), output=b'host checks passed\n', extra=()):
        commands, timeouts = [], []

        def start(command, **kwargs):
            index = len(commands)
            commands.append(command)
            kwargs['stdout'].write(output)

            class Process:
                def wait(self, timeout=None):
                    timeouts.append(timeout)
                    return statuses[index]

            return Process()

        argv = ['test_quick.py'] + (['--full-host'] if full else []) + list(extra)
        with patch('sys.argv', argv), patch.object(test_quick.subprocess, 'Popen', side_effect=start):
            with patch.object(test_quick, 'host_commands', return_value=[['host-one'], ['host-two']]):
                with patch.object(test_quick, 'full_host_commands', return_value=[['full-one'], ['full-two']]):
                    with contextlib.redirect_stdout(io.StringIO()):
                        code = test_quick.main()
        return code, commands, timeouts

    def test_smoke_retains_55_second_deadline(self):
        code, _, timeouts = self.run_host()
        self.assertEqual(code, 0)
        self.assertTrue(all(0 < timeout <= 55 for timeout in timeouts))

    def test_full_host_is_unlimited_and_records_later_failures(self):
        code, commands, timeouts = self.run_host(full=True, statuses=(1, 0))
        self.assertNotEqual(code, 0)
        self.assertEqual(len(commands), 2)
        self.assertEqual(timeouts, [None, None])

    def test_opt_in_host_results_preserve_each_success_and_failure_log(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'results'
            code, _, _ = self.run_host(full=True, statuses=(0, 1),
                                        extra=('--host-result-directory', str(results)))
            self.assertNotEqual(code, 0)
            report = json.loads((results / 'results.json').read_text())
            self.assertEqual(report['recordedCommands'], 2)
            self.assertEqual(report['passedCommands'], 1)
            self.assertEqual([item['status'] for item in report['commands']], ['passed', 'failed'])
            self.assertEqual((results / '001.log').read_bytes(), b'host checks passed\n')
            self.assertEqual((results / '002.log').read_bytes(), b'host checks passed\n')

    def test_unittest_and_tap_skips_fail_host_checks(self):
        for output in (b'OK (skipped=2)\n', b'# skipped 1\n', b"test_case ... skipped 'not available'\n"):
            with self.subTest(output=output):
                self.assertNotEqual(self.run_host(full=True, output=output)[0], 0)
        self.assertFalse(test_quick.has_skipped_host_tests(io.BytesIO(b'# skipped 0\n')))

    def test_full_host_manifest_uses_argument_arrays_and_exact_python_placeholder(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / 'Scripts/tests/full-host-matrix.json'
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps({'commands': [{'command': ['$PYTHON', 'path with spaces.py']}]}))
            with patch.object(test_quick, 'ROOT', root):
                self.assertEqual(test_quick.full_host_commands(), [[test_quick.sys.executable, 'path with spaces.py']])
                manifest.write_text(json.dumps({'commands': [{'command': 'python command.py'}]}))
                with self.assertRaises(ValueError):
                    test_quick.full_host_commands()


if __name__ == '__main__':
    unittest.main()
