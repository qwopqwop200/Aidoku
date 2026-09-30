# Yomii version 7 native contract recovery

The backed `ko.yomii` v7 package had no matching public Rust source in the current Aidoku-Community sources tree or either modern/legacy GitHub path history. This adapter was derived from the actual backed module, not from a guessed generic scraper.

- Package: `output/pipeline-speed-0929/depth-after/ApplicationSupport/Sources/ko.yomii`
- `main.wasm` SHA-256: `d1fa9dbcb1167d2e54356888daafad693b292b165e9aa76d35968b158766a670`
- Recovery tool: official WebAssembly/wabt 1.0.37 macOS release, `wasm-decompile`; disassembly and static data recovered with official wabt 1.0.42 `wasm2wat`.
- Module export functions: home 91; image request 103; listing 112; details 113; pages 120; search 124; deep link 153.
- Listing provider helper: function 80; literal selector offset 1051842, `#free-genre-list > li[data-id], #comic-top100-rank > li[data-id]`.
- Search: `/bbs/ajax.search.php?search_key=`, raw array or `{list:[...]}` response, fields `wr_id`, `wr_subject`, `ca_name`, `wr_content`, `wr_6`, `wr_datetime`, `num`. Search page >1 yields an empty result. Sort helper 252 compares unsigned numeric `num` for popular or lexical `wr_datetime`, reversing when ascending is false. Genre filtering compares trimmed comma-separated exact tags.
- Listing routes map latest/popular/daily100/completed to the module's exact `bo_table=toon_c` parameters. `a.pg_next` indicates another page.
- Details: `#cover-info h2.title`, `img.banner`, `.genre .genre-link`, `.content .genre-link`, `.publisher` with `작가:` text.
- Chapters: `button.episode`, numeric `wr_id=` in onclick, `.episode-title`, `.episode-banner` CSS URL, `a.pg_page` numeric `page=`. All pages are fetched in order with a maximum of five concurrent requests. Chapter language remains Korean.
- Images: script string data markers `var img_list = [` / `var img_list_2 = [` ending `];`. The module probes primary first/middle/last image with HEAD; HTTP outside 200–399 or transport failure selects alternate when available. Images are extracted as data; scripts are never executed.
- Native image requests retain the module's fixed iPhone user agent and `https://11toon.com` Referer. Common source transport preserves cookies and challenge handling.
- Rating helper 68 returns **Safe** by default and **Suggestive** for exact `17` or `성인` tags; this unusual backed behavior is intentionally preserved.
- Backed package contains no settings or login exports. Static filters and four listing names stay package-owned; the adapter does not invent login/settings implementations.

Safety differences: native deep links require a real 11toon numeric host and numeric IDs, rejecting lookalike hosts; pagination is capped at 10,000 pages; HTTP/parse failures remain errors. Recovery fixtures test the backed selectors, routes, sorting, pagination, headers and primary/alternate probes. They do not establish current live-site availability. Future JavaScript expressions or changed selectors require an explicit parser update; there is no JavaScript/WASM fallback.
