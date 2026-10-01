#!/usr/bin/env python3
"""Check the production CSS-length-to-physical helper against float32 CSS used lengths.

This is a bounded length/transform proof, not a DOM or image raster parity claim.
"""
import json
import pathlib
import subprocess
import tempfile
ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = ROOT / 'Scripts/tests/fixtures/native-scaled-text-lengths'
OVERLAY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'
def main():
    cases = [{'x': x, 'y': -7.0078125, 'width': width, 'height': 50.015625,
              'padding': [1.0078125, 2.015625, 3.03125, 4.0078125], 'scale': scale}
             for x in [149.9921875, -149.9921875, 0.0078125, 100.1171875]
             for width in [100.015625, 100.0078125, 83.3333333333, 19.9999999, 128.03125, 400.1171875]
             for scale in [1, .9, .85, .99]]
    with tempfile.TemporaryDirectory(prefix='aidoku-scaled-text-') as folder:
        folder = pathlib.Path(folder)
        source = (OVERLAY / 'NativeTranslationRenderer.swift').read_text()
        start = source.index('    static func usedLayoutItem(')
        end = source.index('    static func remeasureTypography(', start)
        stub = (FIX / 'Stub.swift').read_text().replace('// PRODUCTION_USED_LAYOUT_ITEM', source[start:end])
        # Preserve the production raw-padding transport dependency as well as
        # usedLayoutItem; the fixture still asserts all eight used lengths.
        layout = (OVERLAY / 'NativeTranslationLayout.swift').read_text()
        padding_start = layout.index('    var paddingTop: CGFloat { didSet')
        padding_end = layout.index('    var rotation: CGFloat', padding_start)
        stub_start = stub.index('    var paddingTop:CGFloat')
        stub_end = stub.index('    var rect:CGRect', stub_start)
        stub = stub[:stub_start] + layout[padding_start:padding_end] + stub[stub_end:]
        (folder / 'Stub.swift').write_text(stub)
        (folder / 'input.json').write_text(json.dumps(cases))
        subprocess.run(['swiftc', '-O', str(folder / 'Stub.swift'), str(OVERLAY / 'NativeTranslationRenderer+TextFrame.swift'), str(FIX / 'main.swift'), '-o', str(folder / 'probe')], check=True)
        subprocess.run([str(folder / 'probe'), str(folder / 'input.json'), str(folder / 'native.json')], check=True)
        subprocess.run(['node', str(FIX / 'oracle.cjs'), str(folder / 'input.json'), str(folder / 'frozen.json')], check=True)
        native = json.loads((folder / 'native.json').read_text())
        frozen = json.loads((folder / 'frozen.json').read_text())
        differences = [{'case': i, 'native': a, 'expected': b} for i, (a, b) in enumerate(zip(native, frozen)) if a != b]
        report = {'cases': len(cases), 'exact': len(cases) - len(differences), 'differences': differences,
                  'scope': 'Production usedScaledTextItem + production usedLayoutItem versus Float32 CSS used-length resolution then centered scale. No DOM geometry or raster claim.'}
        destination = ROOT / 'build/native-render-parity/scaled-text-used-lengths-policy.json'
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(report, indent=2))
        print(json.dumps(report))
        assert not differences
if __name__ == '__main__': main()
