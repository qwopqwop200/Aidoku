# V2 image translation pipeline

The only page translation pipeline, used by the reader, translated downloads and the Mac host CLI. Priorities:
**1. speed, 2. quality, 3. simplicity.** Recognition and translation quality are bounded by the Core ML recognizer
and the LLM, so V2 optimizes everything around them. It is built and measured on the Mac host first, then on iOS.

## Stages and owners

All code is in `Aidoku/Core/Translation/V2/` (compiled by the app and the Mac host). Shared value types live in
`V2Types.swift`; stages are plain functions over them, with no singletons, task-locals, registries or
environment-variable policy switches.

| Stage | File | Contract | Budget (Mac, ms, median) |
|---|---|---|---|
| Models | `V2Models.swift` | `final class V2Models` loads detector, recognizer, RF-DETR layout and AOT once and keeps them resident; `static func load(bundle:) throws -> V2Models` | load once |
| S1 layout | `V2LayoutDetection.swift` | `detect(_ page: V2Page, models:) async throws -> [V2LayoutRegion]` (RF-DETR), runs concurrently with S2 | 100 |
| S2 detect | `V2Detection.swift` | `detect(_ page:, models:) async throws -> [V2Line]` (corners in the recognition reading-quad order, so a tilted column keeps its short edge on top) then `V2LineAssembly.assemble(_ lines:, layout:) -> [V2Line]` merging detector fragments of one column/row (recall-first) | 200 |
| S3 recognize | `V2Recognition.swift` | `recognize(_ page:, lines:, models:) async throws -> [V2Line]` batched by width bucket; one read per line, text lines (long >= 1.5 x short side) cropped 5% of the short side wider | 250 |
| S4 group | `V2Grouping.swift` | `group(_ lines:, layout:, pageSize:) -> [V2Block]` + reading order; `V2RoleFilter.classify(_ blocks:, layout:) -> [V2Block]` (also keeps low-confidence fragments of <= 4 characters outside any balloon as source: no request, erase or paint); legacy utterance boundaries keep complete quoted units, and closed sentences in separate columns, apart; a component outside every RF text region and without a quote mark (SFX) never joins quoted speech; a one-glyph line may join a column or a row; a one- or two-letter fragment cut off a column/row end (inside its cross span, overlapping at most half its own length, within 1.5 of the full line's glyphs) continues that line and is read in place; side-by-side lines in one RF balloon may be 1.25 glyph apart (else 1); a fragment (< 3 letters) on the same enclosed paper component within 1.6 glyph joins its neighbour (`V2BalloonUnits.swift`); an intercolumn ruby rail (kana-only, <= 1/1.5 of one kanji column's width, just right of it) is erased with its host and never translated | 10 |
| S4b interior | `V2Interior.swift` | `apply(_ blocks:, raster:, pageSize:, layout:) -> [V2Block]` sets `balloon` to the lettering box: the legacy exterior box: a granted margin of 3 x 1.5 line thicknesses, then up to 6 growth steps per side (1 em sideways, 0.5 em vertically, within 8 x 4 line thicknesses), stopped by other text (> 2% of the strip), other RF balloons, the enclosing RF panel frame and the block's own balloon box, and on clean paper, once the box holds 3x the source area, by > 3% ink or art in the added strip; plus per-row clean half-widths about the source centre on clean paper, `V2Block.rows`, or the ellipse-inscribed rectangle of a detected balloon that holds no other text, whichever is larger. On clean paper enclosed within the growth limit, the legacy balloon lobe (distance cores >= 0.32 of the peak, lobe holding >= 70% of the source) gives a tail-free centred rectangle that replaces the grown box when it keeps >= 60% of its area | 2 |
| S5 translate | `V2Translation.swift` | one request per page through `TranslationHTTPCodec` / `RemoteTranslationClient` with the page-lettering contract (page role descriptions, one call, no fallback) when the page image is attached; raw tabs/newlines a reply leaves inside JSON strings are read as spaces, leaked escapes are decoded, and a reply left in Japanese with no Hangul at all keeps the source; replay mode reads saved translations (no LLM) for evaluation | LLM |
| S6 mask | `V2RemovalMask.swift` | `build(_ page:, blocks:, layout:) -> [UInt8]` page-size 0/255 text-ink mask, **recall first** (erase every trace) with an artwork false-positive guard; searches the line polygons dilated by max(8, 0.3 T) plus each line box grown 0.5 T along its axis (glyphs past a short detection) | 80 |
| S7 inpaint | `V2Inpaint.swift` | `restore(_ page:, mask:, models:) async throws -> CGImage` (AOT, one prediction per page, pixels outside the mask unchanged): the mask's 16-px cells plus context (widest of 384/256/160/96/64 px that fits) are merged into disjoint rects and shelf-packed as a mosaic into the 1024 input at native resolution (16-px replicated border per patch), else at the largest common scale, else the union of all rects is downscaled as one patch | 200 |
| S8 style | `V2Style.swift` | `estimate(_ page:, blocks:) -> [V2Block]` font px (geometric per-block rule; blocks of similar size are grouped, longer texts seeding the groups, and each group takes the median weighted by text length), bold, text/stroke colour | 30 |
| S9 layout | `V2Layout.swift`, `V2Cohort.swift`, `V2Rotation.swift` | `place(_ blocks:, pageSize:) -> [V2PlacedText]` single bounded pass: largest CoreText size that fits the lettering box, capped at 1.05x the source size in a balloon and at the source size outside (legacy source-size hold); never refuses a page (floor 10 px, then allowed balloon overflow). Size cohorts (same orientation/bold; colour ignored as in the legacy families, outline ignored as S8 presence is noisy; sources snapped within 1.08x, chained within 1.22x; a block in no cohort joins the nearest one of its orientation and weight within 1.08x, since outline detection is noisy) share one cap (family median source x cap ratio); after the fits every family takes the largest cap step (1, 0.95 ... 0.65, >= 12 px) all its members reached, then the page takes the smallest family scale; members only shrink, and one that cannot reach 0.65 keeps its fit; a re-fit that lands below its family size (whole words preferred) pulls the family down to it, up to three more rounds. Horizontal family members share one paragraph alignment, the majority (narration left, else centred; ties centred). Shared start lines (legacy source clusters, separate from size cohorts): upright blocks of one orientation and panel with source tops within 0.75 em and boxes < 5 em apart (chained) share the median centred top (left when their lefts spread less), clamped to every member's balloon or panel; a member that would collide keeps its frame, and so does a tilted member while the upright rest share the line. Whole words are preferred down to 0.85x of the split size, then narrowed to 0.9 width before a word is split (never inside a Latin word or number); closing marks never start and opening marks never end a line; punctuation never stands alone; Korean phrase coupling (determiners, negation, dependent nouns), no lone trailing syllable and no line-initial suffix mark unless they cost > 10% of the size. A tall paragraph in a balloon (h >= 1.4 w) keeps its lines within 1.35x the source width (at least 3.5 em and the widest word). The chosen wrap is compacted to the narrowest width no taller than the source (a wrap at most 1.15x wider wins when it has fewer lone one-grapheme lines and split Korean phrases) and centred on the source; with row spans, lines may take the full width of their rows in a rounded balloon when that allows a >= 3% larger size. A vertical source whose horizontal fit stacks one or two graphemes per line is set in vertical columns; tilted sources (line-quad consensus, >= 2.5 degrees) are painted at their tilt when the rotated text fits. Provider line markup (`<br>`, `\|` and `/` in Hangul (a slash next to Latin letters or digits stays), separators, zero-width and braille blanks) is painted as spaces and a long-vowel mark after Hangul as `~`; provider narration/story_text lines are left-aligned; frames keep a small page-edge margin and fallback growth stays inside the RF panel; a horizontal frame is the painted ink (1.18 em line advances, 0.94 em of ink for the last line: 0.83 above to 0.11 below the baseline) | 50 |
| S10 paint | `V2Painter.swift` | `paint(background:, blocks:, placed:) -> CGImage` CoreText horizontal/vertical (vertical punctuation forms) in Apple SD Gothic Neo Medium, the legacy overlay face (Bold only for S8-bold lettering; 98.5% of GT sources are regular), rotated about the frame centre when tilted; outline width scales with the size, round joins, outlines before fills; text whose fill and outline would vanish into the sampled restored background gets a black/white legibility halo; each baseline sits 0.83 em below its line's ink top, and condensed left-aligned lines start at the frame edge after the condense | 100 |
| Orchestrator | `V2Pipeline.swift` | runs one page, records `V2Timings`, returns `V2PageResult`; host overlaps pages (S1+S2 concurrent, S3 batched, LLM overlapped, encode off the critical path) | — |

