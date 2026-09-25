#!/usr/bin/env python3
"""Build an optimized device app using a persistent, exclusive build cache."""

import argparse
import fcntl
from pathlib import Path
import shlex
import subprocess
import time


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='Connected device UDID')
    parser.add_argument('--team', required=True, help='Apple development team ID')
    parser.add_argument('--app-id-prefix', required=True, help='Existing installation bundle prefix')
    parser.add_argument('--derived-data', type=Path, default=root / 'build/device')
    parser.add_argument('--jobs', type=int, default=2, help='Parallel build jobs (default: 2)')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    cache = args.derived_data.expanduser().resolve()
    command = [
        'xcodebuild', '-project', str(root / 'Aidoku.xcodeproj'),
        '-scheme', 'Aidoku', '-configuration', 'Release',
        '-destination', f'id={args.device}', '-derivedDataPath', str(cache),
        '-clonedSourcePackagesDirPath', str(root / 'build/device/SourcePackages'),
        '-disableAutomaticPackageResolution', '-skipPackagePluginValidation',
        '-allowProvisioningUpdates', 'CODE_SIGN_STYLE=Automatic',
        f'DEVELOPMENT_TEAM={args.team}', f'APP_ID_PREFIX={args.app_id_prefix}',
        '-jobs', str(args.jobs), '-showBuildTimingSummary', 'build',
    ]
    print(shlex.join(command), flush=True)
    if args.dry_run:
        return 0
    cache.mkdir(parents=True, exist_ok=True)
    # Serialize this helper's builds; direct xcodebuild callers must also avoid
    # sharing the cache concurrently. Keep the lock file to avoid inode races.
    with (cache / '.device-release.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.exit(1, 'Another device Release build is using this cache.\n')
        started = time.monotonic()
        result = subprocess.run(command, cwd=root, check=False)
        print(f'Build elapsed: {time.monotonic() - started:.1f}s', flush=True)
        if result.returncode == 0:
            print(f'App: {cache / "Build/Products/Release-iphoneos/Aidoku.app"}')
        return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
