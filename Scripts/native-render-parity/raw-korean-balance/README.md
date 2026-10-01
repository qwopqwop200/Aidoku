# Primary WebKit paragraph balance policy

Run `python3 Scripts/native-render-parity/raw-korean-balance/run.py`.

The oracle compiles extracted WebKit `computeRaggedness`,
`balanceRangeWithLineRequirement`, and `balanceRangeWithNoLineRequirement` bodies
from commit `dd5fe1011df7e3438ac4889356abcab7681df46d`. Supplied legal break
opportunities and Float sliding-width matrices isolate the policy. Swift uses
these same supplied values. The tested decision retains the actual original
ordinary-wrap line count through 12 rows, then uses unlimited-row DP; no-solution
falls back to ordinary layout. Cost is cubic raggedness, not minimax width.

230 cases match exactly, including 41 ordinary paragraphs beyond 12 rows. This
does not establish Unicode wrap-opportunity discovery, CoreText font metrics or
final raster equality. The pure helper is production-published; caller integration remains with the
Typography owner and its actual line breaker.

Primary source:
https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/layout/formattingContexts/inline/InlineContentConstrainer.cpp

Report: `build/native-render-parity/raw-korean-balance/report.json`.
