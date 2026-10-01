# Released-column normal wrap diagnostic

`python3 Scripts/native-render-parity/raw-korean-balance/normal-columns/run.py` captures two exact BUILD36 real1 column descriptors and the existing 14 primary ASCII/CF texts at two widths, plus collapsed-space and unsupported-input controls. CSS is `white-space:normal`, `word-break:normal`, `overflow-wrap:anywhere`, block flow. Auto is captured before balance.

The staged **native ordinary greedy helper** computes auto source rows itself. The shared DP then consumes these native rows, never the WK ordinary rows. Both actual captured Canvas and genuine CoreText advances are exercised. Primary C++ `BreakLines` fast paths/Latin1 table and `InlineItemsBuilder` surround public CF neutral token ends as an **experimental substitute** for the original ICU mechanical backend. General CF/ICU equivalence is not established.

29 supported cases match ordinary and balanced rows with both width providers; 5 TAB/LF/bidi controls return nil. The caller must retain its established fallback when nil; no production caller is changed here. Normal collapse measures contiguous ASCII spaces once and removes leading spaces. Initial `pre-wrap` whitespace must not use this collapsed-space helper. Selection requires actual CSS provenance, never merely Korean font script. NBSP stays a text item.

Collapsed `white-space:normal` source characters can have zero or absent Range rectangles. The diagnostic groups **nonempty physical fragments**, assigning unpainted collapsed source whitespace to the preceding visible row (or first row). This convention prevents invented y=0 rows and is explicitly not a caret-ownership equivalence proof. Supported input is one LTR text node; the conservative RTL/control veto is bounded and not a complete Unicode bidi algorithm.

Artifacts: `build/native-render-parity/raw-korean-balance/normal-columns/{capture,input,native,report}.json`; source hashes retained. No production implementation is published by this diagnostic.