Gate: Mac non-LLM wall time per page median <= 1.0 s, p90 <= 2.0 s.

## Quality gates (vs the legacy baseline on GT dev)

Evaluation uses `aidoku-unified-gt-20261116.json` (all labels user-reviewed)
and the canonical split in
`pipeline-generalization-20261117/evaluation-audit/CANONICAL-GROUPED-SOURCE-MANIFEST.json`
(train 506 / dev 179 / test 145 pages). Fit on train, select on dev, test is run
once at the end. Report group-fold and 20-page-block CV; a change counts only
if it wins most folds.

- Detection (S2): recall at IoU 0.5/0.7 >= legacy (0.974 / 0.939); precision is secondary (filtering happens downstream).
- Grouping (S4): pairwise F1 with V2 detection >= legacy 0.915; purity >= 0.99.
- Mask (S6): pixel recall and 2 px edge-band recall >= legacy (0.998 / 0.993); far false positives within +15%.
- Role (S4): dialogue recall 1.0; F1 >= 0.98.
- Style (S8): font size MAE <= 2.6 px; weight accuracy >= 0.98.
- Render (S9/S10): zero page failures; no text outside the page; no overlap between painted blocks.
  Typesetting is also checked against the GT balloon/narration masks (share of each text frame outside its
  balloon), the GT exact source-size classes (painted size spread inside a class), distance from the source and
  a gradient-based art-coverage proxy, plus line breaks inside words, lines opening with closing punctuation and
  punctuation-only lines. Replay, train 506 pages (never used for selection), before -> after: blocks with a split
  word 1330 -> 736, closing-mark line starts 1190 -> 49, punctuation-only lines 1101 -> 16, frames > 5% outside
  their GT balloon 744 -> 63, overlaps 6 -> 0, frame-to-source distance p90 5.3 -> 0.50 em, art coverage
  0.123 -> 0.038; source-size classes within 1.10x / 1.25x 0.446 / 0.588 -> 0.351 / 0.584; painted size vs GT
  source size 1.18x -> 1.00x, sizes < 0.6x source 50 -> 53. Evaluated and left out: shadows and multi-ring
  outlines (0.3% / 0.2% of GT sources), SFX notes (unreliable SFX role), page style harmonization (raised fill
  and outline colour error against GT source_appearance at every threshold), AOT boundary-bias calibration
  (changed 8 of 179 dev pages by one level: flat rings are rare), raster line-end extension (recall@0.7 0.974 ->
  0.92 on dev: GT boxes are tight and label trailing marks as lines) and the balloon optical centre (dev gain did
  not hold on train).

