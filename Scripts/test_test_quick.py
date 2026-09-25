"""Regression checks for iOS runner deadlines and source rebuild policy."""
import contextlib
import io
import unittest
from unittest.mock import patch

import test_quick


class QuickIOSRunnerTests(unittest.TestCase):
    def run_ios(self, extra=(), output=b'Test run with 1 test passed\n',
                selection=('--ios', 'ExampleTests')):
        commands, timeouts = [], []

        def start(command, **kwargs):
            commands.append(command)
            kwargs['stdout'].write(output)

            class Process:
                def wait(self, timeout=None):
                    timeouts.append(timeout)
                    return 0

            return Process()

        argv = ['test_quick.py', *selection, '--device', 'example', *extra]
        with patch('sys.argv', argv), patch.object(test_quick.subprocess, 'Popen', side_effect=start):
            with contextlib.redirect_stdout(io.StringIO()):
                code = test_quick.main()
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

    def test_explicit_suite_can_run_outside_fast_plan(self):
        code, commands, _ = self.run_ios()
        self.assertEqual(code, 0)
        command = commands[0]
        self.assertEqual(command[command.index('-testPlan') + 1], 'AidokuFull')
        self.assertIn('-only-testing:AidokuTests/ExampleTests', command)

    def test_explicit_deadline_can_exceed_former_limit(self):
        code, _, timeouts = self.run_ios(['--seconds', '120'])
        self.assertEqual(code, 0)
        self.assertGreater(timeouts[0], 55)
        self.assertLessEqual(timeouts[0], 120)

    def test_zero_executed_tests_is_not_a_pass(self):
        code, _, _ = self.run_ios(output=b'Test run with 0 tests passed\n')
        self.assertNotEqual(code, 0)


if __name__ == '__main__':
    unittest.main()
