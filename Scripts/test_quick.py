#!/usr/bin/env python3
"""Run focused checks by default, or an explicitly requested complete test scope."""
import argparse
from contextlib import ExitStack
import fcntl
import json
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
import uuid

ROOT = Path(__file__).resolve().parents[1]


def host_commands():
    # Native runtime checks live in the iOS suites and explicit full-host matrix.
    return [
        [sys.executable, '-m', 'unittest', 'discover', '-s', 'Scripts', '-v'],
        [sys.executable, 'Scripts/validate_localizations.py'],
    ]


def log_tail(log, limit=12000):
    """Read a bounded diagnostic tail even when a compiler produced a large log."""
    log.seek(0, os.SEEK_END)
    log.seek(max(0, log.tell() - limit))
    return log.read().decode('utf-8', errors='replace')


def full_host_commands():
    manifest = ROOT / 'Scripts/tests/full-host-matrix.json'
    entries = json.loads(manifest.read_text())['commands']
    commands = []
    for entry in entries:
        command = entry['command']
        if not isinstance(command, list) or not command or not all(isinstance(item, str) and item for item in command):
            raise ValueError(f'Invalid full-host command: {entry!r}')
        commands.append([sys.executable if item == '$PYTHON' else item for item in command])
    if not commands:
        raise ValueError('The full-host manifest contains no commands')
    return commands


def has_skipped_host_tests(log):
    log.seek(0)
    patterns = (
        rb'^\s*#\s*(?:skip|skipped)\s+[1-9][0-9]*\s*$',
        rb'\bOK \(skipped=[1-9][0-9]*\)',
        rb'\.\.\. skipped [\'"]',
    )
    return any(any(re.search(pattern, line) for pattern in patterns) for line in log)


def xcresult_json(bundle, *arguments):
    output = subprocess.check_output(
        ['xcrun', 'xcresulttool', 'get', *arguments, '--path', str(bundle), '--compact'],
        cwd=ROOT, stderr=subprocess.STDOUT)
    return json.loads(output)


def result_summary_error(summary):
    # Xcode's top-level counts are declarations; device counts can expand dynamic
    # parameter cases. Do not add them together or infer execution from log text.
    counts = ('passedTests', 'failedTests', 'skippedTests', 'expectedFailures', 'totalTestCount')
    if not isinstance(summary, dict):
        return 'invalid result summary'
    if any(type(summary.get(key)) is not int or summary[key] < 0 for key in counts):
        return 'missing or invalid executed-test counts'
    if summary['passedTests'] <= 0 or summary['totalTestCount'] <= 0:
        return 'zero passed tests'
    if summary['skippedTests']:
        return f"{summary['skippedTests']} tests were skipped"
    if summary['failedTests'] or summary['expectedFailures'] or summary.get('testFailures'):
        return 'test failures or expected failures were recorded'
    if summary.get('result') != 'Passed':
        return f"test result was {summary.get('result')!r}"
    if summary['passedTests'] != summary['totalTestCount']:
        return 'passed count does not match the complete executed scope'
    for device in summary.get('devicesAndConfigurations', []):
        if any(device.get(key, 0) for key in ('failedTests', 'skippedTests', 'expectedFailures')):
            return 'a device/configuration recorded failed, skipped or expected-failure cases'
    return None


def selected_suite_execution_error(document, requested_suites):
    """Require actual cases for each --ios suite, using xcresult's test tree."""
    def nodes(value):
        if not isinstance(value, dict) or not isinstance(value.get('children', []), list):
            raise ValueError('invalid test-tree node')
        yield value
        for child in value.get('children', []):
            yield from nodes(child)

    if not isinstance(document, dict) or not isinstance(document.get('testNodes'), list):
        return 'invalid executed-test tree'
    try:
        # Same Test Suite / Test Case / Arguments traversal as the mandatory
        # native quality gate, verified against actual xcresult JSON exports.
        all_nodes = [node for root in document['testNodes'] for node in nodes(root)]
        for name in dict.fromkeys(requested_suites):
            matches = [node for node in all_nodes
                       if node.get('nodeType') == 'Test Suite' and node.get('name') == name]
            if len(matches) != 1:
                return f'requested suite {name!r}: expected one executed suite, found {len(matches)}; check the bare suite name'
            descendants = list(nodes(matches[0]))
            cases = [node for node in descendants if node.get('nodeType') == 'Test Case']
            if not cases:
                return f'requested suite {name!r}: zero executed test cases'
            if any(node.get('result') != 'Passed' for node in descendants):
                return f'requested suite {name!r}: failed, skipped or non-passing execution'
    except ValueError as error:
        return str(error)
    return None


