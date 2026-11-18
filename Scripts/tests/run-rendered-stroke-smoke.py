"""Focused host tests of the actual production selection and preparation code."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
ensemble = root/'Aidoku/Core/Translation/NativeEngine/Ensemble'
with tempfile.TemporaryDirectory(prefix='aidoku-stroke-') as folder:
    executable = Path(folder)/'stroke-smoke'
    subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-module-cache-path',
                    str(root/'build/image-translation-host/module-cache'),
                    str(ensemble/'NativeRenderedStrokeSelection.swift'),
                    str(ensemble/'NativeSourceInkSelection.swift'),
                    str(ensemble/'NativeExplicitDisplayStrokePolicy.swift'),
                    str(ensemble/'NativeMandatoryDisplayStroke.swift'),
                    str(root/'Scripts/tests/NativeRenderedStrokeSelectionSmoke.swift'),
                    '-o',str(executable)],check=True,cwd=root)
    subprocess.run([str(executable)],check=True,cwd=root)
