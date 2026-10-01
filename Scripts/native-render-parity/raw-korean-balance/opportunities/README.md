# Raw Korean soft-wrap opportunity evidence

The production `NativeKeepAllBreakOpportunities.swift` implements the one raw,
same-bidi text-node case with `white-space:pre-wrap`, `word-break:keep-all`,
`line-break:auto`, normal NBSP and zero word spacing. It keeps original UTF16
positions. It groups U0020 and TAB, marks LF as a forced break, splits before
ZWSP and after ideographic space. NBSP, narrow NBSP and word joiner stay text.
`overflow-wrap:anywhere` is emergency layout, not an extra balance opportunity.
Preserved TAB and trailing soft-hyphen disable the original constrainer; caller
must honor these eligibility conditions and ordinary-layout fallback.

Run `python3 Scripts/native-render-parity/raw-korean-balance/opportunities/run-keep-all.py`.
This extracts actual primary C++ `BreakLines::isBreakableSpace`,
`nextBreakableSpace`, `moveToNextNonWhitespacePosition`, and
`moveToNextBreakablePosition` bodies at WebKit commit
`dd5fe1011df7e3438ac4889356abcab7681df46d` (see sibling `reference`).
It compares original item ranges and forced paragraphs with Swift on 1,215 cases,
including emoji UTF16, repeated whitespace and zero-width characters.
Report: `build/native-render-parity/raw-korean-balance/keep-all/report.json`.
This isolates regular opportunity discovery, not glyph measurement or pixels.

`capture.swift` compares public CFStringTokenizer line-break tokens with actual
host WKWebView ordinary wrap observations across a bounded width sweep, under
explicit `lang=ko`. Run it using a compiled host Swift executable with output
`build/native-render-parity/raw-korean-balance/opportunities/capture.json`, then
`summarize.py`. The `und` and English tokenizer ends match the observed normal
(no emergency anywhere) ends on 13/14 strings. `A/B—C-D 안녕･세계` exposes a CF
extra break after slash. Korean tokenizer uses morphological-looking boundaries
that do not reproduce WebKit normal mechanical analysis. Therefore neutral CF
is only an experiment for normal wrapping; it is not used in production.

A missing end in the bounded width sweep is not proof that it is illegal.
Frozen HTML explicitly chooses node lang from script (`ko`, `ja`, `zh`, `und`),
so no default English locale assumption is made. Tabs, punctuation, NBSP,
word-joiner, ZWSP, ideographic space, mixed CJK/Latin, Jamo and emoji are covered.
Source Typography's `TextUtil::contentAnalysis` distinguishes Mechanical from
Linguistic; keep-all takes `BreakLines::nextBreakableSpace`, bypassing ICU.

SlidingWidth sums per-item widths. For pre-wrap it retains first-line leading
whitespace, trims later-line leading whitespace and all trailing whitespace.
Do not replace those rules with Unicode whitespace normalization: NBSP and
ideographic space are non-whitespace inline items in this source contract.
