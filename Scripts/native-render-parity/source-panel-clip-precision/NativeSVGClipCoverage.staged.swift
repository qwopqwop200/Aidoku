import CoreGraphics

/// Pinned SVG PathStream coordinate transport. This is an external proof helper,
/// not an app implementation or a guess about the last CSS producer.
enum NativeSVGClipCoverageProof {
    enum Commands { case absoluteHVH, relativeHVH }

    static func vertices(piece: CGRect, owner: CGRect, snappedOwner: CGRect, commands: Commands) -> [CGPoint]? {
        let input = [piece.minX,piece.minY,piece.width,piece.height,owner.minX,owner.minY,snappedOwner.minX,snappedOwner.minY]
        guard input.allSatisfy({ $0.isFinite && Float($0).isFinite }), piece.width > 0, piece.height > 0 else { return nil }
        // JS emits local command coordinates as Double strings. The SVG source
        // parser stores each argument in Float before normalized accumulation.
        let x = Float(piece.minX-owner.minX), y = Float(piece.minY-owner.minY)
        let local: [(Float,Float)]
        switch commands {
        case .absoluteHVH:
            let right = Float(piece.minX+piece.width-owner.minX)
            let bottom = Float(piece.minY+piece.height-owner.minY)
            local = [(x,y),(right,y),(right,bottom),(x,bottom)]
        case .relativeHVH:
            let width = Float(piece.width), height = Float(piece.height)
            let right = x+width, bottom = y+height
            // A relative reverse h command does not reassign the original M.x.
            let reversed = right+(-width)
            local = [(x,y),(right,y),(right,bottom),(reversed,bottom)]
        }
        // AffineTransform.mapPoint uses Double then narrows its FloatPoint.
        // The snapped reference-box origin is itself a FloatPoint.
        let ox = Double(Float(snappedOwner.minX)), oy = Double(Float(snappedOwner.minY))
        return local.map { p in CGPoint(x:CGFloat(Float(Double(p.0)+ox)),y:CGFloat(Float(Double(p.1)+oy))) }
    }

    static func path(pieces: [CGRect], owner: CGRect, snappedOwner: CGRect, commands: Commands) -> CGPath? {
        let path = CGMutablePath()
        for piece in pieces {
            guard let points = vertices(piece:piece,owner:owner,snappedOwner:snappedOwner,commands:commands) else { return nil }
            path.move(to:points[0])
            for point in points.dropFirst() { path.addLine(to:point) }
            path.closeSubpath()
        }
        return path
    }
}
