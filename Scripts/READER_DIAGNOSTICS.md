# Reader image translation diagnostics

Normal reader use records numeric milestones and timings automatically; no text, URL,
credential, prompt or model name is logged. Copy these files from the installed app's
`Documents` directory: `reader-memory-events.log`, `translation-performance.log` and
their `.previous.log` rotations.

```sh
xcrun devicectl device copy from --device <device-id> \
  --domain-type appDataContainer --domain-identifier <installed-bundle-id> \
  --source Documents/reader-memory-events.log --destination work/reader-memory-events.log
python3 Scripts/reader_pipeline_report.py work/*events*.log work/*performance*.log --page 60
```

`--json` emits structured results; `--token <page_token>` isolates one page when several
chapters share a page number. Old anonymous events cannot be connected to a page.

## Events

Each event has wall time, monotonic uptime, process ID and a per-file sequence. `trace`
identifies a work chain in one process; `page_token` (first 64 bits of the SHA-256 page
identity) connects loads of one page; `page` is the 1-based position or -1. Measured
scopes emit `_begin`/`_end`; ends carry `elapsed_ms`, an error `code` and `outcome`
(0 returned, 1 cancelled, 2 error). Durations include nested work: do not sum nested
spans. An unmatched start may be active work, cancellation, rotation or a crash, not
necessarily a deadlock. `bitmap_attached_before_layout` is a diagnostic condition, not
proof of a display failure.

## Cost

Callers only take a timestamp and a short lock. Each writer holds at most 256 pending
records (excess counted as `dropped`), writes batches every ~250 ms without `fsync`, and
keeps two files of at most 512 KiB. Memory is sampled at most once per second
(`memory_sample_uptime`). Diagnostics add no OCR, provider or render work.