def report_ios_result(bundle, log, wall_seconds, requested_suites=()):
    summary = xcresult_json(bundle, 'test-results', 'summary')
    selection_evidence = None
    selection_error = None
    if requested_suites:
        tree_path = bundle.with_suffix('.tests.json')
        try:
            tree = xcresult_json(bundle, 'test-results', 'tests')
            tree_path.write_text(json.dumps(tree, indent=2) + '\n')
            selection_error = selected_suite_execution_error(tree, requested_suites)
        except (subprocess.CalledProcessError, OSError, ValueError) as error:
            selection_error = f'could not read selected-suite execution evidence: {error}'
        selection_evidence = {'requestedSuites': list(requested_suites),
                              'testTree': str(tree_path), 'error': selection_error}
    build_seconds = None
    try:
        build_seconds = xcresult_json(bundle, 'log', '--type', 'build').get('duration')
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f'Build timing unavailable: {error}', flush=True)
    log.seek(0)
    test_body_seconds = None
    for line in log:
        match = re.search(rb'Test run with [0-9]+ tests?.*after ([0-9.]+) seconds', line)
        if match:
            test_body_seconds = float(match.group(1))
    report = {
        'summary': summary,
        'selectionEvidence': selection_evidence,
        'wallSeconds': wall_seconds,
        'buildActivitySeconds': build_seconds,
        'swiftTestingBodySeconds': test_body_seconds,
        'note': 'Build activity and test-body timings are independent measurements; wall time also includes startup and result collection.',
    }
    report_path = bundle.with_suffix('.summary.json')
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(f"iOS results: {summary.get('passedTests')} passed, "
          f"{summary.get('failedTests')} failed, {summary.get('skippedTests')} skipped", flush=True)
    print(f'Timings: wall {wall_seconds:.2f}s; build activity {build_seconds}; '
          f'Swift Testing body {test_body_seconds}', flush=True)
    print(f'Result summary: {report_path}', flush=True)
    return result_summary_error(summary) or selection_error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float,
                        help='Optional total deadline including build/startup '
                             '(default: unlimited for iOS/full host, 55 seconds for host smoke checks)')
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--fast-ios', action='store_true',
                           help='Run the default sub-minute iOS regression plan')
    selection.add_argument('--full-ios', action='store_true',
                           help='Run every test in AidokuFull, without suite filters')
    selection.add_argument('--full-host', action='store_true',
                           help='Run the complete checked-in host test matrix without the smoke deadline')
    selection.add_argument('--ios', nargs='+', metavar='SUITE',
                        help='Run these AidokuTests suites and require execution of every selected suite; pass bare names without method filters')
    parser.add_argument('--device', help='Simulator UDID (required for iOS runs)')
    parser.add_argument('--derived-data', help='Reuse a consistent Xcode build cache')
    parser.add_argument('--result-bundle', type=Path, help='New iOS .xcresult output path; existing results are never overwritten')
    parser.add_argument('--host-result-directory', type=Path,
                        help='New directory for every host command log and execution-result JSON')
    parser.add_argument('--jobs', type=int, default=2, help='Parallel Xcode build jobs (default: 2; one test simulator)')
    parser.add_argument('--configuration', choices=['Debug', 'Release'],
                        help='Default: Release for --fast-ios/--full-ios, Debug for explicit --ios suites')
    args = parser.parse_args()
    if args.seconds is not None and (not math.isfinite(args.seconds) or args.seconds <= 0):
        parser.error('--seconds must be a finite number greater than 0')
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    is_ios = args.ios is not None or args.fast_ios or args.full_ios
    configuration = args.configuration or ('Release' if args.fast_ios or args.full_ios else 'Debug')
    deadline = args.seconds if args.seconds is not None else (None if is_ios or args.full_host else 55)
    if is_ios and not args.device:
        parser.error('--ios/--fast-ios/--full-ios requires --device')
    if not is_ios and (args.device or args.derived_data or args.result_bundle):
        parser.error('--device, --derived-data and --result-bundle require an iOS selection')
    if is_ios and args.host_result_directory:
        parser.error('--host-result-directory applies only to host checks')
    if args.ios and any('/' in suite or '(' in suite or ')' in suite or suite.startswith('-') for suite in args.ios):
        parser.error('--ios accepts bare suite names only, e.g. --ios NativeOCRRecognitionRegressionTests. '
                     'Remove the AidokuTests/ prefix and /method suffix; run the whole affected suite. '
                     'Method filters can silently match zero Swift Testing tests.')
    started = time.monotonic()
    bundle = None
    cache = None
    host_results = None
    if args.host_result_directory:
        host_results = args.host_result_directory.expanduser().resolve()
        if host_results.exists():
            parser.error(f'Host result directory already exists: {host_results}')
        host_results.mkdir(parents=True)
    if is_ios:
        cache = Path(args.derived_data or ROOT / ('build/simulator-fast-' + configuration.lower())).expanduser().resolve()
        bundle = (args.result_bundle or ROOT / 'build/test-results' / f'{uuid.uuid4()}.xcresult').expanduser().resolve()
        if bundle.exists() or bundle.with_suffix('.log').exists() or bundle.with_suffix('.summary.json').exists() or bundle.with_suffix('.tests.json').exists():
            parser.error(f'Result path already exists: {bundle}')
        commands = [[
            'xcodebuild', 'test', '-project', 'Aidoku.xcodeproj', '-scheme', 'Aidoku',
            '-configuration', configuration, 'SWIFT_COMPILATION_MODE=singlefile',
            '-testPlan', 'AidokuFast' if args.fast_ios else 'AidokuFull',
            'ENABLE_TESTABILITY=YES', 'ONLY_ACTIVE_ARCH=YES',
            'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=YES', 'CODE_SIGN_IDENTITY=-',
            *(['SWIFT_OPTIMIZATION_LEVEL=-O'] if configuration == 'Release' else []),
            '-destination', 'platform=iOS Simulator,id=' + args.device,
            '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1',
            '-jobs', str(args.jobs), '-skipPackagePluginValidation',
            '-derivedDataPath', str(cache), '-resultBundlePath', str(bundle),
            *['-only-testing:AidokuTests/' + suite for suite in (args.ios or [])],
        ]]
    else:
        try:
            commands = full_host_commands() if args.full_host else host_commands()
        except (OSError, ValueError, KeyError) as error:
            parser.error(str(error))
    print('Scope: ' + (('AidokuFast iOS regressions (incremental build)' if args.fast_ios else
                       'complete AidokuFull (incremental build)' if args.full_ios else
                       'selected iOS tests from AidokuFull (incremental build)') if is_ios else
                      'complete checked-in host matrix' if args.full_host else
                      'host tooling smoke checks'), flush=True)
    with ExitStack() as resources:
        if cache is not None:
            cache.mkdir(parents=True, exist_ok=True)
            bundle.parent.mkdir(parents=True, exist_ok=True)
            lock = resources.enter_context((cache / '.test-runner.lock').open('a'))
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                parser.exit(1, 'Another test runner is using this DerivedData cache.\n')
        return run_commands(commands, deadline, started, bundle, args.full_host, host_results,
                            requested_suites=tuple(args.ios or ()))


