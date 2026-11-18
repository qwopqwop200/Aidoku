import Foundation

/// Native adaptation of the supplied adaptive_stroke.py design, not an exact port.
/// Scores the existing CoreGraphics halo-then-fill compositor, without changing ink.
/// Scores are engineering visibility proxies, not calibrated readability probabilities.
enum NativeRenderedStrokeSelection {
    struct Pair { let inside: Int; let outside: Int; let weight: Double }

    static func lightness(_ y: Double) -> Double {
        y > 0.008856 ? 1.16 * cbrt(max(0, y)) - 0.16 : 9.03296 * max(0, y)
    }

    static func linear(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    static func blur(_ values: [Double], _ w: Int, _ h: Int, _ sigma: Double) -> [Double] {
        let r = Int(ceil(3 * sigma))
        var kernel = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let mass = kernel.reduce(0, +)
        kernel = kernel.map { $0 / mass }
        var tmp = values, result = values
        for y in 0..<h { for x in 0..<w {
            var sum = 0.0
            for dx in -r...r { sum += values[y*w + min(w-1, max(0, x+dx))] * kernel[dx+r] }
            tmp[y*w+x] = sum
        }}
        for y in 0..<h { for x in 0..<w {
            var sum = 0.0
            for dy in -r...r { sum += tmp[min(h-1, max(0, y+dy))*w+x] * kernel[dy+r] }
            result[y*w+x] = sum
        }}
        return result
    }

    static func resize(_ a: [Double], _ w: Int, _ h: Int, _ nw: Int, _ nh: Int) -> [Double] {
        if w == nw && h == nh { return a }
        var out = [Double](repeating: 0, count: nw*nh)
        for y in 0..<nh { for x in 0..<nw {
            let sx = max(0, min(Double(w-1), (Double(x)+0.5)*Double(w)/Double(nw)-0.5))
            let sy = max(0, min(Double(h-1), (Double(y)+0.5)*Double(h)/Double(nh)-0.5))
            let ix = Int(sx), iy = Int(sy), fx = sx-Double(ix), fy = sy-Double(iy)
            let jx = min(w-1, ix+1), jy = min(h-1, iy+1)
            out[y*nw+x] = (a[iy*w+ix]*(1-fx)+a[iy*w+jx]*fx)*(1-fy)
                + (a[jy*w+ix]*(1-fx)+a[jy*w+jx]*fx)*fy
        }}
        return out
    }

    static func pairs(_ mask: [Double], _ fill: [Double], _ w: Int, _ h: Int,
                      _ offset: Double, outer: Bool) -> [Pair] {
        guard w > 2, h > 2, let peak = mask.max(), peak > 0 else { return [] }
        let smooth = blur(mask, w, h, 0.65), threshold = peak*0.5
        var result = [Pair]()
        for y in 1..<(h-1) { for x in 1..<(w-1) {
            let i = y*w+x
            guard mask[i] >= threshold,
                  min(mask[i-1], mask[i+1], mask[i-w], mask[i+w]) < threshold else { continue }
            let gx = smooth[i+1]-smooth[i-1], gy = smooth[i+w]-smooth[i-w]
            let length = hypot(gx, gy)
            guard length > 0.00001 else { continue }
            let nx = -gx/length, ny = -gy/length
            let ix = Int((Double(x)-nx*offset).rounded()), iy = Int((Double(y)-ny*offset).rounded())
            let distance = outer ? 2.0 : offset
            let ox = Int((Double(x)+nx*distance).rounded()), oy = Int((Double(y)+ny*distance).rounded())
            guard ix >= 0, ix < w, iy >= 0, iy < h, ox >= 0, ox < w, oy >= 0, oy < h else { continue }
            let a = iy*w+ix, b = oy*w+ox, weight = max(0, mask[a]-mask[b])
            if weight > 0.12 && (!outer || fill[a] <= 0.2) {
                result.append(Pair(inside: a, outside: b, weight: weight))
            }
        }}
        if result.count > 6000 {
            let all = result
            result = (0..<6000).map { all[$0*(all.count-1)/5999] }
        }
        return result
    }

    static func robust(_ values: [(Double, Double)]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mass = values.reduce(0) { $0+$1.1 }
        let mean = values.reduce(0) { $0+$1.0*$1.1 }/max(1e-12, mass)
        var sum = 0.0, tail = 0.0
        for (value, weight) in values.sorted(by: { $0.0 < $1.0 }) {
            sum += weight; tail = value
            if sum >= mass*0.15 { break }
        }
        return 0.65*mean+0.35*tail
    }

    static func select(fill: [UInt8], alpha: [UInt8], dilated: [UInt8], background: [UInt8],
                       width w: Int, height h: Int, radius: Double,
                       preferredEndpoint: UInt8? = nil) -> (UInt8, [String: Any]) {
        let n = w*h, a = alpha.map { Double($0)/255 }, d = dilated.map { Double($0)/255 }
        var rgb = Array(repeating: Array(repeating: [Double](repeating: 0, count: n), count: 3), count: 2)
        var visible = [Double](repeating: 0, count: n), premult = visible
        var inkSum = 0.0, inkMass = 0.0
        var inkRGBSum = [Double](repeating: 0, count: 3)
        let weights = [0.2126, 0.7152, 0.0722]
        for i in 0..<n {
            // Existing painter draws D halo then A fill. Match it exactly;
            // do not score the reference's D-A while painting (1-A)*D.
            visible[i] = (1-a[i])*(1-d[i])
            var bgY = 0.0, inkY = 0.0
            for c in 0..<3 {
                inkRGBSum[c] += Double(fill[i*4+c])/255
                let bg = Double(background[i*4+c])/max(1, Double(background[i*4+3]))
                bgY += linear(bg)*weights[c]
                if a[i] > 0 { inkY += linear(Double(fill[i*4+c])/Double(alpha[i]))*weights[c] }
                for e in 0..<2 {
                    rgb[e][c][i] = Double(fill[i*4+c])/255 + (1-a[i])*d[i]*Double(e) + visible[i]*bg
                }
            }
            premult[i] = visible[i]*bgY
            inkSum += a[i]*inkY; inkMass += a[i]
        }
        let inkL = lightness(inkSum/max(1e-12, inkMass))
        let eta = 0.35*sqrt(a.reduce(0,+)/max(1e-12,d.reduce(0,+)))
        var scores = [[Double](), [Double]()], innerScores = scores, outerScores = scores
        var evaluationScores = scores
        var innerCounts = [Int](), outerCounts = [Int]()
        for scale in [1.0, 0.75] {
            let nw = max(1, Int((Double(w)*scale).rounded())), nh = max(1, Int((Double(h)*scale).rounded()))
            let aa = resize(a,w,h,nw,nh), dd = resize(d,w,h,nw,nh)
            let vv = resize(visible,w,h,nw,nh), pp = resize(premult,w,h,nw,nh)
            let inner = pairs(aa,aa,nw,nh, min(2, max(1,radius*scale*0.4)),outer:false)
            let outer = pairs(dd,aa,nw,nh, min(2, max(1,radius*scale*0.5)),outer:true)
            innerCounts.append(inner.count); outerCounts.append(outer.count)
            let mass = blur(vv,nw,nh,1.5)
            let mean = blur(pp,nw,nh,1.5)
            let second = blur(zip(pp,vv).map { $0*$0/max(1e-12,$1) },nw,nh,1.5)
            let noise = (0..<(nw*nh)).map { i in
                sqrt(max(0,second[i]/max(1e-12,mass[i])-pow(mean[i]/max(1e-12,mass[i]),2)))
            }
            for e in 0..<2 {
                var y = [Double](repeating: 0, count: nw*nh)
                for c in 0..<3 {
                    let channel = resize(rgb[e][c],w,h,nw,nh)
                    for i in y.indices { y[i] += linear(channel[i])*weights[c] }
                }
                var scaleScores = [Double]()
                for sigma in [0.5,1.0] {
                    let l = blur(y,nw,nh,sigma).map(lightness)
                    func visibility(_ delta: Double, _ clutter: Double) -> Double { delta/(delta+0.20+0.70*clutter) }
                    let sign = inkL >= Double(e) ? 1.0 : -1.0
                    let vi = inner.isEmpty ? 0.25*visibility(abs(inkL-Double(e)),0) : robust(inner.map { p in
                        (visibility(max(0,sign*(l[p.inside]-l[p.outside])), noise[p.outside]*(1-dd[p.outside])),p.weight)
                    })
                    let vo = robust(outer.map { p in
                        (visibility(abs(l[p.inside]-l[p.outside]),noise[p.outside]),p.weight)
                    })
                    innerScores[e].append(vi); outerScores[e].append(vo)
                    scaleScores.append(vi+eta*(1-vi)*vo)
                    evaluationScores[e].append(vi+eta*(1-vi)*vo)
                }
                scores[e].append(scaleScores.reduce(0,+)/Double(scaleScores.count))
            }
        }
        let totals = scores.map { 0.75*$0.reduce(0,+)/Double($0.count)+0.25*($0.min() ?? 0) }
        let scoreWinner = abs(totals[0]-totals[1]) < 1e-12 ? (inkL >= 0.5 ? 0 : 1) : (totals[1] > totals[0] ? 1 : 0)
        var best = scoreWinner
        // The score is not trained on human preferences. A small numerical win
        // must not erase the upstream source-aware palette when it is smaller
        // than this very raster's sensitivity to scale/blur. This is a stability
        // guard, not a confidence interval or proof that the prior is correct.
        let sensitivity = evaluationScores.map { ($0.max() ?? 0)-($0.min() ?? 0) }.max() ?? 0
        let switchThreshold = max(0.025, sensitivity)
        var retainedStablePrior = false
        if let prior = preferredEndpoint, prior == 0 || prior == 255 {
            let index = prior == 255 ? 1 : 0
            let supported = (innerCounts.min() ?? 0) >= 8 && (outerCounts.min() ?? 0) >= 8
            let priorMean = innerScores[index].reduce(0,+)/Double(innerScores[index].count)
            let otherMean = innerScores[1-index].reduce(0,+)/Double(innerScores[1-index].count)
            let priorReadableProxy = priorMean >= 0.25 && priorMean >= otherMean*0.65
            if index != scoreWinner, supported, priorReadableProxy,
               totals[scoreWinner]-totals[index] <= switchThreshold {
                best = index
                retainedStablePrior = true
            }
        }
        let inkRGB = inkRGBSum.map { $0/max(1e-12,inkMass) }
        let chroma = (inkRGB.max() ?? 0)-(inkRGB.min() ?? 0)
        // Explicit display preference for dark chromatic ink, not source-colour
        // inference: a viable white surround preserves coloured thin stems when
        // the untrained luminance metric cannot robustly distinguish endpoints.
        // Neutral gray still responds to background; pale/yellow ink is exempt.
        let innerMeans = innerScores.map { $0.reduce(0,+)/Double($0.count) }
        let preferWhiteChromatic = chroma >= 0.25 && inkL <= 0.80
            && (innerCounts.min() ?? 0) >= 8 && (outerCounts.min() ?? 0) >= 8
            && innerMeans[1] >= 0.25 && innerMeans[1] >= innerMeans[0]*0.65
        if preferWhiteChromatic {
            best = 1
            retainedStablePrior = preferredEndpoint == 255 && scoreWinner != 1
        }
        var reasons = [String]()
        if preferWhiteChromatic, scoreWinner != 1 { reasons.append("ambiguous-dark-chromatic-ink-prefers-viable-white-surround") }
        if retainedStablePrior { reasons.append("score-win-below-render-sensitivity-preserved-viable-prior") }
        if abs(totals[0]-totals[1]) < 0.025 { reasons.append("small-score-margin") }
        if (innerCounts.min() ?? 0) < 8 { reasons.append("few-inner-boundary-samples") }
        if (outerCounts.min() ?? 0) < 8 { reasons.append("few-outer-boundary-samples") }
        if radius*0.75 < 2 { reasons.append("thin-outline-at-reduced-scale") }
        if innerScores[best].reduce(0,+)/Double(innerScores[best].count) < 0.4 { reasons.append("weak-inner-boundary") }
        return (best == 1 ? 255 : 0, ["algorithm":"native-rendered-boundary-v4-relative-inner",
            "scoresBW":totals,"scaleScoresBW":scores,"innerVisibilityBW":innerScores,
            "outerVisibilityBW":outerScores,"innerSampleCounts":innerCounts,"outerSampleCounts":outerCounts,
            "margin":abs(totals[0]-totals[1]),"effectiveBackgroundWeight":eta,
            "fillStrokeLightnessDifferenceBW":[inkL,1-inkL],
            "scoreWinningEndpoint":scoreWinner == 1 ? 255 : 0,
            "renderSensitivity":sensitivity,"switchThreshold":switchThreshold,
            "retainedViablePrior":retainedStablePrior,"minimumMeanInnerVisibility":0.25,
            "minimumRelativeInnerVisibility":0.65,"meanInnerVisibilityBW":innerMeans,
            "preferredWhiteForDarkChromaticInk":preferWhiteChromatic,
            "displayPreferenceLimits":["minimumChroma":0.25,"maximumInkLightness":0.80],
            "reviewReasons":reasons,"needsReview": !reasons.isEmpty,
            "compositing":"existing-premultiplied-halo-then-fill",
            "authority":"final glyph alpha and visible restored background; engineering proxy, not readability gold"])
    }
}
