#!/usr/bin/env python3
"""Run hosted reader screen regressions with real simulator screenshots.

From the repository root, for example:
  python3 Scripts/run_webtoon_screen_tests.py --device SIMULATOR_UDID \
    --bundle app.aidoku.Aidoku -- -project Aidoku.xcodeproj -scheme Aidoku \
    -only-testing:AidokuTests/ReaderWebtoonLifecycleTests test

Arguments after -- are passed to xcodebuild. The destination is set from --device.
The simulator must be booted. The host app's bundle ID must match --bundle.
Unlike UIKit drawHierarchy/XCUIScreen in a hosted unit-test process, simctl
captures the actual WebKit compositor. Each test checks the resulting pixels
with Vision; absence of a screenshot or translated text is a test failure.
"""
import argparse
import math
import os
import pathlib
import re
import subprocess
import sys
import time


def run() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--device', required=True, help='Booted simulator UDID')
    parser.add_argument('--bundle', required=True, help='Host app bundle identifier')
    parser.add_argument('--timeout', type=float, default=1800, help='Build and test timeout, seconds')
    parser.add_argument('--count', type=int, default=4, help='Expected screen cases')
    parser.add_argument('xcodebuild_args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    build_args = args.xcodebuild_args
    if build_args[:1] == ['--']:
        build_args = build_args[1:]
    if not build_args:
        parser.error('Provide xcodebuild test arguments after --')
    if not math.isfinite(args.timeout) or args.timeout <= 0 or args.count <= 0:
        parser.error('timeout and count must be positive')
    started = time.time_ns()
    deadline = time.monotonic() + args.timeout
    seen = set()
    container = None
    next_lookup = 0.0
    process = subprocess.Popen(['xcodebuild', '-destination', f'id={args.device}', *build_args])
    try:
        while process.poll() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError('Build/test timeout exceeded')
            if time.monotonic() >= next_lookup:
                result = subprocess.run(
                    ['xcrun', 'simctl', 'get_app_container', args.device, args.bundle, 'data'],
                    capture_output=True, text=True, timeout=15)
                if result.returncode == 0:
                    container = pathlib.Path(result.stdout.strip()) / 'Documents' / 'AuditWebtoon'
                next_lookup = time.monotonic() + 2
            if container is not None:
                marker = container / 'capture-ready'
                try:
                    with marker.open() as stream:
                        stamp = os.fstat(stream.fileno()).st_mtime_ns
                        label = stream.read().strip()
                    identity = (str(container), stamp, label)
                    if stamp >= started and identity not in seen:
                        if not re.fullmatch(r'mode-[0-9]+-(cold|cached)', label):
                            raise RuntimeError('Unexpected screen capture marker')
                        destination = container / (label + '-external-screen.png')
                        temporary = container / (label + '-capture.tmp.png')
                        subprocess.run(
                            ['xcrun', 'simctl', 'io', args.device, 'screenshot', str(temporary)],
                            check=True, timeout=20)
                        temporary.replace(destination)
                        seen.add(identity)
                        print(f'Captured actual display: {destination}', flush=True)
                except FileNotFoundError:
                    pass  # The host is not installed yet or has not requested a capture.
            time.sleep(0.1)
        result = process.wait()
        if result:
            return result
        if len(seen) != args.count:
            print(f'Expected {args.count} actual screens, captured {len(seen)}', file=sys.stderr)
            return 1
        return 0
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == '__main__':
    sys.exit(run())
