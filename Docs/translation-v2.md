# V2 image translation pipeline

A second, speed-first page translation pipeline that lives next to the legacy
`NativeEngine` pipeline. Priorities: **1. speed, 2. quality, 3. simplicity.**
OCR character recognition and translation quality are bounded by the Core ML
recognizer and the LLM, so V2 reuses them unchanged and optimizes everything
around them. V2 is built and measured on the Mac host first, then ported to iOS.
The legacy pipeline stays the default until V2 wins on the gates below.

## Why

Profile of the final 830-page live run (Mac, non-LLM wall time, 823 pages):
render 61% (layout retries/recovery alone 75% of paint time on 125 pages;
obstruction recovery improved nothing on 69 of 77 pages), OCR 21% (recognition
2.8x detection, repeated model loads), OCR lane queueing 16%, source appearance
11%. GT experiments showed the biggest quality hole is detection fragmentation:
grouping recall is 0.969 with GT boxes but 0.845 with production detection.

## Stages and owners

All code is in `Aidoku/Core/Translation/V2/` (compiled by the app and by the
host `--pipeline v2` entry). Shared value types: `V2Types.swift`. Stages are
plain functions over those values; no legacy singletons, task-locals, cache
stores, registries or environment-variable policy switches.

| Stage | File | Contract | Budget (Mac, ms, median) |
|---|---|---|---|
| Models | `V2Models.swift` | `final class V2Models` loads detector, recognizer, RF-DETR layout and AOT once and keeps them resident; `static func load(bundle:) throws -> V2Models` | load once |
| S1 layout | `V2LayoutDetection.swift` | `detect(_ page: V2Page, models:) async throws -> [V2LayoutRegion]` (RF-DETR), runs concurrently with S2 | 100 |
| S2 detect | `V2Detection.swift` | `detect(_ page:, models:) async throws -> [V2Line]` then `V2LineAssembly.assemble(_ lines:, layout:) -> [V2Line]` merging detector fragments of one column/row (recall-first) | 200 |
| S3 recognize | `V2Recognition.swift` | `recognize(_ page:, lines:, models:) async throws -> [V2Line]` batched by width bucket | 250 |
| S4 group | `V2Grouping.swift` | `group(_ lines:, layout:, pageSize:) -> [V2Block]` + reading order; `V2RoleFilter.classify(_ blocks:, layout:) -> [V2Block]` | 10 |
| S5 translate | `V2Translation.swift` | one request per page through `TranslationHTTPCodec` / `RemoteTranslationClient`; replay mode reads saved translations (no LLM) for evaluation | LLM |
| S6 mask | `V2RemovalMask.swift` | `build(_ page:, blocks:, layout:) -> [UInt8]` page-size 0/255 text-ink mask, **recall first** (erase every trace) with an artwork false-positive guard | 80 |
| S7 inpaint | `V2Inpaint.swift` | `restore(_ page:, mask:, models:) async throws -> CGImage` (AOT, pixels outside the mask unchanged) | 200 |
| S8 style | `V2Style.swift` | `estimate(_ page:, blocks:) -> [V2Block]` font px, bold, text/stroke colour | 30 |
| S9 layout | `V2Layout.swift` | `place(_ blocks:, pageSize:) -> [V2PlacedText]` single bounded pass: largest CoreText size that fits the balloon/block; never refuses a page (floor 10 px, then allowed balloon overflow) | 50 |
| S10 paint | `V2Painter.swift` | `paint(background:, blocks:, placed:) -> CGImage` CoreText horizontal/vertical with stroke | 100 |
| Orchestrator | `V2Pipeline.swift` | runs one page, records `V2Timings`, returns `V2PageResult`; host overlaps pages (S1+S2 concurrent, S3 batched, LLM overlapped, encode off the critical path) | — |

Gate: Mac non-LLM wall time per page median <= 1.0 s, p90 <= 2.0 s.

## Quality gates (vs legacy on GT dev)

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

## iOS app integration (opt-in)

`Reader.translationPipelineV2` (default off; Settings > Translation > Fast Pipeline)
routes reader pages and translated downloads through
`Core/Translation/ReaderTranslationV2Service.swift`: models load lazily once per
session (recognizer 2, or 3 at >= 7 GB; detector 1-2; AOT 1) and are released on
memory warnings; S5 uses the live `RemoteTranslationClient` through
`ReaderTranslationService.translateV2` (shared provider limiter, mandatory page
settings). The rendered page is cached under `v2-<version>-` keys (image as
`.layout`, blocks as `.translation`) and presented by `ReaderTranslationPage.processV2`
through the cached-page canvas; the legacy session stays off in V2 mode.
Compute admission is split: S1-S4 and S8/S6-S10 each take a priority-ordered
slot (2 each, visible before look-ahead) and no slot is held during the
provider wait. The coordinator pre-translates the next 1-2 pages with the
legacy look-ahead policy (pretranslation limit, background-only mode); a page
that becomes visible joins and promotes its running look-ahead. Blocks pass the
legacy source-language rule (manga recognizer, plus Han-only recall) before S5.
`V2ReaderPipelineBenchmarkTests` (AidokuFull) prints per-stage timings for three
synthetic pages without any LLM call.

## Rules

Never view or describe page images (private); process pixels in code only.
No credentials in logs. LLM is called only in live mode; evaluation replays
saved translations.

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

The training/fitting scripts that generated `V2RemovalMaskWeights.swift` and
`V2StyleParameters.swift`, and the per-stage experiment reports, are kept outside
the repository (they depend on private page data). `Scripts/v2/eval.py` scores a
V2 run against the GT split.
