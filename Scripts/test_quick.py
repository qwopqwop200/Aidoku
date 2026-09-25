#!/usr/bin/env python3
"""Focused local regression checks; not a substitute for the full iOS suite."""
import argparse
import math
import os
import re
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def host_commands():
    # Explicit smoke scope. The larger sampler/corpus matrix remains in CI.
    commands = [
        ['node', 'Scripts/tests/' + name + '.cjs'] for name in [
            'source-color-regression',
            'source-color-readability-regression',
            'source-inpainting-regression',
            'column-layout-surface-regression',
        ]
    ]
    commands += [
        ['node', '--test', 'Scripts/tests/typography-clusters-regression.cjs'],
        ['node', '--test', 'Scripts/tests/source-inpainting-inferred-ruby.cjs'],
        ['node', 'Scripts/tests/dictionary-popup-regression.cjs'],
        [sys.executable, '-m', 'unittest', 'discover', '-s', 'Scripts', '-v'],
        [sys.executable, 'Scripts/validate_localizations.py'],
    ]
    return commands


def log_tail(log, limit=12000):
    """Read a bounded diagnostic tail even when a compiler produced a large log."""
    log.seek(0, os.SEEK_END)
    log.seek(max(0, log.tell() - limit))
    return log.read().decode('utf-8', errors='replace')


def has_executed_tests(log):
    log.seek(0)
    return any(re.search(rb'(?:Executed|Test run with) [1-9][0-9]* tests?', line)
               for line in log)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float,
                        help='Optional total deadline including build/startup '
                             '(default: unlimited for iOS, 55 seconds for host checks)')
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--fast-ios', action='store_true',
                           help='Run the default sub-minute iOS regression plan')
    selection.add_argument('--ios', nargs='+', metavar='SUITE',
                        help='Run only these AidokuTests suites/methods instead of host checks')
    parser.add_argument('--device', help='Simulator UDID (required for iOS runs)')
    parser.add_argument('--derived-data', help='Reuse a consistent Xcode build cache')
    parser.add_argument('--configuration', choices=['Debug', 'Release'],
                        help='Default: Release for --fast-ios, Debug for explicit --ios suites')
    args = parser.parse_args()
    if args.seconds is not None and (not math.isfinite(args.seconds) or args.seconds <= 0):
        parser.error('--seconds must be a finite number greater than 0')
    is_ios = args.ios is not None or args.fast_ios
    configuration = args.configuration or ('Release' if args.fast_ios else 'Debug')
    deadline = args.seconds if args.seconds is not None else (None if is_ios else 55)
    if is_ios and not args.device:
        parser.error('--ios/--fast-ios requires --device')
    if not is_ios and (args.device or args.derived_data):
        parser.error('--device and --derived-data require --ios or --fast-ios')
    if args.ios and any(s.startswith('-') or s.startswith('AidokuTests/') for s in args.ios):
        parser.error('Specify suite or suite/method without the AidokuTests/ prefix')
    started = time.monotonic()
    if is_ios:
        commands = [[
            'xcodebuild', 'test', '-project', 'Aidoku.xcodeproj', '-scheme', 'Aidoku',
            '-configuration', configuration, 'SWIFT_COMPILATION_MODE=singlefile',
            '-testPlan', 'AidokuFast' if args.fast_ios else 'AidokuFull',
            'ENABLE_TESTABILITY=YES', 'ONLY_ACTIVE_ARCH=YES',
            '-destination', 'platform=iOS Simulator,id=' + args.device,
            '-parallel-testing-enabled', 'NO', '-skipPackagePluginValidation',
            '-derivedDataPath', args.derived_data or str(
                ROOT / ('build/simulator-fast-' + configuration.lower())),
            *['-only-testing:AidokuTests/' + suite for suite in (args.ios or [])],
        ]]
    else:
        commands = host_commands()
    print('Scope: ' + (('AidokuFast iOS regressions (incremental build)' if args.fast_ios else
                       'selected iOS tests from AidokuFull (incremental build)') if is_ios else
                      'host regressions only; no Swift compilation, simulator, OCR or device validation'), flush=True)
    for index, command in enumerate(commands, 1):
        remaining = None if deadline is None else deadline - (time.monotonic() - started)
        if remaining is not None and remaining <= 0:
            print('TIMEOUT: checks incomplete; not a pass', flush=True)
            return 124
        print(f'[{index}/{len(commands)}] {shlex.join(command)}', flush=True)
        with tempfile.TemporaryFile(mode='w+b') as log:
            try:
                process = subprocess.Popen(command, cwd=ROOT, stdout=log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
            except OSError as error:
                print(f'FAIL: {error}', flush=True)
                return 1
            try:
                code = process.wait(timeout=remaining)
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                # Stop only this invocation and its children, never other test runs.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=1)
                print(log_tail(log))
                print(f'INCOMPLETE after {time.monotonic() - started:.1f}s; not a pass', flush=True)
                return 124 if isinstance(error, subprocess.TimeoutExpired) else 130
            if is_ios and not code:
                if not has_executed_tests(log):
                    print(log_tail(log))
                    print('INCOMPLETE: no nonzero executed-test count found; not a pass')
                    return 1
            if code:
                print(log_tail(log))
                print(f'FAIL after {time.monotonic() - started:.1f}s (exit {code})', flush=True)
                return 1
    print(f'PASS: {len(commands)} commands in {time.monotonic() - started:.1f}s '
          '(selected scope only)', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
