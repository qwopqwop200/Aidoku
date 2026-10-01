import Foundation

/// Frozen aidokuSurfacePool/Ready. Whole k×k cells retain exact native-byte
/// extrema; unsafe or off-page cells never authorize surface measurements.
enum NativeTranslationSurfacePool {
    struct Crop {
        let safe: [UInt8]
        let luminance: [UInt8]
        let width: Int
        let height: Int
        let x: Double
        let y: Double
        let sx: Double
        let sy: Double
        let imageWidth: Double
        let imageHeight: Double
        let frameWidth: Double
        let frameHeight: Double
    }
    struct Box { let left: Int; let top: Int; let right: Int; let bottom: Int }
    private struct Geometry: Equatable {
        let width: Int, height: Int
        let x: Double, y: Double, sx: Double, sy: Double, imageWidth: Double, imageHeight: Double
        init(_ c: Crop) {
            width = c.width; height = c.height; x = c.x; y = c.y; sx = c.sx; sy = c.sy
            imageWidth = c.imageWidth; imageHeight = c.imageHeight
        }
    }
    final class Pool {
        let crop: Crop
        let k: Int
        let columns: Int
        let rows: Int
        let tileColumns: Int
        let tileRows: Int
        fileprivate(set) var tiles: [UInt8]
        fileprivate(set) var low: [UInt8]?
        fileprivate(set) var high: [UInt8]?
        fileprivate init(crop: Crop, k: Int) {
            self.crop = crop; self.k = k; columns = crop.width / k; rows = crop.height / k
            tileColumns = (columns + 7) / 8; tileRows = (rows + 7) / 8
            tiles = [UInt8](repeating: 0, count: tileColumns * tileRows)
        }
        func cellBox(_ box: Box) -> Box? {
            guard (box.right - box.left) * (box.bottom - box.top) >= 64 else { return nil }
            let left = Int(ceil(Double(max(0, box.left)) / Double(k))), top = Int(ceil(Double(max(0, box.top)) / Double(k)))
            let right = min(columns, Int(floor(Double(min(crop.width, box.right)) / Double(k))))
            let bottom = min(rows, Int(floor(Double(min(crop.height, box.bottom)) / Double(k))))
            return left < right && top < bottom ? Box(left: left, top: top, right: right, bottom: bottom) : nil
        }
    }
    final class Cache {
        private struct Entry { let geometry: Geometry; let luminanceIdentity: String; let pool: Pool }
        private var pools: [String: Entry] = [:]
        private(set) var remaining: Int
        private(set) var pixels = 0
        /// Only a lookup-budget refusal is retryable; an unsafe range is cached nil.
        private(set) var lastLookupExhausted = false
        init(budget: Int = 1_048_576) { remaining = budget }
        /// Identities must distinguish replacement masks and luminance rasters.
        /// A patch's image identity plus surfaceRevision are suitable native keys.
        func pool(_ crop: Crop, safeIdentity: String, luminanceIdentity: String) -> Pool? {
            guard crop.width > 0, crop.height > 0, crop.width <= Int.max / crop.height,
                  crop.safe.count == crop.width * crop.height, crop.luminance.count == crop.width * crop.height,
                  crop.frameWidth > 0, crop.frameHeight > 0,
                  [crop.frameWidth,crop.frameHeight,crop.sx,crop.sy,crop.imageWidth,crop.imageHeight].allSatisfy(\.isFinite) else { return nil }
            let scale = floor(min(crop.imageWidth / crop.frameWidth * crop.sx, crop.imageHeight / crop.frameHeight * crop.sy) / 1.25)
            guard scale >= 2, scale <= 16 else { return nil }
            let geometry = Geometry(crop)
            if let cached = pools[safeIdentity], cached.luminanceIdentity == luminanceIdentity, cached.geometry == geometry { return cached.pool }
            let k = Int(scale)
            guard crop.width / k >= 1, crop.height / k >= 1 else { return nil }
            let pool = Pool(crop: crop, k: k)
            pools[safeIdentity] = Entry(geometry: geometry, luminanceIdentity: luminanceIdentity, pool: pool)
            return pool
        }
        func ready(_ pool: Pool, cells: Box, build: Bool) -> Bool {
            guard cells.left >= 0, cells.top >= 0, cells.left < cells.right, cells.top < cells.bottom,
                  cells.right <= pool.columns, cells.bottom <= pool.rows else { return false }
            let tx0 = cells.left >> 3, tx1 = (cells.right - 1) >> 3, ty0 = cells.top >> 3, ty1 = (cells.bottom - 1) >> 3
            var cost = 0
            for ty in ty0...ty1 { for tx in tx0...tx1 where pool.tiles[ty * pool.tileColumns + tx] == 0 {
                if !build { return false }
                cost += (min(pool.columns, tx * 8 + 8) - tx * 8) * (min(pool.rows, ty * 8 + 8) - ty * 8) * pool.k * pool.k
            } }
            if cost == 0 { return true }
            if cost > remaining { return false }
            remaining -= cost; pixels += cost
            if pool.low == nil { pool.low = [UInt8](repeating: 0, count: pool.columns * pool.rows); pool.high = pool.low }
            let c = pool.crop, k = pool.k
            for ty in ty0...ty1 { for tx in tx0...tx1 {
                let tile = ty * pool.tileColumns + tx
                if pool.tiles[tile] != 0 { continue }
                pool.tiles[tile] = 1
                for cy in (ty * 8)..<min(pool.rows, ty * 8 + 8) { for cx in (tx * 8)..<min(pool.columns, tx * 8 + 8) {
                    var lo: UInt8 = 255, hi: UInt8 = 0, valid = true
                    for yy in (cy * k)..<(cy * k + k) {
                        if !valid { break }
                        let py = c.y + (Double(yy) + 0.5) / c.sy
                        if py < 0 || py > c.imageHeight { valid = false; break }
                        for xx in (cx * k)..<(cx * k + k) {
                            let px = c.x + (Double(xx) + 0.5) / c.sx, i = yy * c.width + xx
                            if px < 0 || px > c.imageWidth || c.safe[i] == 0 { valid = false; break }
                            let value = c.luminance[i]; lo = min(lo,value); hi = max(hi,value)
                        }
                    }
                    let j = cy * pool.columns + cx
                    pool.low![j] = valid ? lo : 255; pool.high![j] = valid ? hi : 0
                } }
            } }
            return true
        }
        /// Frozen inspectSurface cell/edge scan, including certified exterior pixels. A histogram
        /// must use the native scan instead; this method never approximates one.
        func range(_ pool: Pool, boxes: [Box], lookupBudget: inout Int,
                   exterior: ((Int, Int) -> Double?)? = nil) -> [Double]? {
            lastLookupExhausted = false
            let c = pool.crop
            var native = 0, reduced = 0
            for box in boxes {
                let n = (box.right - box.left) * (box.bottom - box.top); native += n
                if let q = pool.cellBox(box) { reduced += n - (q.right-q.left)*(q.bottom-q.top)*(pool.k*pool.k-1) }
                else { reduced += n }
            }
            let build = native > lookupBudget && reduced <= lookupBudget
            var low = Double.infinity, high = -Double.infinity
            for box in boxes {
                let count = (box.right-box.left)*(box.bottom-box.top)
                if count < 0 || (exterior == nil && (box.left < 0 || box.top < 0 || box.right > c.width || box.bottom > c.height)) { return nil }
                let q = pool.cellBox(box)
                let ready = q.map { self.ready(pool,cells:$0,build:build) } ?? false
                let cells = ready ? q! : Box(left:0,top:0,right:0,bottom:0), k = ready ? pool.k : 1
                let n = (cells.right-cells.left)*(cells.bottom-cells.top), cost = count - n*k*k + n
                if cost > lookupBudget { lastLookupExhausted = true; return nil }
                lookupBudget -= cost
                if n > 0 { for y in cells.top..<cells.bottom { for x in cells.left..<cells.right {
                    let j=y*pool.columns+x, lo=Int(pool.low![j]), hi=Int(pool.high![j])
                    if lo > hi { return nil }; low=min(low,Double(lo)); high=max(high,Double(hi))
                } } }
                for yy in box.top..<box.bottom { for xx in box.left..<box.right {
                    if n > 0 && yy >= cells.top*k && yy < cells.bottom*k && xx >= cells.left*k && xx < cells.right*k { continue }
                    let value: Double
                    if xx >= 0, yy >= 0, xx < c.width, yy < c.height {
                        let px=c.x+(Double(xx)+0.5)/c.sx,py=c.y+(Double(yy)+0.5)/c.sy,i=yy*c.width+xx
                        if px < 0 || px > c.imageWidth || py < 0 || py > c.imageHeight || c.safe[i] == 0 { return nil }
                        value=Double(c.luminance[i])
                    } else {
                        guard let sampled=exterior?(xx,yy),sampled.isFinite else { return nil }
                        value=sampled
                    }
                    low=min(low,value);high=max(high,value)
                } }
            }
            return low.isFinite && low <= high ? [max(0,(low-0.5)/255),min(1,(high+0.5)/255)] : nil
        }
    }
}
