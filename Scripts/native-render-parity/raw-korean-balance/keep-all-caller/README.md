# Actual raw keep-all balance caller proof

Production helper: `NativeKeepAllTextBalance.swift`; it reuses primary-policy
`NativeRawTextBalance` (230 supplied matrix cases) and
`NativeKeepAllBreakOpportunities` (1,215 extracted primary scanner cases).

Capture `capture.swift` in a host macOS WKWebView. It contains 18 bounded
fixtures (six strings at widths 75, 100, 120), CSS `lang=ko`, Apple SD Gothic Neo
700/16px, line height20px, zero tracking, pre-wrap, word-break keep-all,
overflow-wrap anywhere and line-break auto. It records **actual text-wrap:wrap
ordinary auto ranges first**, then actual text-wrap:balance ranges; it does not
substitute a preferred-word count for the ordinary baseline.

```
xcrun swiftc -O Scripts/native-render-parity/raw-korean-balance/keep-all-caller/capture.swift -o /tmp/native-keep-all-caller-capture
/tmp/native-keep-all-caller-capture build/native-render-parity/raw-korean-balance/keep-all-caller/capture.json
python3 Scripts/native-render-parity/raw-korean-balance/keep-all-caller/run.py
```

The helper is run twice: supplied actual Canvas substring advances, and genuine
CoreText advances at the same host font. Both reproduce 18/18 **literal UTF16
flow ranges** and visible row texts. Four cases correctly keep the original
emergency layout because no regular keep-all balanced solution fits. Fourteen
accept a balance solution. Three ordinary baselines exceed six lines (9/12/15).
Leading/multiple U0020 spaces and NBSP are covered; NBSP is never normalized.

Primary DP boundaries can precede a preserved whitespace group. Actual pre-wrap
flow hangs that group on the preceding line. Result retains abstract `ranges`
for DP evidence and separately transports `flowRanges`; painting must use the
flow result or reflow using the returned constraints. Zero-content direct row
transport, preserved TAB, forced LF paragraphs and trailing soft hyphens are
explicitly declined here. These need caller-owned behavior, not a whole-word
fallback invented by this helper.

Widths sum exact per-item Float advances, retain first-line leading whitespace,
trim later leading and trailing whitespace, then use LayoutUnit ceil(raw+1/64).
The API accepts originalAutoRanges supplied by the native shaper. **This proof
uses actual WK ordinary auto input and does not establish the current native
CT auto/emergency baseline as CSS equivalent**. Typography core wiring owns
that boundary. Floating accumulation at arbitrary platform font values and
other CSS/bidi styles remain outside these 18 bounded cases.

Report: `build/native-render-parity/raw-korean-balance/keep-all-caller/report.json`.
This is line policy/layout evidence, not final raster pixel equivalence. The
neutral CF normal scanner remains a separate diagnostic experiment.