## iOS app integration

Reader pages and translated downloads always run through `Core/Translation/ReaderTranslationV2Service.swift`:
models load lazily once per session (recognizer 2, or 3 at >= 7 GB; detector 1-2; AOT 1) and are released on memory
warnings; S5 uses the live `RemoteTranslationClient` through `ReaderTranslationService.translateV2` (shared
provider limiter, mandatory page settings). The rendered page is cached under `v2-<version>-` keys (image as
`.layout`, blocks as `.translation`) plus the render version (`renderVersion`): a rendering-only change re-renders
from the stored blocks (S1-S4 re-run, translations replayed by id and source text) without a provider call, and the
blocks are stored even when only S7/S9 failed. A sent provider request is not cancelled with its page (at most two
outlive their pages); it stores its translations, so a page left mid-request is not paid for twice. Transient
provider failures (408/409/425/429/5xx, dropped connections, timeouts; a malformed response once) retry after 1 s
and 3 s. Provider `error` roles and replies that repeat lettered source text keep the source pixels. Pages are
presented by `ReaderTranslationPage.processV2` through the cached-page canvas. A cached page (memory LRU, then
disk) is attached in the loader's source commit (`prepareCachedImage`), so it never flashes the source. Finished
bitmaps, including temporary (non-persisted) pages, stay in an in-memory LRU bounded like the old translated-bitmap
budget (32-192 MB of headroom). S4 orders blocks/panels by the reader direction (`V2ReadingDirection`:
right-to-left manga, mirrored left-to-right, top-to-bottom bands for vertical/webtoon); non-RTL directions are part
of the cache key. At launch, legacy cache rows and compiled copies of the retired OCR tiers are deleted once. The
disk cache clears its page rows when the provider, model, credentials, languages or source filter change
(`ReaderTranslationCachePolicy`); OCR and overlay-appearance settings no longer affect it. Compute admission is
split: S1-S4 and the back work each take a priority-ordered slot (2 each, visible before look-ahead) and no slot is
held while merely waiting for the provider. S8, S6 and S7 read no translation text, so `V2Pipeline` starts them
right after S4 (on the blocks predicted to be painted: replayed or language-eligible, non-background; the host CLI
predicts replay the same way) and they run during the provider call under their own back slot; only S9/S10 wait for
S5. If S5 paints a different block set, S6/S7 are recomputed after S5 (`speculation_miss`), so output never depends
on the overlap. The page is decoded once: for an opaque sRGB page the detector/recognizer RGBA frame is also the
S1/S6/S7 raster (`decode_conversions` = 1). The page JPEG is only encoded when the page image is sent (concurrently
with S1-S4), and the disk-cache JPEG is written after the page is returned. The coordinator pre-translates the next
1-2 pages (both halves, in reading order, for wide pages the reader splits) with the look-ahead policy
(pretranslation limit, background-only mode); a page that becomes visible joins and promotes its running
look-ahead. Blocks pass the legacy source-language rule (manga recognizer, plus Han-only recall) before S5.
`V2ReaderPipelineBenchmarkTests` (AidokuFull) prints per-stage timings for three synthetic pages without any LLM
call.

