# Native source policy comparison

Run `python3 Scripts/native-render-parity/policy-parity/run.py`. Output is stored in the fixed `build/native-render-parity/policy-parity` directory.

The source sampler harness captures every estimator call, including seeded and competing-surface retries, in the existing source-color regressions. It reads the immutable pre-migration JavaScript copy and compares complete native descriptors, not only foreground RGB. Captures clone descriptors immediately because recursive browser calls subsequently decorate their returned objects.

The donor front harness compares final RGB bytes, the remaining erase mask, ordered contaminated donor indexes, and isolated donor specks across 80 deterministic cases. It covers blocked and unreachable fronts, gradients, ink fringes, continuing shading bands, measured strokes, and a boundary case. Float32 frontier averages and Uint8ClampedArray ties-to-even behavior are checked exactly.

The gloss placement harness compares 120 deterministic axis-aligned and tilted page grids against the frozen `aidokuGlossPlacer`. It covers source fill masks, ink-box shrinking, page rules, collision vetoes, relaxed texture admission, candidate ranking, selected size/side/gap, native coordinate moves, and all rejection counters. Integer/counter decisions are exact; floating geometry allows 1e-9 absolute numerical tolerance. Text measurements are injected identically in both policies, so this test isolates placement policy from browser/Core Text glyph metrics.

The host donor executable compiles the production helper enum and donor extension. Its sole isolation stub supplies the production clamp rule used by unrelated helper methods; no donor or color algorithm is duplicated in Swift test code. The source sampler executable uses the production native Rust ABI wrapper and host archive.

Build, JavaScript capture, and native execution timings are separate. These tests establish pure policy equivalence for the executed inputs. They do not establish browser/Core Graphics crop resampling, glyph rasterization, or final page image equality.
