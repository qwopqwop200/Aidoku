"""Generated native bridge must reproduce exactly without rewriting user files."""
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch


class NativeKernelBindingGenerationTests(unittest.TestCase):
    def test_canonical_generator_reproduces_all_outputs(self):
        root = Path(__file__).resolve().parents[1]
        generated = {}

        def capture(path, text, *args, **kwargs):
            generated[path.resolve()] = text
            return len(text)

        with patch.object(Path, "write_text", capture):
            runpy.run_path(str(root / "Scripts/overlay-kernels/native/generate-bindings.py"))

        expected = {
            root / "Scripts/overlay-kernels/native/kernels.h",
            root / "Scripts/overlay-kernels/native/module.modulemap",
            root / "Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationPixelKernels.swift",
        }
        self.assertEqual(set(generated), expected)
        for path, text in generated.items():
            with self.subTest(path=path.relative_to(root)):
                self.assertEqual(text, path.read_text())
