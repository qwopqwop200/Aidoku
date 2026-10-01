# Source readability panel PDF causal probe

The probe inputs are the actual three remaining readability panels in the
immutable iOS BUILD42 `real-comic-0001` capture: square partial coverage and two
rounded full coverage panels. This is a bounded diagnostic fixture, not an image
oracle replacement or a production branch keyed to its fixture ID.

`main.swift` uses the production `NativeTranslationPDFCapture` helpers to paint
old raw geometry, snapped rounded clipping, and snapped rounded filling. Its
page and raster dimensions match this captured fixture. `raster.swift` reads
the generated PDFs with one common sRGB Core Graphics raster contract.

Removing only BT…ET text operations from the captured native and WebKit PDFs
isolates the background planes. The old native drawing reproduces 7,219 changed
RGBA pixels with maximum delta 132. Snapped rounded clipping still leaves 1,486
pixels with maximum delta 1. Snapped rectangle clipping followed by rounded
path filling gives **zero changed RGBA pixels** over the entire 3192 × 2254
page against the original WebKit background planes.

The exact policy is to snap the parent border, leave a partial clip-path's local
dimensions intact, relocate that path to the snapped parent origin, omit the
redundant coverage clip when coverage is exactly the whole panel, and fill the
rounded path. Clipping to that rounded path remains necessary for child planes.
The live renderer has a separate bitmap contract.

A diagnostic native full-PDF clone replacing only these three background
blocks reduces the full PDF difference to 218 pixels. A separate font-size
Float-narrowing control reduces that to 9 pixels, maximum delta 1. Those 9 pixels
remain unresolved; they are not accepted as a tolerance. No captured original
PDF, PNG, mask, or layout is modified by this analysis.

Reports and generated vectors are under
`build/native-render-parity/real1-export42/`. The main renderer's actual iOS
validation belongs to the coordinator's next compiled checkpoint.
