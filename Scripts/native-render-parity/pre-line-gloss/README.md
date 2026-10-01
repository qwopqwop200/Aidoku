# Staged pre-line gloss proof

Run `python3 Scripts/native-render-parity/pre-line-gloss/run.py` from the worktree.
This builds one local macOS WKWebView capture and one host Swift probe. It uses
an isolated nonpersistent WebKit data store, local literals only, and actual
CoreText advances. It does not invoke Xcode or the iOS simulator.

The frozen caller at `reference-source/BrowserOverlayView.swift:15938-15941`
**reuses** the original `note.node`. It explicitly sets title `white-space:
pre-line` (effect notes use `normal`) and `word-break:keep-all`. It does not set
`overflow-wrap`; initial OCR nodes use `anywhere`, while earlier accepted CSS
mutations may have changed it. Captures cover both `normal` and `anywhere`.

The staged helper emits original UTF16 ownership for every normalized display
unit, then maps paragraph rows through the actual production keep-all greedy
helper. It preserves LF and blank rows, drops the final LF's extra empty row,
collapses only ASCII spaces/tabs, and preserves NBSP and Unicode em-space.
Actual DOM CR produces no advance or new line; CRLF keeps its LF. This is a
DOM textContent capture, not HTML parser normalization or general file newline
normalization.

The initial result remains preserved in `report-before-control-resolution.json`:
76 supported controls exact and 79/80 total. The extra form-feed control differed
because CoreText emits glyph1 with zero advance for U+000C, while WebKit's
`WidthIterator.cpp:801-806` replaces non-TAB/LF/CR control glyphs with glyph0 and
its actual selected font advance. AppleSDGothicNeo-Bold at 16 has glyph0 advance
13.84. The staged `NativeVisibleControlGlyphs` supplies this real advance while
retaining original UTF16 source positions; the repeated capture/probe is now
80/80 exact original-source glyph rows and exact line heights. The staged two
tests pass, including the previously failing FF overflow case.

This establishes row decisions, not painted glyph/pixel identity. A production
integration must replace the control glyph AND advance in the actual shaped
font run. Adding width alone or replacing FF with U+FFFD/ASCII space is not a
complete rendering implementation. Full font/Unicode coverage, production
Typography raster output, and iOS parity remain unverified by this proof.

`NativePreLineTextFlowTests.staged.swift` proposes two targeted next-batch tests.
It is not an app test target source. A production API would add
`HorizontalWhitespace.preLine`, retaining an independently selected
`HorizontalWrapping.keepAll` or `.keepAllWithEmergency`. The gloss caller must
carry its actual inherited overflow behavior and source mapping. It must not
trim NBSP by `CharacterSet.whitespaces` or replace standalone CR with a visible
ASCII space as the current `glossText(title:)` does.

Integration handoff is `build/native-render-parity/pre-line-gloss/typography-handoff.json`.
The capture fixes `text-wrap:wrap` and default `line-break` to isolate this bounded
whitespace proof. The actual reused gloss node also retains its previous
text-wrap and line-break: those inheritance rules require caller-level coverage
and cannot be silently reset during promotion. `textContent=note.text` destroys
old controlled SPAN/DIV children, so copied Style row flags must be cleared even
when source OCR geometry/provenance remains intact.

Batch41: actual production helper API is published with explicit
`preservesLineBreaks` (default true) and `balances` (default false). Normal
mode collapses LF, pre-line preserves it; balance invokes the existing shared
solver separately per forced paragraph and keeps auto on decline. Actual host
WK captures now cover 320 controls: pre-line/normal × wrap/balance × normal/
anywhere overflow × widths50/100. All original-source glyph row maps/heights
are exact, including FF. The probe measures attributes after the production
`NativeVisibleControlGlyphs.apply` hook, without an extra width adjustment.

`production-helper-tests-report.json` records optimized actual production
4 declarations/7 cases and independent glyph0 paint proof: direct
CTFontDrawGlyphs reference and CTLineDraw+GlyphInfo outputs have zero differing
RGBA bytes in bitmap and PDF raster, two fonts and two antialias modes.
Raw96×64 sRGB RGBA and lossless PNG views are under `control-paint`.
App suites `NativePreLineTextFlowTests` and `NativeVisibleControlGlyphTests`
are published; actual iOS execution remains parent-owned/pending BUILD41.
This is glyph-level native reference identity, not WebKit full-page pixel proof.
