# Portable source model and tensor contract

Shared macOS MAIN/iOS Foundation sources:
- `NativeFrozenSourceModel.swift`
- existing `NativeAppearanceForest.swift` (reused compatible tree primitive)
- `NativeFrozenTensor.swift` (mapped large reference-bank tensors)

No Python, C++, OpenCV, GT lookup, query examples or prediction tables are used
at inference. Caller wiring and image-feature extraction belong to parent modules.

## Assets and authentication

Keep the entire `Aidoku/Resources/Translation/SourceModels` folder in BOTH targets:
- `registry-index.json`: ~21KiB heads/provenance/authenticated metadata pointers.
- `registry.json`: ~4.6MiB full recursive metadata tree and head registry.
- `appearance-metadata.json`: ~137KiB appearance-only metadata.
- `heads/<sha256>.plist`: 59 exact learned heads, unchanged by tensor packaging.
- `tensors/<sha256>.bin`: two large f32 source TRAIN feature banks.

The existing Xcode SourceModels folder reference and resource build phase preserve
nested tensor paths. Tensor paths resolve relative to this SourceModels root.
Do not flatten the tensors subtree when packaging SDK/app resources.

Registry sourceArtifacts contains original artifact SHA256; each head entry
records sourceModelSHA256 plus its exported asset SHA. Model reads verify the
asset SHA before decoding. Approved font198 source bundle SHA:
`30f0072a07ec393fb26a3ea6d0b306fac836bf5290d0e16f3a94b3e2b0107f05`.
Both graph and measurement identity maps retain 1444 keys, including 715 RGB aliases.

## Model and metadata access

```swift
let registry = try NativeFrozenSourceModel.Registry(directory: assetsDirectory)
let model = try registry.model("font198/optimizedGraph/earlyModels/round68")
let vectorOutput: [Double] = try model.predict(vector)
let rowOutputs: [[Double]] = try model.predict(matrix)
let probabilities = try classifier.predictProbability(matrix)
let treeMajorOutputs: [[Double]] = try model.predictTrees(vector)
let metadata = try registry.metadataTreeFoundation
```

`predict` follows estimator semantics: original numeric labels for classifiers,
all outputs for regression, transformed vectors for PCA/scalers.
`predictProbability` uses original class order (`classes`). Multioutput
classifiers expose `classGroups`, concatenating probability groups.
`predictTrees(vector)` returns tree-major/output-minor values. For tree-major
scalar matrix outputs, transpose `matrix.map { try model.predictTrees($0).map { $0[0] } }`.
`positiveProbabilities(_ rowMajor:[Float], rowCount:Int, positions:[Int]? = nil)`
returns class-index-1 probabilities for selected binary-classifier rows.

Default Registry construction reads the small index. The THROWING getter
`try registry.metadataTreeFoundation` lazily loads and SHA-validates metadataAsset;
it never returns an empty map just because the index omits the tree.
`Registry(directory:includeMetadata:true)` eagerly authenticates/retains metadata.
JSONDecoder/Value parsing and `.foundationValue` preserve double values. Do NOT
substitute JSONSerialization for numeric graph metadata: ulp changes can alter
HGB branches. Tensor records remain dictionaries; they are NEVER autoexpanded.

`metadata["font198"]` is the original accepted bundle, with `.optimizedGraph`
containing complete base/early/late configs, wrappers, TRAIN banks, priors and
identity/exclusion guards. `metadata["appearance/model"]` and other appearance
pickle prefixes retain their full configs; `metadata["appearance/policies"]`
contains the JSON policies. Every estimator is replaced by `{ "modelID": "..." }`.

Head `.metadataFoundation` retains immediate mean/std/logTarget/standardized/
targetScale/OOFNoise/clip. PCA adds components/pcaMean/explainedVariance/whiten.
Parent late adapters merge PCA metadata into the enclosing style_encoder state.
Inputs are estimator-space vectors: graphs apply their own normalization,
clipping and target policies once. Runtime applies internal baseline/loss links,
CatBoost scale/bias, LightGBM objective, and PCA centering/whitening.

Stable IDs:
- `font198/optimizedGraph/baseModel/model`, `.../contextModel`
- `font198/optimizedGraph/pairModel`
- `font198/optimizedGraph/earlyModels/roundN`
- `font198/optimizedGraph/lateModels/133` (also 138,139,142,144,148,159,164,189)
- `font198/optimizedGraph/lateModels/175/0/model` through `/175/3/model`
- `font198/optimizedGraph/lateModels/177/model` (179,181,182,184,190)
- `font198/optimizedGraph/lateModels/style_encoder/model`
- `appearance/<pickle-stem>/<nested-key>`; BackgroundBlend: `appearance/model/background`
- `segmentation/context83`, `segmentation/style78`

All forest output dimensions are chunked at 32 without per-chunk class
renormalization. Full tree distributions are normalized before slicing.
ExtraTrees/CatBoost round numerical inputs to float32; trained thresholds remain
float64. Missing directions and legitimate infinite missing-only splits are preserved.

## Mapped tensors

Only numeric NumPy arrays with >=1,000,000 elements become records:
`{tensorAsset:"tensors/<sha>.bin",shape:[...],dtype:"f32",sha256:"..."}`.
All smaller arrays remain nested lists, including style_bank2182x32 and PCA.
Payloads are C-order, little-endian, preserving original numerical dtype/bits.
Accepted bank76 features: `[41349,198]`; bank84: `[41625,198]`; both f32.

```swift
let tensor = try NativeFrozenTensor(directory: assetsDirectory, record: record)
let row: [Float] = try tensor.readRowFloat32(0)
let row64: [Double] = try tensor.readRowDouble(0)
let scalar = try tensor.double(at: 0)
try tensor.withUnsafeFloat32Buffer { buffer in /* zero-copy operations */ }
tensor.withUnsafeBytes { bytes in /* loadUnaligned + littleEndian typed reads */ }
```

Descriptor is Codable; shape/dtype/elementCount/rowWidth/rowCount/byteCount are
exposed. Init uses Data(.mappedIfSafe), verifies dimensions/byte count/SHA, and
SHA streams mapped bytes without a full payload copy. Pointer lifetimes are
restricted to their closure and tensor lifetime. f16/f32/f64 and signed/unsigned
8/16/32/64-bit integers retain binary dtype. Double reading performs ordinary
numeric conversion; raw pointer access preserves integer and floating-point bits.
Parent prototype nearest-neighbor code owns consumption; no algorithm is added.

## Export and focused tests

```
.venv-source-inference/bin/python Scripts/models/export_source_model_runtime.py --expected-font198-sha 30f0072a07ec393fb26a3ea6d0b306fac836bf5290d0e16f3a94b3e2b0107f05
.venv-source-inference/bin/python -m unittest discover -s Scripts/models -p test_source_model_runtime.py -v
.venv-source-inference/bin/python -m unittest discover -s Scripts/models -p test_frozen_tensor_runtime.py -v
```

Exporter supports `--out DIRECTORY` and repeated `--source ID=TRUSTED_PICKLE`.
Model/tensor replay harnesses compile only Foundation sources, never the full app.
Expected predictions are temporary test data, never registry assets.
