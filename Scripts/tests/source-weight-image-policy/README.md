# Native source-weight image policy: isolated dictionary parity

Owned new files only:

- `Aidoku/Core/Translation/NativeEngine/Ensemble/NativeSourceWeightImagePolicy.swift`
- this focused test directory: `Main.swift`, `parity.py`, `README.md`

No other Swift, Python, build, metadata, graph or measurement files are changed.
The new enum imports only Foundation and operates on dictionaries/arrays/scalars.
There is no image extraction, models, training, source IDs, GT or font lookup.
Existing font/segmentation/RF reuse stays with the caller's observation producers.

## API / integration contract

`NativeSourceWeightImagePolicy.Row` is `[String: Any]`. Methods are internal
static throwing functions, independent of private NativeSourceWeightGraph
helpers. No registry or metadata is loaded here; the parent supplies policies
and measurement/version/hash binding.

| API | Original implementation |
| --- | --- |
| `classifyDirectionalPage(observations:predictions:policy:)` | `directional_ink_rules.classify_page` |
| `applyDirectionalPage(observations:predictions:policy:)` | `directional_ink_rules.apply_page` |
| `referenceWordPasses(_:policy:)`, `applyReference(observation:prediction:policy:)` | `reference_ink_rules.word_passes`, `apply` |
| `softWordPasses(_:policy:)`, `softProposes(observation:confidence:policy:)`, `applySoft(observation:prior:policy:)` | `soft_ink_rules.word_passes`, `proposes`, `apply` |
| `expectedGlyphCounts(members:)`, `outlineWitness(style:policy:)` | `ordered_ink_rules.expected_counts`, `outline_witness` |
| `orderedProposes(observation:confidence:policy:)`, `applyOrdered(observation:prior:policy:)` | `ordered_ink_rules.proposes`, `apply` |
| `regularGlyphAgreement(observation:counts:policy:)` | new `font_context_soft.regular_glyph_agreement` |

Directional must receive every peer from ONE source page in the same order as
predictions. Controls are usable rows with components>=2 and chosen-direction
count>=16, excluding baseline `sourceWeight == bold`. Mixed rows remain controls
but cannot promote. The .25 control quantile normalizes page-relative evidence;
it is not a per-row rule. Other directions qualify at count>=16, and their
minimum width supplies direction contrast. Measurement minimumDirectionalRays
is a separate final gate, not a control-selection filter. Fewer than two
controls yield zero page-relative values. The original empty directional-page
NumPy error is retained as a Swift throw, not silently converted to a pass.
Canonical groups use the actual producer's order (verticalStems, horizontalStems,
diagonalStems), including Python min's first-NaN behaviour; unsupported extra
group names are visited in sorted order because Swift dictionaries have no
Python insertion-order contract. Do not use extra groups for production policy.

Apply methods copy ALL prior fields, set their own rescue flag to the current
Boolean decision, and update the five local render-policy fields only on a
promotion. Local bold policy exactly matches Python: sourceWeight=bold,
renderBold=true, renderWeight=bold, requiresTranslationSpanAlignment=false,
translatedStyleRuns=[]. Prior unrelated/nested fields and other flags survive;
nonpromoted render fields/runs are untouched. These functions deliberately do
not OR their own historical flag: any source-wrapper historical-flag merge is
parent orchestration, as it is in the original Python wrappers.

Reference retains optional registered evidence, finite float conversions,
fraction spread, partial word-agreement ratios, and optional prior score.
Soft requires a complete expectedWordCount, finite confidence from the fixed
polarityRescueScore field, and every usable word. Ordered additionally requires
complete expected glyph counts, optional witnessed outline, every reliable
positive glyph heavyMargin (>0), and the mean margin floor. Regular agreement
instead requires every reliable glyph margin strictly NEGATIVE (<0); missing,
incomplete, zero-margin or unreliable observations cannot veto. It does not
inspect word-level weights/fits or an outline witness. Unicode expected counts
use NFC and letter/number scalar categories, restricted to the first six
members, matching Python (Unicode-version differences for newly assigned
characters remain a platform limitation).

