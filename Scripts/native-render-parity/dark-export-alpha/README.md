# PDF device-scale precision

Run `python3 Scripts/native-render-parity/dark-export-alpha/run.py` from the worktree.
The probe preserves captured native text/font bytes and regenerates only the
background vector geometry with the actual production `NativeTranslationPDFCapture`.
It compares every decoded RGBA byte after drawing the actual frozen source image.

The baseline differs at two rounded-edge pixels, each by one channel step.
The production transform regenerates both clips and gradient rectangles and
closes both differences: 0/563,200 differing pixels across all four channels.
The full iOS renderer still needs the root's next simulator parity run because
its text and background now share the same matrix.

The general cause is the snapshot matrix, not a dark-color special case:
[WebPage::paintSnapshotAtSize](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/WebPage.cpp#L3744-L3777)
narrows the original `Double` device scale to `Float` for painting, divides its
`Float` snapshot scale by the original `Double` value, applies the resulting
`Float` reciprocal, then translates the crop.
For a 3x device that yields `3 * Float(1/3) = 1.0000000298023224`.
The native helper preserves that arithmetic and ordering for every device scale.
The frozen 21-file reference archive is untouched.
