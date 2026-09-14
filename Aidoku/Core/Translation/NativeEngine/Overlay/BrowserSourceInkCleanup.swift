// Conservative source-pixel cleanup. Integration owns source coordinates, image
// decoding, page budgets and opacity; this helper never invents background art.
enum BrowserSourceInkCleanup {
    static let script = """
    const aidokuSourceInkMask = (rgba, width, height, vertical) => {
      // Input includes an unscaled two-pixel margin on every side.
      // Orientation is reserved; this version applies identical gates to both.
      if (!Number.isInteger(width) || !Number.isInteger(height) ||
          width < 14 || height < 14 || width * height > 262144 ||
          !rgba || rgba.length !== width * height * 4) return null;
      const count = width * height;
      const coreWidth = width - 5, coreHeight = height - 5;
      let whiteCount = 0, coloredCount = 0, insideCount = 0;
      for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
          const p = (y * width + x) * 4;
          const low = Math.min(rgba[p], rgba[p + 1], rgba[p + 2]);
          const high = Math.max(rgba[p], rgba[p + 1], rgba[p + 2]);
          const white = low >= 245 && high - low <= 10;
          // Transparent pixels are unknown, never assumed white.
          if (rgba[p + 3] !== 255) return null;
          if (x < 2 || y < 2 || x >= width - 2 || y >= height - 2) {
            if (!white) return null;
          } else {
            insideCount++;
            if (white) whiteCount++;
            if (high - low > 20) coloredCount++;
          }
        }
      }
      if (whiteCount / insideCount < 0.75 ||
          coloredCount / insideCount > 0.02) return null;
      const dark = new Uint8Array(count);
      for (let y = 2; y < height - 2; y++) {
        for (let x = 2; x < width - 2; x++) {
          const i = y * width + x, p = i * 4;
          const lo = Math.min(rgba[p], rgba[p + 1], rgba[p + 2]);
          const hi = Math.max(rgba[p], rgba[p + 1], rgba[p + 2]);
          if (hi <= 180 && hi - lo <= 20) dark[i] = 1;
        }
      }
      const seen = new Uint8Array(count), mask = new Uint8Array(count);
      const queue = new Int32Array(count);
      let kept = 0;
      for (let seed = 0; seed < count; seed++) {
        if (!dark[seed] || seen[seed]) continue;
        let head = 0, tail = 1, touchesBoundary = false;
        queue[0] = seed; seen[seed] = 1;
        let minX = width, minY = height, maxX = 0, maxY = 0;
        while (head < tail) {
          const i = queue[head++], y = Math.floor(i / width), x = i % width;
          minX = Math.min(minX, x); maxX = Math.max(maxX, x);
          minY = Math.min(minY, y); maxY = Math.max(maxY, y);
          for (let dy = -1; dy <= 1; dy++) {
            for (let dx = -1; dx <= 1; dx++) {
              const nx = x + dx, ny = y + dy;
              if (nx < 2 || ny < 2 || nx >= width - 2 || ny >= height - 2) {
                touchesBoundary = true; continue;
              }
              const next = ny * width + nx;
              if (dark[next] && !seen[next]) {
                seen[next] = 1; queue[tail++] = next;
              }
            }
          }
        }
        const cw = maxX - minX + 1, ch = maxY - minY + 1;
        if (touchesBoundary || tail < 2 || tail > 0.25 * coreWidth * coreHeight ||
            cw > 0.8 * coreWidth || ch > 0.8 * coreHeight ||
            Math.max(cw, ch) > 8 * Math.min(cw, ch)) continue;
        for (let j = 0; j < tail; j++) mask[queue[j]] = 255;
        kept += tail;
      }
      return kept ? mask : null;
    };
    """
}