def run_commands(commands, deadline, started, bundle, full_host, host_results=None, requested_suites=()):
    failures = 0
    records = []

    def record_host(index, command, status, code, seconds, **details):
        if host_results is None:
            return
        record = dict(index=index, name=shlex.join(command), argv=command, command=command,
                      status=status, exitCode=code, seconds=seconds,
                      log=str(host_results / f'{index:03d}.log'), **details)
        records.append(record)
        (host_results / f'{index:03d}.json').write_text(json.dumps(record, indent=2) + '\n')
        (host_results / 'results.json').write_text(json.dumps({
            'totalCommands': len(commands), 'recordedCommands': len(records),
            'passedCommands': sum(item['status'] == 'passed' for item in records),
            'commands': records,
        }, indent=2) + '\n')
    for index, command in enumerate(commands, 1):
        remaining = None if deadline is None else deadline - (time.monotonic() - started)
        if remaining is not None and remaining <= 0:
            print('TIMEOUT: checks incomplete; not a pass', flush=True)
            return 124
        print(f'[{index}/{len(commands)}] {shlex.join(command)}', flush=True)
        command_started = time.monotonic()
        log_path = bundle.with_suffix('.log') if bundle else host_results / f'{index:03d}.log' if host_results else None
        with (log_path.open('w+b') if log_path else tempfile.TemporaryFile(mode='w+b')) as log:
            try:
                process = subprocess.Popen(command, cwd=ROOT, stdout=log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
            except OSError as error:
                print(f'FAIL: {error}', flush=True)
                record_host(index, command, 'failed', None, time.monotonic() - command_started, error=str(error))
                failures += 1
                if full_host:
                    continue
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
                    pass
                # The group leader may exit before a compiler/test worker that
                # ignored SIGTERM. Stop the entire invocation even in that case.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=1)
                record_host(index, command, 'incomplete', None, time.monotonic() - command_started, error=type(error).__name__)
                print(log_tail(log))
                print(f'INCOMPLETE after {time.monotonic() - started:.1f}s; not a pass', flush=True)
                return 124 if isinstance(error, subprocess.TimeoutExpired) else 130
            skipped = False
            if bundle:
                try:
                    problem = report_ios_result(bundle, log, time.monotonic() - command_started, requested_suites)
                except (subprocess.CalledProcessError, OSError, ValueError) as error:
                    problem = f'could not read executed-test evidence: {error}'
                if problem:
                    print(log_tail(log))
                    print(f'INCOMPLETE: {problem}; not a pass', flush=True)
                    return 1
            elif has_skipped_host_tests(log):
                print(log_tail(log))
                print('FAIL: host tests skipped execution', flush=True)
                code = 1
                skipped = True
            record_host(index, command, 'failed' if code else 'passed', code,
                        time.monotonic() - command_started, skipped=skipped)
            if code:
                print(log_tail(log))
                print(f'FAIL after {time.monotonic() - started:.1f}s (exit {code})', flush=True)
                failures += 1
                if not full_host:
                    return 1
            elif full_host:
                print(f'Command passed in {time.monotonic() - command_started:.2f}s', flush=True)
    if failures:
        print(f'FAIL: {failures}/{len(commands)} commands failed', flush=True)
        return 1
    print(f'PASS: {len(commands)} commands in {time.monotonic() - started:.1f}s '
          '(selected scope only)', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
