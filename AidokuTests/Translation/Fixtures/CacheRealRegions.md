# Translation cache storage fixture

`CacheRealRegions.json` contains the first 24 nontrivial (at least four regions) saved page results, ordered by filename, from `datasets/real-comics-3000/pipeline-quality-v12/candidate/*-regions.json` in the parent workspace. Page identifiers are retained as dictionary keys. Text, Korean translations, coordinates and OCR attributes are unchanged.

The storage regression compares the existing compressed full-record representation with shared source records. It covers one actual translation per page and, separately, three variants (the extra two are simulated setting changes, not new provider results). It checks exact reconstruction, migration, allocated disk size, and shared-reference eviction. It does not measure OCR or translation quality or physical-device latency.

The multi-variant case stress-tests the storage primitive only. Production settings synchronization removes prior-model translation/layout entries, preserving OCR; users do not accumulate those model variants.
