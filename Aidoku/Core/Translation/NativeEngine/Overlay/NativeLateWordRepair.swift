import Foundation
import CoreGraphics

/// Late (post-harmony) whole-word repair. Query callbacks operate on the live trial,
/// including its inherited style and explicit block children; a failed trial restores
/// the complete caption. This file is staged until the next application checkpoint.
enum NativeLateWordRepair {
    struct Profile {
        var ink: [CGRect]
        var lines: Int
        var splits: Int
        var bad: Int
        var isolated: Int
        var fragments: Int
        var punctuationOnly: Int
        var badStarts: Int
        var badEnds: Int
        var bounds: CGRect? { ink.reduce(nil) { $0?.union($1) ?? $1 } }
    }
    struct Input {
        var balanced = false
        var rotated = false
        var automatic = true
        var korean = true
        var hasSurfaceQuery = true
        var hasPanelGeometry = true
        var containsNewline = false
        var utf16Length: Int
        var rootChild = true
        var hidden = false
        var transformed = false
        var inpainted = true
        var textInside = true
        var restored = true
        var balloonRestored = false
        var hasWordMeasure = true
        var hasScale = false
        var font: Double
        var pitchRatio: Double
        var sourceGlyph: Double
        var source: CGRect
        var frame: CGRect
        /// Panel crop projected through its exact image sampling geometry.
        var crop: CGRect
        var cropSafe = false
        var sourceInkLuminance: Double?
        var obstacles: [CGRect] = []
    }
    struct Budget {
        var late = 1_048_576
        var type: Int
        var surface: Int
        var exterior: Int
        var lookup: Int
    }
    struct Candidate {
        var rect: CGRect
        var font: Double
        var condense: Double
        var maxLines: Int
        var anchor: CGPoint
        var pitch: Double
    }
    struct Measurement {
        var profile: Profile
        var contentFits: Bool
        /// getBoundingClientRect from the live Range, after child replacement.
        var live: CGRect
    }
    struct Result {
        var candidate: Candidate
        var profile: Profile
        var originalBad: Int
        var originalFont: Double
        var attempts: Int
        var spent: Int
        var diagnostic: [Double] { [Double(originalBad), originalFont, candidate.font, candidate.condense] }
    }
    static func repair<Snapshot>(input: Input, original: Profile?, budget: inout Budget,
        snapshot: () -> Snapshot, restore: (Snapshot) -> Void,
        wordWidth: (Double) -> Double,
        measure: (Candidate) -> Measurement?,
        surface: (Profile, Double, inout Budget) -> Bool,
        accept: () -> Bool) -> Result? {
        guard !input.balanced, !input.rotated, input.automatic, input.korean,
            input.hasSurfaceQuery, input.hasPanelGeometry, !input.containsNewline,
            input.utf16Length <= 180, input.rootChild, !input.hidden, !input.transformed,
            input.inpainted, input.textInside, input.restored || input.balloonRestored,
            input.hasWordMeasure, !input.hasScale, budget.late > 0 else { return nil }
        let savedCaption = snapshot()
        let savedType = budget.type, savedSurface = budget.surface, savedExterior = budget.exterior
        var accepted = false
        defer {
            let spent = max(1, (savedType-budget.type)*64 + savedSurface-budget.surface + savedExterior-budget.exterior)
            budget.late -= spent
            budget.type = savedType; budget.surface = savedSurface; budget.exterior = savedExterior
            if !accepted { restore(savedCaption) }
        }
        guard let original, original.bad > 0, input.font > 0,
            let box = original.bounds, box.width > 0, box.height > 0,
            let inkLuminance = input.sourceInkLuminance, inkLuminance.isFinite,
            input.sourceGlyph > 0, input.sourceGlyph.isFinite else { return nil }
        var window = input.crop
        if input.cropSafe {
            let expansion = min(64, input.sourceGlyph*1.5)
            window = CGRect(x:max(input.frame.minX,window.minX-expansion),
                y:max(input.frame.minY,window.minY-expansion),
                width:min(input.frame.maxX,window.maxX+expansion)-max(input.frame.minX,window.minX-expansion),
                height:min(input.frame.maxY,window.maxY+expansion)-max(input.frame.minY,window.minY-expansion))
        }
        var centers = [CGPoint(x:box.midX,y:box.midY)]
        let sourceCenter = CGPoint(x:input.source.midX,y:input.source.midY)
        if !centers.contains(where:{abs($0.x-sourceCenter.x)<0.5 && abs($0.y-sourceCenter.y)<0.5}) { centers.append(sourceCenter) }
        let minimum = max(ceil(input.font*0.95*4)/4,min(input.font,8.5))
        var sizes = [input.font]
        var size = floor(input.font*4)/4-0.25
        while size >= minimum-0.001 { if sizes.count<5 { sizes.append(size) }; size -= 0.25 }
        var attempts = 0
        for font in sizes {
            for condense in [1.0,0.9] {
                let word = wordWidth(font)*condense
                let scaled = box.width*font/input.font
                let widths = Set([word+1,word*1.12,scaled*1.2,scaled*1.45,scaled*1.8,word*1.5].map{floor($0*4)/4})
                    .filter{$0>=word}.sorted()
                for anchor in centers {
                    for width in widths {
                        guard attempts<48 else { return nil }; attempts += 1
                        guard width >= font*1.8, input.utf16Length<=budget.type, budget.surface>0 else { continue }
                        budget.type -= input.utf16Length
                        let height = 2*min(anchor.y-window.minY-2,window.maxY-anchor.y-2)
                        let pitch = font*input.pitchRatio
                        guard height >= pitch, pitch>0 else { continue }
                        let layoutWidth = width/condense
                        let candidate = Candidate(rect:CGRect(x:anchor.x-layoutWidth/2,y:anchor.y-height/2,width:layoutWidth,height:height),
                            font:font,condense:condense,maxLines:min(original.lines,Int(floor(height/pitch))),anchor:anchor,pitch:pitch)
                        guard candidate.maxLines>=1, let measured = measure(candidate), measured.contentFits else { continue }
                        let p = measured.profile
                        guard p.lines<=original.lines, p.bad==0, p.splits<=original.splits,
                            p.isolated<=original.isolated,p.fragments<=original.fragments,
                            p.punctuationOnly<=original.punctuationOnly,p.badStarts<=original.badStarts,p.badEnds<=original.badEnds,
                            let next=p.bounds,next.width>0,next.height>0,
                            next.minX>=window.minX,next.maxX<=window.maxX,next.minY>=window.minY,next.maxY<=window.maxY else { continue }
                        guard !input.obstacles.contains(where:{next.minX-1<$0.maxX && next.maxX+1>$0.minX && next.minY-0.75<$0.maxY && next.maxY+0.75>$0.minY}) else { continue }
                        let mx=max(1,font*0.1), my=max(0.75,font*0.1)
                        var probe=p; probe.ink=p.ink.map{$0.insetBy(dx:-mx,dy:-my)}
                        let previous=budget.lookup, allowance=min(budget.surface,65_536)
                        budget.lookup=allowance
                        let fits=surface(probe,inkLuminance,&budget)
                        budget.surface -= allowance-budget.lookup; budget.lookup=previous
                        guard fits,abs(measured.live.midX-anchor.x)<=1.5,abs(measured.live.midY-anchor.y)<=1.5,accept() else { continue }
                        accepted=true
                        let spent=max(1,(savedType-budget.type)*64+savedSurface-budget.surface+savedExterior-budget.exterior)
                        return Result(candidate:candidate,profile:p,originalBad:original.bad,originalFont:input.font,attempts:attempts,spent:spent)
                    }
                }
            }
        }
        return nil
    }

    /// Literal late caller: only captured snap members receive repair; the trial
    /// must not increase either page style conflicts or its combined row conflicts.
    static func afterCohort<Identifier: Hashable>(members: [Identifier],
        harmonyRows: [[Identifier]], sourceRows: [[Identifier]],
        pageConflicts: @escaping () -> Int, rowConflicts: @escaping ([[Identifier]]) -> Int,
        repair: (Identifier, () -> Bool) throws -> Bool) -> Int {
        var accepted = 0
        for id in members {
            let rows=(harmonyRows+sourceRows).filter{$0.contains(id)}
            let beforePage=pageConflicts(), beforeRows=rowConflicts(rows)
            do {
                if try repair(id,{pageConflicts()<=beforePage && rowConflicts(rows)<=beforeRows}) { accepted += 1 }
            } catch { /* Original caller isolates one failed entry and continues. */ }
        }
        return accepted
    }
}
