# Frozen vertical CSS content-fit policy

`python3 Scripts/native-render-parity/vertical-content-fit/run.py` uses real host
WKWebView to capture 448 nodes. The renderer's `Object.assign(node.style, {...})`
block is taken verbatim from the immutable reference archive. Fixtures cover
Japanese, Han, Korean, Latin mixed text, explicit newlines, 800 weight, fractional
sizes/padding, vertical-rl, mixed orientation, clipping and balanced flex start.

Every native client/scroll metric agrees with the actual CSS when supplied the
observed full Range-visible column count and span-clone inline extent: 448/448, including
336 overflowing fixtures. That is a layout-policy proof, not a font-shaping proof.

`Probe.swift` separately compiles the production Core Text shaper and records its
columns/advances/ranges and invokes the actual production Post metric branch.
The corrected vertical advance API uses raw widths for untrimmed lines and
removes terminal CR/LF advances. The current host run records 80 differences
in observed Range/clone inputs and 62 actual original-node CSSOM differences.
Range-visible columns and a cloned explicit span are distinct observations: for
Korean case 320, the original Range exposes two columns while the clone spans
three. This alone does not establish a native font defect. Further anonymous
layout/paint investigation is required; fixture values never replace production
Core Text inputs. `run-shaping.py` records these limits and source digests.

The pure `NativeVerticalContentFit.metrics` policy accounts for negative column
flow on the left, clipping's leading padding and the inline axis's min-content
extent. `inlineExtent` accepts break-free Core Text advances and shaped UTF16
line ranges. Typography's owner integrates it after correcting those inputs.
Host results do not claim iOS vertical shaping parity.
