import UIKit
@testable import Aidoku

extension ReaderTranslationImageExporter {
    static let prepareExportScript = #"""
    await document.fonts.ready;
    const source = document.getElementById('reader-source-image');
    if (!source) throw new Error('Missing export background');
    await source.decode();
    const frame = node => {
      const r = node.getBoundingClientRect();
      return [r.x, r.y, r.width, r.height];
    };
    // Every source-pixel repair belongs to the image composite. PDF typography
    // is clipped to text/card bounds, which need not contain the original ink.
    const sourceLayers = [...document.querySelectorAll([
      'source-cleanup', 'source-panel-restoration', 'source-blur', 'source-readability-blur'
    ].map(kind => `[data-aidoku-image-ocr-overlay="${kind}"]`).join(','))];
    const masks = sourceLayers.map(node => ({
      frame: frame(node), opacity: Number(getComputedStyle(node).opacity), png: node.toDataURL('image/png')
    }));
    const surfaces = [];
    // Readability plates are vector surfaces, not repaired source pixels. Keep
    // them in the PDF and include their padding in the typography clipping union.
    const paintBounds = [...document.querySelectorAll(
      '[data-aidoku-image-ocr-overlay="source-readability-panel"]'
    )].map(frame);
    for (const node of document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')) {
      const style = getComputedStyle(node);
      const range = document.createRange();
      range.selectNodeContents(node);
      const text = range.getBoundingClientRect();
      const box = node.getBoundingClientRect();
      const left = Math.min(box.left, text.width ? text.left : box.left) - 2;
      const top = Math.min(box.top, text.height ? text.top : box.top) - 2;
      const right = Math.max(box.right, text.width ? text.right : box.right) + 2;
      const bottom = Math.max(box.bottom, text.height ? text.bottom : box.bottom) + 2;
      paintBounds.push([left, top, right - left, bottom - top]);
      const filter = style.backdropFilter || style.webkitBackdropFilter || '';
      const blur = /blur\(([0-9.]+)px\)/.exec(filter);
      const saturation = /saturate\(([0-9.]+)\)/.exec(filter);
      if (blur) surfaces.push({frame: frame(node), radius: parseFloat(style.borderTopLeftRadius) || 0,
        blur: Number(blur[1]), saturation: saturation ? Number(saturation[1]) : 1});
      node.style.setProperty('backdrop-filter', 'none', 'important');
      node.style.setProperty('-webkit-backdrop-filter', 'none', 'important');
    }
    // A clipped <img> still embeds its ENTIRE source bitmap in a PDF.
    // Persist only its clip rectangles and reuse original pixels at composite time.
    const sourceRestorations=[];
    for(const node of document.querySelectorAll('[data-aidoku-image-ocr-overlay="kept-lettering"]')){
      const rects=JSON.parse(node.dataset.sourceRestoreRects||'null');
      if(!Array.isArray(rects)||rects.length>1024||rects.some(r=>!Array.isArray(r)||r.length!==4||
        !r.every(Number.isFinite)||r[2]<=0||r[3]<=0))throw new Error('Invalid source restoration geometry');
      sourceRestorations.push(...rects);
      node.style.visibility='hidden';
    }
    if(sourceRestorations.length>1024)throw new Error('Too many source restoration rectangles');
    source.style.visibility = 'hidden';
    for (const node of sourceLayers) {
      node.style.visibility = 'hidden';
    }
    await Promise.race([
      new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))),
      new Promise(resolve => setTimeout(resolve, 150))
    ]);
    return JSON.stringify({masks, surfaces, paintBounds, sourceRestorations});
    """#

}
