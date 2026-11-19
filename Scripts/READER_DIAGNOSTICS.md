# Reader image translation diagnostics

Normal reader use records numeric milestones and timings automatically. No `run.json`, debugger,
OCR-text dump, screenshot, or provider key is required. Detailed typography profiling remains opt-in.

## Collect and summarize

Discover the current phone with `xcrun devicectl list devices`. Copy these files from the installed
app's `Documents` directory (`--domain-type appDataContainer --domain-identifier <installed-bundle-id>`):

- `reader-memory-events.log` and `reader-memory-events.previous.log`
- `translation-performance.log` and `translation-performance.previous.log`

For example, with a verified device ID and the installed bundle ID:

```sh
xcrun devicectl device copy from --device <device-id> \
  --domain-type appDataContainer --domain-identifier dev.junjae.Aidoku \
  --source Documents/reader-memory-events.log --destination work/reader-memory-events.log
python3 Scripts/reader_pipeline_report.py work/*events*.log work/*performance*.log
python3 Scripts/reader_pipeline_report.py work/*events*.log work/*performance*.log --page 60
```

`--json` emits structured results. `--token <page_token>` isolates one page if logs contain several
chapters with the same page number. The report accepts old logs, but old anonymous events cannot
be retroactively connected to a page. It never needs to open the translation database.

## Correlation and timing

Each event includes wall time, monotonic uptime, process ID and a per-file sequence number.
`trace` identifies a work chain within one process. `page_token` is the first 64 bits of the existing
SHA-256 page identity; it stays consistent across OCR, provider work, cache replay and UIKit callbacks.
`page` is the 1-based chapter position when known, otherwise -1. Separate loads of one page may have
separate traces; the token connects them.

Recorded events:

1. `source_load` / `source_image_response` / `source_download` / `source_decode_load`: source acquisition,
   cache/network response and decode/load. `source_load_result` has count 1 for success, 0 for failure.
2. `loaded_translation_hit/miss`, `loaded_presentation_fallback`: whether a saved translation was reused.
3. `service`, `providerAttempt`, `providerFailure`, `transport`, `batch` and `api_*` milestones: provider
   admission, retries and network/response timing.
4. `memory_reclaim_begin/end`: image work-budget reclamation.
5. `visible_bitmap_attached`: presentation. `bitmap_attached_before_layout` means the image view had
   nonpositive bounds at attachment; it is a diagnostic condition, not proof that the display failed.

Measured scopes emit `_begin` and `_end`. End records include `elapsed_ms`, numeric error `code`,
and `outcome` (0 returned normally, 1 cancellation, 2 error). Optional-cache scopes may return nil
normally; consult hit/miss records too. Durations include nested work and some queue waits: **do not
sum nested spans**. The report ranks phases by maximum duration and shows mean/P95, fallback/error
milestones and unmatched starts. An unmatched start can be active work, cancellation, log rotation,
a crash or dropped records; it is not automatically a deadlock.

`api_invalid_response` helps distinguish a rejected translation from a renderer failure. No source/translated text, URL, credential, prompt or model name is added.

## Cost and retention contract

- Caller-side work is timestamp capture and a short lock to admit a scalar record. No caller-side
  file I/O, `task_info`, source-image encoding, chapter-wide hash scan, or wait for logging completion.
- Each of the two writers holds at most 256 pending records and one scheduled drain. A drain owns
  at most one additional bounded batch. Excess events are discarded and counted as `dropped`.
- Writes are grouped on a utility queue, normally every 250 ms. Files are opened per batch rather
  than per event; no `fsync` is requested. A crash can lose the latest pending batch.
- Each sink retains two files of at most 512 KiB each (2 MiB total). Rotation/formatting stays on the
  writer queue. `write_failures` records cumulative persistence failures without affecting the reader.
- Reader memory is sampled on the writer queue at most once per second. `memory_sample_uptime`
  identifies the sample instant; repeated values are shared samples, **not** per-event measurements.
- There is no extra OCR/provider/render work to obtain diagnostics. Existing admission limits,
  cancellation, output pixels and cache identities are unchanged.
