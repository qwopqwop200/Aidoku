# Final native appearance source stage

Production entrypoint is
`NativeAppearanceLateGradient.refine(input:packet:prediction:heads:ops:) throws -> [String:Any]`.
It is implemented in six NEW `NativeAppearanceLateGradient*.swift` files only.
No existing registry, feature, segmentation, font, caller or graph files changed.
Pauli's graph invokes it after final background and observed shadow.

Implemented sequence:
1. Restore own native-primary, interior-pruning, bright-primary and contour/palette
   warm mutations to the source baseline.
2. Finite source gradient growth, source component PCA/plane validation and
   independent pixel71 fill confirmation; bounded native primary-contour rays.
3. Independently certified bright-hole contour fallback; owned native palette
   candidates, repeated witnesses and bounded marginal-coverage additions.
4. Certified repeated bright primary; component palette pruning with exact
   Euclidean contour/core distance and independent-colour preservation.
5. Exact native medoid / eroded-core candidates, all88 frozen source features and
   the actual native-primary-quality model/gate. Preserve Python number()'s
   intentional missingness for direct numpy.float32 features; do not substitute
   numeric values that the frozen model never received during training.
6. Finite white secondary shell geometry with four shifted nulls; original
   scalar width, presence, index provenance and unrelated paint fields preserved.

Pixel71 seed confirmation calls the production graph's independent featureContext
(the reference role model, nested recovery and normal primary/background refresh).
Native medoid uses exact weighted costs with admissible Jensen pruning, not
sampled or approximate RGB. All evidence is computed from original RGB and
supplied source ownership/RF/seg/OCR grids; no target or source identity lookup.

Isolated verification commands (do not run shared MAIN builds):
```
python3 Scripts/native-source-cv/late-gradient/compile.py iphoneos
python3 Scripts/native-source-cv/late-gradient/compile.py iphonesimulator
.venv-source-inference/bin/python Scripts/native-source-cv/late-gradient/parity.py
```
`parity.py` expects the isolated optimized `build/native-source-late-gradient/late-gradient`
executable compiled from the SOURCES listed by compile.py plus LateGradientMain.swift.
Link against the EXISTING native source CV archives (no shared archive rebuild).
FeatureContextShim.swift is test-only and duplicates the exact production
reference-context sequence while avoiding unrelated graph heads. Its RF model
identity matches Layout/NativeRFDETRLayoutModels.swift.

Completed evidence is VERIFICATION.json:13 synthetic cases plus2 supplied
original source crop packets; all88 features and NaN masks exact, actual frozen
model scores exact, paint RGB/palettes/presence/width/layers exact, warm results
exact. Includes a positive actual native-primary gate and contour, palette,
bright primary/pruning and finite-shell applied paths. Source styles are freshly
predicted from original pixels/arrays; cached appearance.json/labels are not read.
Actual iOS launch/full app verification remains parent-owned.
