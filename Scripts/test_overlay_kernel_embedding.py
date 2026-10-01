"""Frozen Web oracle embedding tooling must not dirty unchanged sources or unrelated content.
Production pixel kernels are native; this tests only the historical embedding utility."""
import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class OverlayKernelEmbeddingTests(unittest.TestCase):
    def test_embedding_preserves_surroundings_and_unchanged_source_timestamp(self):
        script = Path(__file__).parent / 'overlay-kernels' / 'embed.py'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wasm = root / 'kernel.wasm'
            swift = root / 'source.swift'
            binary = bytes(range(256))
            wasm.write_bytes(binary)
            prefix = "before\n    // BEGIN aidokuPixelKernelBytes\n"
            suffix = "\n    // END aidokuPixelKernelBytes\nafter\n"
            swift.write_text(prefix + "    'old';" + suffix)
            subprocess.run([sys.executable, script, wasm, swift], check=True, capture_output=True)
            updated = swift.read_text()
            self.assertTrue(updated.startswith(prefix))
            self.assertTrue(updated.endswith(suffix))
            body = updated[len(prefix):-len(suffix)]
            encoded = ''.join(line.strip().removesuffix('+').removesuffix(';').strip("'") for line in body.splitlines())
            self.assertEqual(base64.b64decode(encoded), binary)
            timestamp = 1_600_000_000_000_000_000
            os.utime(swift, ns=(timestamp, timestamp))
            subprocess.run([sys.executable, script, wasm, swift], check=True, capture_output=True)
            self.assertEqual(swift.stat().st_mtime_ns, timestamp)
            self.assertEqual(swift.read_text(), updated)

    def test_missing_markers_leave_source_intact(self):
        script = Path(__file__).parent / 'overlay-kernels' / 'embed.py'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wasm, swift = root / 'kernel.wasm', root / 'source.swift'
            wasm.write_bytes(b'wasm')
            swift.write_text('unrelated Swift source\n')
            result = subprocess.run([sys.executable, script, wasm, swift], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(swift.read_text(), 'unrelated Swift source\n')


if __name__ == '__main__':
    unittest.main()
