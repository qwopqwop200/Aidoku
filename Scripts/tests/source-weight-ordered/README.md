# Ordered source glyph correspondence

`SourceWeightOrderedGlyph.h/.mm` implements `ordered_glyph_ink.partition/measure`.
It receives the existing reconstructed word alpha/known arrays, original OCR,
winning shared-frame reference family and measured source em. Projection cuts
retain OCR order; punctuation anchors cuts but contributes no body-weight vote.
The paired punctuation table is Unicode metadata, not an image/class rule.

Run with `.venv-source-inference/bin/python -B Scripts/tests/source-weight-ordered/parity.py`.
The isolated harness compares normal and soft profiles, vertical/horizontal text,
punctuation, missing partitions, and two existing bounded word observations.
It compiles only its dependency closure in a private temporary directory. No
model fitting, GT weight lookup, full-page image view or shared build occurs.

`source-weight-evidence/parity.py` separately checks actual source packet tensor
serialization, segmentation/RF reconstruction, directional/reference/soft
observations, glyph-information counting and source-em normalization through
`AIDMeasureSourceWeightImageEvidence`. This is host evidence, not iOS execution.
