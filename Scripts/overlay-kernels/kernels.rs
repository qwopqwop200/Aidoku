#![no_std]
// Exact integer/IEEE ports of hot per-pixel loops of the overlay renderer (see BrowserSourceTextColor.swift).
// No allocator, no std: scratch memory is laid out by the JavaScript glue. sqrt is imported from Math.sqrt so it
// is the same function the JavaScript paths use.
#[panic_handler] fn panic(_: &core::panic::PanicInfo) -> ! { core::arch::wasm32::unreachable() }
#[link(wasm_import_module = "env")]
extern "C" { #[link_name = "sqrt"] fn js_sqrt(x: f64) -> f64; }
#[inline(always)] fn sqrt(x: f64) -> f64 { unsafe { js_sqrt(x) } }
// Exact for the finite, |x| < 2^52 values used here.
#[inline(always)] fn floor(x: f64) -> f64 { let t = x as i64 as f64; if t > x { t - 1.0 } else { t } }
#[inline(always)] fn ceil(x: f64) -> f64 { let t = x as i64 as f64; if t < x { t + 1.0 } else { t } }

const DX: [i32; 8] = [1, -1, 0, 0, 1, -1, 1, -1];
const DY: [i32; 8] = [0, 0, 1, -1, 1, -1, -1, 1];

#[inline(always)] fn min3(a: i32, b: i32, c: i32) -> i32 { let m = if a < b { a } else { b }; if m < c { m } else { c } }
#[inline(always)] fn max3(a: i32, b: i32, c: i32) -> i32 { let m = if a > b { a } else { b }; if m > c { m } else { c } }
#[inline(always)] fn absd(a: i32, b: i32) -> i32 { if a > b { a - b } else { b - a } }

/// Ray phase of aidokuObservedLetteringInk. Writes events (i, r, g, b) to `out`; returns the event count.
#[no_mangle]
pub unsafe extern "C" fn lettering_rays(rgba: *const u8, dark: *mut u8, w: i32, h: i32,
                                        x0: i32, x1: i32, y0: i32, y1: i32, out: *mut i32) -> i32 {
    let n = (w * h) as usize;
    for i in 0..n {
        let o = i * 4;
        let m = min3(*rgba.add(o) as i32, *rgba.add(o + 1) as i32, *rgba.add(o + 2) as i32);
        *dark.add(i) = (m < 185) as u8;
    }
    let mut hr = [0i32; 8]; let mut hg = [0i32; 8]; let mut hb = [0i32; 8]; let mut at = [0u8; 8];
    let mut count = 0i32;
    let mut y = y0;
    while y < y1 {
        let mut x = x0;
        while x < x1 {
            let i = y * w + x; let o = (i * 4) as usize;
            let r0 = *rgba.add(o) as i32; let g0 = *rgba.add(o + 1) as i32; let b0 = *rgba.add(o + 2) as i32;
            let lo = min3(r0, g0, b0); let hi = max3(r0, g0, b0);
            if !(lo >= 190 && hi >= 230 && hi - lo <= 70) { x += 1; continue; }
            let mut misses = 0;
            let mut d = 0usize;
            while d < 8 && misses < 4 {
                at[d] = 0;
                let mut step = 1;
                while step <= 5 {
                    let xx = x + DX[d] * step; let yy = y + DY[d] * step;
                    if xx < 0 || yy < 0 || xx >= w || yy >= h { break; }
                    let k = yy * w + xx;
                    if *dark.add(k as usize) != 0 {
                        let q = (k * 4) as usize;
                        at[d] = 1; hr[d] = *rgba.add(q) as i32; hg[d] = *rgba.add(q + 1) as i32; hb[d] = *rgba.add(q + 2) as i32;
                        break;
                    }
                    step += 1;
                }
                if at[d] == 0 { misses += 1; }
                d += 1;
            }
            if misses >= 4 { x += 1; continue; }
            let mut d = 0usize;
            while d < 8 {
                if at[d] == 0 || at[d + 1] == 0 { d += 2; continue; }
                let (ar, ag, ab) = (hr[d], hg[d], hb[d]);
                if max3(absd(ar, hr[d + 1]), absd(ag, hg[d + 1]), absd(ab, hb[d + 1])) > 28 { d += 2; continue; }
                let mut near = 0; let mut best = d; let mut best_min = min3(ar, ag, ab);
                for e in 0..8usize {
                    if at[e] == 0 || max3(absd(hr[e], ar), absd(hg[e], ag), absd(hb[e], ab)) > 28 { continue; }
                    near += 1; let m = min3(hr[e], hg[e], hb[e]); if m < best_min { best = e; best_min = m; }
                }
                if near < 5 { d += 2; continue; }
                let p = out.add((count * 4) as usize);
                *p = i; *p.add(1) = hr[best]; *p.add(2) = hg[best]; *p.add(3) = hb[best];
                count += 1;
                break;
            }
            x += 1;
        }
        y += 1;
    }
    count
}

/// Ink support counts of one mode: [insideCount, outsideCount, inkInside, inkOutside] into out.
#[no_mangle]
pub unsafe extern "C" fn lettering_support(rgba: *const u8, w: i32, h: i32, l: f64, r: f64, t: f64, b: f64,
                                           ir: i32, ig: i32, ib: i32, out: *mut i32) {
    let (mut ic, mut oc, mut ii, mut io) = (0i32, 0i32, 0i32, 0i32);
    for y in 0..h { for x in 0..w {
        let xf = x as f64; let yf = y as f64;
        let local = xf >= l && xf < r && yf >= t && yf < b;
        if local { ic += 1 } else { oc += 1 }
        let o = ((y * w + x) * 4) as usize;
        if max3(absd(*rgba.add(o) as i32, ir), absd(*rgba.add(o + 1) as i32, ig), absd(*rgba.add(o + 2) as i32, ib)) <= 28 {
            if local { ii += 1 } else { io += 1 }
        }
    }}
    *out = ic; *out.add(1) = oc; *out.add(2) = ii; *out.add(3) = io;
}

// ---- aidokuObservedGlyphPalette -------------------------------------------------------------------
/// Pixels by 4-bit colour bin (counting sort, scan order within a bin). start: 4097 i32, order: n i32,
/// cursor: 4096 i32 scratch.
#[no_mangle]
pub unsafe extern "C" fn glyph_index(rgba: *const u8, n: i32, start: *mut i32, order: *mut i32, cursor: *mut i32) {
    for k in 0..4097usize { *start.add(k) = 0; }
    for i in 0..n as usize {
        let o = i * 4;
        let key = ((*rgba.add(o) >> 4) as usize) * 256 + ((*rgba.add(o + 1) >> 4) as usize) * 16 + (*rgba.add(o + 2) >> 4) as usize;
        *start.add(key + 1) += 1;
    }
    for k in 0..4096usize { *start.add(k + 1) += *start.add(k); }
    for k in 0..4096usize { *cursor.add(k) = *start.add(k); }
    for i in 0..n as usize {
        let o = i * 4;
        let key = ((*rgba.add(o) >> 4) as usize) * 256 + ((*rgba.add(o + 1) >> 4) as usize) * 16 + (*rgba.add(o + 2) >> 4) as usize;
        let c = cursor.add(key); *order.add(*c as usize) = i as i32; *c += 1;
    }
}

#[inline(always)]
unsafe fn contrast_at(rgba: *const u8, o: usize, q: usize) -> i32 {
    max3(absd(*rgba.add(o) as i32, *rgba.add(q) as i32), absd(*rgba.add(o + 1) as i32, *rgba.add(q + 1) as i32),
         absd(*rgba.add(o + 2) as i32, *rgba.add(q + 2) as i32))
}

/// One seed of aidokuObservedGlyphPalette: mask within 24, edge-free components, in-box core, bands, energy.
/// stats: [total, retained, components, energy, bandCount]. Returns the core length, or -1 when the in-box
/// mask count is below minTotal (the JavaScript loop's early skip).
#[no_mangle]
pub unsafe extern "C" fn glyph_seed(rgba: *const u8, w: i32, h: i32, cr: i32, cg: i32, cb: i32,
                                    left: f64, right: f64, top: f64, bottom: f64, min_total: f64,
                                    vertical: i32, origin: f64, span: f64,
                                    start: *const i32, order: *const i32, mask: *mut u8, seen: *mut u8,
                                    queue: *mut i32, core: *mut i32, stats: *mut i32) -> i32 {
    let n = (w * h) as usize;
    for i in 0..n { *mask.add(i) = 0; *seen.add(i) = 0; }
    let mut band_seen = [0u8; 8];
    let mut total = 0i32;
    let r1 = (if cr + 24 < 255 { cr + 24 } else { 255 }) >> 4;
    let g1 = (if cg + 24 < 255 { cg + 24 } else { 255 }) >> 4;
    let b1 = (if cb + 24 < 255 { cb + 24 } else { 255 }) >> 4;
    let mut rb = (if cr - 24 > 0 { cr - 24 } else { 0 }) >> 4;
    while rb <= r1 {
        let mut gb = (if cg - 24 > 0 { cg - 24 } else { 0 }) >> 4;
        while gb <= g1 {
            let mut bb = (if cb - 24 > 0 { cb - 24 } else { 0 }) >> 4;
            while bb <= b1 {
                let key = (rb * 256 + gb * 16 + bb) as usize;
                let mut p = *start.add(key); let end = *start.add(key + 1);
                while p < end {
                    let i = *order.add(p as usize) as usize; let o = i * 4;
                    p += 1;
                    if max3(absd(*rgba.add(o) as i32, cr), absd(*rgba.add(o + 1) as i32, cg), absd(*rgba.add(o + 2) as i32, cb)) > 24 { continue; }
                    *mask.add(i) = 1;
                    let x = (i % w as usize) as f64; let y = (i / w as usize) as f64;
                    if y >= top && y < bottom && x >= left && x < right { total += 1; }
                }
                bb += 1;
            }
            gb += 1;
        }
        rb += 1;
    }
    *stats = total;
    if (total as f64) < min_total { return -1; }
    let (mut retained, mut components, mut energy, mut band_count, mut core_len) = (0i32, 0i32, 0i32, 0i32, 0usize);
    let wu = w as usize;
    let mut s = 0usize;
    while s < n {
        if *mask.add(s) == 0 || *seen.add(s) != 0 { s += 1; continue; }
        let (mut head, mut tail) = (0usize, 1usize);
        let (mut x0, mut y0, mut x1, mut y1) = (w, h, 0i32, 0i32);
        let mut edge = false; let mut local = 0i32;
        *queue = s as i32; *seen.add(s) = 1;
        while head < tail {
            let i = *queue.add(head) as usize; head += 1;
            let x = (i % wu) as i32; let y = (i / wu) as i32;
            if x < x0 { x0 = x } if x > x1 { x1 = x } if y < y0 { y0 = y } if y > y1 { y1 = y }
            edge = edge || x == 0 || x == w - 1 || y == 0 || y == h - 1;
            let (xf, yf) = (x as f64, y as f64);
            if xf >= left && xf < right && yf >= top && yf < bottom { local += 1; }
            if x != 0 && *mask.add(i - 1) != 0 && *seen.add(i - 1) == 0 { *seen.add(i - 1) = 1; *queue.add(tail) = (i - 1) as i32; tail += 1; }
            if x + 1 < w && *mask.add(i + 1) != 0 && *seen.add(i + 1) == 0 { *seen.add(i + 1) = 1; *queue.add(tail) = (i + 1) as i32; tail += 1; }
            if y != 0 && *mask.add(i - wu) != 0 && *seen.add(i - wu) == 0 { *seen.add(i - wu) = 1; *queue.add(tail) = (i - wu) as i32; tail += 1; }
            if y + 1 < h && *mask.add(i + wu) != 0 && *seen.add(i + wu) == 0 { *seen.add(i + wu) = 1; *queue.add(tail) = (i + wu) as i32; tail += 1; }
            if edge { break; }
        }
        if edge {
            while head < tail {
                let i = *queue.add(head) as usize; head += 1;
                let x = i % wu;
                if x != 0 && *mask.add(i - 1) != 0 && *seen.add(i - 1) == 0 { *seen.add(i - 1) = 1; *queue.add(tail) = (i - 1) as i32; tail += 1; }
                if x + 1 < wu && *mask.add(i + 1) != 0 && *seen.add(i + 1) == 0 { *seen.add(i + 1) = 1; *queue.add(tail) = (i + 1) as i32; tail += 1; }
                if i >= wu && *mask.add(i - wu) != 0 && *seen.add(i - wu) == 0 { *seen.add(i - wu) = 1; *queue.add(tail) = (i - wu) as i32; tail += 1; }
                if i + wu < n && *mask.add(i + wu) != 0 && *seen.add(i + wu) == 0 { *seen.add(i + wu) = 1; *queue.add(tail) = (i + wu) as i32; tail += 1; }
            }
            s += 1; continue;
        }
        let bw = x1 - x0 + 1; let bh = y1 - y0 + 1;
        let density = tail as f64 / (bw * bh) as f64;
        let big = if bw > bh { bw } else { bh };
        if tail < 3 || (local as f64) < tail as f64 * 0.85 || (bw as f64) > w as f64 * 0.9 || (bh as f64) > h as f64 * 0.9
            || density > 0.88 || big < 4 { s += 1; continue; }
        components += 1; retained += local;
        for k in 0..tail {
            let i = *queue.add(k) as usize; let x = (i % wu) as i32; let y = (i / wu) as i32;
            let (xf, yf) = (x as f64, y as f64);
            if !(xf >= left && xf < right && yf >= top && yf < bottom) { continue; }
            *core.add(core_len) = i as i32; core_len += 1;
            let v = if vertical != 0 { yf } else { xf };
            let span1 = if span > 1.0 { span } else { 1.0 };
            let f = libm_floor((v - origin) / span1 * 8.0);
            let band = if f < 0.0 { 0 } else if f > 7.0 { 7 } else { f as usize };
            if band_seen[band] == 0 { band_seen[band] = 1; band_count += 1; }
            let o = i * 4;
            let mut e = 0i32;
            if x >= 2 { let c = contrast_at(rgba, o, o - 8); if c > e { e = c } }
            if x + 2 < w { let c = contrast_at(rgba, o, o + 8); if c > e { e = c } }
            if y >= 2 { let c = contrast_at(rgba, o, o - 8 * wu); if c > e { e = c } }
            if y + 2 < h { let c = contrast_at(rgba, o, o + 8 * wu); if c > e { e = c } }
            energy += e;
        }
        s += 1;
    }
    *stats.add(1) = retained; *stats.add(2) = components; *stats.add(3) = energy; *stats.add(4) = band_count;
    core_len as i32
}

#[inline(always)] fn libm_floor(x: f64) -> f64 { floor(x) }

/// Enclosure test of aidokuObservedGlyphPalette: sampled core pixels whose 8 rays (<= 5 steps) reach the other
/// colour on at least 5 rays. out: [kept, total].
#[no_mangle]
pub unsafe extern "C" fn glyph_enclosure(rgba: *const u8, w: i32, h: i32, core: *const i32, len: i32, stride: i32,
                                         or: i32, og: i32, ob: i32, out: *mut i32) {
    let (mut kept, mut total) = (0i32, 0i32);
    let mut k = 0i32;
    while k < len {
        let i = *core.add(k as usize); let x = i % w; let y = i / w;
        let mut hit = 0;
        for d in 0..8usize {
            let mut step = 1;
            while step <= 5 {
                let xx = x + DX[d] * step; let yy = y + DY[d] * step;
                if xx < 0 || xx >= w || yy < 0 || yy >= h { break; }
                let q = ((yy * w + xx) * 4) as usize;
                if max3(absd(*rgba.add(q) as i32, or), absd(*rgba.add(q + 1) as i32, og), absd(*rgba.add(q + 2) as i32, ob)) <= 24 { hit += 1; break; }
                step += 1;
            }
        }
        total += 1; if hit >= 5 { kept += 1; }
        k += stride;
    }
    *out = kept; *out.add(1) = total;
}

// ---- aidokuObservedStrokePalette ------------------------------------------------------------------
const SX: [i32; 8] = [1, -1, 0, 0, 1, -1, 1, -1];
const SY: [i32; 8] = [0, 0, 1, -1, 1, -1, -1, 1];

/// Fill mask (<= 20), components: boundary-connected ones mark exteriorFill; bounded ones add their height and
/// in-box pixels. out: [coreLength, heightCount].
#[no_mangle]
pub unsafe extern "C" fn stroke_glyph(rgba: *const u8, w: i32, h: i32, fr: i32, fg: i32, fb: i32,
                                      left: f64, right: f64, top: f64, bottom: f64,
                                      mask: *mut u8, seen: *mut u8, exterior: *mut u8, queue: *mut i32,
                                      core: *mut i32, heights: *mut i32, out: *mut i32) {
    let n = (w * h) as usize; let wu = w as usize;
    for i in 0..n {
        let o = i * 4;
        *mask.add(i) = (max3(absd(*rgba.add(o) as i32, fr), absd(*rgba.add(o + 1) as i32, fg), absd(*rgba.add(o + 2) as i32, fb)) <= 20) as u8;
        *seen.add(i) = 0; *exterior.add(i) = 0;
    }
    let (mut core_len, mut height_count) = (0usize, 0usize);
    for s in 0..n {
        if *mask.add(s) == 0 || *seen.add(s) != 0 { continue; }
        let (mut head, mut tail) = (0usize, 1usize);
        let (mut x0, mut x1, mut y0, mut y1) = (w, 0i32, h, 0i32);
        let mut edge = false; let mut local = 0i32;
        *seen.add(s) = 1; *queue = s as i32;
        while head < tail {
            let i = *queue.add(head) as usize; head += 1;
            let x = (i % wu) as i32; let y = (i / wu) as i32;
            if x < x0 { x0 = x } if x > x1 { x1 = x } if y < y0 { y0 = y } if y > y1 { y1 = y }
            edge = edge || x == 0 || y == 0 || x == w - 1 || y == h - 1;
            let (xf, yf) = (x as f64, y as f64);
            if xf >= left && xf < right && yf >= top && yf < bottom { local += 1; }
            if x != 0 && *mask.add(i - 1) != 0 && *seen.add(i - 1) == 0 { *seen.add(i - 1) = 1; *queue.add(tail) = (i - 1) as i32; tail += 1; }
            if x + 1 < w && *mask.add(i + 1) != 0 && *seen.add(i + 1) == 0 { *seen.add(i + 1) = 1; *queue.add(tail) = (i + 1) as i32; tail += 1; }
            if y != 0 && *mask.add(i - wu) != 0 && *seen.add(i - wu) == 0 { *seen.add(i - wu) = 1; *queue.add(tail) = (i - wu) as i32; tail += 1; }
            if y + 1 < h && *mask.add(i + wu) != 0 && *seen.add(i + wu) == 0 { *seen.add(i + wu) = 1; *queue.add(tail) = (i + wu) as i32; tail += 1; }
            if edge { break; }
        }
        if edge {
            while head < tail {
                let i = *queue.add(head) as usize; head += 1;
                let x = i % wu;
                if x != 0 && *mask.add(i - 1) != 0 && *seen.add(i - 1) == 0 { *seen.add(i - 1) = 1; *queue.add(tail) = (i - 1) as i32; tail += 1; }
                if x + 1 < wu && *mask.add(i + 1) != 0 && *seen.add(i + 1) == 0 { *seen.add(i + 1) = 1; *queue.add(tail) = (i + 1) as i32; tail += 1; }
                if i >= wu && *mask.add(i - wu) != 0 && *seen.add(i - wu) == 0 { *seen.add(i - wu) = 1; *queue.add(tail) = (i - wu) as i32; tail += 1; }
                if i + wu < n && *mask.add(i + wu) != 0 && *seen.add(i + wu) == 0 { *seen.add(i + wu) = 1; *queue.add(tail) = (i + wu) as i32; tail += 1; }
            }
            for k in 0..tail { *exterior.add(*queue.add(k) as usize) = 1; }
            continue;
        }
        let bw = x1 - x0; let bh = y1 - y0;
        if tail < 3 || (local as f64) < tail as f64 * 0.85 || tail as f64 / ((bw + 1) * (bh + 1)) as f64 > 0.9
            || (if bw > bh { bw } else { bh }) < 3 { continue; }
        *heights.add(height_count) = if bw + 1 > bh + 1 { bw + 1 } else { bh + 1 }; height_count += 1;
        for k in 0..tail {
            let q = *queue.add(k) as usize; let (xf, yf) = ((q % wu) as f64, (q / wu) as f64);
            if xf >= left && xf < right && yf >= top && yf < bottom { *core.add(core_len) = q as i32; core_len += 1; }
        }
    }
    *out = core_len as i32; *out.add(1) = height_count as i32;
}

/// First step leaving the fill (> 24) along each of the 8 rays of every sampled core pixel.
#[no_mangle]
pub unsafe extern "C" fn stroke_first(rgba: *const u8, w: i32, h: i32, core: *const i32, len: i32, stride: i32, reach: i32,
                                      fr: i32, fg: i32, fb: i32, sx: *mut i32, sy: *mut i32, first: *mut i32) -> i32 {
    let (mut k, mut p) = (0i32, 0usize);
    while k < len {
        let i = *core.add(k as usize); let x = i % w; let y = i / w;
        *sx.add(p) = x; *sy.add(p) = y;
        for di in 0..8usize {
            *first.add(p * 8 + di) = 0;
            let mut step = 1;
            while step <= reach {
                let xx = x + SX[di] * step; let yy = y + SY[di] * step;
                if xx < 0 || xx >= w || yy < 0 || yy >= h { break; }
                let o = ((yy * w + xx) * 4) as usize;
                if max3(absd(*rgba.add(o) as i32, fr), absd(*rgba.add(o + 1) as i32, fg), absd(*rgba.add(o + 2) as i32, fb)) <= 24 { step += 1; continue; }
                *first.add(p * 8 + di) = step; break;
            }
        }
        k += stride; p += 1;
    }
    p as i32
}

#[inline(always)] fn fabs(x: f64) -> f64 { if x < 0.0 { -x } else { x } }
#[inline(always)] fn fmax3(a: f64, b: f64, c: f64) -> f64 { let m = if a > b { a } else { b }; if m > c { m } else { c } }

/// One stroke seed of aidokuObservedStrokePalette. stats: [rays, hits, exits, points, enclosed, backgroundExits,
/// bandCount, exitsByDirection x8]. Returns 1 when the seed was rejected early, else 0.
#[no_mangle]
pub unsafe extern "C" fn stroke_seed(rgba: *const u8, w: i32, h: i32, samples: i32, sx: *const i32, sy: *const i32,
                                     first: *const i32, reach: i32, fr: i32, fg: i32, fb: i32, sr: i32, sg: i32, sb: i32,
                                     rejoins: i32, exterior: *const u8, bands: *mut i32, stats: *mut i32) -> i32 {
    let (vr, vg, vb) = (sr - fr, sg - fg, sb - fb);
    let axis = (vr * vr + vg * vg + vb * vb) as f64;
    let (vrf, vgf, vbf) = (vr as f64, vg as f64, vb as f64);
    let (mut rays, mut hits, mut exits, mut points, mut enclosed, mut background_exits) = (0i32, 0i32, 0i32, 0i32, 0i32, 0i32);
    let mut band_count = 0usize; let mut by_dir = [0i32; 8];
    let near8 = |q: i32, r: i32, g: i32, b: i32| -> bool {
        let o = (q * 4) as usize;
        max3(absd(r, *rgba.add(o) as i32), absd(g, *rgba.add(o + 1) as i32), absd(b, *rgba.add(o + 2) as i32)) <= 8
    };
    let mut rejected = 0;
    for p in 0..samples as usize {
        let x = *sx.add(p); let y = *sy.add(p);
        let (mut local_rays, mut local_hits, mut local_exits) = (0i32, 0i32, 0i32);
        for di in 0..8usize {
            let f = *first.add(p * 8 + di); if f == 0 { continue; }
            let dx = SX[di]; let dy = SY[di];
            let (mut hit, mut exit, mut blocked) = (0i32, 0i32, false);
            let mut step = f;
            while step <= reach {
                let xx = x + dx * step; let yy = y + dy * step;
                if xx < 0 || xx >= w || yy < 0 || yy >= h { break; }
                let o = ((yy * w + xx) * 4) as usize;
                let (r, g, b) = (*rgba.add(o) as i32, *rgba.add(o + 1) as i32, *rgba.add(o + 2) as i32);
                let df = max3(absd(r, fr), absd(g, fg), absd(b, fb));
                let ds = max3(absd(r, sr), absd(g, sg), absd(b, sb));
                if hit == 0 {
                    if df <= 24 { step += 1; continue; }
                    if ds <= 28 && df >= 48 { hit = step; step += 1; continue; }
                    let (dr, dg, db) = (r - fr, g - fg, b - fb);
                    let t = (dr * vr + dg * vg + db * vb) as f64 / axis;
                    if t > 0.0 && t < 1.0 && fmax3(fabs(dr as f64 - t * vrf), fabs(dg as f64 - t * vgf), fabs(db as f64 - t * vbf)) <= 24.0 {
                        step += 1; continue;
                    }
                    blocked = true; break;
                } else if ds > 24 {
                    if df <= 40 {
                        if *exterior.add((yy * w + xx) as usize) != 0 && rejoins != 0 {
                            exit = step; *bands.add(band_count) = step - hit; band_count += 1; background_exits += 1;
                        }
                        break;
                    }
                    let (xx2, yy2, xx3, yy3) = (xx + dx, yy + dy, xx + 2 * dx, yy + 2 * dy);
                    let (dr, dg, db) = (r - fr, g - fg, b - fb);
                    let t = (dr * vr + dg * vg + db * vb) as f64 / axis;
                    let off = fmax3(fabs(dr as f64 - t * vrf), fabs(dg as f64 - t * vgf), fabs(db as f64 - t * vbf));
                    if t > 1.05 && off <= 24.0 { break; }
                    if t < -0.12 || off > 24.0 { exit = step; *bands.add(band_count) = step - hit; band_count += 1; break; }
                    if xx3 >= 0 && xx3 < w && yy3 >= 0 && yy3 < h && xx2 >= 0 && xx2 < w && yy2 >= 0 && yy2 < h &&
                        near8(yy2 * w + xx2, r, g, b) && near8(yy3 * w + xx3, r, g, b) {
                        exit = step; *bands.add(band_count) = step - hit; band_count += 1; break;
                    }
                }
                step += 1;
            }
            if hit != 0 || blocked {
                local_rays += 1; if hit != 0 { local_hits += 1; }
                if exit != 0 { local_exits += 1; by_dir[di] += 1; }
            }
        }
        rays += local_rays; hits += local_hits; exits += local_exits; points += 1;
        if local_hits >= 5 && local_exits >= 2 { enclosed += 1; }
        let remaining = samples - points;
        let a = (hits + 8 * remaining) as f64 / (if rays + 8 * remaining > 1 { rays + 8 * remaining } else { 1 }) as f64;
        let b = (enclosed + remaining) as f64 / (if samples > 1 { samples } else { 1 }) as f64;
        if a < 0.8 || b < 0.3 { rejected = 1; break; }
    }
    *stats = rays; *stats.add(1) = hits; *stats.add(2) = exits; *stats.add(3) = points; *stats.add(4) = enclosed;
    *stats.add(5) = background_exits; *stats.add(6) = band_count as i32;
    for d in 0..8 { *stats.add(7 + d) = by_dir[d]; }
    rejected
}

// ---- shared: 4-bit colour bins of the in-box pixels in first-seen order -------------------------------
/// counts: 4096 i32, sums: 4096*3 i32 (exact integer sums), order: first-seen keys. Returns the bin count, or -1
/// when check_alpha is set and any crop pixel has alpha < 250 (scan order does not matter for that result).
#[no_mangle]
pub unsafe extern "C" fn bins_inside(rgba: *const u8, w: i32, h: i32, left: f64, right: f64, top: f64, bottom: f64,
                                     check_alpha: i32, counts: *mut i32, sums: *mut i32, order: *mut i32) -> i32 {
    let n = (w * h) as usize;
    if check_alpha != 0 { for i in 0..n { if *rgba.add(i * 4 + 3) < 250 { return -1; } } }
    for k in 0..4096usize { *counts.add(k) = 0; *sums.add(k * 3) = 0; *sums.add(k * 3 + 1) = 0; *sums.add(k * 3 + 2) = 0; }
    let mut bins = 0usize;
    for y in 0..h { let yf = y as f64; if !(yf >= top && yf < bottom) { continue; }
        for x in 0..w { let xf = x as f64; if !(xf >= left && xf < right) { continue; }
            let o = ((y * w + x) * 4) as usize;
            let (r, g, b) = (*rgba.add(o) as i32, *rgba.add(o + 1) as i32, *rgba.add(o + 2) as i32);
            let key = ((r >> 4) * 256 + (g >> 4) * 16 + (b >> 4)) as usize;
            let c = counts.add(key);
            if *c == 0 { *order.add(bins) = key as i32; bins += 1; }
            *c += 1;
            *sums.add(key * 3) += r; *sums.add(key * 3 + 1) += g; *sums.add(key * 3 + 2) += b;
        }
    }
    bins as i32
}

// ---- aidokuRecoverOutlinedColor --------------------------------------------------------------------
#[no_mangle]
pub unsafe extern "C" fn transpose_rgba(src: *const u8, dst: *mut u8, w: i32, h: i32) {
    for y in 0..h { for x in 0..w { for c in 0..4 {
        *dst.add(((x * h + y) * 4 + c) as usize) = *src.add(((y * w + x) * 4 + c) as usize);
    }}}
}

/// Components of non-white (min channel < 230) pixels that pass the size/shape checks, in scan order. Per component
/// 9 i32 go to out: [tail, topCount, topSumR, topSumG, topSumB, edgeCount, edgeSumR, edgeSumG, edgeSumB]
/// (topCount 0 when the component has no qualifying bin). Returns the component count.
#[no_mangle]
pub unsafe extern "C" fn outlined_components(rgba: *const u8, w: i32, h: i32, allow_dark: i32, white: *mut u8, seen: *mut u8,
                                             queue: *mut i32, counts: *mut i32, sums: *mut i32, keys: *mut i32, out: *mut i32) -> i32 {
    let n = (w * h) as usize; let wu = w as usize; let limit = n as f64 * 0.12;
    for i in 0..n {
        let p = i * 4;
        *white.add(i) = (min3(*rgba.add(p) as i32, *rgba.add(p + 1) as i32, *rgba.add(p + 2) as i32) >= 230) as u8;
        *seen.add(i) = 0;
    }
    for k in 0..4096usize { *counts.add(k) = 0; }
    let mut groups = 0usize;
    for s in 0..n {
        if *seen.add(s) != 0 || *white.add(s) != 0 { continue; }
        let (mut head, mut tail) = (0usize, 1usize); let mut edge = false;
        let (mut x0, mut y0, mut x1, mut y1) = (w, h, 0i32, 0i32);
        *seen.add(s) = 1; *queue = s as i32;
        while head < tail {
            let i = *queue.add(head) as usize; head += 1;
            let x = (i % wu) as i32; let y = (i / wu) as i32;
            if x < x0 { x0 = x } if y < y0 { y0 = y } if x > x1 { x1 = x } if y > y1 { y1 = y }
            edge = edge || x == 0 || y == 0 || x == w - 1 || y == h - 1;
            if x != 0 && *seen.add(i - 1) == 0 && *white.add(i - 1) == 0 { *seen.add(i - 1) = 1; *queue.add(tail) = (i - 1) as i32; tail += 1; }
            if x + 1 < w && *seen.add(i + 1) == 0 && *white.add(i + 1) == 0 { *seen.add(i + 1) = 1; *queue.add(tail) = (i + 1) as i32; tail += 1; }
            if y != 0 && *seen.add(i - wu) == 0 && *white.add(i - wu) == 0 { *seen.add(i - wu) = 1; *queue.add(tail) = (i - wu) as i32; tail += 1; }
            if y + 1 < h && *seen.add(i + wu) == 0 && *white.add(i + wu) == 0 { *seen.add(i + wu) = 1; *queue.add(tail) = (i + wu) as i32; tail += 1; }
            if edge || tail as f64 > limit { break; }
        }
        if edge || tail as f64 > limit {
            while head < tail {
                let i = *queue.add(head) as usize; head += 1;
                let x = i % wu;
                if x != 0 && *seen.add(i - 1) == 0 && *white.add(i - 1) == 0 { *seen.add(i - 1) = 1; *queue.add(tail) = (i - 1) as i32; tail += 1; }
                if x + 1 < wu && *seen.add(i + 1) == 0 && *white.add(i + 1) == 0 { *seen.add(i + 1) = 1; *queue.add(tail) = (i + 1) as i32; tail += 1; }
                if i >= wu && *seen.add(i - wu) == 0 && *white.add(i - wu) == 0 { *seen.add(i - wu) = 1; *queue.add(tail) = (i - wu) as i32; tail += 1; }
                if i + wu < n && *seen.add(i + wu) == 0 && *white.add(i + wu) == 0 { *seen.add(i + wu) = 1; *queue.add(tail) = (i + wu) as i32; tail += 1; }
            }
            continue;
        }
        if tail < 3 || (x1 - x0) as f64 > w as f64 * 0.75 || (y1 - y0) as f64 > h as f64 * 0.4 ||
            (tail > 12 && tail as f64 / ((x1 - x0 + 1) * (y1 - y0 + 1)) as f64 > 0.9) { continue; }
        let (mut edge_count, mut er, mut eg, mut eb) = (0i32, 0i32, 0i32, 0i32);
        let mut nkeys = 0usize;
        for k in 0..tail {
            let i = *queue.add(k) as usize; let p = i * 4;
            let (r, g, b) = (*rgba.add(p) as i32, *rgba.add(p + 1) as i32, *rgba.add(p + 2) as i32);
            let x = i % wu; let y = i / wu;
            let mut at = |j: usize| { if *white.add(j) != 0 { edge_count += 1; er += *rgba.add(4 * j) as i32; eg += *rgba.add(4 * j + 1) as i32; eb += *rgba.add(4 * j + 2) as i32; } };
            if x != 0 { at(i - 1) } if x + 1 < wu { at(i + 1) } if y != 0 { at(i - wu) } if (y as i32) + 1 < h { at(i + wu) }
            let hi = max3(r, g, b);
            if hi - min3(r, g, b) < 40 && !(allow_dark != 0 && hi < 80) { continue; }
            let key = ((r >> 4) * 256 + (g >> 4) * 16 + (b >> 4)) as usize;
            if *counts.add(key) == 0 { *keys.add(nkeys) = key as i32; nkeys += 1; *sums.add(key * 3) = 0; *sums.add(key * 3 + 1) = 0; *sums.add(key * 3 + 2) = 0; }
            *counts.add(key) += 1; *sums.add(key * 3) += r; *sums.add(key * 3 + 1) += g; *sums.add(key * 3 + 2) += b;
        }
        let mut best = usize::MAX; let mut best_count = 0i32;
        for k in 0..nkeys { let key = *keys.add(k) as usize; let c = *counts.add(key); if best == usize::MAX || c > best_count { best = key; best_count = c; } }
        let o = out.add(groups * 9);
        *o = tail as i32;
        if best != usize::MAX { *o.add(1) = best_count; *o.add(2) = *sums.add(best * 3); *o.add(3) = *sums.add(best * 3 + 1); *o.add(4) = *sums.add(best * 3 + 2); }
        else { *o.add(1) = 0; *o.add(2) = 0; *o.add(3) = 0; *o.add(4) = 0; }
        *o.add(5) = edge_count; *o.add(6) = er; *o.add(7) = eg; *o.add(8) = eb;
        for k in 0..nkeys { *counts.add(*keys.add(k) as usize) = 0; }
        groups += 1;
    }
    groups as i32
}

// ---- aidokuObservedCaptionBackground (collect) --------------------------------------------------------
/// Ink-near components with halo dilation (mask) or dot halo; dots marked. stats: [dotCount, dotInside, dotOutside,
/// nearCount]. Returns -1 when any pixel has alpha < 250.
#[no_mangle]
pub unsafe extern "C" fn caption_mask(rgba: *const u8, w: i32, h: i32, ir: i32, ig: i32, ib: i32, tolerance: i32, radius: i32,
                                      il: f64, it: f64, iright: f64, ibottom: f64, dark_ink: i32, interior_min: f64,
                                      near: *mut u8, mask: *mut u8, dots: *mut u8, halo: *mut u8, seen: *mut u8, queue: *mut i32,
                                      stats: *mut i32) -> i32 {
    let n = (w * h) as usize; let wu = w as usize;
    let mut near_count = 0i32;
    for i in 0..n {
        let p = i * 4;
        if *rgba.add(p + 3) < 250 { return -1; }
        let d = max3(absd(*rgba.add(p) as i32, ir), absd(*rgba.add(p + 1) as i32, ig), absd(*rgba.add(p + 2) as i32, ib));
        *near.add(i) = (d <= tolerance) as u8; if d <= tolerance { near_count += 1; }
        *mask.add(i) = 0; *dots.add(i) = 0; *halo.add(i) = 0; *seen.add(i) = 0;
    }
    let (mut dot_count, mut dot_inside, mut dot_outside) = (0i32, 0i32, 0i32);
    for seed in 0..n {
        if *near.add(seed) == 0 || *seen.add(seed) != 0 { continue; }
        let (mut read, mut count) = (0usize, 1usize);
        let (mut edges, mut interior) = (0i32, 0i32);
        let (mut x0, mut y0, mut x1, mut y1) = (w, h, 0i32, 0i32);
        *queue = seed as i32; *seen.add(seed) = 1;
        while read < count {
            let i = *queue.add(read) as usize; read += 1;
            let x = (i % wu) as i32; let y = (i / wu) as i32;
            if x < x0 { x0 = x } if x > x1 { x1 = x } if y < y0 { y0 = y } if y > y1 { y1 = y }
            if x == 0 { edges |= 1 } if x == w - 1 { edges |= 2 } if y == 0 { edges |= 4 } if y == h - 1 { edges |= 8 }
            let (xf, yf) = (x as f64, y as f64);
            if xf >= il && xf < iright && yf >= it && yf < ibottom { interior += 1; }
            if x > 0 && *near.add(i - 1) != 0 && *seen.add(i - 1) == 0 { *seen.add(i - 1) = 1; *queue.add(count) = (i - 1) as i32; count += 1; }
            if x < w - 1 && *near.add(i + 1) != 0 && *seen.add(i + 1) == 0 { *seen.add(i + 1) = 1; *queue.add(count) = (i + 1) as i32; count += 1; }
            if y > 0 && *near.add(i - wu) != 0 && *seen.add(i - wu) == 0 { *seen.add(i - wu) = 1; *queue.add(count) = (i - wu) as i32; count += 1; }
            if y < h - 1 && *near.add(i + wu) != 0 && *seen.add(i + wu) == 0 { *seen.add(i + wu) = 1; *queue.add(count) = (i + wu) as i32; count += 1; }
        }
        let surface = dark_ink != 0 && interior as f64 >= interior_min && (edges & (edges - 1)) != 0;
        let dot = count <= 4 && x1 - x0 <= 2 && y1 - y0 <= 2;
        if dot { dot_count += 1; dot_inside += interior; dot_outside += count as i32 - interior; }
        let target = if dot { halo } else { mask };
        for j in 0..count {
            let q = *queue.add(j) as usize;
            if dot { *dots.add(q) = 1; }
            let x = (q % wu) as i32; let y = (q / wu) as i32; let p = q * 4;
            if surface && max3(absd(*rgba.add(p) as i32, ir), absd(*rgba.add(p + 1) as i32, ig), absd(*rgba.add(p + 2) as i32, ib)) > 12 { continue; }
            let reach = if surface { if radius < 1 { radius } else { 1 } } else { radius };
            let ya = if y - reach > 0 { y - reach } else { 0 }; let yb = if y + reach < h - 1 { y + reach } else { h - 1 };
            let xa = if x - reach > 0 { x - reach } else { 0 }; let xb = if x + reach < w - 1 { x + reach } else { w - 1 };
            let mut yy = ya;
            while yy <= yb { let mut xx = xa; while xx <= xb { *target.add((yy * w + xx) as usize) = 1; xx += 1; } yy += 1; }
        }
    }
    *stats = dot_count; *stats.add(1) = dot_inside; *stats.add(2) = dot_outside; *stats.add(3) = near_count;
    0
}

/// periodic(axis) of collect: repeated dot lags along one axis.
#[no_mangle]
pub unsafe extern "C" fn caption_periodic(dots: *const u8, w: i32, h: i32, axis: i32) -> i32 {
    let (mut best, mut worst) = (0.0f64, 1.0f64);
    for lag in 2..=8i32 {
        let (mut hits, mut total) = (0i32, 0i32);
        let ylim = h - if axis != 0 { lag } else { 0 }; let xlim = w - if axis != 0 { 0 } else { lag };
        let step = lag * if axis != 0 { w } else { 1 };
        for y in 0..ylim { for x in 0..xlim {
            let i = y * w + x; if *dots.add(i as usize) == 0 { continue; }
            total += 1; if *dots.add((i + step) as usize) != 0 { hits += 1; }
        }}
        let score = hits as f64 / (if total > 1 { total } else { 1 }) as f64;
        if score > best { best = score; } if score < worst { worst = score; }
    }
    (best >= 0.35 && best - worst >= 0.2) as i32
}

/// Exposed in-box pixels (not masked, and not dot halo unless textured) as channel columns and bands.
/// stats: [count, total, bandMask].
#[no_mangle]
pub unsafe extern "C" fn caption_exposed(rgba: *const u8, w: i32, mask: *const u8, halo: *const u8, textured: i32,
                                         x0: i32, x1: i32, y0: i32, y1: i32, vertical: i32, start: f64, length: f64,
                                         r: *mut u8, g: *mut u8, b: *mut u8, band: *mut u8, stats: *mut i32) {
    let (mut total, mut count, mut bands) = (0i32, 0usize, 0i32);
    for y in y0..y1 { for x in x0..x1 {
        total += 1; let i = (y * w + x) as usize; let p = i * 4;
        if *mask.add(i) != 0 || (textured == 0 && *halo.add(i) != 0) { continue; }
        let v = if vertical != 0 { y } else { x } as f64;
        let f = libm_floor((v - start) * 8.0 / length);
        let bd = if f > 7.0 { 7.0 } else { f };
        *r.add(count) = *rgba.add(p); *g.add(count) = *rgba.add(p + 1); *b.add(count) = *rgba.add(p + 2);
        *band.add(count) = (bd as i64) as u8; count += 1; bands |= 1 << ((bd as i64) & 31);
    }}
    *stats = count as i32; *stats.add(1) = total; *stats.add(2) = bands;
}

// ---- aidokuObservedCaptionBackground (statistics over exposed pixels) ---------------------------------
/// Stable counting sort of channel columns by r+g+b. offsets: 767 i32 scratch.
#[no_mangle]
pub unsafe extern "C" fn columns_sort(r: *const u8, g: *const u8, b: *const u8, band: *const u8, count: i32,
                                      ro: *mut u8, go: *mut u8, bo: *mut u8, bando: *mut u8, offsets: *mut i32) {
    for v in 0..767usize { *offsets.add(v) = 0; }
    let c = count as usize;
    for k in 0..c { let s = *r.add(k) as usize + *g.add(k) as usize + *b.add(k) as usize; *offsets.add(s + 1) += 1; }
    for v in 1..767usize { *offsets.add(v) += *offsets.add(v - 1); }
    for k in 0..c {
        let s = *r.add(k) as usize + *g.add(k) as usize + *b.add(k) as usize;
        let j = *offsets.add(s) as usize; *offsets.add(s) += 1;
        *ro.add(j) = *r.add(k); *go.add(j) = *g.add(k); *bo.add(j) = *b.add(k); *bando.add(j) = *band.add(k);
    }
}

/// 4-bit bins of channel columns in first-seen order (exact integer sums). Returns the bin count.
#[no_mangle]
pub unsafe extern "C" fn columns_bins(r: *const u8, g: *const u8, b: *const u8, count: i32, counts: *mut i32, sums: *mut i32,
                                      order: *mut i32) -> i32 {
    for k in 0..4096usize { *counts.add(k) = 0; *sums.add(k * 3) = 0; *sums.add(k * 3 + 1) = 0; *sums.add(k * 3 + 2) = 0; }
    let mut bins = 0usize;
    for k in 0..count as usize {
        let (rv, gv, bv) = (*r.add(k) as i32, *g.add(k) as i32, *b.add(k) as i32);
        let key = ((rv >> 4) * 256 + (gv >> 4) * 16 + (bv >> 4)) as usize;
        if *counts.add(key) == 0 { *order.add(bins) = key as i32; bins += 1; }
        *counts.add(key) += 1; *sums.add(key * 3) += rv; *sums.add(key * 3 + 1) += gv; *sums.add(key * 3 + 2) += bv;
    }
    bins as i32
}

/// Pixels within 28 (max channel) of a fractional mode, with their sums. out: [near, s0, s1, s2].
#[no_mangle]
pub unsafe extern "C" fn columns_support(r: *const u8, g: *const u8, b: *const u8, count: i32, m0: f64, m1: f64, m2: f64, out: *mut i32) {
    let (mut near, mut s0, mut s1, mut s2) = (0i32, 0i32, 0i32, 0i32);
    for k in 0..count as usize {
        let (rv, gv, bv) = (*r.add(k) as i32, *g.add(k) as i32, *b.add(k) as i32);
        if fmax3(fabs(rv as f64 - m0), fabs(gv as f64 - m1), fabs(bv as f64 - m2)) > 28.0 { continue; }
        near += 1; s0 += rv; s1 += gv; s2 += bv;
    }
    *out = near; *out.add(1) = s0; *out.add(2) = s1; *out.add(3) = s2;
}

/// Largest channel p90-p10 spread (histogram ranks floor((count-1)*.9) and floor((count-1)*.1)).
#[no_mangle]
pub unsafe extern "C" fn columns_range(r: *const u8, g: *const u8, b: *const u8, count: i32, hist: *mut i32) -> i32 {
    let hi_rank = libm_floor((count - 1) as f64 * 0.9) as i32; let lo_rank = libm_floor((count - 1) as f64 * 0.1) as i32;
    let mut best = i32::MIN;
    for channel in [r, g, b] {
        for v in 0..256usize { *hist.add(v) = 0; }
        for k in 0..count as usize { *hist.add(*channel.add(k) as usize) += 1; }
        let at = |rank: i32| -> i32 { let mut seen = 0; for v in 0..256usize { seen += *hist.add(v); if seen > rank { return v as i32; } } 255 };
        let spread = at(hi_rank) - at(lo_rank);
        if spread > best { best = spread; }
    }
    best
}

/// Pixels uniformly brighter than a fractional mode (low >= 32, spread <= 20). out: [brighter, bandMask].
#[no_mangle]
pub unsafe extern "C" fn columns_brighter(r: *const u8, g: *const u8, b: *const u8, band: *const u8, count: i32,
                                          m0: f64, m1: f64, m2: f64, out: *mut i32) {
    let (mut brighter, mut bands) = (0i32, 0i32);
    for k in 0..count as usize {
        let d0 = *r.add(k) as f64 - m0; let d1 = *g.add(k) as f64 - m1; let d2 = *b.add(k) as f64 - m2;
        let low = if d0 < d1 { d0 } else { d1 }; let low = if low < d2 { low } else { d2 };
        let high = fmax3(d0, d1, d2);
        if low >= 32.0 && high - low <= 20.0 { brighter += 1; bands |= 1 << (*band.add(k) & 31); }
    }
    *out = brighter; *out.add(1) = bands;
}

/// Channel sums over [from, to). out: [s0, s1, s2].
#[no_mangle]
pub unsafe extern "C" fn columns_sum(r: *const u8, g: *const u8, b: *const u8, from: i32, to: i32, out: *mut i32) {
    let (mut s0, mut s1, mut s2) = (0i32, 0i32, 0i32);
    let mut k = from; while k < to { s0 += *r.add(k as usize) as i32; s1 += *g.add(k as usize) as i32; s2 += *b.add(k as usize) as i32; k += 1; }
    *out = s0; *out.add(1) = s1; *out.add(2) = s2;
}

// ---- aidokuHarmonicFill ----------------------------------------------------------------------------
/// Relaxation of queue[0..tail) toward linked four-neighbours, in Float32 like the JavaScript work array
/// (Float64 arithmetic, Float32 stores). work: n*3 f32 (filled here from p), links: tail u8. p may be the last third
/// of work: the ascending conversion reads every pixel before its bytes are overwritten.
#[no_mangle]
pub unsafe extern "C" fn harmonic_fill(p: *const u8, w: i32, n: i32, queue: *const i32, tail: i32, blocked: *const u8,
                                       paint: *const u8, accelerated: i32, work: *mut f32, links: *mut u8) {
    let nu = n as usize; let t = tail as usize; let wu = w as usize;
    for i in 0..nu { for c in 0..3 { *work.add(i * 3 + c) = *p.add(i * 4 + c) as f32; } }
    let link = |j: usize| -> bool { *blocked.add(j) == 0 || *paint.add(j) != 0 };
    for k in 0..t {
        let i = *queue.add(k) as usize;
        *links.add(k) = (if link(i - 1) { 1 } else { 0 }) | (if link(i + 1) { 2 } else { 0 }) |
            (if link(i - wu) { 4 } else { 0 }) | (if link(i + wu) { 8 } else { 0 });
    }
    let passes = if accelerated != 0 { 32 } else { 48 };
    for pass in 0..passes {
        let check = accelerated != 0 && (pass & 3) == 3; let mut maximum = 0.0f64;
        for k in 0..t {
            let i = *queue.add(k) as usize; let bits = *links.add(k); if bits == 0 { continue; }
            let (left, right, up, down) = ((i - 1) * 3, (i + 1) * 3, (i - wu) * 3, (i + wu) * 3);
            let count = ((bits & 1) + ((bits >> 1) & 1) + ((bits >> 2) & 1) + ((bits >> 3) & 1)) as f64;
            for c in 0..3 {
                let at = i * 3 + c;
                let a = if bits & 1 != 0 { *work.add(left + c) as f64 } else { 0.0 };
                let b = if bits & 2 != 0 { *work.add(right + c) as f64 } else { 0.0 };
                let u = if bits & 4 != 0 { *work.add(up + c) as f64 } else { 0.0 };
                let d = if bits & 8 != 0 { *work.add(down + c) as f64 } else { 0.0 };
                let average = (((a + b) + u) + d) / count;
                if accelerated != 0 {
                    let change = (average - *work.add(at) as f64) * 1.6;
                    *work.add(at) = (*work.add(at) as f64 + change) as f32;
                    if check { let m = fabs(change); if m > maximum { maximum = m; } }
                } else { *work.add(at) = average as f32; }
            }
        }
        if check && maximum < 0.05 { break; }
    }
}

// ---- aidokuSourceExemplarFill ----------------------------------------------------------------------
#[inline(always)]
fn clamp_u8(x: f64) -> u8 {
    // ECMAScript ToUint8Clamp: NaN -> 0, clamp, round half to even.
    if !(x > 0.0) { return 0; }
    if x >= 255.0 { return 255; }
    let f = libm_floor(x); let d = x - f;
    let r = if d < 0.5 { f } else if d > 0.5 { f + 1.0 } else if (f as i64) % 2 == 0 { f } else { f + 1.0 };
    r as u8
}

/// Whole exemplar patch fill. coeff: 9 f64 (3 channels x [a0, a1, a2]); fg: 3 f64. stats (f64): [patches, maxError,
/// comparisons, operations, donors, donorSquares, donorCount]. Returns 1 on success (output written), 0 for null.
#[no_mangle]
pub unsafe extern "C" fn exemplar_fill(rgba: *const u8, w: i32, h: i32, mask: *const u8, forbidden: *const u8,
                                       fg: *const f64, coeff: *const f64, erased: i32,
                                       work: *mut u8, pending: *mut u8, residual: *mut f32, filled: *mut f32, integral: *mut i32,
                                       output: *mut u8, donors: *mut i32, cell: *mut f64, grid_x: *mut i32, grid_y: *mut i32,
                                       stats: *mut f64) -> i32 {
    let r = 4i32; let n = (w * h) as usize; let wu = w as usize;
    let (wf, hf) = (w as f64, h as f64);
    let mut left = erased;
    let coef = |c: usize, k: usize| *coeff.add(c * 3 + k);
    // work may alias rgba (rgba is only read before the patch loop writes work).
    for i in 0..n * 4 { *output.add(i) = 0; *work.add(i) = *rgba.add(i); }
    for i in 0..n {
        *pending.add(i) = *mask.add(i);
        let (x, y) = ((i % wu) as f64, (i / wu) as f64);
        for c in 0..3 {
            let v = *rgba.add(i * 4 + c) as f64 - (coef(c, 0) + coef(c, 1) * x / wf + coef(c, 2) * y / hf);
            *residual.add(i * 3 + c) = v as f32; *filled.add(i * 3 + c) = v as f32;
        }
    }
    let w1 = wu + 1;
    for k in 0..w1 { *integral.add(k) = 0; }
    for y in 0..h as usize {
        let mut row = 0i32; *integral.add((y + 1) * w1) = 0;
        for x in 0..wu { let i = y * wu + x; row += (*mask.add(i) != 0 || *forbidden.add(i) != 0) as i32;
            *integral.add((y + 1) * w1 + x + 1) = *integral.add(y * w1 + x + 1) + row; }
    }
    let boxsum = |x: i32, y: i32| -> i32 {
        let (x, y, w1) = (x as isize, y as isize, w1 as isize); let r = r as isize;
        *integral.offset((y + r + 1) * w1 + x + r + 1) - *integral.offset((y - r) * w1 + x + r + 1)
            - *integral.offset((y + r + 1) * w1 + x - r) + *integral.offset((y - r) * w1 + x - r)
    };
    let (f0, f1, f2) = (*fg, *fg.add(1), *fg.add(2));
    let mut donor_count_n = 0usize; let mut donor_squares = 0.0f64; let mut donor_count = 0.0f64; let mut active = 0i32;
    let mut y = r + 1;
    while y < h - r - 1 {
        let mut x = r + 1;
        while x < w - r - 1 {
            if boxsum(x, y) != 0 { x += 2; continue; }
            let mut bad = 0;
            for yy in y - r..=y + r { for xx in x - r..=x + r {
                let i = ((yy * w + xx) * 4) as usize; let mut d = 0.0f64;
                let v0 = fabs(*rgba.add(i) as f64 - f0); if v0 > d { d = v0 }
                let v1 = fabs(*rgba.add(i + 1) as f64 - f1); if v1 > d { d = v1 }
                let v2 = fabs(*rgba.add(i + 2) as f64 - f2); if v2 > d { d = v2 }
                if d < 48.0 { bad += 1; }
            }}
            if bad > 5 { x += 2; continue; }
            let (mut sum, mut squared, mut high) = (0.0f64, 0.0f64, 0i32);
            for yy in y - r..=y + r { for xx in x - r..=x + r {
                let j = (yy * w + xx) as usize; let v = *residual.add(j * 3 + 1) as f64; sum += v; squared += v * v;
                let g = |q: usize| *rgba.add(q * 4 + 1) as f64;
                if fabs(g(j) - (((g(j - 1) + g(j + 1)) + g(j - wu)) + g(j + wu)) / 4.0) > 4.0 { high += 1; }
            }}
            let mean = sum / 81.0; let variance = squared / 81.0 - mean * mean;
            if fabs(sum / 81.0) > 12.0 || variance > 625.0 { x += 2; continue; }
            if variance >= 9.0 && high >= 3 { active += 1; }
            donor_squares += squared; donor_count += 81.0; *donors.add(donor_count_n) = y * w + x; donor_count_n += 1;
            x += 2;
        }
        y += 2;
    }
    *stats.add(5) = donor_squares; *stats.add(6) = donor_count;
    if donor_count_n < 24 || (active as f64) < donor_count_n as f64 * 0.4 || donor_squares / donor_count < 9.0 { return 0; }
    // sample = donors.filter((_, i) => i % max(1, ceil(len / 192)) === 0), compacted in place.
    let every = { let c = (donor_count_n + 191) / 192; if c > 1 { c } else { 1 } };
    let mut samples = 0usize; for i in 0..donor_count_n { if i % every == 0 { *donors.add(samples) = *donors.add(i); samples += 1; } }
    *stats.add(4) = samples as f64;
    let (mut patches, mut max_error, mut comparisons, mut operations) = (0i32, 0.0f64, 0.0f64, 0.0f64);
    let mut grid_w = 0usize; let mut x = r + 1; while x < w - r - 1 { *grid_x.add(grid_w) = x; grid_w += 1; x += 2; }
    let mut grid_h = 0usize; let mut y = r + 1; while y < h - r - 1 { *grid_y.add(grid_h) = y; grid_h += 1; y += 2; }
    let priority_of = |gx: usize, gy: usize| -> f64 {
        let i = (*grid_y.add(gy) * w + *grid_x.add(gx)) as usize;
        if *pending.add(i) == 0 || (*pending.add(i - 1) != 0 && *pending.add(i + 1) != 0 && *pending.add(i - wu) != 0 && *pending.add(i + wu) != 0) { return -1.0; }
        let (mut count, mut lo, mut hi) = (0i32, 255i32, 0i32);
        let mut dy = -r; while dy <= r { let mut dx = -r; while dx <= r {
            let j = (i as i32 + dy * w + dx) as usize;
            if *pending.add(j) == 0 { count += 1; let v = *work.add(j * 4 + 1) as i32; if v < lo { lo = v } if v > hi { hi = v } }
            dx += 2; } dy += 2; }
        let span = if hi - lo < 80 { hi - lo } else { 80 };
        count as f64 * (1.0 + span as f64 / 80.0)
    };
    let cells = grid_w * grid_h; let mut candidates = 0i32;
    for gy in 0..grid_h { for gx in 0..grid_w { let v = priority_of(gx, gy); *cell.add(gy * grid_w + gx) = v; if v >= 0.0 { candidates += 1; } } }
    let mut known_offset = [0i32; 81]; let mut known_pixel = [0i32; 81];
    while left != 0 {
        patches += 1; if patches > 1200 { return 0; }
        if operations + 25.0 * candidates as f64 > 24000000.0 { return 0; }
        operations += 25.0 * candidates as f64;
        let mut at = -1i32; let mut priority = -1.0f64;
        for g in 0..cells { let v = *cell.add(g); if v > priority { priority = v; at = *grid_y.add(g / grid_w) * w + *grid_x.add(g % grid_w); } }
        if at < 0 { let mut found = -1i32; for i in 0..n { if *pending.add(i) != 0 { found = i as i32; break; } } if found < 0 { break; } at = found; }
        let ax = at % w; let ay = at / w;
        if ax < r || ay < r || ax >= w - r || ay >= h - r { return 0; }
        let mut known = 0usize;
        for dy in -r..=r { for dx in -r..=r { let j = at + dy * w + dx; if *pending.add(j as usize) == 0 { known_offset[known] = dy * w + dx; known_pixel[known] = j; known += 1; } } }
        if known < 12 { return 0; }
        let mut best = -1i32; let mut error = f64::INFINITY;
        for s in 0..samples {
            let donor = *donors.add(s); let mut sum = 0.0f64;
            for k in 0..known {
                let q = (donor + known_offset[k]) as usize; let j = known_pixel[k] as usize;
                for c in 0..3 { let d = *filled.add(j * 3 + c) as f64 - *residual.add(q * 3 + c) as f64; sum += d * d; }
                comparisons += 1.0; operations += 1.0; if operations > 24000000.0 { return 0; }
                if sum > error { break; }
            }
            if sum < error { error = sum; best = donor; }
        }
        let rmse = sqrt(error / (known * 3) as f64); if rmse > max_error { max_error = rmse; }
        if best < 0 || rmse > 24.0 { return 0; }
        for dy in -r..=r { for dx in -r..=r {
            let j = (at + dy * w + dx) as usize; if *pending.add(j) == 0 { continue; }
            let q = ((best + dy * w + dx) * 4) as usize;
            let (jx, jy) = ((j % wu) as f64, (j / wu) as f64);
            for c in 0..3 {
                let v = *residual.add((q / 4) * 3 + c); *filled.add(j * 3 + c) = v;
                let value = v as f64 + coef(c, 0) + coef(c, 1) * jx / wf + coef(c, 2) * jy / hf;
                let b = clamp_u8(value); *work.add(j * 4 + c) = b; *output.add(j * 4 + c) = b;
            }
            *output.add(j * 4 + 3) = 255; *pending.add(j) = 0; left -= 1;
        }}
        let gwi = grid_w as i32; let ghi = grid_h as i32;
        let ceil_half = |v: i32| -> i32 { if v >= 0 { (v + 1) / 2 } else { -((-v) / 2) } };
        let floor_half = |v: i32| -> i32 { if v >= 0 { v / 2 } else { -((-v + 1) / 2) } };
        let gx0 = { let v = ceil_half(ax - 2 * r - (r + 1)); if v > 0 { v } else { 0 } };
        let gx1 = { let v = floor_half(ax + 2 * r - (r + 1)); if v < gwi - 1 { v } else { gwi - 1 } };
        let gy0 = { let v = ceil_half(ay - 2 * r - (r + 1)); if v > 0 { v } else { 0 } };
        let gy1 = { let v = floor_half(ay + 2 * r - (r + 1)); if v < ghi - 1 { v } else { ghi - 1 } };
        let mut gy = gy0;
        while gy <= gy1 { let mut gx = gx0; while gx <= gx1 {
            let g = (gy * gwi + gx) as usize; let v = priority_of(gx as usize, gy as usize);
            if *cell.add(g) >= 0.0 { candidates -= 1; } if v >= 0.0 { candidates += 1; } *cell.add(g) = v;
            gx += 1; } gy += 1; }
    }
    *stats = patches as f64; *stats.add(1) = max_error; *stats.add(2) = comparisons; *stats.add(3) = operations;
    1
}

// ---- aidokuEnclosedPaperRestore --------------------------------------------------------------------
/// Whole enclosed-paper proposal. rects: auxiliary (aux_n x 4 f64) then excluded (exc_n x 4 f64).
/// stats: [erased, components, frame]. Returns 1 with output/safe written, 0 for null.
#[no_mangle]
pub unsafe extern "C" fn enclosed_paper(rgba: *const u8, w: i32, h: i32, l: i32, t: i32, r: i32, bottom: i32,
                                        rects: *const f64, aux_n: i32, exc_n: i32,
                                        paper: *mut u8, seen: *mut u8, q: *mut i32, best: *mut i32, region: *mut u8, outside: *mut u8,
                                        points: *mut i32, meta: *mut i32, output: *mut u8, safe: *mut u8, stats: *mut i32) -> i32 {
    let n = (w * h) as usize; let wu = w as usize;
    let area = ((r - l) * (bottom - t)) as f64;
    for i in 0..n {
        let p = i * 4; let (a, b, c) = (*rgba.add(p) as i32, *rgba.add(p + 1) as i32, *rgba.add(p + 2) as i32);
        let lo = min3(a, b, c); let hi = max3(a, b, c);
        *paper.add(i) = (*rgba.add(p + 3) >= 254 && lo >= 232 && hi - lo <= 12) as u8;
        *seen.add(i) = 0; *region.add(i) = 0; *outside.add(i) = 0; *safe.add(i) = 0;
    }
    for i in 0..n * 4 { *output.add(i) = 0; }
    let mut best_len = 0usize; let mut have_best = false; let mut score = 0i32;
    for s in 0..n {
        if *paper.add(s) == 0 || *seen.add(s) != 0 { continue; }
        let (mut head, mut end, mut inside) = (0usize, 1usize, 0i32);
        *q = s as i32; *seen.add(s) = 1;
        while head < end {
            let i = *q.add(head) as usize; head += 1; let x = (i % wu) as i32; let y = (i / wu) as i32;
            if x >= l && x < r && y >= t && y < bottom { inside += 1; }
            if x > 0 && *paper.add(i - 1) != 0 && *seen.add(i - 1) == 0 { *seen.add(i - 1) = 1; *q.add(end) = (i - 1) as i32; end += 1; }
            if x < w - 1 && *paper.add(i + 1) != 0 && *seen.add(i + 1) == 0 { *seen.add(i + 1) = 1; *q.add(end) = (i + 1) as i32; end += 1; }
            if y > 0 && *paper.add(i - wu) != 0 && *seen.add(i - wu) == 0 { *seen.add(i - wu) = 1; *q.add(end) = (i - wu) as i32; end += 1; }
            if y < h - 1 && *paper.add(i + wu) != 0 && *seen.add(i + wu) == 0 { *seen.add(i + wu) = 1; *q.add(end) = (i + wu) as i32; end += 1; }
        }
        if inside > score && inside as f64 >= area * 0.4 {
            score = inside; have_best = true; best_len = end;
            for k in 0..end { *best.add(k) = *q.add(k); }
        }
    }
    if !have_best { return 0; }
    for k in 0..best_len { *region.add(*best.add(k) as usize) = 1; }
    let mut end = 0usize;
    {
        let mut seed = |i: usize| { if *region.add(i) == 0 && *outside.add(i) == 0 { *outside.add(i) = 1; *q.add(end) = i as i32; end += 1; } };
        for x in 0..wu { seed(x); seed((h as usize - 1) * wu + x); }
        for y in 0..h as usize { seed(y * wu); seed(y * wu + wu - 1); }
    }
    let mut head = 0usize;
    while head < end {
        let i = *q.add(head) as usize; head += 1; let x = (i % wu) as i32; let y = (i / wu) as i32;
        if x > 0 && *region.add(i - 1) == 0 && *outside.add(i - 1) == 0 { *outside.add(i - 1) = 1; *q.add(end) = (i - 1) as i32; end += 1; }
        if x < w - 1 && *region.add(i + 1) == 0 && *outside.add(i + 1) == 0 { *outside.add(i + 1) = 1; *q.add(end) = (i + 1) as i32; end += 1; }
        if y > 0 && *region.add(i - wu) == 0 && *outside.add(i - wu) == 0 { *outside.add(i - wu) = 1; *q.add(end) = (i - wu) as i32; end += 1; }
        if y < h - 1 && *region.add(i + wu) == 0 && *outside.add(i + wu) == 0 { *outside.add(i + wu) = 1; *q.add(end) = (i + wu) as i32; end += 1; }
    }
    for i in 0..n { *seen.add(i) = 0; *safe.add(i) = *region.add(i); }
    let (lf, rf, tf, bf) = (l as f64, r as f64, t as f64, bottom as f64);
    let hole_limit = { let v = area * 0.35; if v > 48.0 { v } else { 48.0 } };
    let (mut holes, mut tiny_outside, mut used) = (0usize, 0i32, 0usize);
    for s in 0..n {
        if *region.add(s) != 0 || *outside.add(s) != 0 || *seen.add(s) != 0 { continue; }
        let base = q.add(0); let (mut head, mut end) = (0usize, 1usize); *base = s as i32; *seen.add(s) = 1;
        let (mut x0, mut x1, mut y0, mut y1) = (w, 0i32, h, 0i32);
        while head < end {
            let i = *q.add(head) as usize; head += 1; let x = (i % wu) as i32; let y = (i / wu) as i32;
            if x < x0 { x0 = x } if x > x1 { x1 = x } if y < y0 { y0 = y } if y > y1 { y1 = y }
            let ya = if y > 0 { y - 1 } else { 0 }; let yb = if y < h - 1 { y + 1 } else { h - 1 };
            let xa = if x > 0 { x - 1 } else { 0 }; let xb = if x < w - 1 { x + 1 } else { w - 1 };
            for yy in ya..=yb { for xx in xa..=xb { let j = (yy * w + xx) as usize;
                if *region.add(j) == 0 && *outside.add(j) == 0 && *seen.add(j) == 0 { *seen.add(j) = 1; *q.add(end) = j as i32; end += 1; } } }
        }
        let cx = (x0 + x1) as f64 / 2.0; let cy = (y0 + y1) as f64 / 2.0;
        let body = cx >= lf - 3.0 && cx <= rf + 3.0 && cy >= tf - 3.0 && cy <= bf + 3.0;
        let mut aux = false;
        for a in 0..aux_n as usize { let v = rects.add(a * 4);
            if cx >= *v - 2.0 && cx <= *v + *v.add(2) + 2.0 && cy >= *v.add(1) - 2.0 && cy <= *v.add(1) + *v.add(3) + 2.0 { aux = true; break; } }
        let mut excluded = false;
        for e in 0..exc_n as usize { let v = rects.add((aux_n as usize + e) * 4);
            if (x0 as f64) < *v + *v.add(2) && x1 as f64 >= *v && (y0 as f64) < *v.add(1) + *v.add(3) && y1 as f64 >= *v.add(1) { excluded = true; break; } }
        if end <= 5 && !body { tiny_outside += 1; }
        if (body || aux) && !excluded && (end as f64) < hole_limit {
            for k in 0..end { *points.add(used + k) = *q.add(k); }
            *meta.add(holes * 2) = used as i32; *meta.add(holes * 2 + 1) = end as i32; used += end; holes += 1;
        }
    }
    if holes == 0 || tiny_outside >= 8 { return 0; }
    let mut erased = 0i32;
    for hidx in 0..holes {
        let start = *meta.add(hidx * 2) as usize; let len = *meta.add(hidx * 2 + 1) as usize;
        let mut samples = 0i32; let mut color = [0i32; 3];
        for k in 0..len { let i = *points.add(start + k) as usize; let x = (i % wu) as i32; let y = (i / wu) as i32;
            let ya = if y > 0 { y - 1 } else { 0 }; let yb = if y < h - 1 { y + 1 } else { h - 1 };
            let xa = if x > 0 { x - 1 } else { 0 }; let xb = if x < w - 1 { x + 1 } else { w - 1 };
            for yy in ya..=yb { for xx in xa..=xb { let j = (yy * w + xx) as usize; if *region.add(j) == 0 { continue; }
                samples += 1; for c in 0..3 { color[c] += *rgba.add(j * 4 + c) as i32; } } } }
        if samples < 4 { continue; }
        let cf = [color[0] as f64 / samples as f64, color[1] as f64 / samples as f64, color[2] as f64 / samples as f64];
        for k in 0..len { let i = *points.add(start + k) as usize; *safe.add(i) = 1; erased += 1;
            for c in 0..3 { *output.add(i * 4 + c) = clamp_u8(cf[c]); } *output.add(i * 4 + 3) = 255; }
    }
    if erased < 8 || erased as f64 > area * 0.65 { return 0; }
    let (mut unresolved, mut frame) = (0i32, 0i32);
    for y in t..bottom { for x in l..r { let i = (y * w + x) as usize; if *safe.add(i) == 0 { if *outside.add(i) != 0 { frame += 1 } else { unresolved += 1 } } } }
    for a in 0..aux_n as usize { let v = rects.add(a * 4);
        let ya = { let f = floor(*v.add(1)); if f > 0.0 { f } else { 0.0 } } as i32;
        let yb = { let c = ceil(*v.add(1) + *v.add(3)); if c < h as f64 { c } else { h as f64 } } as i32;
        let xa = { let f = floor(*v); if f > 0.0 { f } else { 0.0 } } as i32;
        let xb = { let c = ceil(*v + *v.add(2)); if c < w as f64 { c } else { w as f64 } } as i32;
        for y in ya..yb { for x in xa..xb { if *safe.add((y * w + x) as usize) == 0 { unresolved += 1; } } } }
    if unresolved != 0 { return 0; }
    *stats = erased; *stats.add(1) = holes as i32; *stats.add(2) = frame;
    1
}

// ---- aidokuLocalComponentRestore -------------------------------------------------------------------
/// Everything after the background mode: ink/safe masks, 8-connected ink parts, per-part ring colour and paint.
/// bg: 3 f64; b: 4 f64 (OCR box). stats: [erased, components, unresolved, frame]. Returns 1 when the proposal
/// survives the part loop (the JavaScript checks erased/components/samples and the auxiliary boxes), 0 for null and
/// 2 when more parts than part_capacity touch the box (the caller then keeps its JavaScript path).
#[no_mangle]
pub unsafe extern "C" fn local_components(rgba: *const u8, w: i32, h: i32, l: i32, t: i32, right: i32, bottom: i32, bg: *const f64,
                                          bmax: f64, excluded: *const u8, ink: *mut u8, seen: *mut u8, safe: *mut u8, q: *mut i32,
                                          paint: *mut u8, member: *mut u8, output: *mut u8, parts: *mut i32, part_capacity: i32,
                                          points: *mut i32, stats: *mut i32) -> i32 {
    let n = (w * h) as usize; let wu = w as usize;
    let (b0, b1, b2) = (*bg, *bg.add(1), *bg.add(2));
    for i in 0..n {
        let p = i * 4;
        let d = fmax3(fabs(*rgba.add(p) as f64 - b0), fabs(*rgba.add(p + 1) as f64 - b1), fabs(*rgba.add(p + 2) as f64 - b2));
        *ink.add(i) = (d > 22.0) as u8; *safe.add(i) = (d <= 22.0) as u8;
        *seen.add(i) = 0; *paint.add(i) = 0;
    }
    for i in 0..n * 4 { *output.add(i) = 0; }
    let (mut outside_dots, mut inside_dots) = (0i32, 0i32);
    let (mut nparts, mut used) = (0usize, 0usize);
    for s in 0..n {
        if *ink.add(s) == 0 || *seen.add(s) != 0 { continue; }
        let (mut head, mut tail) = (0usize, 1usize); let (mut x0, mut y0, mut x1, mut y1) = (w, h, 0i32, 0i32); let mut inside = 0i32;
        *q = s as i32; *seen.add(s) = 1;
        while head < tail {
            let i = *q.add(head) as usize; head += 1; let x = (i % wu) as i32; let y = (i / wu) as i32;
            if x < x0 { x0 = x } if x > x1 { x1 = x } if y < y0 { y0 = y } if y > y1 { y1 = y }
            if x >= l && x < right && y >= t && y < bottom { inside += 1; }
            let ya = if y > 0 { y - 1 } else { 0 }; let yb = if y < h - 1 { y + 1 } else { h - 1 };
            let xa = if x > 0 { x - 1 } else { 0 }; let xb = if x < w - 1 { x + 1 } else { w - 1 };
            for yy in ya..=yb { for xx in xa..=xb { let j = (yy * w + xx) as usize;
                if *ink.add(j) != 0 && *seen.add(j) == 0 { *seen.add(j) = 1; *q.add(tail) = j as i32; tail += 1; } } }
        }
        if tail <= 5 { if inside != 0 { inside_dots += 1 } else { outside_dots += 1 } }
        if inside == 0 { continue; }
        let contained = x0 >= l - 1 && y0 >= t - 1 && x1 <= right && y1 <= bottom && x0 > 2 && y0 > 2 && x1 < w - 3 && y1 < h - 3;
        if nparts as i32 >= part_capacity { return 2; }
        let m = parts.add(nparts * 8);
        *m = used as i32; *m.add(1) = tail as i32; *m.add(2) = x0; *m.add(3) = y0; *m.add(4) = x1; *m.add(5) = y1;
        *m.add(6) = inside; *m.add(7) = contained as i32;
        for k in 0..tail { *points.add(used + k) = *q.add(k); }
        used += tail; nparts += 1;
    }
    if inside_dots >= 8 && outside_dots >= 8 { return 0; }
    // member may alias seen (finished with the part walk).
    for i in 0..n { *member.add(i) = 0; }
    let (mut erased, mut components, mut unresolved, mut frame) = (0i32, 0i32, 0i32, 0i32);
    for pi in 0..nparts {
        let m = parts.add(pi * 8);
        let (start, len, x0, y0, x1, y1, inside, contained) =
            (*m as usize, *m.add(1) as usize, *m.add(2), *m.add(3), *m.add(4), *m.add(5), *m.add(6), *m.add(7));
        if contained == 0 { frame += inside; continue; }
        let mut hit = false; for k in 0..len { if *excluded.add(*points.add(start + k) as usize) != 0 { hit = true; break; } }
        if hit { unresolved += inside; continue; }
        let bw = x1 - x0 + 1; let bh = y1 - y0 + 1;
        if (len as f64 > (bw * bh) as f64 * 0.98 && len > 24) || (if bw > bh { bw } else { bh }) as f64 > bmax * 1.1 { unresolved += inside; continue; }
        let (mut total, mut good) = (0i32, 0i32); let mut sums = [0i32; 3]; let mut sq = [0i32; 3];
        for yy in y0 - 2..=y1 + 2 { for xx in x0 - 2..=x1 + 2 {
            if xx > x0 - 2 && xx < x1 + 2 && yy > y0 - 2 && yy < y1 + 2 { continue; }
            let j = (yy * w + xx) as usize; total += 1; if *ink.add(j) != 0 { continue; } good += 1;
            for c in 0..3 { let v = *rgba.add(j * 4 + c) as i32; sums[c] += v; sq[c] += v * v; }
        }}
        if good < 12 || (good as f64) < total as f64 * 0.55 { unresolved += inside; continue; }
        let gf = good as f64;
        let color = [sums[0] as f64 / gf, sums[1] as f64 / gf, sums[2] as f64 / gf];
        let mut deviation = f64::NEG_INFINITY;
        for c in 0..3 { let v = sq[c] as f64 / gf - color[c] * color[c]; let d = sqrt(if v > 0.0 { v } else { 0.0 }); if d > deviation { deviation = d; } }
        if deviation > 18.0 { unresolved += inside; continue; }
        for k in 0..len { *member.add(*points.add(start + k) as usize) = 1; }
        for k in 0..len {
            let i = *points.add(start + k) as usize; let x = (i % wu) as i32; let y = (i / wu) as i32;
            for yy in y - 1..=y + 1 { for xx in x - 1..=x + 1 {
                let j = (yy * w + xx) as usize;
                if *excluded.add(j) != 0 || xx < l - 1 || xx > right || yy < t - 1 || yy > bottom || (*ink.add(j) != 0 && *member.add(j) == 0) { continue; }
                if *paint.add(j) == 0 { erased += 1; } *paint.add(j) = 1; *safe.add(j) = 1;
                for c in 0..3 { *output.add(j * 4 + c) = clamp_u8(color[c]); } *output.add(j * 4 + 3) = 255;
            }}
        }
        for k in 0..len { *member.add(*points.add(start + k) as usize) = 0; }
        components += 1;
    }
    *stats = erased; *stats.add(1) = components; *stats.add(2) = unresolved; *stats.add(3) = frame;
    1
}

// ---- aidokuObservedPixelClasses --------------------------------------------------------------------
struct Blend { valid: bool, s: [f64; 3], d: [f64; 3], length: f64 }
fn blend(end: [f64; 3], start: [f64; 3], present: bool) -> Blend {
    let d = [end[0] - start[0], end[1] - start[1], end[2] - start[2]];
    let length = ((0.0 + d[0] * d[0]) + d[1] * d[1]) + d[2] * d[2];
    Blend { valid: present && length != 0.0, s: start, d, length }
}
#[inline(always)]
fn blend_at(b: &Blend, r: f64, g: f64, bl: f64) -> bool {
    if !b.valid { return false; }
    let v = (((0.0 + (r - b.s[0]) * b.d[0]) + (g - b.s[1]) * b.d[1]) + (bl - b.s[2]) * b.d[2]) / b.length;
    let t = if v < 1.0 { v } else { 1.0 }; let t = if t > 0.0 { t } else { 0.0 };
    fmax3(fabs(r - (b.s[0] + t * b.d[0])), fabs(g - (b.s[1] + t * b.d[1])), fabs(bl - (b.s[2] + t * b.d[2]))) <= 24.0
}

/// colors: f64 [foreground 3, background 3, secondary 3, stroke 3]; flags: 1 secondary, 2 stroke, 4 matched (observedInk),
/// 8 light surface. Writes raw, observed (when matched) and protected masks.
#[no_mangle]
pub unsafe extern "C" fn pixel_classes(rgba: *const u8, n: i32, colors: *const f64, flags: i32, ink_tolerance: f64, halo_separation: f64,
                                       raw: *mut u8, observed: *mut u8, protected: *mut u8) {
    let c = |k: usize| *colors.add(k);
    let fg = [c(0), c(1), c(2)]; let bg = [c(3), c(4), c(5)]; let sec = [c(6), c(7), c(8)]; let st = [c(9), c(10), c(11)];
    let has_secondary = flags & 1 != 0; let has_stroke = flags & 2 != 0; let matched = flags & 4 != 0; let light = flags & 8 != 0;
    let ink_stroke = blend(st, fg, has_stroke); let ink_background = blend(bg, fg, true); let stroke_background = blend(bg, st, has_stroke);
    for i in 0..n as usize {
        let p = i * 4; let (pr, pg, pb) = (*rgba.add(p) as f64, *rgba.add(p + 1) as f64, *rgba.add(p + 2) as f64);
        let ink_d = fmax3(fabs(pr - fg[0]), fabs(pg - fg[1]), fabs(pb - fg[2]));
        let bg_d = fmax3(fabs(pr - bg[0]), fabs(pg - bg[1]), fabs(pb - bg[2]));
        let sec_d = if has_secondary { fmax3(fabs(pr - sec[0]), fabs(pg - sec[1]), fabs(pb - sec[2])) } else { f64::INFINITY };
        let sec_match = sec_d <= ink_tolerance && sec_d + 8.0 < bg_d;
        let mut obs = false;
        if matched && ((ink_d <= ink_tolerance && ink_d + 8.0 < bg_d) || sec_match) { obs = true; }
        *observed.add(i) = obs as u8;
        let hi = fmax3(pr, pg, pb);
        let r = sec_match || obs || (light && hi < 110.0);
        *raw.add(i) = r as u8;
        let prot = matched && !r && bg_d >= halo_separation && ink_d > ink_tolerance &&
            (!has_stroke || fmax3(fabs(pr - st[0]), fabs(pg - st[1]), fabs(pb - st[2])) > ink_tolerance) &&
            !blend_at(&ink_stroke, pr, pg, pb) && !blend_at(&ink_background, pr, pg, pb) && !blend_at(&stroke_background, pr, pg, pb);
        *protected.add(i) = prot as u8;
    }
}