## Mac host

`swift Scripts/image-translation.swift` compiles this folder, an explicit list of shared app files (detector,
recognizer, translation client, simple grouping, painters) and `Scripts/image-translation-v2` into an incremental
`-O` binary (`build/image-translation-v2`). Live mode (default) calls the provider like the app (page JPEG attached,
SFX/background filtering, at most three concurrent requests) but does not apply the reader's source-language
filter; `--replay-translations DIR` replays a legacy (`page-index.json`) or V2 (`pages/*.json`) run without an LLM;
`--ocr-only` runs S1-S4 and renders nothing. Options, outputs and smokes: `Scripts/image-translation/README.md`.

## Rules

Never view or describe page images (private); process pixels in code only. No credentials in logs. The LLM is
called only in live mode; evaluation replays saved translations.

## Measured results (Mac host, replayed translations, no LLM)

Canonical split, models resident, `--jobs 3`. Test was scored once after all
selection was finished on train/dev.

| | Legacy dev | V2 dev (179) | Legacy test | V2 test (145) |
|---|---|---|---|---|
| Detection recall @IoU 0.5 / 0.7 | 0.974 / 0.939 | 0.997 / 0.974 | 0.989 / 0.971 | 0.996 / 0.988 |
| Grouping F1 (production detection) | 0.915 | 0.977 | 0.922 | 0.982 |
| Grouping purity | 0.999 | 0.998 | 0.996 | 0.995 |
| Page failures | — | 0 | — | 0 |
| Non-LLM ms per page, median / p90 | render alone 1667 / 4285 | 633 / 870 | — | 673 / 914 |

Stage-level dev results: mask recall 0.99827 (edge 0.99728) at 34 ms vs ~430 ms
legacy; style fill ΔE 0.99 vs 1.16 at 14 ms vs 389 ms; recognition text identical
to legacy at 94 ms vs 323 ms median; layout+paint 7 ms vs 282 ms median (21.6 s max).

The training/fitting scripts that generated the tables in
`Resources/Translation/V2Weights.bin` (read by `V2Weights.swift`), and the per-stage experiment reports, are kept outside
the repository (they depend on private page data). `Scripts/v2/eval.py` scores a
V2 run against the GT split.