Missing measurement values produce the original false result via NaN defaults;
present invalid values such as null numeric fields throw where Python does.
Soft expectedWordCount=null/string is incomplete (false), while an absent key
throws only if the original short-circuit reaches it. Reference/soft words
accept numeric strings where Python explicitly calls float; ordered/glyph rules
do not silently cast numeric strings. Nonregular soft/ordered priors skip
measurement/confidence access exactly as Python. Malformed later words/glyphs
are not eagerly parsed after a preceding failure already determines false.
Policy thresholds are required on the same evaluated paths as Python; this is
not a blanket prevalidator that changes short-circuit/error semantics. Swift
errors use `Failure.invalid` with diagnostic messages, not Python exception
classes or byte-for-byte Python error strings.

## Focused parity

Run from the Aidoku Git root:

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python Scripts/tests/source-weight-image-policy/parity.py
```

The runner imports the actual unmodified original rules and newly added
font_context_soft function and generates observation dictionaries. It does NOT
replace rule functions or synthesize expected decisions with a mirrored rule
implementation. Every expected decision/apply result comes from those original
functions. No image extraction, fonts/models, source packets, datasets or IDs
are read. SHA256 checks cover the six original Python files and existing
NativeSourceWeightGraph.swift before/after.

The JSON-only test transport uses IEEE754 bit tags for finite doubles and
explicit nonfinite tags. This avoids Foundation JSON decimal parsing collapsing
nextafter neighbours at threshold boundaries. Tags exist only in the isolated
harness; production APIs receive ordinary NSNumber/Double values. Output
comparison checks entire rows, including nested arbitrary prior payloads and
all flags; finite float payloads compare bit-for-bit. Error cases check that
both implementations throw, not their exception class/message spelling.

Passing macOS host result, 2026-11-12:

- 541 cases: 74 directional PAGE cases, 26 reference apply, 53 soft apply,
  70 ordered apply, 71 reference-word predicates, 56 soft-word predicates,
  21 soft proposes, 53 ordered proposes, 79 regular-glyph agreement,
  31 outline witnesses, 7 Unicode/member-count controls.
- All 492 nonerror results/updated rows exactly match Python. All 49 Python
  error cases also throw in Swift.
- Tests include true multirow context, mixed-control/bold-exclusion effects,
  page permutations and singleton context; counts/components/ray gates;
  nextafter neighbours at numeric thresholds; score defaults and distinct
  nonfinite score semantics; signed zero-margin opposition; optional registered
  profiles; partial/complete word agreement; missing/null/nonfinite measurements;
  short-circuit behaviour; opaque prior fields and historical flags; outline
  presence/probability/paint separation; NFC and Unicode letters/numbers; and
  40 deterministic varied soft/ordered/regular-glyph case families.
- Private standalone `swiftc -O -swift-version 5` compilation: 4.974s.
  Swift fixture execution: 0.347s. Private module cache and executable are inside
  TemporaryDirectory. Only the NEW Swift module and NEW driver are compiled.

No shared/app build, policy tuning, metadata loading, full830, device or visual
acceptance is claimed. Parent owns source runtime orchestration, stage ordering,
regular-glyph remeasurement/veto render update and audit flags, optional-policy
selection, historical wrapper-flag merges, and full830 public-source inference.
Word-fit/font callbacks and existing segmentation/RF evidence remain external.

Oracle identities:

```
directional_ink_rules.py 47aa9b4d4d6531fefe83e6040a36b0daecd2e29be885d05179bb8629a8403aa8
reference_ink_rules.py 734ffccd3c86cb9c8870a327b645c671b9b9f58b4b54a8eb0d7831b628605091
soft_ink_rules.py da4b0cd1d6b115f985f2e90bdba25c42faa082cf384cdb653de271d7d51c349b
ordered_ink_rules.py 34cf277d5f05610cdeae3a0d6d6429b431b518a4b829c500452f01350ebf88cd
font_context_soft.py 01eebdc8ab8546df61f216c6b77352a2fedc59d94c4b4725ce8266865f9c8649
features.py 98d3723990681305912e919788b9a277747e02f0481539d0b1fe4140daf18a5f
NativeSourceWeightGraph.swift 74997ccd6044c126f1883f00901cabf9cf4192593a2f7c5912a4d3196ea0e759
```
