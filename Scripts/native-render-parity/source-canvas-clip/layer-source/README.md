# Actual iOS direct contents controls

BUILD56 immutable observations: `build/native-render-parity/verify-canvas-layer-build56-snapshot`. Four controls are transparent/opaque backgrounds × stock explicit CALayer linear/trilinear minification. Same `.bin` PNG hash, 412×527 canonical source, frame [135,7,91,121], contentsGravity.resize and scale3 are recorded. Both filters are byte-identical on each background; no bias or LOD search occurred.

`analyze.py` independently decodes8bit sRGB PNG using standard zlib/PNG filters and verifies every chunk CRC. Original, source-realized and source cross-input buffers all match canonical hash `170fc21b...`. Every final PNG decoded and premultiplied half-up exactly matches its saved canonical RGBA (0changedpixels). This rules out encoded-file/canonical-buffer provenance errors in these controls. It does not identify a private sampler implementation.

All comparisons against original producer53 are negative. Layer transparent differs from WK A/C by6,821pixels/max48, B by6,923/max57; opaque differs from A/C by6,782/max30, B by6,888/max35. Alpha56 WK actual-mask ROI equals53A/C exactly. Layer transparent ROI equalsalpha56native exactly; opaque differs fromalpha56native by472pixels,max1, with RGB±1changes and alpha unchanged.

Direct contents differs frompublic UIView.drawCG original-source51 andrealization55 by6,909pixels/max72transparent and6,898/max42opaque. Original-source51 andallrealization55converters produce identicalpublicCGview outputs. This supports an observable directcontents-versusCGpaintedview route seam without attributing it to a changed source buffer or asserting a closed GPUkernel. CALayer filters have not yielded a WebKit equivalent.

Reports: `build/native-render-parity/source-canvas-layer56/{comparison,cross-control-source-audit}.json`. Source-only analysis; no simulator/Xcode/app/oracle changes or filter fitting. The separate public CARenderer+MTLTexture control will reuse the Tests owner's helper once stable; no second renderer implementation is proposed.
