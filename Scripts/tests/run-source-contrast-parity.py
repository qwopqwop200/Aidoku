"""Compare native source-contrast queries with independent OpenCV medians.

Synthetic RGB only. No dataset image, GT or visual-review decision is read.
Run using the existing source-inference Python environment (numpy/OpenCV).
"""
from pathlib import Path
import json, subprocess, tempfile, time
import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble'
rng = np.random.default_rng(4721)
fixtures = []
for width, height in [(1, 1), (2, 3), (19, 17), (33, 25)]:
    for pattern in ['flat', 'random', 'thin', 'colour']:
        rgb = np.full((height, width, 3), 192, dtype=np.uint8)
        if pattern == 'random':
            rgb[:] = rng.integers(0, 256, rgb.shape, dtype=np.uint8)
        if pattern in ['thin', 'colour']:
            rgb[:, width // 2] = [0, 0, 0] if pattern == 'thin' else [192, 0, 192]
        points = [(0, 0), (width - 1, height - 1), (width // 2, height // 2)]
        points += [(int(rng.integers(width)), int(rng.integers(height))) for _ in range(60)]
        queries = []
        for radius in [1, 2, 4, 7]:
            median = cv2.medianBlur(rgb, radius * 2 + 1)
            residual = np.max(np.abs(rgb.astype(np.int16) - median.astype(np.int16)), axis=2)
            for threshold in [16, 24, 32]:
                for x, y in points:
                    queries.append(dict(x=x, y=y, radius=radius, threshold=threshold,
                                        expected=bool(residual[y, x] >= threshold)))
        fixtures.append(dict(width=width, height=height, rgb=rgb.reshape(-1).tolist(), queries=queries))
program = r'''
import Foundation
struct Query: Decodable { let x:Int; let y:Int; let radius:Int; let threshold:Int; let expected:Bool }
struct Fixture: Decodable { let width:Int; let height:Int; let rgb:[UInt8]; let queries:[Query] }
@main enum Check {
 static func main() throws {
  let fixtures=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
  var count=0
  for fixture in fixtures {for q in fixture.queries {
   let actual=NativeSourceContrastSupport.contains(rgb:fixture.rgb,width:fixture.width,height:fixture.height,
    x:q.x,y:q.y,radius:q.radius,minimumContrast:q.threshold)
   guard actual==q.expected else {fatalError("Median contrast mismatch at query \(count)")}
   count+=1
  }}
  print("PASS \(count) native/OpenCV contrast queries, replicated borders, all supported kernel radii")
 }
}
'''
start = time.monotonic()
with tempfile.TemporaryDirectory(prefix='aidoku-source-contrast-') as folder:
    folder = Path(folder)
    (folder / 'fixtures.json').write_text(json.dumps(fixtures))
    (folder / 'Check.swift').write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library',
                    str(ENGINE / 'NativeSourceContrastSupport.swift'), str(folder / 'Check.swift'),
                    '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check'), str(folder / 'fixtures.json')], check=True)
print('wallSeconds', round(time.monotonic() - start, 3))
