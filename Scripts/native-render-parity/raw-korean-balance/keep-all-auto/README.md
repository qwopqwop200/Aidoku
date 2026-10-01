# Raw keep-all ordinary auto baseline

`NativeKeepAllAutoLines.swift` is staged outside app inputs while BUILD36 is
held. Its scoped ordinary decisions follow pinned primary WebKit
InlineContentBreaker::wordBreakBehavior/processOverflowingContent,
InlineLineBuilder's accepted wrap-opportunity recording, and TextUtil::breakWord.
One same-bidi raw pre-wrap keep-all text node with overflow-wrap:anywhere is
supported. Shaped width and emergency grapheme prefix fitting are explicit
callbacks. Tabs, LF paragraphs, soft hyphens and other modes are declined.

A regular wrap position already accepted on a nonempty line prevents an
emergency intra-word split: move the new whole word first, then emergency-fit
its prefix on the empty next line. Preserved whitespace hangs, first glyph on
an empty line may overflow, and overflowNormal keeps an unbreakable long word.
This is independent of the previous CTTypesetter ordinary fallback that filled
an earlier partial line with the next word fragment.

`capture.swift` captures actual WK ordinary wrap before balance, with corrected
per-scalar nonempty getClientRects fragments, and Canvas substring advances.
The 25 bounded cases reuse the existing18 caller fixtures and seven real
producer descriptors: real7 ID16 fonts7.25/8.75/11 from web-fit.json; real1
ID0 fonts9.25/8.75 and ID6 fonts7.5/8.75. These are a causal baseline comparison,
not a fresh full image matrix. Dynamic fractional tracking and used CSS padding
are retained. Parent input descriptors remain unchanged.

```
xcrun swiftc -O Scripts/native-render-parity/raw-korean-balance/keep-all-auto/capture.swift -o /tmp/native-keep-all-auto-capture
/tmp/native-keep-all-auto-capture build/native-render-parity/raw-korean-balance/keep-all-auto/capture.json
python3 Scripts/native-render-parity/raw-korean-balance/keep-all-auto/run.py
```

With captured Canvas advances **and separately genuine CoreText advances**,
ordinary greedy UTF16 ranges match25/25 and the resulting native
ordinary-greedy→balance pipeline flow ranges match25/25. Three >6-row cases
(9/12/15), NBSP and preserved leading/multiple spaces are included. Ten final
balances correctly keep the source-greedy emergency baseline; fifteen accept.
Emergency callback iterates actual Foundation composed-character boundaries
and measures prefixes; the helper does not fake an ordinary word-count baseline.
Font/Unicode versions and styles beyond these cases are not fully certified.

Literal real7 rows at7.25 and8.75 are [0,3],[3,4],[7,3] ('부, ','부탁드립','니다♡').
The older getBoundingClientRect union can span the previous zero-width caret
and next-row glyph, so it is not a literal scalar row rectangle. The earlier
reported split4,8 is not substituted for the corrected actual range capture.

The normal CSS keep-all/overflowNormal mode is separate; ASCII collapse and
NBSP preservation must be explicitly transported. The released-column
word-break:normal path must bypass this keep-all helper. The neutral CF normal
bridge remains diagnostic. Production Type integration owns those mode gates.

Report includes SHA256s for the tested helper, primary source and capture
inputs at build/native-render-parity/raw-korean-balance/keep-all-auto/report.json.
No full-render or pixel-equivalence claim is made.
