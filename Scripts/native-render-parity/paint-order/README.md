# Native paint order policy

`python3 Scripts/native-render-parity/paint-order/run.py` compiles the unchanged Swift policy and runs the **actual frozen** `BrowserOverlayView.swift` paint-order block in a bounded DOM mock. It compares every lift/blocked decision, final layer z-index, and final root DOM order.

The deterministic 160 pages include 149 pages with accepted lifts, 211 accepted node/plate lifts, 404 blocked attempts, overlapping opaque item backgrounds, separate rotated plates, readability occluders, contrasting/dark fill choices, hidden layers, and the >256-item admission gate.

This checks policy with supplied axis-aligned physical character rectangles. It does not prove platform font pixels or the renderer's layer adapter; the actual renderer adapter is published separately and is exercised by NativePaintOrderAdapterTests. Platform output still requires the frozen final image suite.
