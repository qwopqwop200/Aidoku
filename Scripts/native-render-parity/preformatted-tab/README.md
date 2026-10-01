# Literal preformatted TAB fidelity

`run.py` captures102 actual host WK block-span cases and runs the complete native
CoreText shaper. `run-app-tests-host.py` runs three unchanged app/staged regression
assertions. Optional AIDOKU_TAB_TYPOGRAPHY/AIDOKU_TAB_POLICY paths select a staged
candidate without changing production source during a build hold.

The original48 whole Range boxes are exact, including12 prior TAB failures.
Across102 fixtures, inline origin/width, literal source text, and relative line
pitch match exactly. Controls include repeated/leading/trailing tabs, a tab gap
between half-space and half-zero, NBSP, emoji UTF16, and positive-leading Hiragino
at6/12 points. Full geometry mismatches remain visible in the report: primary
font Range y/height differs in some larger Korean and small Japanese cases; that
does not invalidate the tab-width proof or establish final PNG equality.

The space grid excludes letter spacing. Each tab advances to an explicit grid
location, then includes its own spacing. Replacing the interval by eight tracked
spaces accumulates an error across repeated tabs. The helper never replaces tabs
with spaces or changes original UTF16 indices. The final paragraph style must
retain fixed CoreText pitch while adding explicit stops.

The frozen engine uses a minimum gap of half the primary space, confirmed by the
official WebKit c479f0fb22bf0e4c7b15074191592c3d5bf1b75d source and actual WK
counterexamples. Main changed that rule to half-zero on2026-09-08; following the
newer rule would break the original renderer's actual reference pixels.
