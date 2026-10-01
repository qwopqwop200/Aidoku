# Final plate linkage differential

`python3 Scripts/native-render-parity/final-plate-linkage/run.py` extracts the
complete frozen BrowserOverlayView final-plate linkage block14597–14903 without
changing its policy. DOM geometry/style setters, source-byte reads and
restoration membership are deterministic fixture adapters. It compares final
panel boxes/coverage, accepted moves, release count/area, all source crop requests
and the shared pixel budget against the actual production Swift policy.

Fixtures exercise source/caption/neighbor/restoration coverage, existing clips,
parent-local caption coordinates, artwork and isolated source-like marks,
transparency, relink acceptance/rollback, fractional edges and2×/8×/16× source
raster density. The frozen performance clock is held at0; native runtime uses a
monotonic60ms deadline checked between panels, as in the original policy.

`python3 Scripts/native-render-parity/final-plate-linkage/run-app-tests-host.py`
executes the actual4 app-test methods on macOS with only the Aidoku import
removed. The app-hosted suite is NativeFinalPlateLinkageTests. Actual iOS builds
and rendered-image parity are run separately by the root implementation owner.

Outputs: build/native-render-parity/final-plate-linkage/report.json,
app-tests-report.json,fixtures.json,web.json,native.json.
