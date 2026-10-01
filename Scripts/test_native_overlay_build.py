"""Native kernel build cache and platform contracts; compiler calls are isolated."""
import contextlib
import importlib.util
import io
from pathlib import Path
import os
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    'native_overlay_build', Path(__file__).parent / 'overlay-kernels/native/build.py')
native_build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native_build)


class NativeOverlayBuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / 'Scripts/overlay-kernels/kernels.rs'
        self.source.parent.mkdir(parents=True)
        self.source.write_text('kernel source for mocked compiler\n')
        self.environment = {'RUSTC': '/usr/bin/true', 'PLATFORM_NAME': 'macosx', 'ARCHS': 'arm64'}
        self.commands = []

    def compile(self, command, **kwargs):
        self.commands.append(command)
        if 'lipo' in command:
            destination = Path(command[command.index('-output') + 1])
            destination.write_bytes(b'universal:' + b''.join(Path(path).read_bytes() for path in command[3:-2]))
        else:
            destination = Path(command[command.index('-o') + 1])
            target = command[command.index('--target') + 1]
            environment = kwargs['env']
            deployment = environment.get('MACOSX_DEPLOYMENT_TARGET', environment.get('IPHONEOS_DEPLOYMENT_TARGET', ''))
            destination.write_bytes(target.encode() + deployment.encode() + self.source.read_bytes())

    def build(self, **overrides):
        with patch.object(native_build.subprocess, 'check_output', return_value=b'rustc fixture version'):
            with patch.object(native_build.subprocess, 'run', side_effect=self.compile):
                with contextlib.redirect_stdout(io.StringIO()):
                    return native_build.build(self.root, self.environment | overrides)

    def test_unchanged_source_reuses_archive_and_macos_deployment_change_rebuilds(self):
        archive = self.build(MACOSX_DEPLOYMENT_TARGET='15.0')
        timestamp = 1_600_000_000_000_000_000
        os.utime(archive, ns=(timestamp, timestamp))
        self.build(MACOSX_DEPLOYMENT_TARGET='15.0')
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(archive.stat().st_mtime_ns, timestamp)
        self.build(MACOSX_DEPLOYMENT_TARGET='16.0')
        self.assertEqual(len(self.commands), 2)
        self.assertIn(b'16.0', archive.read_bytes())

    def test_default_host_architecture_matches_the_running_host(self):
        del self.environment['ARCHS']
        with patch.object(native_build.platform, 'machine', return_value='x86_64'):
            self.build()
        self.assertIn('x86_64-apple-darwin', self.commands[0])

    def test_source_changes_rebuild_and_duplicate_architectures_do_not_duplicate_link_inputs(self):
        archive = self.build(PLATFORM_NAME='iphonesimulator', ARCHS='arm64 arm64 x86_64')
        self.assertEqual(len(self.commands), 3)
        self.assertEqual(self.commands[-1].count('-create'), 1)
        self.assertIn(b'aarch64-apple-ios-sim', archive.read_bytes())
        self.assertIn(b'x86_64-apple-ios', archive.read_bytes())
        self.source.write_text('changed kernel\n')
        self.build(PLATFORM_NAME='iphonesimulator', ARCHS='arm64 x86_64')
        self.assertEqual(len(self.commands), 6)

    def test_empty_or_unsupported_architecture_never_reports_success(self):
        for architecture in ('', 'armv7'):
            with self.subTest(architecture=architecture):
                with self.assertRaises(ValueError):
                    self.build(ARCHS=architecture)
        self.assertEqual(self.commands, [])


if __name__ == '__main__':
    unittest.main()
