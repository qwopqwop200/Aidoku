import Foundation
import CoreGraphics

extension NativeParagraphFragmentGrouping {
    @TaskLocal static var relationObserver: (@Sendable ([ReaderTranslationRegion], [TextScope]) -> Void)?
    @TaskLocal static var relationDecisionObserver: (@Sendable (String, [String]) -> Void)?
    /// Reconcile overlapping ownership and interrupted columns using source
    /// geometry and RF support, before the single provider request.
    static func reconcilingObservations(_ original: [ReaderTranslationRegion], scopes: [TextScope], balloons: [TextScope] = [],
                                       didCoalesce: (([String]) -> Void)? = nil,
                                       didSplit: ((String, [ReaderTranslationRegion]) -> Void)? = nil) -> [ReaderTranslationRegion] {
        if simpleGroupingEnabled {
            let result = simpleResult(original, scopes: scopes, balloons: balloons, didCoalesce: didCoalesce)
            relationDecisionObserver?("simple-"+result.outcome.rawValue, original.map(\.id))
            relationObserver?(result.regions, scopes + balloons.map { .init(owner: -$0.owner-1, box: $0.box, confidence: $0.confidence) })
            return result.regions
        }
        return incumbentReconcilingObservations(original, scopes: scopes, balloons: balloons,
            didCoalesce: didCoalesce, didSplit: didSplit)
    }

    static func incumbentReconcilingObservations(_ original: [ReaderTranslationRegion], scopes: [TextScope], balloons: [TextScope] = [],
                                       didCoalesce: (([String]) -> Void)? = nil,
                                       didSplit: ((String, [ReaderTranslationRegion]) -> Void)? = nil) -> [ReaderTranslationRegion] {
        guard validSourceInput(original, scopes: scopes) else { return original }
        var observations = original.map { observingSource($0) }
        var boundaries: [SourceSeparation] = []
        let packetCount = original.compactMap { $0.acceptedSource.membership?.table.packets.count }.max() ?? original.count
        // Canonical aliases and a first merge can expose the missing middle of
        // a column. Close over those source revisions rather than requiring a
        // second external invocation. Proven physical splits remain cannot-links.
        for _ in 0...(packetCount*2+original.count) {
            let next = reconcilingPrimaryObservations(observations, scopes: scopes,
                priorSeparations:boundaries,recordSeparations:{ discovered in
                    for separation in discovered where !boundaries.contains(where:{
                        $0.table === separation.table && Set($0.parts) == Set(separation.parts)
                    }) { boundaries.append(separation) }
                },didCoalesce:didCoalesce,didSplit:didSplit)
            if revisionKeys(next) == revisionKeys(observations) { observations = next;break }
            observations = next.map { observingSource($0.region) }
        }
        observations = completingAlignedParagraphs(observations, scopes: scopes, balloons: balloons,
                                                   separations: boundaries, didCoalesce: didCoalesce)
        let result = observations.map { observation in
                var region = observation.region
                // A retained composite can carry an obsolete aggregate angle even
                // when this pass neither joins nor splits its physical sources.
                if let membership = region.acceptedSource.membership, membership.body.count > 1 {
                    preservingOriginalAngle(&region)
                }
                return region
            }
        relationObserver?(result, scopes + balloons.map { .init(owner: -$0.owner-1, box: $0.box, confidence: $0.confidence) })
        return result
    }


    private static func validSourceInput(_ original: [ReaderTranslationRegion], scopes: [TextScope]) -> Bool {
        (1...256).contains(original.count) && Set(original.map(\.id)).count == original.count &&
            original.allSatisfy { $0.translation == nil && !$0.rect.isEmpty && !$0.rect.isNull &&
                [$0.rect.minX, $0.rect.minY, $0.rect.maxX, $0.rect.maxY].allSatisfy(\.isFinite) &&
                ($0.sourceImageAspectRatio.map { $0.isFinite && $0 > 0 } ?? true) } && scopes.count <= 1024
    }

    /// Bind each source revision to its immutable exact-read proof, including failed proofs.
    private static func observingSource(_ region: ReaderTranslationRegion, read: PrimaryRead? = nil) -> ObservedSource {
        let read = read ?? primarySequence(region)
        return (region, read, read.flatMap { projectedPacketInventory($0.1, table: $0.0.table) }, nil)
    }

    private typealias ObservedSource = (region: ReaderTranslationRegion, read: PrimaryRead?,
                                       packets: [PacketObservation]?, scope: TextScope?)

    private struct RevisionKey: Equatable {
        let table: ObjectIdentifier?
        let body: [Int]
        let readings: [Int]
        let unknown: [Int]
        let source: String
        let rect: CGRect
    }

    private static func revisionKeys(_ sources:[ObservedSource]) -> [RevisionKey] {
        sources.map { source in
            let m=source.region.acceptedSource.membership
            return .init(table:m.map { ObjectIdentifier($0.table) },body:m?.body.sorted() ?? [],
                readings:m?.readings.sorted() ?? [],unknown:m?.unknownDedup.sorted() ?? [],
                source:source.region.source,rect:source.region.rect)
        }
    }

    /// A proved original partition is a cannot-link constraint on physical
    /// packets, not display IDs. Keep it across both graph passes and indirect
    /// joins through a third source.
    private typealias SourceSeparation = (table: NativeOCRAcceptedSource.PacketTable, parts: [Set<Int>])

    /// A common native contour is an identity of its measured boundary, not
    /// merely intersecting/containing envelopes or RF text co-membership.
    private static func sameVerifiedBalloon(_ a: ReaderTranslationRegion, _ b: ReaderTranslationRegion) -> Bool {
        guard let x = a.balloonInterior, let y = b.balloonInterior,
              x.contourVerified == true, y.contourVerified == true else { return false }
        return x.rect == y.rect && x.spans == y.spans
    }

    /// A source without its own contour can still lie completely inside a
    /// neighbor's measured paper runs. RF/model envelopes are not this proof.
    private static func sharedMeasuredInterior(_ a:ReaderTranslationRegion,_ b:ReaderTranslationRegion) -> Bool {
        func contains(_ host:ReaderTranslationRegion,_ guest:ReaderTranslationRegion) -> Bool {
            guard let interior=host.balloonInterior,interior.contourVerified == true,
                  interior.rect.contains(guest.rect),interior.spans.count >= 4,interior.spans.count%2 == 0 else { return false }
            let bands=interior.spans.count/2
            let start=max(0,Int(floor((guest.rect.minY-interior.rect.minY)/interior.rect.height*CGFloat(bands))))
            let end=min(bands-1,Int(floor((guest.rect.maxY-interior.rect.minY)/interior.rect.height*CGFloat(bands))))
            guard start <= end else { return false }
            return (start...end).allSatisfy { i in
                interior.spans[i*2] >= 0 && Double(guest.rect.minX) >= interior.spans[i*2] &&
                    Double(guest.rect.maxX) <= interior.spans[i*2+1]
            }
        }
        return sameVerifiedBalloon(a,b) || contains(a,b) || contains(b,a)
    }

    /// Adjacent samples of one physical column can have different RF query
    /// winners. A sub-em interruption and a common RF scope preserve that lane.
    private static func coherentColumn(_ a:CGRect,_ b:CGRect,gap:CGFloat=0.75) -> Bool {
        let glyph=min(a.width,b.width)
        return glyph > 0 && max(a.width,b.width) <= glyph*3 &&
            max(a.height,b.height) >= max(a.width,b.width)*2 &&
            min(a.maxX,b.maxX)-max(a.minX,b.minX) >= glyph*0.75 &&
            max(a.minY,b.minY)-min(a.maxY,b.maxY) <= max(a.width,b.width)*gap
    }

    private static func complementaryQuote(_ a:String,_ b:String) -> Bool {
        let pairs:[Character:Character]=["「":"」","『":"』","“":"”"]
        return pairs.contains { opening,closing in
            let first=a.filter { $0 == opening || $0 == closing }
            let second=b.filter { $0 == opening || $0 == closing }
            return first == String(opening) && second == String(closing)
        }
    }

    private static func closedUtterance(_ text:String) -> Bool {
        guard let last=text.last(where:{ !$0.isWhitespace && $0 != "♡" && $0 != "♥" }) else { return false }
        return "。.!?！？…」』".contains(last)
    }

    private static func opensUtterance(_ text:String) -> Bool {
        guard let first = text.first(where:{ !$0.isWhitespace }) else { return false }
        return "「『“\"".contains(first)
    }

    private static func hasOpenQuotation(_ source:String) -> Bool {
        let pairs:[Character:Character]=["「":"」","『":"』","（":"）","(":")","“":"”"]
        var stack:[Character]=[]
        for c in source {
            if let closing=pairs[c] { stack.append(closing) }
            else if stack.last == c { stack.removeLast() }
        }
        return !stack.isEmpty
    }

    private static func paragraphBoundarySeparations(_ sources:[ObservedSource],scopes:[TextScope]) -> [SourceSeparation] {
        var result:[SourceSeparation]=[]
        for i in sources.indices { for j in sources.indices where j > i {
            // Persist measured owner separation on the immutable packets.
            // A later sourceRevision deliberately drops aggregate balloon
            // metadata; losing that display field must not erase this proof.
            if let x = sources[i].region.balloonInterior, let y = sources[j].region.balloonInterior,
               x.contourVerified == true, y.contourVerified == true,
               x.rect != y.rect || x.spans != y.spans,
               let a = sourceMembership(sources[i].region), let b = sourceMembership(sources[j].region), a.table === b.table {
                result.append((a.table, [a.body, b.body]))
                continue
            }
            if let a=sourceMembership(sources[i].region),let b=sourceMembership(sources[j].region),a.table === b.table,
               let aa=projectedPacketInventory(a.body,table:a.table),let bb=projectedPacketInventory(b.body,table:b.table),
               aa.contains(where:{ x in bb.contains { independentInlineLabels(x.raw,$0.raw) } }) {
                result.append((a.table,[a.body,b.body]))
                continue
            }
            if opensUtterance(sources[i].region.source), opensUtterance(sources[j].region.source),
               let a = sourceMembership(sources[i].region), let b = sourceMembership(sources[j].region), a.table === b.table {
                var continuation = false
                if let aa = projectedPacketInventory(a.body,table:a.table),
                   let bb = projectedPacketInventory(b.body,table:b.table),
                   let frame = sourceAlignmentFrame(aa+bb,table:a.table) {
                    let x = pointBounds(aa.flatMap(\.polygon).map { $0.applying(frame) })
                    let y = pointBounds(bb.flatMap(\.polygon).map { $0.applying(frame) })
                    let glyph = min(x.width,y.width)
                    let leading = x.minY <= y.minY ? sources[i].region.source : sources[j].region.source
                    let sameColumn=min(x.maxX,y.maxX)-max(x.minX,y.minX) >= glyph*0.75
                    var joinedGap=max(x.minY,y.minY)-min(x.maxY,y.maxY) <= glyph*2
                    if !joinedGap, sameColumn,
                       let ownerA=owningScope(sources[i].region.rect,scopes:scopes,minimumConfidence:0.25),
                       let ownerB=owningScope(sources[j].region.rect,scopes:scopes,minimumConfidence:0.25),ownerA.owner == ownerB.owner {
                        let top=x.minY<=y.minY ? x:y, bottom=x.minY<=y.minY ? y:x
                        let bridges=sources.indices.compactMap { k -> CGRect? in
                            guard k != i,k != j,let m=sourceMembership(sources[k].region),m.table === a.table,
                                  let pk=projectedPacketInventory(m.body,table:m.table),
                                  let owner=owningScope(sources[k].region.rect,scopes:scopes,minimumConfidence:0.25),owner.owner == ownerA.owner else { return nil }
                            let box=pointBounds(pk.flatMap(\.polygon).map { $0.applying(frame) })
                            guard box.minY >= top.minY,box.maxY <= bottom.maxY,
                                  min(box.maxX,top.maxX)-max(box.minX,top.minX) >= min(box.width,top.width)*0.75 else { return nil }
                            return box
                        }.sorted { $0.minY < $1.minY }
                        var end=top.maxY
                        for box in bridges where box.minY-end <= glyph*2 { end=max(end,box.maxY) }
                        joinedGap=bottom.minY-end <= glyph*2
                    }
                    continuation = hasOpenQuotation(leading) && sameColumn && joinedGap
                }
                if !continuation {
                    result.append((a.table,[a.body,b.body]))
                    continue
                }
            }
            if sameVerifiedBalloon(sources[i].region,sources[j].region) {
                if let a=sourceMembership(sources[i].region),let b=sourceMembership(sources[j].region),a.table === b.table,
                   let aa=projectedPacketInventory(a.body,table:a.table),let bb=projectedPacketInventory(b.body,table:b.table),
                   (aa+bb).allSatisfy({ $0.raw.orientation == .vertical }),
                   let frame=sourceAlignmentFrame(aa+bb,table:a.table),
                   let ownerA=owningScope(sources[i].region.rect,scopes:scopes,minimumConfidence:0.25),
                   let ownerB=owningScope(sources[j].region.rect,scopes:scopes,minimumConfidence:0.25),ownerA.owner != ownerB.owner {
                    let x=pointBounds(aa.flatMap(\.polygon).map { $0.applying(frame) })
                    let y=pointBounds(bb.flatMap(\.polygon).map { $0.applying(frame) })
                    let glyphs=(aa+bb).map { pointBounds($0.polygon.map { $0.applying(frame) }).width }.sorted()
                    if max(x.minX,y.minX) >= min(x.maxX,y.maxX),
                       abs(x.minY-y.minY) > glyphs[glyphs.count/2]*0.5 {
                        result.append((a.table,[a.body,b.body]))
                    }
                }
                continue
            }
            guard closedUtterance(sources[i].region.source) || closedUtterance(sources[j].region.source),
                  let a=sourceMembership(sources[i].region),let b=sourceMembership(sources[j].region),a.table === b.table,
                  let aa=projectedPacketInventory(a.body,table:a.table),
                  let bb=projectedPacketInventory(b.body,table:b.table),
                  aa.contains(where:{ $0.raw.orientation == .vertical }),bb.contains(where:{ $0.raw.orientation == .vertical }),
                  let frame=sourceAlignmentFrame(aa+bb,table:a.table) else { continue }
            let widths=(aa+bb).filter { $0.raw.orientation == .vertical }.map {
                pointBounds($0.polygon.map { $0.applying(frame) }).width
            }.sorted()
            let glyph=widths[widths.count/2]
            let x=pointBounds(aa.flatMap(\.polygon).map { $0.applying(frame) })
            let y=pointBounds(bb.flatMap(\.polygon).map { $0.applying(frame) })
            guard glyph > 0,max(x.minX,y.minX)-min(x.maxX,y.maxX) > glyph*0.75,
                  min(x.maxY,y.maxY)-max(x.minY,y.minY) >= min(x.height,y.height)*0.25 else { continue }
            let scale=CGAffineTransform(scaleX:1,y:CGFloat(a.table.width)/CGFloat(a.table.height))
            let inkA=pointBounds(aa.flatMap(\.ink)).applying(scale),inkB=pointBounds(bb.flatMap(\.ink)).applying(scale)
            guard !inkA.isEmpty,!inkB.isEmpty else { continue }
            let common=scopes.contains {
                owningScope(inkA,scopes:[$0],minimumConfidence:0.25) != nil &&
                    owningScope(inkB,scopes:[$0],minimumConfidence:0.25) != nil
            }
            if !common { result.append((a.table,[a.body,b.body])) }
        } }
        return result
    }

    private static func constrainedSourceGraph(_ sources: [ObservedSource], edges: [Edge],
                                               separations: [SourceSeparation]) -> ObservationGraph {
        var graph = ObservationGraph(Array(sources.indices))
        for edge in edges {
            let members = graph.groups.values.filter {
                $0.contains(edge.first) || $0.contains(edge.second)
            }.flatMap { $0 }
            // A source with no verified face cannot become a bridge between
            // two independently measured balloons. Check the entire proposed
            // component, not only the endpoints of this particular edge.
            let faces = members.compactMap { sources[$0].region.balloonInterior }.filter { $0.contourVerified == true }
            if let first = faces.first, faces.contains(where: {
                $0.rect != first.rect || $0.spans != first.spans
            }) { continue }
            let violates = separations.contains { separation in
                let packets = members.reduce(into: Set<Int>()) { result, index in
                    if let membership = sourceMembership(sources[index].region), membership.table === separation.table {
                        result.formUnion(membership.body)
                    }
                }
                return separation.parts.filter { !$0.isDisjoint(with: packets) }.count > 1
            }
            if !violates { graph.join(edge.first, edge.second) }
        }
        return graph
    }

    /// Detaching a tiny measured inline symbol repairs its current attachment;
    /// it does not prove a permanent paragraph boundary against every former
    /// neighbor. Keep actual body/body cannot-links while allowing that symbol
    /// to find its own independently aligned column in the shared RF scope.
    private static func paragraphSeparationParts(_ parts:[ObservedSource],table:NativeOCRAcceptedSource.PacketTable,
                                                 scopes:[TextScope]) -> [Set<Int>] {
        let bodies=parts.compactMap { sourceMembership($0.region)?.body }
        let all=bodies.reduce(into:Set<Int>()) { $0.formUnion($1) }
        guard let inventory=projectedPacketInventory(all,table:table),
              inventory.contains(where:{ $0.raw.orientation == .vertical }),
              let frame=sourceAlignmentFrame(inventory,table:table) else { return bodies }
        let vertical=inventory.filter { $0.raw.orientation == .vertical }
        let glyphs=vertical.map { pointBounds($0.polygon.map { $0.applying(frame) }).width }.sorted()
        let glyph=glyphs[glyphs.count/2],aspect=CGFloat(table.width)/CGFloat(table.height)
        return bodies.filter { body in
            guard body.count == 1,let id=body.first,let fragment=inventory.first(where:{ $0.raw.index == id }),
                  fragment.raw.orientation == .horizontal,fragment.raw.source.count == 1,
                  fragment.raw.source.unicodeScalars.allSatisfy({
                      CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
                  }),!fragment.ink.isEmpty else { return true }
            let local=pointBounds(fragment.ink.map { $0.applying(frame) })
            guard local.width <= glyph*1.5,local.height <= glyph*1.5 else { return true }
            let ink=pointBounds(fragment.ink).applying(.init(scaleX:1,y:aspect))
            let common=scopes.contains { scope in
                owningScope(ink,scopes:[scope],minimumConfidence:0.25) != nil && vertical.contains { packet in
                    let support=pointBounds(packet.ink).applying(.init(scaleX:1,y:aspect))
                    return !support.isEmpty && owningScope(support,scopes:[scope],minimumConfidence:0.25) != nil
                }
            }
            return !common
        }
    }

    private static func reconcilingPrimaryObservations(_ observations: [ObservedSource], scopes: [TextScope],
                                       priorSeparations: [SourceSeparation] = [],
                                       recordSeparations: (([SourceSeparation]) -> Void)? = nil,
                                       didCoalesce: (([String]) -> Void)? = nil,
                                       didSplit: ((String, [ReaderTranslationRegion]) -> Void)? = nil) -> [ObservedSource] {
        guard validSourceInput(observations.map(\.region), scopes: scopes) else { return observations }
        let internalReadings = resolvingInternalContinuationReadings(observations)
        let aliases = resolvingContainedReadings(internalReadings, scopes:scopes, didCoalesce: didCoalesce)
        let overlapping = resolvingOverlappingReadings(aliases, scopes: scopes, didCoalesce: didCoalesce)
        let resolved = columnRubyRecoveryEnabled
            ? recoveringColumnRuby(overlapping, scopes: scopes, didCoalesce: didCoalesce) : overlapping
        var separations: [SourceSeparation] = priorSeparations
        var records = resolved.flatMap { observation -> [ObservedSource] in
            let parts = separatedOriginalBlocks(observation, scopes: scopes)
            if parts.count > 1 {
                let memberships = parts.compactMap { sourceMembership($0.region) }
                if let first = memberships.first, memberships.count == parts.count,
                   memberships.allSatisfy({ $0.table === first.table }) {
                    let permanent=paragraphSeparationParts(parts,table:first.table,scopes:scopes)
                    if permanent.count > 1 { separations.append((first.table,permanent)) }
                }
                didSplit?(observation.region.id, parts.map(\.region))
            }
            return parts
        }
        guard records.count <= 256 else { return records }
        // Each RF text query supplies one scope. A unique winner above 0.8
        // remains the same unique winner in the high-confidence subset.
        for index in records.indices {
            let region = records[index].region
            let support = records[index].read.flatMap { m, _, _ -> CGRect? in
                let records = m.body.flatMap { packetEvidence(m.table, $0) }
                let core = pointBounds(projectedRunEndpoints(records, components: {
                    $0.components + ($0.candidateComponents ?? []).map(\.component)
                }) { e, x, y in
                    CGPoint(x: x / CGFloat(e.mapFullWidth), y: y / CGFloat(e.mapFullHeight))
                })
                return core.isEmpty || core.isNull ? nil : core
            } ?? region.rect
            records[index].scope = records[index].scope ?? owningScope(support, scopes: scopes, minimumConfidence: 0.25)
        }
        separations += paragraphBoundarySeparations(records,scopes:scopes)
        recordSeparations?(separations)
        let packets = modelBlockEdges(records, scopes: scopes)
        guard !packets.sources.isEmpty else {
            return coalescingWholeSources(records,scopes:scopes,separations:separations,didCoalesce:didCoalesce)
        }
        let graph = constrainedSourceGraph(records,edges:packets.sources,separations:separations)
        let groups = graph.groups
        var replacements: [Int: ObservedSource] = [:], removed = Set<Int>()
        for (_, members) in groups where members.count > 1 {
            let originals = members.map { records[$0].region }
            // Recover absent aggregate metadata only from its exact immutable read.
            // The union below still rejects incompatible detector frames or claims.
            let seeds = members.map { member -> [NativeOCRDetectorSeedEvidence]? in
                let record = records[member]
                if let seeds = record.region.detectorSeedEvidence, !seeds.isEmpty { return seeds }
                guard let membership = record.read?.0 else { return record.region.detectorSeedEvidence }
                return NativeOCRDetectorSeedEvidence.preservingUnion(
                    membership.body.union(membership.readings).sorted().map { membership.table.packets[$0].detectorSeedEvidence })
            }
            let union = NativeOCRDetectorSeedEvidence.preservingUnion(seeds)
            guard union != nil || seeds.allSatisfy({ $0?.isEmpty ?? true }) else { continue }
            // Every relation uses the immutable packet DAG below. Source
            // ordering here only selects the stable display owner.
            let sources = members.sorted {
                records[$0].region.rect.minY != records[$1].region.rect.minY ? records[$0].region.rect.minY < records[$1].region.rect.minY : $0 < $1
            }
            guard let owner = sources.first else { continue }
            guard let packetSource = orderedPrimarySource(sources.map { records[$0] }, precedence: packets.order) else { continue }
            // Preserve an existing containing envelope verbatim rather
            // than perturb its edges through normalized union round trips.
            let box = originals.first(where: { envelope in
                originals.allSatisfy { envelope.rect.contains($0.rect) }
            })?.rect ?? originals.map(\.rect).reduce(CGRect.null) { $0.union($1) }
            let primary = records[owner].region
            var body = sourceRevision(primary, rect: box, source: packetSource.source)
            body.confidence = sources.map { records[$0].region.confidence }.min() ?? primary.confidence
            body.sourceOrientation = originals.allSatisfy { $0.sourceOrientation == .horizontal } ? .horizontal : .vertical
            body.unitMemberRects = originals.flatMap { $0.unitMemberRects.isEmpty ? [$0.rect] : $0.unitMemberRects }
            body.auxiliaryInkRects = originals.flatMap(\.auxiliaryInkRects)
            body.auxiliaryInkPolygons = originals.flatMap(\.auxiliaryInkPolygons) + originals.filter { $0.id != body.id }.map(\.polygon)
            body.detectorSeedEvidence = union
            body.acceptedSource = .union(originals.map(\.acceptedSource))
            preservingOriginalAngle(&body)
            body.sourceOCRAlternatives = originals.flatMap(\.sourceOCRAlternatives)
            body.isRecoveredLine = originals.contains { $0.isRecoveredLine }
            if let membership = sourceMembership(body), membership.unknownDedup.isEmpty,
               membership.table === records[owner].read?.0.table, membership.body == Set(packetSource.ids) {
                replacements[owner] = observingSource(body, read: (membership, packetSource.ids, packetSource.chunks))
            } else {
                replacements[owner] = observingSource(body)
            }
            removed.formUnion(members.filter { $0 != owner })
            didCoalesce?(members.map { records[$0].region.id })
        }
        let retained=records.indices.compactMap { replacements[$0] ?? (removed.contains($0) ? nil : records[$0]) }
        return coalescingWholeSources(retained,scopes:scopes,separations:separations,didCoalesce:didCoalesce)
    }

    /// Fresh source revision: carry page/order metadata, never stale translation or lineage.
    private static func sourceRevision(_ primary: ReaderTranslationRegion, id: String? = nil,
                                       rect: CGRect, source: String) -> ReaderTranslationRegion {
        .init(id: id ?? primary.id, rect: rect, source: source,
              polygon: [.init(x: rect.minX, y: rect.minY), .init(x: rect.maxX, y: rect.minY),
                        .init(x: rect.maxX, y: rect.maxY), .init(x: rect.minX, y: rect.maxY)],
              sourceImageAspectRatio: primary.sourceImageAspectRatio,
              translationOrder: primary.translationOrder, translationOrderVersion: primary.translationOrderVersion,
              sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
    }

    /// Re-enclose immutable original quads in their common baseline frame.
    /// The display envelope may rotate; packet geometry and erasure evidence do not.
    static func preservingOriginalAngle(_ region: inout ReaderTranslationRegion, useLayout: Bool = true) {
        guard let m = region.acceptedSource.membership, !m.body.isEmpty else { return }
        let packets = m.body.sorted().map { m.table.packets[$0] }
        func shape(_ packet: NativeOCRAcceptedSource.Packet) -> [CGPoint] {
            useLayout ? packet.groupingPolygon : packet.polygon
        }
        guard packets.allSatisfy({ shape($0).count == 4 }) else { return }
        let width = CGFloat(m.table.width), height = CGFloat(m.table.height)
        // An inline horizontal OCR fragment (often a punctuation rail) cannot
        // rotate an otherwise vertical paragraph's envelope. Use the body's
        // dominant reading orientation; retain ALL packet points below.
        let horizontal = packets.allSatisfy { $0.orientation == .horizontal }
        let aligned = packets.filter { horizontal ? $0.orientation == .horizontal : $0.orientation == .vertical }
        let direction = aligned.reduce(CGPoint.zero) { value, packet in
            let p = shape(packet)
            // Opposite edges describe axes, not directed starting corners.
            // Select the short side for vertical text and the long side for
            // horizontal text, independently of cyclic/reversed point order.
            let a = CGPoint(x: (p[1].x-p[0].x+p[2].x-p[3].x)/2,
                            y: (p[1].y-p[0].y+p[2].y-p[3].y)/2)
            let b = CGPoint(x: (p[2].x-p[1].x+p[3].x-p[0].x)/2,
                            y: (p[2].y-p[1].y+p[3].y-p[0].y)/2)
            let la = hypot(a.x,a.y), lb = hypot(b.x,b.y)
            let edge = horizontal ? (la >= lb ? a : b) : (la <= lb ? a : b)
            let length = hypot(edge.x,edge.y)
            guard length > 0 else { return value }
            // Axial (double-angle) averaging is invariant to edge reversal.
            // Long body columns carry more evidence than short inline marks.
            let weight = max(la,lb)
            return CGPoint(x:value.x+weight*(edge.x*edge.x-edge.y*edge.y)/(length*length),
                           y:value.y+weight*2*edge.x*edge.y/(length*length))
        }
        guard width > 0, height > 0, hypot(direction.x, direction.y) > 0 else { return }
        let angle = atan2(direction.y, direction.x)/2, frame = CGAffineTransform(rotationAngle: -angle)
        let quads = packets.flatMap { shape($0) }
        let box = pointBounds(quads.map { $0.applying(frame) })
        let inverse = frame.inverted()
        let points = packets.count == 1 ? shape(packets[0]) :
            [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
             CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].map { $0.applying(inverse) }
        region.polygon = points.map { .init(x: $0.x / width, y: $0.y / height) }
        // rect remains the stable source envelope; polygon carries rotation.
        if packets.allSatisfy({ $0.orientation == .horizontal }) { region.sourceOrientation = .horizontal }
    }

    /// A complete expanded read can be joined with its own original fragments
    /// before reconciliation. Keep the original leading read as body evidence;
    /// an exactly accounted downstream fragment is an alternative of that read.
    /// This requires disjoint complete detector records, not bbox containment alone.
    private static func resolvingInternalContinuationReadings(_ observations: [ObservedSource]) -> [ObservedSource] {
        observations.map { observation in
            guard let (m, sequence, chunks) = observation.read, m.unknownDedup.isEmpty else { return observation }
            var aliases = Set<Int>()
            for full in sequence {
                let complete = packetEvidence(m.table, full)
                guard complete.count >= 2 else { continue }
                let parts = sequence.filter { id in
                    let evidence = packetEvidence(m.table, id)
                    return id != full && !evidence.isEmpty && evidence.count < complete.count && evidence.allSatisfy(complete.contains)
                }
                guard parts.count >= 2 else { continue }
                let records = parts.flatMap { packetEvidence(m.table, $0) }
                guard records.count == complete.count,
                      records.sorted(by: { $0.ownerID < $1.ownerID }) == complete.sorted(by: { $0.ownerID < $1.ownerID }) else { continue }
                let polygon = m.table.packets[full].polygon
                guard polygon.count == 4 else { continue }
                let edges = polygon.indices.map { i in
                    CGPoint(x: polygon[(i+1)%4].x-polygon[i].x, y: polygon[(i+1)%4].y-polygon[i].y)
                }
                guard let axis = edges.max(by: { hypot($0.x,$0.y) < hypot($1.x,$1.y) }), hypot(axis.x,axis.y) > 0 else { continue }
                let frame = CGAffineTransform(rotationAngle: -atan2(axis.y,axis.x))
                let whole = pointBounds(polygon.map { $0.applying(frame) }), glyph = whole.height
                guard glyph > 0, whole.width >= glyph*2 else { continue }
                let boxes = Dictionary(uniqueKeysWithValues: parts.map { id in
                    (id, pointBounds(m.table.packets[id].polygon.map { $0.applying(frame) }))
                })
                guard boxes.values.allSatisfy({ whole.insetBy(dx: -glyph*0.5,dy: -glyph*0.5).contains($0) }) else { continue }
                let anchors = parts.filter { id in
                    let box = boxes[id]!
                    return min(abs(box.minX-whole.minX),abs(box.maxX-whole.maxX)) <= glyph*0.5
                }
                guard anchors.count == 1, let anchor = anchors.first else { continue }
                let leading = abs(boxes[anchor]!.minX-whole.minX) <= glyph*0.5
                for id in parts where id != anchor {
                    let box = boxes[id]!
                    let offset = leading ? box.minX-whole.minX : whole.maxX-box.maxX
                    // Complete shared detector records alone can also describe a
                    // distinct short reaction. Require a literal lexical suffix
                    // of the selected read, not punctuation-only agreement.
                    let alternate = Array(m.table.packets[id].text)
                    let selected = Array(m.table.packets[full].text)
                    let common = zip(alternate.reversed(),selected.reversed()).prefix { $0 == $1 }.map { $0.0 }
                    let lexical = common.contains { $0.isLetter || $0.isNumber }
                    if offset > glyph, lexical, common.count*2 >= alternate.count { aliases.insert(id) }
                }
            }
            guard !aliases.isEmpty, aliases.isSubset(of: m.body), !aliases.contains(sequence.first!) else { return observation }
            var literal = zip(sequence,chunks).filter { !aliases.contains($0.0) }
            guard !literal.isEmpty else { return observation }
            if aliases.contains(sequence.last!) {
                guard let tail = packetRemainder(chunks.last!,word:m.table.packets[sequence.last!].text) else { return observation }
                literal[literal.count-1].1 = (String(literal.last!.1)+String(tail))[...]
            }
            let original = observation.region
            var region = sourceRevision(original,rect:original.rect,source:literal.map(\.1).joined())
            region.polygon = original.polygon
            region.sourceOrientation = original.sourceOrientation
            region.sourceSingleVerticalColumn = original.sourceSingleVerticalColumn
            region.balloonInterior = original.balloonInterior
            region.auxiliaryInkRects = original.auxiliaryInkRects
            region.auxiliaryInkPolygons = original.auxiliaryInkPolygons
            region.unitMemberRects = original.unitMemberRects
            region.detectorSeedEvidence = original.detectorSeedEvidence
            region.sourceOCRAlternatives = original.sourceOCRAlternatives
            region.isRecoveredLine = original.isRecoveredLine
            region.isOccludedFinePrint = original.isOccludedFinePrint
            region.keepsClassifiedSFXSource = original.keepsClassifiedSFXSource
            region.rendersUnchangedSymbols = original.rendersUnchangedSymbols
            let retained = m.body.subtracting(aliases)
            region.acceptedSource = .init(.init(table:m.table,body:retained,readings:m.readings.union(aliases),
                unknownDedup:[],hasUntrackedInputs:false))
            region.confidence = retained.map { m.table.packets[$0].score }.min() ?? region.confidence
            return observingSource(region,read:(region.acceptedSource.membership!,literal.map(\.0),literal.map(\.1)))
        }
    }

    /// An already selected original read can overlap other original reads
    /// in another paragraph. Reconcile only an exact partition of its immutable
    /// valid detector records. Keep differing transcriptions as readings;
    /// alternative OCR spelling never replaces the already selected source.
    /// Never append the same physical glyphs twice or fabricate a fresh read.
    private static func resolvingOverlappingReadings(_ observations: [ObservedSource], scopes: [TextScope],
        didCoalesce: (([String]) -> Void)?) -> [ObservedSource] {
        var output = observations, removed = Set<Int>()
        // Canonicalize surviving sources here; peer queries certify their own complete reads.
        for i in observations.indices where !removed.contains(i) {
            guard let m = output[i].read?.0 ?? sourceMembership(output[i].region), m.unknownDedup.isSubset(of: m.body),
                  m.table.packets.count <= 4096 else { continue }
            // The cached read already certifies this canonical membership and unchanged source.
            output[i].region.acceptedSource = .init(m)
            let selected = output[i].region
            let preferred = m.body.subtracting(m.unknownDedup)
            guard preferred.count == 1, let full = preferred.first,
                  selected.source == m.table.packets[full].text, !selected.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let table = m.table
            guard let evidence = NativeOCRDetectorSeedEvidence.preservingUnion([packetEvidence(table, full)]) else { continue }
            let peers = output.indices.compactMap { j -> (Int, PrimaryRead, Set<Int>)? in
                guard j != i, !removed.contains(j),
                      let read = output[j].read,
                      read.0.table === table, read.0.body.isDisjoint(with: m.body.union(m.readings)) else { return nil }
                let overlaps = read.0.body.filter { id in
                    let part = packetEvidence(table, id)
                    return !part.isEmpty && part.allSatisfy(evidence.contains)
                }
                return !overlaps.isEmpty && overlaps.count < read.0.body.count ? (j, read, overlaps) : nil
            }
            guard peers.count == 1, let (j, read, overlaps) = peers.first else { continue }
            let (n, sequence, chunks) = read, alternatives = overlaps.union(m.unknownDedup)
            let parts = alternatives.sorted().map { packetEvidence(table, $0) }
            // The complete selected inventory is already validated. Exact record
            // equality proves both coverage and absence of repeated owners.
            guard parts.allSatisfy({ !$0.isEmpty }),
                  parts.flatMap({ $0 }).sorted(by: { $0.ownerID < $1.ownerID }) == evidence else { continue }
            // Convert original width-normalized geometry using its immutable page frame.
            let aspect = CGFloat(table.width) / CGFloat(table.height)
            var chosen = selected
            chosen.sourceImageAspectRatio = Double(aspect)
            chosen.acceptedSource = .init(.init(table: table, body: preferred, readings: m.readings.union(m.unknownDedup),
                unknownDedup: [], hasUntrackedInputs: false))
            // Project certified literal slices once. A removed final packet
            // leaves only trailing formatting; retained slices stay intact.
            var literal = zip(sequence, chunks).filter { !overlaps.contains($0.0) }
            if overlaps.contains(sequence.last!) {
                let tail = packetRemainder(chunks.last!, word: table.packets[sequence.last!].text)!
                literal[literal.count - 1].1 = (String(literal.last!.1) + String(tail))[...]
            }
            let text = literal.map(\.1).joined()
            let retained = n.body.subtracting(overlaps)
            guard let units = projectedPacketInventory(retained, table: table)?.map(\.raw) else { continue }
            let box = units.map(\.box).reduce(CGRect.null) { $0.union($1) }.applying(.init(scaleX: 1, y: aspect))
            var peer = sourceRevision(output[j].region, rect: box, source: text)
            peer.acceptedSource = .init(.init(table: table, body: retained, readings: n.readings.union(overlaps),
                unknownDedup: [], hasUntrackedInputs: false))
            peer.confidence = output[j].region.confidence; peer.sourceImageAspectRatio = Double(aspect)
            peer.sourceOrientation = output[j].region.sourceOrientation; peer.balloonInterior = output[j].region.balloonInterior
            peer.auxiliaryInkRects = output[j].region.auxiliaryInkRects
            peer.auxiliaryInkPolygons = output[j].region.auxiliaryInkPolygons + (output[j].region.polygon.isEmpty ? [] : [output[j].region.polygon])
            peer.detectorSeedEvidence = output[j].region.detectorSeedEvidence; peer.sourceOCRAlternatives = output[j].region.sourceOCRAlternatives
            peer.isRecoveredLine = output[j].region.isRecoveredLine
            peer.sourceSingleVerticalColumn = retained.count == 1
            // Preserve the original envelopes as well as all existing auxiliary
            // ink. The narrower primary reading is not an erasure-mask edit.
            peer.unitMemberRects = output[j].region.unitMemberRects.isEmpty ? [output[j].region.rect] : output[j].region.unitMemberRects
            let joined = reconcilingPrimaryObservations([observingSource(chosen, read: (chosen.acceptedSource.membership!, [full], [chosen.source[...]])),
                observingSource(peer, read: (peer.acceptedSource.membership!, literal.map(\.0), literal.map(\.1)))], scopes: scopes)
            guard joined.count == 1 else { continue }
            let originalEnvelope = selected.rect.union(output[j].region.rect), joinedBox = joined[0].region.rect
            let epsilon = [originalEnvelope.minX, originalEnvelope.maxX, originalEnvelope.minY, originalEnvelope.maxY,
                joinedBox.minX, joinedBox.maxX, joinedBox.minY, joinedBox.maxY].map(\.ulp).max()! * 4
            guard joinedBox.insetBy(dx: -epsilon, dy: -epsilon).contains(originalEnvelope) else { continue }
            output[i] = joined[0]; removed.insert(j)
            didCoalesce?([selected.id, observations[j].region.id])
        }
        return output.indices.compactMap { index in
            removed.contains(index) ? nil : output[index]
        }
    }

    /// Paragraph envelopes can hide a broken column amongst other long columns.
    /// Use immutable primary packets only when their complete token sequence
    /// accounts for each source, including formatting between whole packets.
    /// Internal insertion is not concatenation or transcription normalization.
    private static func primarySequence(_ region: ReaderTranslationRegion)
        -> PrimaryRead? {
        guard let m = sourceMembership(region),
              (1...256).contains(m.body.count) else { return nil }
        let fullText = region.source[...]
        var states = 0, exhausted = false, solutions = 0
        var result: (ids: [Int], chunks: [Substring], remaining: Set<Int>)?
        // Prefix ambiguity is not whole-source ambiguity. Accept only one complete
        // immutable packet chain; bounded search never invents or rerecognizes text.
        func visit(_ text: Substring, remaining: Set<Int>, ordered: [Int], chunks: [Substring]) {
            guard !exhausted, solutions < 2 else { return }
            states += 1
            guard states <= 4096 else { exhausted = true; return }
            if text.allSatisfy(\.isWhitespace) {
                guard !ordered.isEmpty, remaining.allSatisfy({ alternate in
                    uniqueIndex(ordered.indices) { index in
                        states += 1
                        if states > 4096 { exhausted = true; return false }
                        return coveredOriginalReading(alternate, by: ordered[index], table: m.table)
                    } != nil
                }), !exhausted else { return }
                solutions += 1
                result = (ordered, chunks, remaining)
                return
            }
            for id in remaining.sorted() {
                guard let suffix = packetRemainder(text, word: m.table.packets[id].text) else { continue }
                visit(suffix, remaining: remaining.subtracting([id]), ordered: ordered + [id],
                    chunks: chunks + [text[..<suffix.startIndex]])
            }
        }
        visit(fullText, remaining: m.body, ordered: [], chunks: [])
        guard !exhausted, solutions == 1, let result else { return nil }
        var chunks = result.chunks
        chunks[chunks.count - 1] = fullText[chunks.last!.startIndex...]
        guard m.unknownDedup.isSubset(of: result.remaining) else { return nil }
        return (.init(table: m.table, body: Set(result.ids), readings: m.readings.union(result.remaining),
            unknownDedup: [], hasUntrackedInputs: m.hasUntrackedInputs), result.ids, chunks)
    }

    /// An exact selected read already accounts for these detector records.
    /// Absorb a uniquely contained alternative without appending its OCR twice.
    private static func resolvingContainedReadings(_ observations: [ObservedSource], scopes:[TextScope],
        didCoalesce: (([String]) -> Void)?) -> [ObservedSource] {
        var output = observations, removed = Set<Int>()
        for child in observations.indices {
            guard !removed.contains(child), let read = output[child].read else { continue }
            let parents = output.indices.filter { parent in
                guard parent != child, !removed.contains(parent), let primary = output[parent].read,
                      primary.0.table === read.0.table,
                      primary.0.body.isDisjoint(with: read.0.body),
                      primary.0.body.count > read.0.body.count else { return false }
                let a = owningScope(output[child].region.rect,scopes:scopes,minimumConfidence:0.25)
                let b = owningScope(output[parent].region.rect,scopes:scopes,minimumConfidence:0.25)
                if let a, let b, a.owner != b.owner { return false }
                return read.0.body.allSatisfy { alternate in
                    primary.0.body.filter { coveredOriginalReading(alternate, by: $0, table: read.0.table) }.count == 1
                }
            }
            guard parents.count == 1, let parent = parents.first, let primary = output[parent].read else { continue }
            var region = output[parent].region
            region.acceptedSource = .init(.init(table: primary.0.table, body: primary.0.body,
                readings: primary.0.readings.union(read.0.body).union(read.0.readings),
                unknownDedup: [], hasUntrackedInputs: false))
            region.unitMemberRects += output[child].region.unitMemberRects + [output[child].region.rect]
            region.auxiliaryInkPolygons += output[child].region.auxiliaryInkPolygons + [output[child].region.polygon]
            output[parent] = observingSource(region)
            removed.insert(child)
            didCoalesce?([region.id, output[child].region.id])
        }
        return output.indices.compactMap { removed.contains($0) ? nil : output[$0] }
    }

    /// Validate the immutable source inventory; alias policy remains with each caller.
    private static func sourceMembership(_ region: ReaderTranslationRegion) -> NativeOCRAcceptedSource.Membership? {
        guard let m = region.acceptedSource.membership, !m.hasUntrackedInputs,
              m.body.isDisjoint(with: m.readings), m.table.width > 0, m.table.height > 0,
              m.body.union(m.readings).allSatisfy(m.table.packets.indices.contains) else { return nil }
        return m
    }

    private typealias PrimaryRead = (NativeOCRAcceptedSource.Membership, [Int], [Substring])

    /// Revisit unassigned singleton kana packets after the earlier balloon join.
    /// Do not relabel embedded OCR substrings: they lack independent geometry.
    /// Original packets remain immutable, and recovered rails become erase-only
    /// readings rather than additional translated text. This is not a GT edit.
    private static func recoveringColumnRuby(_ observations: [ObservedSource], scopes: [TextScope],
                                             didCoalesce: (([String]) -> Void)?) -> [ObservedSource] {
        var output = observations, removed = Set<Int>()
        for child in observations.indices {
            guard !removed.contains(child), let read = output[child].read,
                  read.0.body.count == 1, read.0.readings.isEmpty, read.0.unknownDedup.isEmpty,
                  let candidateID = read.1.first,
                  let candidate = output[child].packets?.first?.raw,
                  !packetEvidence(read.0.table, candidateID).isEmpty else { continue }
            let peers = output.indices.filter { index in
                !removed.contains(index) && index != child && output[index].read?.0.table === read.0.table
            }
            let columns = peers.flatMap { output[$0].packets ?? [] }.map(\.raw)
            guard let hostID = intercolumnRubyHost(candidate, columns: columns) else { continue }
            let owners = peers.filter { output[$0].read?.0.body.contains(hostID) == true }
            guard owners.count == 1, let parent = owners.first, let primary = output[parent].read,
                  !packetEvidence(read.0.table, hostID).isEmpty,
                  primary.0.body.union(primary.0.readings).isDisjoint(with: read.0.body) else { continue }
            // A real body glyph can be narrow enough to resemble ruby beside
            // another column. Keep it as body when its original quad continues
            // an independently retained full-size body column at its own end.
            if let own=output[child].packets?.first,
               let host=output[parent].packets?.first(where:{$0.raw.index==hostID}),
               peers.flatMap({output[$0].packets ?? []}).contains(where:{ peer in
                   peer.raw.index != candidateID && peer.raw.index != hostID &&
                   peer.raw.source.unicodeScalars.contains(where:{CharacterSet.letters.contains($0)}) &&
                   hasInlineBodyContinuation(candidate:own.polygon,continuation:peer.polygon,host:host.polygon)
               }) { continue }
            let host = output[parent].region, guest = output[child].region
            // An inter-column rail can be inside the paragraph envelope without
            // being inside either body column. Outside it, require a shared RF owner.
            let a = owningScope(host.rect, scopes: scopes, minimumConfidence: 0.25)
            let b = owningScope(guest.rect, scopes: scopes, minimumConfidence: 0.25)
            guard host.rect.contains(guest.rect) || (a != nil && a?.owner == b?.owner) else { continue }
            let seeds = NativeOCRDetectorSeedEvidence.preservingUnion([
                primary.0.body.union(primary.0.readings).sorted().flatMap { packetEvidence(read.0.table, $0) },
                packetEvidence(read.0.table, candidateID)])
            guard let seeds else { continue }
            var region = host
            region.acceptedSource = .init(.init(table: primary.0.table, body: primary.0.body,
                readings: primary.0.readings.union(read.0.body), unknownDedup: [], hasUntrackedInputs: false))
            region.detectorSeedEvidence = seeds
            region.auxiliaryInkRects += [guest.rect] + guest.auxiliaryInkRects
            region.auxiliaryInkPolygons += [guest.polygon] + guest.auxiliaryInkPolygons
            region.sourceOCRAlternatives += guest.sourceOCRAlternatives
            output[parent] = observingSource(region, read: (region.acceptedSource.membership!, primary.1, primary.2))
            removed.insert(child)
            didCoalesce?([host.id, guest.id])
        }
        return output.indices.compactMap { removed.contains($0) ? nil : output[$0] }
    }

    /// Reading aliases use shared detector observations, not text or padding.
    /// Complete validated detector records supply shared physical cell identity.
    /// All disputed glyphs must match exact runs and fit the primary envelope;
    /// primarySequence separately proves the exact source and full accounting.
    private static func coveredOriginalReading(_ alternate: Int, by primary: Int,
                                               table: NativeOCRAcceptedSource.PacketTable) -> Bool {
        let a = table.packets[alternate], b = table.packets[primary]
        let parts = packetEvidence(table, alternate), whole = packetEvidence(table, primary)
        guard parts.count == a.detectorSeedEvidence?.count, whole.count == b.detectorSeedEvidence?.count,
              !parts.isEmpty else { return false }
        if pointBounds(b.groupingPolygon).contains(pointBounds(a.groupingPolygon)), parts.allSatisfy(whole.contains) {
            return true
        }
        // Two crops can expose the same complete connected components under
        // different ownership flags. This is a reading alias, NOT permission
        // to expand a paragraph. Require exact source-grid/run equality for
        // EVERY alternate component and a strict larger primary inventory.
        let alternateCells = parts.flatMap { e in (e.components+disputedComponents(e)).map { (e,$0) } }
        let primaryCells = whole.flatMap { e in (e.components+disputedComponents(e)).map { (e,$0) } }
        if !alternateCells.isEmpty,
           Set(primaryCells.map { $0.1.seed }).count > Set(alternateCells.map { $0.1.seed }).count,
           alternateCells.allSatisfy({ e, component in
               primaryCells.contains { peer, other in
                   peer.ownerID != e.ownerID && detectorGrid(peer) == detectorGrid(e) &&
                       component.seed == other.seed && component.runs == other.runs
               }
           }) {
            return true
        }
        let ink = pointBounds(projectedRunEndpoints(parts, components: disputedComponents) { e, x, y in
            CGPoint(x: x * CGFloat(e.sourceWidth) / CGFloat(e.mapFullWidth),
                    y: y * CGFloat(e.sourceHeight) / CGFloat(e.mapFullHeight))
        })
        guard pointBounds(b.groupingPolygon).contains(ink) else { return false }
        return parts.allSatisfy { evidence in
            evidence.components.isEmpty && disputedComponents(evidence).allSatisfy { component in
                whole.contains { peer in
                    peer.ownerID != evidence.ownerID && detectorGrid(peer) == detectorGrid(evidence) &&
                        disputedComponents(peer).contains { $0.runs == component.runs }
                }
            }
        }
    }

    /// Ambiguous and candidate cells are disputed; private components stay separate.
    private static func disputedComponents(_ evidence: NativeOCRDetectorSeedEvidence) -> [NativeOCRDetectorSeedEvidence.Component] {
        (evidence.ambiguousComponents ?? []) + (evidence.candidateComponents ?? []).map(\.component)
    }

    /// Only boundary whitespace is formatting. Every character INSIDE a
    /// recorded packet must match verbatim, including its own whitespace.
    private static func packetRemainder(_ text: Substring, word: String) -> Substring? {
        guard let first = word.first else { return nil }
        let start = first.isWhitespace ? text : text.drop(while: \.isWhitespace)
        return start.hasPrefix(word) ? start.dropFirst(word.count) : nil
    }

    /// A complete immutable geometry observation, or no observation at all.
    /// IDs already belong to a validated PrimaryRead table.
    private typealias PacketObservation = (raw: Atom, polygon: [CGPoint], ink: [CGPoint])

    /// Sampling/enclosure padding is not a newly observed glyph baseline.
    /// Bound only excessive leading/trailing padding by this packet's own
    /// complete private detector runs. Keep the immutable output quad intact.
    private static func relationPolygon(_ polygon:[CGPoint], ink:[CGPoint], orientation:BrowserOCRSourceOrientation) -> [CGPoint] {
        guard polygon.count == 4,!ink.isEmpty,orientation != .unknown else { return polygon }
        let p=polygon
        let along=orientation == .horizontal
            ? CGPoint(x:p[1].x+p[2].x-p[0].x-p[3].x,y:p[1].y+p[2].y-p[0].y-p[3].y)
            : CGPoint(x:p[2].x+p[3].x-p[0].x-p[1].x,y:p[2].y+p[3].y-p[0].y-p[1].y)
        let length=hypot(along.x,along.y)
        guard length > 0 else { return polygon }
        let y=CGPoint(x:along.x/length,y:along.y/length),x=CGPoint(x:y.y,y:-y.x)
        func local(_ q:CGPoint)->CGPoint { .init(x:q.x*x.x+q.y*x.y,y:q.x*y.x+q.y*y.y) }
        let box=pointBounds(p.map(local)),core=pointBounds(ink.map(local)),glyph=box.width
        // A short reaction has no independently observed long baseline. Its
        // intentional lettering spacing must not be reinterpreted as padding.
        guard glyph > 0,!core.isEmpty,core.height >= glyph*2,box.intersects(core) else { return polygon }
        let start=core.minY-box.minY > glyph*1.5 ? core.minY-glyph*0.5:box.minY
        let end=box.maxY-core.maxY > glyph*1.5 ? core.maxY+glyph*0.5:box.maxY
        guard start < end,start != box.minY || end != box.maxY else { return polygon }
        return p.map { q in
            let v=local(q),a=min(end,max(start,v.y))
            return CGPoint(x:v.x*x.x+a*y.x,y:v.x*x.y+a*y.y)
        }
    }

    private static func projectedPacketInventory<IDs: Collection>(_ ids: IDs, table: NativeOCRAcceptedSource.PacketTable)
        -> [PacketObservation]? where IDs.Element == Int {
        var observations: [PacketObservation] = []
        for index in ids {
            let packet = table.packets[index], width = CGFloat(table.width)
            // A wider recognition window is not a newly observed paragraph
            // baseline. Layout affinity uses the independently recognized
            // baseline view while the packet retains its actual output extent.
            let sourcePolygon=packet.layoutPolygon ?? packet.polygon
            guard sourcePolygon.count >= 3 else { return nil }
            let box = pointBounds(sourcePolygon).applying(.init(scaleX: 1 / width, y: 1 / width))
            guard !box.isEmpty, !box.isNull,
                  [box.minX, box.minY, box.maxX, box.maxY].allSatisfy(\.isFinite) else { return nil }
            let polygon = sourcePolygon.map { CGPoint(x: $0.x / width, y: $0.y / width) }
            let ink = projectedRunEndpoints(packetEvidence(table, index)) { e, x, y in
                CGPoint(x: x / CGFloat(e.mapFullWidth),
                    y: y * CGFloat(e.sourceHeight) / CGFloat(e.mapFullHeight) / width)
            }
            // Weak/short stylized reactions cannot establish that their
            // intentionally loose enclosure is merely recognition padding.
            let relation=packet.score >= 0.8 ? relationPolygon(polygon,ink:ink,orientation:packet.orientation):polygon
            let raw = Atom(index:index,source:packet.text,box:pointBounds(relation),orientation:packet.orientation,owner:nil)
            observations.append((raw, relation, ink))
        }
        return observations
    }

    /// Bounds remain in the coordinate frame of the supplied points.
    private static func pointBounds(_ points: [CGPoint]) -> CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    private static func packetEvidence(_ table: NativeOCRAcceptedSource.PacketTable, _ index: Int) -> [NativeOCRDetectorSeedEvidence] {
        (table.packets[index].detectorSeedEvidence ?? []).filter {
            $0.ownershipVersion == 2 && $0.isValid &&
                $0.sourceWidth == table.width && $0.sourceHeight == table.height
        }
    }

    /// Runs already include the ROI origin and use the page's full detector grid.
    private static func detectorGrid(_ evidence: NativeOCRDetectorSeedEvidence) -> SIMD2<Int> {
        SIMD2(evidence.mapFullWidth, evidence.mapFullHeight)
    }

    /// One component index witnesses exclusive support and cross-owner contact.
    /// Raw peer claims veto exclusivity; only validated disputed claims link packets.
    private static func componentSupport(_ table: NativeOCRAcceptedSource.PacketTable) -> ComponentIncidence {
        var independent = Set<Int>()
        var disputed: [SIMD3<Int>: [Int: Set<String>]] = [:]
        for id in table.packets.indices {
            let records = packetEvidence(table, id)
            if !records.isEmpty { independent.insert(id) }
            for e in records { for c in disputedComponents(e) {
                disputed[SIMD3(e.mapFullWidth, e.mapFullHeight, c.seed), default: [:]][id, default: []].insert(e.ownerID)
            } }
        }
        for id in table.packets.indices { for e in table.packets[id].detectorSeedEvidence ?? [] {
            for c in e.components + disputedComponents(e) {
                for peer in (disputed[SIMD3(e.mapFullWidth, e.mapFullHeight, c.seed)] ?? [:]).keys where peer != id {
                    independent.remove(peer)
                }
            }
        } }
        return ComponentIncidence(independent: independent, disputed: disputed)
    }

    /// Immutable table facts; a context projects contacts without rescanning raw claims.
    private struct ComponentIncidence {
        let independent: Set<Int>
        let disputed: [SIMD3<Int>: [Int: Set<String>]]
        func contacts(within ids: Set<Int>) -> Set<SIMD2<Int>> {
            var result = Set<SIMD2<Int>>()
            for candidates in disputed.values {
                let claims = candidates.filter { ids.contains($0.key) }
                for (a, owners) in claims { for (b, peers) in claims where a < b && owners.union(peers).count > 1 {
                    result.insert(SIMD2(a, b))
                } }
            }
            return result
        }
    }




    /// The caller supplies a verified native contour; every original run must fit it.
    /// parent padding and auxiliary seed centers cannot substitute for measured cells.
    private static func maskContainsOriginalRuns(_ read: PrimaryRead?, _ contour: ReaderTranslationBalloonInterior) -> Bool {
        guard let (m, order, _) = read,
              contour.rect.width > 0, contour.rect.height > 0,
              [contour.rect.minX, contour.rect.minY, contour.rect.maxX, contour.rect.maxY].allSatisfy(\.isFinite),
              contour.spans.count >= 2, contour.spans.count <= 2048, contour.spans.count.isMultiple(of: 2),
              contour.spans.allSatisfy({ $0.isFinite && ($0 == -1 || (0...1).contains($0)) }) else { return false }
        let rows = contour.spans.count / 2
        for index in order {
            let evidence = packetEvidence(m.table, index)
            guard !evidence.isEmpty else { return false }
            for e in evidence {
                let components = e.components + disputedComponents(e)
                for component in components { for run in component.runs {
                    let y = (Double(run.y) + 0.5) / Double(e.mapFullHeight)
                    let relative = (y - Double(contour.rect.minY)) / Double(contour.rect.height)
                    guard (0..<1).contains(relative) else { return false }
                    // relative is finite in [0,1), and rows is in 1...1024.
                    let row = Int(floor(relative * Double(rows)))
                    let left = contour.spans[row * 2], right = contour.spans[row * 2 + 1]
                    // Nonempty validated runs have ordered endpoints.
                    guard left >= 0,
                          (Double(run.x) + 0.5) / Double(e.mapFullWidth) >= left,
                          (Double(run.x + run.count) - 0.5) / Double(e.mapFullWidth) <= right else { return false }
                } }
            }
        }
        return true
    }

    /// Private ink in the original source-width frame supplies both fit and start.
    /// Keep degenerate bounds: a supported raw fallback can have a measured start
    /// even when its ink cannot be fitted to the original column envelope.

    private static func columnObservations(_ inventory: [PacketObservation],
                                               frames: [CGAffineTransform] = [.identity], horizontal: Bool = false)
        -> [[Int: ColumnObservation]] {
        var observations = frames.map { _ in [Int: ColumnObservation]() }
        for packet in inventory {
            let raw = packet.raw
            for (index, frame) in frames.enumerated() {
                let native = horizontal ? Atom(index: raw.index, source: raw.source, box: raw.box.applying(frame),
                    orientation: .vertical, owner: raw.owner, sourceColumnWidth: raw.glyph) : raw
                let ink = horizontal || raw.orientation == .vertical ? pointBounds(packet.ink.map { $0.applying(frame) }) : nil
                let fitted = ink.flatMap { ink -> Atom? in
                    // Project actual polygon and run endpoints before bounding; native envelopes stay separate.
                    let box = pointBounds(packet.polygon.map { $0.applying(frame) })
                    let epsilon = max(box.minX.ulp, box.maxX.ulp, box.minY.ulp, box.maxY.ulp) * 4
                    guard !ink.isEmpty, !ink.isNull, box.insetBy(dx: -epsilon, dy: -epsilon).contains(ink) else { return nil }
                    let observed = min(box.width, max(ink.width, box.height / CGFloat(raw.source.count)))
                    let center = min(box.maxX - observed / 2, max(box.minX + observed / 2, ink.midX))
                    return Atom(index: raw.index, source: raw.source,
                        box: .init(x: center - observed / 2, y: box.minY, width: observed, height: box.height),
                        orientation: .vertical, owner: raw.owner, sourceColumnWidth: box.width)
                }
                observations[index][raw.index] = (native, ink, fitted, nil)
            }
        }
        return observations
    }

    private typealias ColumnObservation = (raw: Atom, ink: CGRect?, fitted: Atom?, unit: Atom?)



    /// Project actual raster-center endpoints before any bounds or later frame transform.
    private static func projectedRunEndpoints(_ evidence: [NativeOCRDetectorSeedEvidence],
        components: (NativeOCRDetectorSeedEvidence) -> [NativeOCRDetectorSeedEvidence.Component] = { $0.components },
        point: (NativeOCRDetectorSeedEvidence, CGFloat, CGFloat) -> CGPoint) -> [CGPoint] {
        var points: [CGPoint] = []
        for e in evidence { for component in components(e) { for run in component.runs {
            for x in [CGFloat(run.x) + 0.5, CGFloat(run.x + run.count) - 0.5] {
                points.append(point(e, x, CGFloat(run.y) + 0.5))
            }
        } } }
        return points
    }

    /// Project selected vertical packet observations into their common original-quad frame.
    /// Only geometry is projected; immutable polygons, cells and text stay unchanged.
    /// Measured ink containment and frame-envelope pitch feed the adjacency proof.
    private static func sourceAlignmentFrame(_ packets: [PacketObservation], table: NativeOCRAcceptedSource.PacketTable, horizontal: Bool = false) -> CGAffineTransform? {
        // The caller supplies a complete inventory from one validated source table.
        // An identity frame still supplies private-ink, not source-envelope, evidence.
        let columns = packets.filter { horizontal || $0.raw.orientation == .vertical }
        // Sum quad side displacements; normalize the common axis once.
        var direction = CGPoint.zero
        for atom in columns {
            let q = table.packets[atom.raw.index].groupingPolygon
            guard q.count == 4 else { return nil }
            if horizontal {
                var dx = q[1].x + q[2].x - q[0].x - q[3].x
                var dy = q[1].y + q[2].y - q[0].y - q[3].y
                // A 180-degree cyclic start is the same undirected baseline.
                // Align its sign before averaging, or mixed starts cancel and
                // turn ordinary row spacing into a spurious paragraph band.
                if direction.x*dx + direction.y*dy < 0 { dx = -dx; dy = -dy }
                direction.x += dx; direction.y += dy
            } else {
                direction.x += q[2].x + q[3].x - q[0].x - q[1].x
                direction.y += q[2].y + q[3].y - q[0].y - q[1].y
            }
        }
        let length = hypot(direction.x, direction.y)
        guard length.isFinite, length > 0 else { return nil }
        let vx = direction.x / length, vy = direction.y / length
        let frame = CGAffineTransform(a: vy, b: vx, c: -vx, d: vy, tx: 0, ty: 0)
        return frame
    }

    /// Private detector intervals certify shared writing-axis alignment.
    /// Cross-axis calibration admits a pair; otherwise independent neighbors
    /// corroborate the complete group. Reading order is proved separately.
    private static func corroboratedOriginalRows(_ sources: [ObservedSource])
        -> [Set<Int>: CGFloat] {
        typealias Span = (lo: CGFloat, hi: CGFloat, along: CGFloat, across: CGFloat)
        typealias Block = (index: Int, table: NativeOCRAcceptedSource.PacketTable, horizontal: Bool,
                           box: CGRect, calibrated: Bool, leftGlyph: CGFloat, rightGlyph: CGFloat, spans: [SIMD2<Int>: Span])
        let observations = sources.indices.compactMap { index -> Block? in
            guard let (m, _, _) = sources[index].read, let raw = sources[index].packets?.map(\.raw), !raw.isEmpty else { return nil }
            let horizontal = raw.allSatisfy { $0.orientation == .horizontal }
            guard horizontal || raw.allSatisfy({ $0.orientation == .vertical }) else { return nil }
            var common: [SIMD2<Int>: Span]?
            for id in m.body {
                let observed = Dictionary(grouping: packetEvidence(m.table, id), by: detectorGrid)
                    .compactMapValues { records -> Span? in
                        guard records.allSatisfy({ ($0.ambiguousComponents ?? []).isEmpty &&
                            ($0.candidateComponents ?? []).isEmpty }), let e = records.first else { return nil }
                        let along = horizontal ? 1 / CGFloat(e.mapFullWidth) :
                            CGFloat(e.sourceHeight) / CGFloat(e.mapFullHeight * e.sourceWidth)
                        let across = horizontal ? CGFloat(e.sourceHeight) / CGFloat(e.mapFullHeight * e.sourceWidth) :
                            1 / CGFloat(e.mapFullWidth)
                        var lo = CGFloat.infinity, hi = -CGFloat.infinity
                        for record in records { for component in record.components { for run in component.runs {
                            lo = min(lo, CGFloat(horizontal ? run.x : run.y) * along)
                            hi = max(hi, CGFloat(horizontal ? run.x + run.count : run.y + 1) * along)
                        } } }
                        return (lo, hi, along, across)
                    }
                if let previous = common {
                    common = previous.reduce(into: [:]) { result, entry in
                        if let other = observed[entry.key] {
                            result[entry.key] = (min(entry.value.lo, other.lo), max(entry.value.hi, other.hi),
                                                 entry.value.along, entry.value.across)
                        }
                    }
                } else { common = observed }
            }
            let spans = (common ?? [:]).filter { $0.value.lo.isFinite && $0.value.hi.isFinite }
            guard !spans.isEmpty else { return nil }
            let frame = horizontal ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0) : .identity
            let calibrated = raw.allSatisfy { atom in
                let along = atom.orientation == .horizontal ? atom.box.width : atom.box.height
                let advance = along / CGFloat(atom.source.count)
                return advance > atom.glyph && compatibleGlyphScale(advance, atom.glyph)
            }
            let measured = raw.map { ($0.box.applying(frame), calibrated ? lineMeasure($0) : $0.glyph) }
            return (index, m.table, horizontal, measured.map { $0.0 }.reduce(CGRect.null) { $0.union($1) }, calibrated,
                measured.min(by: { $0.0.minX < $1.0.minX })!.1,
                measured.max(by: { $0.0.maxX < $1.0.maxX })!.1, spans)
        }
        // A single interpolation anchor must explain the entire neighborhood.
        // Pairwise independently chosen start/center/end alignment is insufficient.
        func alignment(_ blocks: [Block]) -> CGFloat? {
            guard let first = blocks.first else { return nil }
            for (grid, _) in first.spans {
                let spans = blocks.compactMap { $0.spans[grid] }
                guard spans.count == blocks.count else { continue }
                let crossCalibrated = blocks.allSatisfy { $0.calibrated || $0.horizontal }
                let scale = blocks.map { min($0.leftGlyph, $0.rightGlyph) }.min()!
                let tolerance = max(spans.map(\.along).max()!, crossCalibrated ? scale * 0.25 : 0) +
                    spans.flatMap { [$0.lo.ulp, $0.hi.ulp] }.max()! * 4
                var lower: CGFloat = 0, upper: CGFloat = 1
                for i in spans.indices { for j in spans.indices where j > i {
                    let a = spans[i], b = spans[j]
                    let intercept = a.lo - b.lo, slope = (a.hi - a.lo) - (b.hi - b.lo)
                    if slope == 0 {
                        if abs(intercept) > tolerance { lower = 1; upper = 0 }
                    } else {
                        let x = (-tolerance - intercept) / slope, y = (tolerance - intercept) / slope
                        lower = max(lower, min(x, y)); upper = min(upper, max(x, y))
                    }
                } }
                if lower <= upper { return spans.map(\.across).max() }
            }
            return nil
        }
        let certificates = observations.compactMap { center -> (Set<Int>, CGFloat)? in
            let peers = observations.filter { peer in
                guard center.index != peer.index, center.table === peer.table,
                      center.horizontal == peer.horizontal, let cell = alignment([center, peer]) else { return false }
                let (left, right) = center.box.minX < peer.box.minX ? (center, peer) : (peer, center)
                return withinColumnGap(left.box.maxX, right.box.minX,
                    glyph: min(left.rightGlyph, right.leftGlyph) * (center.horizontal ? 2 : 1.5), cell: cell)
            }
            let alignedRows = center.horizontal && peers.allSatisfy {
                abs($0.box.minY - center.box.minY) <= min($0.leftGlyph, center.leftGlyph) * 0.25
            }
            guard !peers.isEmpty, peers.count > 1 || ([center] + peers).allSatisfy(\.calibrated) || alignedRows,
                  let cell = alignment([center] + peers) else { return nil }
            let members = Set(peers.map(\.index)).union([center.index])
            let owned = Dictionary(grouping: members.compactMap { sources[$0].scope?.owner }, by: { $0 }).values
            // Private head alignment must not bridge an already-owned RF block
            // into a different text query. A native contour can certify that union.
            guard !owned.contains(where: { $0.count > 1 && $0.count < members.count }) else { return nil }
            return (members, cell)
        }
        let cells = Dictionary(certificates, uniquingKeysWith: min)
        return cells
    }



    /// One original-packet graph, not a fixed read count. Native faces witness
    /// complete source glyphs independently of estimated peer margins. RF owners
    /// supply context; source inventories and original indivisibility stay explicit.
    /// Source ordinals follow reconcilingObservations; geometry comes only from packet tables.
    private static func modelBlockEdges(_ sources: [ObservedSource], scopes: [TextScope]) -> (sources: [Edge], order: [ObjectIdentifier: [Edge]]) {
        let boundaryLinks = originalBoundaryLinks(sources)
        typealias WordAttachment = (parent: Int, child: Int, anchor: Int, word: Int, following: Int?)
        var wordAttachments: [WordAttachment] = []
        for child in sources.indices where sources[child].scope == nil {
            guard let read = sources[child].read, read.1.count == 1,
                  let word = sources[child].packets?.first?.raw, word.orientation == .horizontal else { continue }
            var matches: [WordAttachment] = []
            for parent in sources.indices where parent != child && sources[parent].scope == nil {
                guard let chain = sources[parent].read, chain.0.table === read.0.table, chain.1.count > 1,
                      let words = sources[parent].packets, words.allSatisfy({ $0.raw.orientation == .horizontal }),
                      word.box.maxX > words.map({ $0.raw.box.maxX }).max()! else { continue }
                if let a = sources[parent].region.balloonInterior, let b = sources[child].region.balloonInterior,
                   a.contourVerified == true, b.contourVerified == true,
                   a.rect != b.rect || a.center != b.center || a.spans != b.spans { continue }
                for (position, packet) in words.enumerated() {
                    let a = packet.raw.box, b = word.box
                    guard b.minX >= a.midX, b.minX < a.maxX, b.maxX > a.maxX,
                          b.width <= a.width, b.height >= a.height * 0.5, b.height <= a.height,
                          b.minY >= a.minY, b.maxY <= a.maxY, abs(a.midY - b.midY) <= b.height * 0.25 else { continue }
                    matches.append((parent, child, packet.raw.index, word.index,
                        position + 1 < chain.1.count ? chain.1[position + 1] : nil))
                }
            }
            if matches.count == 1 { wordAttachments.append(matches[0]) }
        }
        let wordContexts = Set(wordAttachments.map { Set([$0.parent, $0.child]) })
        // A unique physical continuation can cross RF text-query boundaries.
        // Complete private packet runs, not the RF rectangle, certify its column.
        let singles = sources.indices.filter { source in
            sources[source].read?.1.count == 1 && sources[source].packets?.first?.raw.orientation == .vertical &&
                sources[source].packets?.first?.ink.isEmpty == false &&
                sources[source].packets!.first!.raw.box.height >= sources[source].packets!.first!.raw.box.width * 2
        }
        let verticalPairs = pairEdges(singles, index: { $0 }, reason: "private-column-context") { first, second in
            guard sources[first].read!.0.table === sources[second].read!.0.table else { return false }
            let a = sources[first].packets![0].raw, b = sources[second].packets![0].raw
            // A short heading can continue into a long column. It cannot by
            // itself establish a context with another short reaction fragment.
            guard a.box.height >= a.glyph * 3 || b.box.height >= b.glyph * 3 else { return false }
            if let a = sources[first].region.balloonInterior, let b = sources[second].region.balloonInterior,
               a.contourVerified == true, b.contourVerified == true,
               a.rect != b.rect || a.center != b.center || a.spans != b.spans { return false }
            return !columnRelations(atoms: [sources[first].packets![0].raw, sources[second].packets![0].raw]).isEmpty
        }.filter { $0.first < $0.second }
        let degrees = Dictionary(grouping: verticalPairs.flatMap { [$0.first, $0.second] }, by: { $0 }).mapValues(\.count)
        let verticalContexts = Set(verticalPairs.filter { degrees[$0.first] == 1 && degrees[$0.second] == 1 }
            .map { Set([$0.first, $0.second]) })
        let rowCells = corroboratedOriginalRows(sources)
        let native = Set(sources.compactMap { $0.region.balloonInterior }.filter { $0.contourVerified == true }.map { face in
            Set(sources.indices.filter { maskContainsOriginalRuns(sources[$0].read, face) })
        })
        let owned = sources.indices.filter { sources[$0].scope?.owner != nil && sources[$0].read != nil }
        let owners = Dictionary(grouping: owned, by: { sources[$0].scope!.owner }).values.map { Set($0) }
        // One certificate projection per exact scope; overlapping memberships remain separate keys.
        let contexts = Dictionary(uniqueKeysWithValues: native.union(rowCells.keys).union(owners).union(wordContexts).union(verticalContexts).map { members in
            let raw = native.contains(members) ? members.flatMap { sources[$0].packets?.map(\.raw) ?? [] } : nil
            func pitch(_ centers: [CGFloat]) -> CGFloat {
                let sorted = centers.sorted()
                return zip(sorted.dropFirst(), sorted).map { $0 - $1 }.max() ?? 0
            }
            return (members, (cell: rowCells[members], pitch: raw.map {
                CGSize(width: pitch($0.map { $0.box.midX }), height: pitch($0.map { $0.box.midY }))
            }))
        })
        var result: [Edge] = []
        var componentIndices: [ObjectIdentifier: ComponentIncidence] = [:]
        var order: [ObjectIdentifier: [Edge]] = [:]
        for members in contexts.keys where members.count > 1 {
            let cohort = members.sorted()
            // All context constructors admit only complete PrimaryRead entries.
            let table = sources[cohort[0]].read!.0.table
            guard cohort.allSatisfy({ sources[$0].read!.0.table === table }) else { continue }
            let ids = cohort.flatMap { sources[$0].read!.1 }
            let horizontal = ids.allSatisfy { table.packets[$0].orientation == .horizontal }
            guard ids.count <= 256, Set(ids).count == ids.count,
                  horizontal || ids.contains(where: { table.packets[$0].orientation == .vertical }) else { continue }
            // One writing frame: forward text is +Y, successive lines move toward -X.
            let frame = horizontal ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0) : .identity
            let owner = Dictionary(uniqueKeysWithValues: cohort.flatMap { member in sources[member].read!.1.map { ($0, member) } })
            let componentKey = ObjectIdentifier(table)
            if componentIndices[componentKey] == nil { componentIndices[componentKey] = componentSupport(table) }
            let componentIndex = componentIndices[componentKey]!
            let independentPackets = componentIndex.independent.intersection(ids)
            let packets = cohort.flatMap { sources[$0].packets ?? [] }
            guard packets.count == ids.count else { continue }
            let frames = [frame] + [sourceAlignmentFrame(packets, table: table, horizontal: horizontal)].compactMap { $0 }
            let observations = columnObservations(packets, frames: frames, horizontal: horizontal)
            var geometry = observations[0]
            let original = packets.map { geometry[$0.raw.index]!.raw }
            let spacing = certifiedLineStrides(original, owner: owner, sources: sources,
                contexts: contexts, members: members, horizontal: horizontal, table: table)
            let contactEvidence = componentIndex.contacts(within: Set(ids)).map {
                Edge(first: $0.x, second: $0.y, reason: "original-component-contact")
            }
            let alternative = original.compactMap { observations.last![$0.index]?.fitted }
            let unitSupport = independentPackets.union(contactEvidence.flatMap { [$0.first, $0.second] })
            // Source geometry shares one envelope and uncertain leading observation.
            // Keep packet area and leading support as a nonconvex union.
            let sourceObservations = Dictionary(grouping: original, by: { owner[$0.index]! }).mapValues { packets in
                let box = packets.map(\.box).reduce(CGRect.null) { $0.union($1) }
                let start = packets.compactMap { geometry[$0.index]?.ink }.filter { !$0.isNull && !$0.isEmpty }.map(\.minY).min()
                return (box: box, leading: start.map { CGRect(x: box.minX, y: $0, width: box.width, height: 0) } ?? box)
            }
            // Two distinct private columns anchor one source-wide raw uncertainty envelope.
            let anchors = Set(pairEdges(original.filter { $0.orientation == .vertical },
                index: { $0.index }, reason: "source-envelope-anchor") { a, b in
                guard owner[a.index] == owner[b.index], let fa = geometry[a.index]?.fitted, let fb = geometry[b.index]?.fitted,
                      max(fa.box.minX, fb.box.minX) >= min(fa.box.maxX, fb.box.maxX) else { return false }
                let overlap = max(0, min(a.box.maxY, b.box.maxY) - max(a.box.minY, b.box.minY))
                return overlap >= min(a.box.height, b.box.height) * 0.75
            }.map { owner[$0.first]! })
            // Envelope breadth beyond one packet bounds shared transverse uncertainty.
            let spread = Dictionary(uniqueKeysWithValues: cohort.map { source in
                (source, sourceObservations[source]!.box.width -
                    original.filter { owner[$0.index] == source }.map { $0.box.width }.max()!)
            })
            let envelopeSources = Set(anchors.filter { source in
                cohort.contains { peer in
                    let a = sourceObservations[source]!.box, b = sourceObservations[peer]!.box
                    return source != peer && max(a.minY, b.minY) <= min(a.maxY, b.maxY) &&
                        max(a.minX, b.minX) - min(a.maxX, b.maxX) <= min(spread[source]!, spread[peer]!)
                }
            })
            let units = original.compactMap { raw -> Atom? in
                let unit = envelopeSources.contains(owner[raw.index]!) ? raw :
                    geometry[raw.index]!.fitted ?? (unitSupport.contains(raw.index) ? raw : nil)
                geometry[raw.index]!.unit = unit
                return unit
            }
            guard units.count == ids.count else { continue }
            let contacts = contactEvidence.filter { edge in
                [geometry[edge.first]!.unit!.box, sourceObservations[owner[edge.first]!]!.leading].contains { a in
                    [geometry[edge.second]!.unit!.box, sourceObservations[owner[edge.second]!]!.leading].contains { b in
                        max(a.minX, b.minX) <= min(a.maxX, b.maxX) &&
                            max(a.minY, b.minY) <= min(a.maxY, b.maxY)
                    }
                }
            }
            let inlineWords = wordAttachments.filter { members.contains($0.parent) && members.contains($0.child) }
            var provisionalTails = Set<Edge>()
            var continuations = columnRelations(atoms: units.filter { $0.orientation == .vertical },
                measuredWidths: geometry.compactMapValues { $0.fitted?.box.width }, maximumFitRatio: 2) { upper, lower, glyph in
                let first = sourceObservations[owner[upper.index]!]!.box, second = sourceObservations[owner[lower.index]!]!.box
                let aligned = abs(first.midX - second.midX) <= min(first.width, second.width) * 0.25
                let fitted = max(geometry[upper.index]?.fitted?.box.width ?? upper.box.width,
                    geometry[lower.index]?.fitted?.box.width ?? lower.box.width)
                let tail = anchors.contains(owner[upper.index]!) &&
                    second.width <= lower.glyph * 1.6 && second.minX >= first.minX && second.maxX <= first.maxX &&
                    second.minY >= first.maxY && second.minY - first.maxY <= glyph * 2
                let wordEnd = inlineWords.contains { $0.anchor == upper.index && $0.word == lower.index }
                let containedTail = sources[owner[upper.index]!].scope?.owner != nil &&
                    sources[owner[upper.index]!].scope?.owner == sources[owner[lower.index]!].scope?.owner &&
                    second.minX >= first.minX && second.maxX <= first.maxX && second.minY >= first.maxY &&
                    second.minY - first.maxY <= glyph + max(second.minY.ulp, first.maxY.ulp, glyph.ulp) * 4 &&
                    fitted <= glyph * 2 + max(first.minX.ulp, first.maxX.ulp, second.minX.ulp, second.maxX.ulp) * 4
                if wordEnd || tail || fitted <= glyph * 1.6 && (aligned || first.intersects(second)) { return true }
                if containedTail {
                    provisionalTails.insert(.init(first: upper.index, second: lower.index, reason: "same-column-continuation"))
                }
                return containedTail
            }
            // Independent ink or direct cross-source contact admits adjacency;
            // continuation alone does not authorize unrelated neighbors.
            // A same-source ambiguity is closed only if every global claimant belongs to it.
            var claims: [SIMD3<Int>: Set<Int>] = [:]
            for id in table.packets.indices {
                for evidence in table.packets[id].detectorSeedEvidence ?? [] {
                    for component in evidence.components + disputedComponents(evidence) {
                        claims[SIMD3(evidence.mapFullWidth, evidence.mapFullHeight, component.seed), default: []].insert(id)
                    }
                }
            }
            let closedPackets = Set(ids.filter { id in
                let disputed = packetEvidence(table, id).flatMap { evidence in
                    disputedComponents(evidence).map { SIMD3(evidence.mapFullWidth, evidence.mapFullHeight, $0.seed) }
                }
                return !disputed.isEmpty && disputed.allSatisfy { key in
                    claims[key]?.allSatisfy { owner[$0] == owner[id] } == true
                }
            })
            let directAdjacency = independentPackets.union(contacts.filter { owner[$0.first] != owner[$0.second] }
                .flatMap { [$0.first, $0.second] })
            let adjacencyPackets = directAdjacency.union(closedPackets)
            // Per-source evidence chooses original envelopes or fitted ink.
            // Private starts refine adjacency; continuations retain the full span.
            let columnUnits = units.map { unit -> Atom in
                let top = geometry[unit.index]?.ink?.minY ?? .infinity
                guard top.isFinite, top >= unit.box.minY, top < unit.box.maxY else { return unit }
                return Atom(index: unit.index, source: unit.source,
                    box: CGRect(x: unit.box.minX, y: top, width: unit.box.width, height: unit.box.maxY - top),
                    orientation: unit.orientation, owner: unit.owner, sourceColumnWidth: unit.sourceColumnWidth)
            }
            let sourceUnits = units.map { Atom(index: $0.index, source: $0.source, box: $0.box,
                orientation: $0.orientation, owner: owner[$0.index], sourceColumnWidth: $0.sourceColumnWidth) }
            var columnGraph = ObservationGraph(units.map(\.index))
            columnGraph.join((columnRelations(atoms: sourceUnits) + contacts).filter { owner[$0.first] == owner[$0.second] })
            let envelopes = columnGraph.groups.values.flatMap { members in
                let box = members.compactMap { id in columnUnits.first { $0.index == id }?.box }
                    .reduce(CGRect.null) { $0.union($1) }
                return members.map { ($0, box) }
            }
            let columnEnvelopes = Dictionary(uniqueKeysWithValues: envelopes)
            let completeColumns = columnUnits.map { unit in
                let box = columnEnvelopes[unit.index]!
                return Atom(index: unit.index, source: unit.source,
                    box: CGRect(x: unit.box.minX, y: box.minY, width: unit.box.width, height: box.height),
                    orientation: unit.orientation, owner: owner[unit.index], sourceColumnWidth: unit.sourceColumnWidth)
            }
            let headAlignedColumns = pairEdges(columnUnits, index: { $0.index }, reason: "private-aligned-column-heads") { right, left in
                guard right.orientation == .vertical, left.orientation == .vertical,
                      owner[right.index] != owner[left.index],
                      let scope = sources[owner[right.index]!].scope,
                      scope.owner == sources[owner[left.index]!].scope?.owner,
                      independentPackets.contains(right.index), independentPackets.contains(left.index),
                      right.box.minX >= left.box.maxX,
                      compatibleGlyphScale(right.glyph, left.glyph) else { return false }
                let glyph = min(right.glyph, left.glyph)
                let overlap = min(right.box.maxY, left.box.maxY) - max(right.box.minY, left.box.minY)
                return abs(right.box.minY - left.box.minY) <= glyph * 0.25 &&
                    overlap >= min(right.box.height, left.box.height) * 0.9 &&
                    withinColumnGap(left.box.maxX, right.box.minX, glyph: max(right.glyph, left.glyph))
            }
            let proposedColumns = headAlignedColumns + measuredColumnEdges(atoms: columnUnits,
                alternatives: [completeColumns, frames.count > 1 && alternative.count == original.filter { $0.orientation == .vertical }.count ? alternative : []],
                allowing: adjacencyPackets.contains) { right, left, glyph in
                guard let certificate = spacing[Set([owner[right.index]!, owner[left.index]!])] else { return false }
                if let limit = certificate.limit {
                    let stride = abs(geometry[right.index]!.raw.box.midX - geometry[left.index]!.raw.box.midX)
                    return stride <= limit + certificate.cell + max(stride.ulp, limit.ulp, certificate.cell.ulp) * 4
                }
                let scope = sources[owner[right.index]!].scope?.owner
                let sharedRows = horizontal && (contexts[members]?.cell != nil ||
                    scope != nil && scope == sources[owner[left.index]!].scope?.owner)
                return withinColumnGap(left.box.maxX, right.box.minX,
                    glyph: sharedRows ? glyph * 2 : glyph, cell: certificate.cell)
            }
            let physical = columnGraph.groups.values.map { nodes in
                (source: owner[nodes[0]]!, ids: nodes, box: columnEnvelopes[nodes[0]]!)
            }
            let bySource = Dictionary(grouping: physical, by: { $0.source })
            var boundedColumns: [Edge] = []
            for (childSource, childColumns) in bySource where !horizontal && childColumns.count == 1 {
                let child = childColumns[0]
                let options = cohort.compactMap { parentSource -> Edge? in
                    guard parentSource != childSource, let parent = bySource[parentSource], parent.count > 1,
                          let scope = sources[childSource].scope, scope.owner == sources[parentSource].scope?.owner else { return nil }
                    let box = sourceObservations[parentSource]!.box
                    guard child.box.maxX <= box.minX || child.box.minX >= box.maxX else { return nil }
                    let boundary = parent.min { abs($0.box.midX - child.box.midX) < abs($1.box.midX - child.box.midX) }!
                    let childID = child.ids.max { geometry[$0]!.unit!.box.height < geometry[$1]!.unit!.box.height }!
                    let parentID = boundary.ids.max { geometry[$0]!.unit!.box.height < geometry[$1]!.unit!.box.height }!
                    let glyph = min(geometry[childID]!.unit!.glyph, geometry[parentID]!.unit!.glyph)
                    let gap = max(child.box.minX, boundary.box.minX) - min(child.box.maxX, boundary.box.maxX)
                    let contained = child.box.height <= parent.map({ $0.box.height }).max()! &&
                        child.box.minY >= box.minY - glyph * 0.75 && child.box.maxY <= box.maxY + glyph * 0.75
                    let paragraphEnvelope = child.box.minY >= box.minY - glyph * 0.25 &&
                        child.box.maxY <= box.maxY + glyph + 2 / CGFloat(table.width)
                    let leading = parent.filter { abs($0.box.minY - child.box.minY) <= glyph * 0.5 }.count * 2 > parent.count
                    let matchedExtent = min(child.box.height, boundary.box.height) >= max(child.box.height, boundary.box.height) * 0.9 &&
                        abs(child.box.minY - boundary.box.minY) <= glyph * 0.25 &&
                        spacing[Set([childSource, parentSource])]?.limit.map { abs(child.box.midX - boundary.box.midX) <= $0 } == true
                    guard adjacencyPackets.contains(childID), adjacencyPackets.contains(parentID),
                          gap <= glyph * 0.75 || matchedExtent, contained || leading || paragraphEnvelope else { return nil }
                    return Edge(first: childID, second: parentID,
                        reason: matchedExtent ? "matched-single-column-extents" : "bounded-singleton-column")
                }
                if options.count == 1 { boundedColumns.append(options[0]) }
            }
            let singleColumns = physical.filter { bySource[$0.source]!.count == 1 }.map { column in
                (column: column, id: column.ids.max { geometry[$0]!.unit!.box.height < geometry[$1]!.unit!.box.height }!,
                 glyph: column.ids.map { geometry[$0]!.unit!.glyph }.max()!)
            }
            var staggeredColumns: [Edge] = []
            for continuation in continuations where owner[continuation.first] != owner[continuation.second] {
                let tail = geometry[continuation.second]!.unit!, source = owner[tail.index]!
                guard let scope = sources[source].scope else { continue }
                let peers = singleColumns.filter { peer in
                    let box = peer.column.box
                    guard peer.column.source != source && peer.column.source != owner[continuation.first],
                          peer.column.ids.count > 1, sources[peer.column.source].scope?.owner == scope.owner,
                          adjacencyPackets.contains(tail.index), peer.column.ids.allSatisfy(adjacencyPackets.contains),
                          compatibleGlyphScale(peer.glyph, tail.glyph), box.maxX <= tail.box.minX,
                          box.minY <= tail.box.minY, box.maxY >= tail.box.maxY else { return false }
                    let cell = ([tail.index] + peer.column.ids).flatMap { packetEvidence(table, $0) }
                        .map { 1 / CGFloat($0.mapFullWidth) }.max() ?? 0
                    return withinColumnGap(box.maxX, tail.box.minX, glyph: min(peer.glyph, tail.glyph), cell: cell * 2)
                }
                if peers.count == 1 {
                    staggeredColumns.append(.init(first: tail.index, second: peers[0].id, reason: "continued-tail-adjacent-column"))
                }
            }
            // The wider tail allowance is provisional until a complete private
            // neighboring column corroborates it; a lone short tail stays separate.
            continuations.removeAll { edge in
                provisionalTails.contains(edge) && !staggeredColumns.contains { $0.first == edge.second }
            }
            let extentMatches = horizontal ? [] : pairEdges(singleColumns, index: { $0.id }, reason: "matched-single-column-extents") { a, b in
                guard a.column.box.maxX <= b.column.box.minX,
                      let scope = sources[a.column.source].scope, scope.owner == sources[b.column.source].scope?.owner,
                      !compatibleGlyphScale(a.glyph, b.glyph),
                      adjacencyPackets.contains(a.id), adjacencyPackets.contains(b.id) else { return false }
                let x = a.column.box, y = b.column.box
                return min(x.height, y.height) >= max(x.height, y.height) * 0.9 &&
                    abs(x.minY - y.minY) <= min(a.glyph, b.glyph) * 0.25 &&
                    y.minX - x.maxX <= (a.glyph + b.glyph) * 0.375
            }
            let extentDegrees = Dictionary(grouping: extentMatches.flatMap { [$0.first, $0.second] }, by: { $0 }).mapValues(\.count)
            let matchedColumns = extentMatches.filter { extentDegrees[$0.first] == 1 && extentDegrees[$0.second] == 1 }
            // A narrow interior fragment may occupy one unique measured-cadence
            // slot between normal columns. Both neighboring sources must agree;
            // the fragment cannot independently redefine their font or spacing.
            var slotColumns: [Edge] = []
            for child in singleColumns where !horizontal && adjacencyPackets.contains(child.id) {
                let options = pairEdges(physical, index: { $0.ids[0] }, reason: "cadence-interior-fragment") { left, right in
                    guard left.source != child.column.source, right.source != child.column.source,
                          left.source != right.source, left.box.maxX <= child.column.box.minX,
                          child.column.box.maxX <= right.box.minX,
                          bySource[left.source]!.count > 1 || bySource[right.source]!.count > 1,
                          let scope = sources[child.column.source].scope,
                          sources[left.source].scope?.owner == scope.owner, sources[right.source].scope?.owner == scope.owner,
                          let limit = spacing[Set([left.source, right.source])]?.limit else { return false }
                    let a = left.ids.map { geometry[$0]!.unit!.glyph }.max()!
                    let b = right.ids.map { geometry[$0]!.unit!.glyph }.max()!
                    let glyph = min(a, b), box = child.column.box
                    return compatibleGlyphScale(a, b) && child.glyph < glyph && child.glyph * 2 >= max(a, b) &&
                        abs(left.box.minY - right.box.minY) <= glyph * 0.5 &&
                        box.minY >= max(left.box.minY, right.box.minY) - glyph * 0.25 &&
                        box.maxY <= min(left.box.maxY, right.box.maxY) + glyph * 0.25 &&
                        box.midX - left.box.midX <= limit && right.box.midX - box.midX <= limit &&
                        left.ids.contains(where: adjacencyPackets.contains) && right.ids.contains(where: adjacencyPackets.contains)
                }
                if options.count == 1 {
                    slotColumns += [Edge(first: child.id, second: options[0].first, reason: "cadence-interior-fragment"),
                                    Edge(first: child.id, second: options[0].second, reason: "cadence-interior-fragment")]
                }
            }
            let columns = (proposedColumns + boundedColumns + matchedColumns + slotColumns + staggeredColumns).filter { edge in
                let first = owner[edge.first]!, second = owner[edge.second]!
                // Newly admitted fragments also need whole-paragraph boundary agreement.
                if [edge.first, edge.second].contains(where: { closedPackets.contains($0) && !directAdjacency.contains($0) }) {
                    let a = sourceObservations[first]!.box, b = sourceObservations[second]!.box
                    let scale = min(lineMeasure(geometry[edge.first]!.unit!), lineMeasure(geometry[edge.second]!.unit!))
                    guard min(abs(a.minY - b.minY), abs(a.maxY - b.maxY)) <= scale * 0.5 else { return false }
                }
                // A narrow fragment cannot redefine its whole source's font scale.
                let widths = [first, second].compactMap { source in
                    let packets = original.filter { owner[$0.index] == source }
                    return horizontal ? packets.map(\.glyph).max() : packets.compactMap { geometry[$0.index]?.fitted?.box.width }.max()
                }
                if widths.count == 2 && !compatibleGlyphScale(widths[0], widths[1]) &&
                    edge.reason != "matched-single-column-extents" && edge.reason != "cadence-interior-fragment" { return false }
                if edge.reason == "bounded-singleton-column" || edge.reason == "matched-single-column-extents" ||
                    edge.reason == "cadence-interior-fragment" || edge.reason == "continued-tail-adjacent-column" { return true }
                if first == second || sourceObservations[first]!.box.intersects(sourceObservations[second]!.box) { return true }
                guard let a = geometry[edge.first]?.ink, let b = geometry[edge.second]?.ink,
                      !a.isEmpty, !b.isEmpty, !a.isNull, !b.isNull else { return true }
                let rawA = sourceObservations[first]!.box, rawB = sourceObservations[second]!.box
                let startLow = min(rawA.minY, a.minY) - max(rawB.minY, b.minY)
                let startHigh = max(rawA.minY, a.minY) - min(rawB.minY, b.minY)
                let end = a.maxY - b.maxY
                let scale = min(lineMeasure(geometry[edge.first]!.unit!), lineMeasure(geometry[edge.second]!.unit!))
                return min(startLow, end) <= scale * (horizontal ? 0.5 : 0.25) && max(startHigh, end) >= -scale * (horizontal ? 0.5 : 0.25)
            }
            let boundaries = horizontalSourceLinks(original, inventory: packets)
            let links = columns + continuations + contacts + boundaries
            // Directed source-boundary arcs remain distinct from admission geometry.
            let wordOrder = inlineWords.flatMap { word -> [Edge] in
                [Edge(first: word.anchor, second: word.word, reason: "inline-word-after-anchor")] +
                    (word.following.map { [Edge(first: word.word, second: $0, reason: "inline-word-before-successor")] } ?? [])
            }
            order[ObjectIdentifier(table), default: []] += boundaries + wordOrder +
                continuations.filter { owner[$0.first] != owner[$0.second] }
            result += links.map { Edge(first: owner[$0.first]!, second: owner[$0.second]!, reason: $0.reason) }
        }
        for (table, edges) in boundaryLinks.order { order[table, default: []] += edges }
        let wholeNeighbors=supportedParagraphNeighbors(sources,scopes:scopes).filter {
            sources[$0.first].read != nil && sources[$0.second].read != nil
        }
        let edges = (result + boundaryLinks.sources + wholeNeighbors).filter { edge in
            guard let a = sources[edge.first].packets, let b = sources[edge.second].packets else { return true }
            if let table = sources[edge.first].read?.0.table,
               horizontalBlankBand(a,b,table:table) { return false }
            if let table = sources[edge.first].read?.0.table,
               let band=parallelParagraphBand(a+b,table:table) {
                let x=pointBounds(a.flatMap(\.polygon).map { $0.applying(band.frame) })
                let y=pointBounds(b.flatMap(\.polygon).map { $0.applying(band.frame) })
                if x.maxY <= band.low && y.minY >= band.high || y.maxY <= band.low && x.minY >= band.high { return false }
            }
            guard let table=sources[edge.first].read?.0.table else { return true }
            return !independentParagraphRows(a,b,table:table)
        }
        return (edges, order)
    }

    /// Complete private detector packets can be neighboring columns even when
    /// their paragraph starts/ends are staggered. RF supplies context only;
    /// physical adjacency and a shared reading frame still supply the edge.
    private static func supportedParagraphNeighbors(_ sources: [ObservedSource], scopes: [TextScope]) -> [Edge] {
        var edges: [Edge] = []
        // A common original private-ink baseline across at least three
        // independently RF-owned columns supplies a native paragraph proof.
        let originalRows = corroboratedOriginalRows(sources)
        for i in sources.indices { for j in sources.indices where j > i {
            guard let a=sources[i].read?.0 ?? sourceMembership(sources[i].region),
                  let b=sources[j].read?.0 ?? sourceMembership(sources[j].region), a.table === b.table,
                  a.body.isDisjoint(with:b.body),
                  let aa=sources[i].packets ?? projectedPacketInventory(a.body,table:a.table),
                  let bb=sources[j].packets ?? projectedPacketInventory(b.body,table:b.table),
                  !aa.isEmpty, !bb.isEmpty else { continue }
            if let x=sources[i].region.balloonInterior, let y=sources[j].region.balloonInterior,
               x.contourVerified == true, y.contourVerified == true,
               x.rect != y.rect || x.center != y.center || x.spans != y.spans { continue }
            let inventory=aa+bb, horizontal=inventory.allSatisfy { $0.raw.orientation == .horizontal }
            guard let frame=sourceAlignmentFrame(inventory,table:a.table,horizontal:horizontal) else { continue }
            let vertical=inventory.filter { $0.raw.orientation == .vertical }
            let reference=horizontal ? inventory : vertical
            guard !reference.isEmpty else { continue }
            let quads=reference.map { pointBounds($0.polygon.map { $0.applying(frame) }) }
            let widths=quads.map(\.width).sorted(), glyph=widths[widths.count/2]
            guard glyph > 0 else { continue }
            let left=pointBounds(aa.flatMap(\.polygon).map { $0.applying(frame) })
            let right=pointBounds(bb.flatMap(\.polygon).map { $0.applying(frame) })
            if horizontal && max(left.width,right.width) > min(left.width,right.width)*2 { continue }
            let crossGap=max(left.minX,right.minX)-min(left.maxX,right.maxX)
            let alongGap=max(left.minY,right.minY)-min(left.maxY,right.maxY)
            let crossOverlap=min(left.maxX,right.maxX)-max(left.minX,right.minX)
            let alongOverlap=min(left.maxY,right.maxY)-max(left.minY,right.minY)
            let aspect=CGFloat(a.table.width)/CGFloat(a.table.height)
            let privateA = !pointBounds(aa.flatMap(\.ink)).isEmpty
            let privateB = !pointBounds(bb.flatMap(\.ink)).isEmpty
            func support(_ observations:[PacketObservation],_ membership:NativeOCRAcceptedSource.Membership) -> [CGPoint] {
                let owned=observations.flatMap(\.ink)
                // A private singleton detector cell has zero spatial extent.
                // It cannot stand in for the entire read's support rectangle;
                // use measured disputed runs as context, without reassigning
                // their ownership or promoting them to private evidence.
                if !pointBounds(owned).isEmpty { return owned }
                return projectedRunEndpoints(membership.body.flatMap { packetEvidence(membership.table,$0) },
                    components:{ $0.components+disputedComponents($0) }) { e,x,y in
                    CGPoint(x:x/CGFloat(e.mapFullWidth),y:y*CGFloat(e.sourceHeight)/CGFloat(e.mapFullHeight*e.sourceWidth))
                }
            }
            let inkA=pointBounds(support(aa,a)).applying(.init(scaleX:1,y:aspect))
            let inkB=pointBounds(support(bb,b)).applying(.init(scaleX:1,y:aspect))
            guard !inkA.isNull,!inkB.isNull,!inkA.isEmpty,!inkB.isEmpty else { continue }
            let mixed = !horizontal && aa.contains(where:{ $0.raw.orientation == .vertical }) !=
                bb.contains(where:{ $0.raw.orientation == .vertical })
            func leadingOwner(_ local:CGRect) -> TextScope? {
                let head = CGRect(x:local.minX,y:local.minY,width:local.width,height:min(local.height,glyph*2))
                let page = pointBounds([CGPoint(x:head.minX,y:head.minY),CGPoint(x:head.maxX,y:head.minY),
                    CGPoint(x:head.maxX,y:head.maxY),CGPoint(x:head.minX,y:head.maxY)].map {
                        $0.applying(frame.inverted())
                    }).applying(.init(scaleX:1,y:aspect))
                return owningScope(page,scopes:scopes,minimumConfidence:0.25)
            }
            let ownerA = owningScope(inkA,scopes:scopes,minimumConfidence:0.25) ?? leadingOwner(left)
            let ownerB = owningScope(inkB,scopes:scopes,minimumConfidence:0.25) ?? leadingOwner(right)
            // A nested upper crop can win one source while its enclosing RF
            // query wins the rest of the same paragraph. Keep the existing
            // private-ink/column gates; winner identity alone is not a boundary.
            let nestedScope:Bool
            if let x=ownerA,let y=ownerB,x.owner != y.owner,privateA,privateB,!horizontal {
                let overlap=x.box.intersection(y.box)
                let area=min(x.box.width*x.box.height,y.box.width*y.box.height)
                let multiColumnSources=a.body.count>1 && b.body.count>1
                let witnessedHead=corroboratedInterruptedColumn(aa,host:bb,table:a.table,frame:frame,glyph:glyph) ||
                    corroboratedInterruptedColumn(bb,host:aa,table:a.table,frame:frame,glyph:glyph)
                // A complete short column can have its own nested RF query
                // alongside a longer, already observed parallel paragraph.
                // Require actual private ink and containment in one long host
                // column, rather than using the aggregate envelope alone.
                func nestedColumn(_ child: [PacketObservation], host: [PacketObservation]) -> Bool {
                    guard child.count == 1, host.count >= 2,
                          child[0].raw.orientation == .vertical, !pointBounds(child[0].ink).isEmpty else { return false }
                    let x = pointBounds(child[0].polygon.map { $0.applying(frame) })
                    return host.contains { packet in
                        guard packet.raw.orientation == .vertical, !pointBounds(packet.ink).isEmpty else { return false }
                        let y = pointBounds(packet.polygon.map { $0.applying(frame) })
                        let cell = min(x.width, y.width)
                        let gap = max(x.minX, y.minX) - min(x.maxX, y.maxX)
                        return cell > 0 && max(x.width, y.width) <= cell * 1.6 &&
                            x.height >= cell * 3 && x.height <= y.height * 0.5 &&
                            x.minY >= y.minY - cell * 0.25 && x.maxY <= y.maxY + cell * 0.25 &&
                            gap >= -cell * 0.25 && gap <= cell * 0.75
                    }
                }
                let witnessedNested = nestedColumn(aa, host: bb) || nestedColumn(bb, host: aa)
                nestedScope=area>0 && !overlap.isNull && overlap.width*overlap.height >= area*0.98 &&
                    (multiColumnSources || witnessedHead || witnessedNested)
            } else {nestedScope=false}
            let sharedScope = ownerA != nil && (ownerA?.owner == ownerB?.owner || nestedScope)
            let sameContour = sharedMeasuredInterior(sources[i].region,sources[j].region)
            let commonScope=scopes.contains {
                owningScope(inkA,scopes:[$0],minimumConfidence:0.25) != nil &&
                    owningScope(inkB,scopes:[$0],minimumConfidence:0.25) != nil
            }
            let columnContinuation = commonScope && privateA && privateB &&
                max(left.width,right.width) <= glyph*1.5 && coherentColumn(left,right)
            let quoteContinuation = commonScope && !horizontal &&
                (left.midX > right.midX ? complementaryQuote(sources[i].region.source,sources[j].region.source) :
                    complementaryQuote(sources[j].region.source,sources[i].region.source))
            let measuredRow = ownerA != nil && ownerB != nil && !horizontal &&
                abs(left.minY-right.minY) <= glyph*0.5 && crossGap >= 0 && crossGap <= glyph*1.25 &&
                originalRows.keys.contains { $0.count >= 3 && $0.contains(i) && $0.contains(j) }
            let inlineScope = mixed && scopes.contains { scope in
                // A previously aggregated source can span several RF queries.
                // Bind the inline fragment to an ORIGINAL long body packet in
                // its own RF query, not to the aggregate envelope as evidence.
                let inline = aa.contains { $0.raw.orientation == .vertical } ? inkB : inkA
                let normal = aa.contains { $0.raw.orientation == .vertical } ? aa : bb
                guard owningScope(inline,scopes:[scope],minimumConfidence:0.25) != nil else { return false }
                return normal.contains { packet in
                    let box=pointBounds(packet.polygon.map { $0.applying(frame) })
                    let ink=pointBounds(packet.ink).applying(.init(scaleX:1,y:aspect))
                    return packet.raw.orientation == .vertical && box.height >= box.width*3 &&
                        !ink.isEmpty && owningScope(ink,scopes:[scope],minimumConfidence:0.25) != nil
                }
            }
            if !privateA || !privateB {
                func cells(_ m:NativeOCRAcceptedSource.Membership) -> Set<SIMD3<Int>> {
                    Set(m.body.flatMap { id in packetEvidence(m.table,id).flatMap { e in
                        (e.components+disputedComponents(e)).map { SIMD3(e.mapFullWidth,e.mapFullHeight,$0.seed) }
                    } })
                }
                // Contested glyphs are not new private evidence. Only their
                // existing, exact shared-cell ancestry plus common RF context
                // can join them; text and contested ownership stay unchanged.
                let strongA=privateA || a.body.allSatisfy { a.table.packets[$0].score >= 0.9 }
                let strongB=privateB || b.body.allSatisfy { b.table.packets[$0].score >= 0.9 }
                let measuredOverlap=crossOverlap >= min(left.width,right.width)*0.75 &&
                    alongOverlap >= min(left.height,right.height)*0.5
                let inlineContinuation = mixed && sharedScope && inventory.contains { anchor in
                    guard anchor.raw.orientation == .vertical else { return false }
                    let box=pointBounds(anchor.polygon.map { $0.applying(frame) })
                    return box.height >= box.width*3 && inventory.contains { fragment in
                        guard fragment.raw.orientation == .horizontal else { return false }
                        let evidence=packetEvidence(a.table,fragment.raw.index)
                        let points=projectedRunEndpoints(evidence,components:{ $0.components+disputedComponents($0) }) { e,x,y in
                            CGPoint(x:x/CGFloat(e.mapFullWidth),y:y*CGFloat(e.sourceHeight)/CGFloat(e.mapFullHeight*e.sourceWidth))
                        }
                        let small=pointBounds((points.isEmpty ? fragment.polygon:points).map { $0.applying(frame) })
                        let cell=evidence.map { max(1/CGFloat($0.mapFullWidth),
                            CGFloat($0.sourceHeight)/CGFloat($0.mapFullHeight*$0.sourceWidth)) }.max() ?? 0
                        let gap=box.width*1.25+cell*2
                        return small.height <= box.width*1.5 && coherentColumn(box,small,gap:gap/box.width) &&
                            small.minY >= box.maxY && small.minY-box.maxY <= gap
                    }
                }
                guard sharedScope || sameContour || measuredRow,
                      !cells(a).isDisjoint(with:cells(b)) || strongA && strongB && measuredOverlap || inlineContinuation else { continue }
            }
            if mixed {
                // A short inline read needs genuine containment, not mere RF
                // co-membership with a neighboring paragraph or a label row.
                let normal=aa.contains { $0.raw.orientation == .vertical } ? left : right
                let inlinePackets=aa.contains { $0.raw.orientation == .vertical } ? bb:aa
                let inlineMembership=aa.contains { $0.raw.orientation == .vertical } ? b:a
                let inline=pointBounds(support(inlinePackets,inlineMembership).map { $0.applying(frame) })
                guard sharedScope || inlineScope, normal.insetBy(dx:-glyph*0.25,dy:-glyph).contains(inline) else { continue }
            } else {
                // A broad, unowned gutter plus a closed utterance is a
                // paragraph boundary. Punctuation ALONE never splits a
                // column or overrides a measured common RF text owner.
                // Lateral expansion requires a unique RF text owner or the
                // same measured balloon boundary AND aligned writing starts.
                // Nearness, overlapping envelopes and a broad losing RF query
                // cannot bridge independent paragraphs.
                let gutter: CGFloat = sameContour ? 3 : measuredRow ? 1.25 : 0.75
                let leadingSlack: CGFloat = quoteContinuation ? 2 : sharedScope && min(left.height,right.height) >= glyph*3 ? 1 : 0.5
                func inside(_ x:CGRect,_ y:CGRect)->Bool {
                    x.minY >= y.minY && x.maxY <= y.maxY && x.height <= y.height*0.75
                }
                func originalBox(_ m:NativeOCRAcceptedSource.Membership)->CGRect {
                    let width=CGFloat(m.table.width)
                    return pointBounds(m.body.flatMap { m.table.packets[$0].groupingPolygon }.map {
                        CGPoint(x:$0.x/width,y:$0.y/width).applying(frame)
                    })
                }
                func independentCohort(_ m:NativeOCRAcceptedSource.Membership)->Bool {
                    m.body.count > 1 && Set(m.body.flatMap { packetEvidence(m.table,$0).map(\.ownerID) }).count > 1
                }
                func measuredCohortInside(_ packets:[PacketObservation],_ m:NativeOCRAcceptedSource.Membership,
                                          host:[PacketObservation])->Bool {
                    guard independentCohort(m),packets.allSatisfy({ $0.raw.orientation == .vertical && !$0.ink.isEmpty }),
                          packets.contains(where:{ packet in
                              let raw=m.table.packets[packet.raw.index].groupingPolygon.map {
                                  CGPoint(x:$0.x/CGFloat(m.table.width),y:$0.y/CGFloat(m.table.width))
                              }
                              return pointBounds(raw) != pointBounds(packet.polygon)
                          }) else { return false }
                    let cores=packets.map { pointBounds($0.ink.map { $0.applying(frame) }) }.sorted { $0.minY < $1.minY }
                    var cell:CGFloat=0
                    for id in m.body { for e in packetEvidence(m.table,id) {
                        let dx:CGFloat=1/CGFloat(e.mapFullWidth)
                        let dy=CGFloat(e.sourceHeight)/CGFloat(e.mapFullHeight*e.sourceWidth)
                        cell=max(cell,max(dx,dy))
                    } }
                    guard zip(cores,cores.dropFirst()).allSatisfy({ x,y in
                        min(x.maxX,y.maxX)-max(x.minX,y.minX) >= min(x.width,y.width)*0.5 &&
                            y.minY-x.maxY <= glyph*1.25+cell*2
                    }) else { return false }
                    let core=pointBounds(packets.flatMap(\.ink).map { $0.applying(frame) })
                    let outer=pointBounds(host.flatMap(\.ink).map { $0.applying(frame) })
                    return !outer.isEmpty && core.height <= outer.height*0.75 &&
                        core.minY >= outer.minY-glyph*0.25 && core.maxY <= outer.maxY+glyph*0.25
                }
                let rawA=originalBox(a),rawB=originalBox(b)
                // Trimming one isolated read's sampling margin cannot create
                // a new lateral-containment certificate. A previously closed
                // multi-packet column may still recover its common paragraph.
                func onlyPunctuation(_ packet: PacketObservation) -> Bool {
                    !packet.raw.source.isEmpty && packet.raw.source.unicodeScalars.allSatisfy {
                        CharacterSet.punctuationCharacters.contains($0)
                    }
                }
                let punctuationRail = (aa + bb).contains(where: onlyPunctuation)
                func measuredPunctuationInside(_ child: [PacketObservation], host: [PacketObservation]) -> Bool {
                    guard child.count == 1, onlyPunctuation(child[0]), sameContour,
                          child[0].raw.orientation == .vertical,
                          host.allSatisfy({ $0.raw.orientation == .vertical }),
                          !host.allSatisfy(onlyPunctuation) else { return false }
                    let core = pointBounds(child.flatMap(\.ink).map { $0.applying(frame) })
                    let outer = pointBounds(host.flatMap(\.ink).map { $0.applying(frame) })
                    return !core.isEmpty && !outer.isEmpty && core.height >= glyph * 0.5 && inside(core, outer)
                }
                let fragmentInside = sharedScope && !horizontal &&
                    (inside(left,right) && (inside(rawA,rawB) || independentCohort(a)) ||
                     inside(right,left) && (inside(rawB,rawA) || independentCohort(b)) ||
                     measuredCohortInside(aa,a,host:bb) || measuredCohortInside(bb,b,host:aa) ||
                     measuredPunctuationInside(aa,host:bb) || measuredPunctuationInside(bb,host:aa))
                let sideGutter = fragmentInside && punctuationRail ? max(gutter, 1.25) : gutter
                let sideBySide=crossGap <= glyph*sideGutter &&
                    alongOverlap >= min(left.height,right.height)*0.25 &&
                    (abs(left.minY-right.minY) <= glyph*leadingSlack || fragmentInside) && (sharedScope || sameContour || measuredRow || quoteContinuation)
                let quoted=sharedScope && hasOpenQuotation((left.minY < right.minY ? sources[i] : sources[j]).region.source)
                let continuation=crossOverlap >= min(left.width,right.width)*0.75 && alongGap <= glyph*(quoted ? 4 : 2)
                guard sideBySide || continuation || columnContinuation else { continue }
                guard sharedScope || sameContour || measuredRow || columnContinuation || quoteContinuation else { continue }
            }
            edges.append(.init(first:i,second:j,reason:"private-packet-paragraph-neighbor"))
        } }
        return edges
    }

    /// A short, separated end of an edge column can share an enclosing RF
    /// query with its own continued paragraph. Require a private parallel
    /// column to span the whole missing band; a callout above the paragraph
    /// or an unrelated nearby reaction cannot supply this physical witness.
    private static func corroboratedInterruptedColumn(_ fragment:[PacketObservation],host:[PacketObservation],
        table:NativeOCRAcceptedSource.PacketTable,frame:CGAffineTransform,glyph:CGFloat)->Bool {
        guard fragment.count==1,host.count>=3,glyph>0,
              (fragment+host).allSatisfy({$0.raw.orientation == .vertical && !pointBounds($0.ink).isEmpty}) else {return false}
        let box=pointBounds(fragment[0].polygon.map {$0.applying(frame)})
        guard box.height<=glyph*3 else {return false}
        var cell:CGFloat=0
        for packet in fragment+host {for evidence in packetEvidence(table,packet.raw.index) {
            let dx=1/CGFloat(evidence.mapFullWidth)
            let dy=CGFloat(evidence.sourceHeight)/CGFloat(evidence.mapFullHeight*evidence.sourceWidth)
            cell=max(cell,hypot(dx,dy))
        }}
        let boxes=Dictionary(uniqueKeysWithValues:host.map {($0.raw.index,pointBounds($0.polygon.map {$0.applying(frame)}))})
        var graph=ObservationGraph(host.map {$0.raw.index})
        for a in host {for b in host where b.raw.index>a.raw.index {
            if coherentColumn(boxes[a.raw.index]!,boxes[b.raw.index]!) {graph.join(a.raw.index,b.raw.index)}
        }}
        let columns=graph.groups.values.map {ids in ids.map {boxes[$0]!}.reduce(CGRect.null) {$0.union($1)}}
        return columns.contains { carrier in
            let overlap=min(box.maxX,carrier.maxX)-max(box.minX,carrier.minX)
            let gap=max(box.minY,carrier.minY)-min(box.maxY,carrier.maxY)
            guard overlap>=min(box.width,carrier.width)*0.75,
                  max(box.width,carrier.width)<=min(box.width,carrier.width)*2,
                  gap>0,gap<=glyph*4+cell*2 else {return false}
            let low:CGFloat,high:CGFloat
            if box.maxY<carrier.minY {
                low=box.minY;high=carrier.minY+min(glyph*2,carrier.height)
            } else {
                low=carrier.maxY-min(glyph*2,carrier.height);high=box.maxY
            }
            return columns.contains { parallel in
                let cross=min(parallel.maxX,carrier.maxX)-max(parallel.minX,carrier.minX)
                let gutter=max(parallel.minX,carrier.minX)-min(parallel.maxX,carrier.maxX)
                return cross<=min(parallel.width,carrier.width)*0.25 && gutter<=glyph*0.75+cell*2 &&
                    parallel.minY<=low+cell*2 && parallel.maxY>=high-cell*2
            }
        }
    }

    /// A fragmented column nested alongside a complete parallel column is
    /// still one paragraph when both complete ink cohorts select the same RF
    /// text owner. An upper partial RF winner of one fragment must not create
    /// a permanent split before the complete-column evidence is considered.
    private static func corroboratedNestedColumn(_ child:[PacketObservation],host:[PacketObservation],
        table:NativeOCRAcceptedSource.PacketTable,frame:CGAffineTransform,scopes:[TextScope])->Bool {
        guard child.count>=2,host.count>=2,
              (child+host).allSatisfy({$0.raw.orientation == .vertical && !pointBounds($0.ink).isEmpty}) else {return false}
        func column(_ packets:[PacketObservation])->CGRect? {
            let boxes=packets.map {pointBounds($0.polygon.map {$0.applying(frame)})}.sorted {$0.minY<$1.minY}
            guard zip(boxes,boxes.dropFirst()).allSatisfy({coherentColumn($0,$1)}) else {return nil}
            return boxes.reduce(CGRect.null) {$0.union($1)}
        }
        guard let x=column(child),let y=column(host) else {return false}
        let glyph=min(x.width,y.width)
        let overlap=min(x.maxX,y.maxX)-max(x.minX,y.minX)
        let gap=max(x.minX,y.minX)-min(x.maxX,y.maxX)
        guard glyph>0,overlap<=glyph*0.25,gap<=glyph*0.75 else {return false}
        let a=pointBounds(child.flatMap(\.ink).map {$0.applying(frame)})
        let b=pointBounds(host.flatMap(\.ink).map {$0.applying(frame)})
        guard a.height<=b.height*0.75,a.minY>=b.minY-glyph*0.25,a.maxY<=b.maxY+glyph*0.25 else {return false}
        let aspect=CGFloat(table.width)/CGFloat(table.height)
        let first=pointBounds(child.flatMap(\.ink)).applying(.init(scaleX:1,y:aspect))
        let second=pointBounds(host.flatMap(\.ink)).applying(.init(scaleX:1,y:aspect))
        guard let owner=owningScope(first,scopes:scopes,minimumConfidence:0.25) else {return false}
        return owner.owner==owningScope(second,scopes:scopes,minimumConfidence:0.25)?.owner
    }

    /// A source with certified aliases need not have a unique internal token
    /// decomposition. Such a source can still be kept WHOLE while joining a
    /// physically adjacent paragraph. Never invent an internal order, remove
    /// aliases, substitute text, or discard physical ownership to force a join.
    /// Close a paragraph on the immutable observed columns after alias/reading
    /// reconciliation converges. An expanded aggregate's old layout margin must
    /// not hide a neighbor's independently observed, aligned writing start.
    private static func completingAlignedParagraphs(_ sources: [ObservedSource], scopes: [TextScope],
                                                    balloons: [TextScope], separations: [SourceSeparation],
                                                    didCoalesce: (([String]) -> Void)?) -> [ObservedSource] {
        var edges: [Edge] = []
        for i in sources.indices { for j in sources.indices where j > i {
            guard let a = sourceMembership(sources[i].region), let b = sourceMembership(sources[j].region),
                  a.table === b.table, a.body.isDisjoint(with: b.body),
                  !a.body.isEmpty, !b.body.isEmpty else { continue }
            let hasVerifiedFace = [sources[i].region, sources[j].region].contains { $0.balloonInterior?.contourVerified == true }
            // The measured contour boundary is the owner identity, not its
            // sampled interior center. A seedless peer cannot expand one known
            // face without an independently shared measured boundary.
            if hasVerifiedFace && !sameVerifiedBalloon(sources[i].region, sources[j].region) { continue }
            let textA = owningScope(sources[i].region.rect, scopes: scopes, minimumConfidence: 0.25)
            let textB = owningScope(sources[j].region.rect, scopes: scopes, minimumConfidence: 0.25)
            let balloonA = owningScope(sources[i].region.rect, scopes: balloons, minimumConfidence: 0.5)
            let balloonB = owningScope(sources[j].region.rect, scopes: balloons, minimumConfidence: 0.5)
            let commonText = textA != nil && textA?.owner == textB?.owner
            let commonBalloon = balloonA != nil && balloonA?.owner == balloonB?.owner
            if let x=balloonA,let y=balloonB,x.owner != y.owner { continue }
            // Scope identity supplies context, never ownership of additional
            // pixels. Do not synthesize a cross-query context from punctuation,
            // paragraph size or the presence of a third matching block.
            guard commonText || commonBalloon || sameVerifiedBalloon(sources[i].region, sources[j].region) else { continue }
            let table = a.table, scale = CGFloat(table.width)
            let ids = a.body.union(b.body).sorted()
            // This is the seedless observation fallback, not a second, weaker
            // opinion on measured source components. When a detector inventory
            // exists, its complete/private/contested evidence must be resolved
            // by the physical source graph above, never bypassed by RF boxes
            // and adjacent quads alone. A recorded empty component inventory is
            // still an observation, not permission to pretend it was absent.
            guard table.packets.allSatisfy({ $0.detectorSeedEvidence?.isEmpty ?? true }) else { continue }
            guard let packets = projectedPacketInventory(ids, table: table), packets.count == ids.count,
                  let orientation = packets.first?.raw.orientation,
                  orientation == .horizontal || orientation == .vertical,
                  packets.allSatisfy({ $0.raw.orientation == orientation }),
                  let frame = sourceAlignmentFrame(packets, table: table, horizontal: orientation == .horizontal) else { continue }
            let atoms = ids.map { id in
                Atom(index: id, source: table.packets[id].text,
                    box: pointBounds(table.packets[id].groupingPolygon.map {
                        CGPoint(x: $0.x/scale, y: $0.y/scale).applying(frame)
                    }), orientation: .vertical, owner: nil)
            }
            // Both writing directions use the same packet-local relations in
            // their common frame. The same physical continuation and adjacency
            // rules already serve the original-column graph; no text grammar,
            // minimum character count or aggregate-box width exception is needed.
            let continuation = columnRelations(atoms: atoms)
            // An end-to-end edge connects two source lanes, not a whole
            // multi-lane paragraph through one of its tails. Parallel owners
            // still use their observed cross-lane adjacency below.
            func singleLane(_ body: Set<Int>) -> Bool {
                var graph = ObservationGraph(body.sorted())
                graph.join(continuation.filter { body.contains($0.first) && body.contains($0.second) })
                return graph.groups.count == 1
            }
            let relations = measuredColumnEdges(atoms: atoms) +
                (singleLane(a.body) && singleLane(b.body) ? continuation : [])
            if relations.contains(where: { a.body.contains($0.first) != a.body.contains($0.second) }) {
                relationDecisionObserver?("candidate", [sources[i].region.id, sources[j].region.id])
                edges.append(.init(first: i, second: j, reason: "adjacent-observed-source-packets"))
            }
        } }
        return coalescingWholeSources(sources, scopes: scopes, separations: separations,
                                     didCoalesce: didCoalesce, explicitEdges: edges)
    }

    private static func coalescingWholeSources(_ sources:[ObservedSource], scopes:[TextScope],
                                               separations:[SourceSeparation],
                                               didCoalesce:(([String])->Void)?, explicitEdges: [Edge]? = nil) -> [ObservedSource] {
        let edges=(explicitEdges ?? supportedParagraphNeighbors(sources,scopes:scopes)).filter { edge in
            guard let a=sourceMembership(sources[edge.first].region),
                  let b=sourceMembership(sources[edge.second].region),
                  let aa=projectedPacketInventory(a.body,table:a.table),
                  let bb=projectedPacketInventory(b.body,table:b.table) else { return false }
            if horizontalBlankBand(aa,bb,table:a.table) { return false }
            if let band=parallelParagraphBand(aa+bb,table:a.table) {
                let x=pointBounds(aa.flatMap(\.polygon).map { $0.applying(band.frame) })
                let y=pointBounds(bb.flatMap(\.polygon).map { $0.applying(band.frame) })
                if x.maxY <= band.low && y.minY >= band.high || y.maxY <= band.low && x.minY >= band.high { return false }
            }
            return !independentParagraphRows(aa,bb,table:a.table)
        }
        guard !edges.isEmpty else { return sources }
        let graph=constrainedSourceGraph(sources,edges:edges,separations:separations)
        var replacements:[Int:ObservedSource]=[:],removed=Set<Int>()
        for members in graph.groups.values where members.count > 1 {
            let originals=members.map { sources[$0].region }
            let memberships=originals.compactMap(sourceMembership)
            guard memberships.count == originals.count, let first=memberships.first,
                  memberships.allSatisfy({ $0.table === first.table }) else { continue }
            let seeds=memberships.map { m in
                m.body.union(m.readings).sorted().flatMap { packetEvidence(m.table,$0) }
            }
            // A valid accepted OCR packet need not originate in the DB grid
            // (e.g. a recovered read). Missing cells are not contradictory
            // ownership. Keep all available cells, and keep every exact packet
            // in acceptedSource; never invent cells for a seedless observation.
            let knownSeeds = explicitEdges == nil ? seeds : seeds.filter { !$0.isEmpty }
            let union = NativeOCRDetectorSeedEvidence.preservingUnion(knownSeeds)
            guard union != nil || explicitEdges != nil && knownSeeds.isEmpty else {
                if explicitEdges != nil { relationDecisionObserver?("seed-union-rejected", originals.map(\.id)) }
                continue
            }
            let body=memberships.reduce(into:Set<Int>()) { $0.formUnion($1.body) }
            guard memberships.reduce(0,{ $0+$1.body.count }) == body.count else { continue }
            let inventory=body.sorted().compactMap { id in projectedPacketInventory([id],table:first.table)?.first }
            let horizontal=inventory.allSatisfy { $0.raw.orientation == .horizontal }
            guard let frame=sourceAlignmentFrame(inventory,table:first.table,horizontal:horizontal) else { continue }
            let boxes=Dictionary(uniqueKeysWithValues:members.map { member in
                let m=sourceMembership(sources[member].region)!
                let points=m.body.flatMap { first.table.packets[$0].groupingPolygon }.map {
                    CGPoint(x:$0.x/CGFloat(first.table.width),y:$0.y/CGFloat(first.table.width)).applying(frame)
                }
                return (member,pointBounds(points))
            })
            let order=members.sorted { a,b in
                let x=boxes[a]!,y=boxes[b]!
                if x.midX != y.midX { return x.midX > y.midX }
                if x.minY != y.minY { return x.minY < y.minY }
                return a < b
            }
            let owner=members.min()!, box=originals.map(\.rect).reduce(CGRect.null) { $0.union($1) }
            var region=sourceRevision(sources[owner].region,rect:box,source:order.map { sources[$0].region.source }.joined())
            region.acceptedSource = .union(originals.map(\.acceptedSource))
            guard let merged=sourceMembership(region), merged.body == body else { continue }
            region.detectorSeedEvidence=union
            region.confidence=originals.map(\.confidence).min()!
            region.sourceOrientation=horizontal ? .horizontal : .vertical
            region.unitMemberRects=originals.flatMap { $0.unitMemberRects.isEmpty ? [$0.rect] : $0.unitMemberRects }
            region.auxiliaryInkRects=originals.flatMap(\.auxiliaryInkRects)
            region.auxiliaryInkPolygons=originals.flatMap(\.auxiliaryInkPolygons)
            region.sourceOCRAlternatives=originals.flatMap(\.sourceOCRAlternatives)
            region.isRecoveredLine=originals.contains { $0.isRecoveredLine }
            preservingOriginalAngle(&region)
            replacements[owner]=observingSource(region)
            removed.formUnion(members.filter { $0 != owner })
            didCoalesce?(members.map { sources[$0].region.id })
        }
        return sources.indices.compactMap { replacements[$0] ?? (removed.contains($0) ? nil : sources[$0]) }
    }

    /// Separate typographically independent rows, not words on the same baseline.
    private static func independentParagraphRows(_ first:[PacketObservation],_ second:[PacketObservation],
                                                  table:NativeOCRAcceptedSource.PacketTable) -> Bool {
        let all=first+second
        guard !first.isEmpty,!second.isEmpty,all.allSatisfy({ $0.raw.orientation == .horizontal }),
              let frame=sourceAlignmentFrame(all,table:table,horizontal:true) else { return false }
        func row(_ packets:[PacketObservation],_ id:Int) -> Atom {
            let b=pointBounds(packets.flatMap(\.polygon).map { $0.applying(frame) })
            return Atom(index:id,source:packets.map { $0.raw.source }.joined(),
                box:CGRect(x:b.minY,y:-b.maxX,width:b.height,height:b.width),orientation:.horizontal,owner:nil)
        }
        // Paragraph envelopes include the gaps between their own rows. They
        // cannot supply font height or advance for a boundary against a peer.
        // Compare the nearest original rows, with the same measurements used
        // by separatedHorizontalRows, so a certified split cannot rejoin.
        var boundary: (PacketObservation, PacketObservation, CGFloat)?
        for x in first { for y in second {
            let a = row([x], 0), b = row([y], 1)
            let gap = max(a.box.minY, b.box.minY) - min(a.box.maxY, b.box.maxY)
            if gap < 0 { return false }
            if boundary == nil || gap < boundary!.2 { boundary = (x, y, gap) }
        } }
        guard let (x, y, _) = boundary else { return false }
        return independentHorizontalRows(row([x],0),row([y],1),
            firstAdvance:observedHorizontalAdvance([x],table:table),
            secondAdvance:observedHorizontalAdvance([y],table:table),
            firstUncertainty:observedHorizontalAdvanceUncertainty([x],table:table),
            secondUncertainty:observedHorizontalAdvanceUncertainty([y],table:table),
            firstGlyphHeight:observedHorizontalGlyphHeight([x],table:table),
            secondGlyphHeight:observedHorizontalGlyphHeight([y],table:table))
    }

    /// Layout cores govern row spacing, but may predate a recovered leading
    /// glyph. Pair the current transcription with its actual sampled extent
    /// when estimating advance; never divide the old core by a new glyph count.
    private static func observedHorizontalAdvance(_ packets:[PacketObservation],
                                                   table:NativeOCRAcceptedSource.PacketTable)->CGFloat? {
        guard let frame=sourceAlignmentFrame(packets,table:table,horizontal:true) else { return nil }
        let width=CGFloat(table.width)
        return pointBounds(packets.flatMap { table.packets[$0.raw.index].polygon }.map {
            CGPoint(x:$0.x/width,y:$0.y/width).applying(frame)
        }).height
    }

    /// Advance and em thickness must describe the same accepted crop. A
    /// stable layout core may retain the old sampling halo after the actual
    /// glyph crop was tightened; mixing those scales can erase a row break.
    private static func observedHorizontalGlyphHeight(_ packets:[PacketObservation],
                                                      table:NativeOCRAcceptedSource.PacketTable)->CGFloat? {
        guard let frame=sourceAlignmentFrame(packets,table:table,horizontal:true) else {return nil}
        let width=CGFloat(table.width)
        let heights = packets.map { packet in
            pointBounds(table.packets[packet.raw.index].polygon.map {
                CGPoint(x:$0.x/width,y:$0.y/width).applying(frame)
            }).width
        }.sorted()
        return heights.isEmpty ? nil : heights[heights.count / 2]
    }

    /// The two measured word ends share at most one detector-cell diagonal
    /// of quantization uncertainty. Removing sampling margin must not revoke
    /// a row boundary on a sub-cell difference in inferred glyph advance.
    private static func observedHorizontalAdvanceUncertainty(_ packets:[PacketObservation],
                                                              table:NativeOCRAcceptedSource.PacketTable)->CGFloat {
        var uncertainty:CGFloat=0
        for packet in packets {
            for evidence in packetEvidence(table,packet.raw.index) {
                guard evidence.isValid,evidence.sourceWidth==table.width,
                      evidence.sourceHeight==table.height else {continue}
                let sx=CGFloat(evidence.sourceWidth)/CGFloat(evidence.mapFullWidth)
                let sy=CGFloat(evidence.sourceHeight)/CGFloat(evidence.mapFullHeight)
                uncertainty=max(uncertainty,hypot(sx,sy)/CGFloat(table.width))
            }
        }
        return uncertainty
    }

    private static func independentHorizontalRows(_ a: Atom, _ b: Atom,
                                                  firstAdvance:CGFloat? = nil,secondAdvance:CGFloat? = nil,
                                                  firstUncertainty:CGFloat = 0,secondUncertainty:CGFloat = 0,
                                                  firstGlyphHeight:CGFloat? = nil,secondGlyphHeight:CGFloat? = nil) -> Bool {
        guard a.orientation == .horizontal, b.orientation == .horizontal else { return false }
        let firstHeight=firstGlyphHeight ?? a.box.height,secondHeight=secondGlyphHeight ?? b.box.height
        let height = min(firstHeight,secondHeight)
        let gap = max(a.box.minY, b.box.minY) - min(a.box.maxY, b.box.maxY)
        let overlap = min(a.box.maxX, b.box.maxX) - max(a.box.minX, b.box.minX)
        func fullHeightAdvance(_ row: Atom,_ advance:CGFloat?,_ uncertainty:CGFloat,_ measuredHeight:CGFloat?) -> Bool {
            let count = row.source.filter { !$0.isWhitespace }.count
            let fullHeight = row.source.unicodeScalars.filter {
                (0x2E80...0xA4CF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) ||
                    (0xF900...0xFAFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
            }.count
            // CJK row height measures the full em. Latin ascenders/capitals
            // vary by wording, so their bbox height is not a font-size witness.
            return count > 0 && fullHeight * 2 >= count &&
                ((advance ?? row.box.width)+uncertainty) / CGFloat(count) >= (measuredHeight ?? row.box.height) * 0.75
        }
        // Full-height row glyphs have measurable font scale. Variable-height
        // narrow glyph rows and side attachments do not certify a paragraph break.
        return height > 0 && gap >= 0 && overlap >= min(a.box.width, b.box.width) * 0.8 &&
            fullHeightAdvance(a,firstAdvance,firstUncertainty,firstGlyphHeight) &&
            fullHeightAdvance(b,secondAdvance,secondUncertainty,secondGlyphHeight) &&
            (gap >= height * 0.75 || max(firstHeight,secondHeight) >= height * 1.25 ||
             gap >= height * 0.45 && differingRowMeasure(a, b, firstAdvance: firstAdvance, secondAdvance: secondAdvance))
    }

    /// Equal-span rows retain ordinary line spacing. A moderate blank band
    /// needs a second witness from row width or independently inferred em size.
    private static func differingRowMeasure(_ a: Atom, _ b: Atom,
                                           firstAdvance: CGFloat?, secondAdvance: CGFloat?) -> Bool {
        let x = firstAdvance ?? a.box.width, y = secondAdvance ?? b.box.width
        guard min(x, y) > 0 else { return false }
        if max(x, y) >= min(x, y) * 1.2 { return true }
        return inferredEmScaleBreak(a, b, firstAdvance: firstAdvance, secondAdvance: secondAdvance)
    }

    private static func inferredEmScaleBreak(_ a: Atom, _ b: Atom,
                                            firstAdvance: CGFloat?, secondAdvance: CGFloat?) -> Bool {
        let x = firstAdvance ?? a.box.width, y = secondAdvance ?? b.box.width
        let na = a.source.filter { !$0.isWhitespace }.count
        let nb = b.source.filter { !$0.isWhitespace }.count
        guard na > 0, nb > 0 else { return false }
        let ea = x / CGFloat(na), eb = y / CGFloat(nb)
        return max(ea, eb) >= min(ea, eb) * 1.25
    }

    /// Recognition margins cannot bridge a multi-em empty band between owned
    /// rows. Measure original detector ink in their shared baseline frame, not
    /// padded OCR rectangles or the height of an aggregate paragraph.
    private static func horizontalBlankBand(_ first: [PacketObservation], _ second: [PacketObservation],
                                            table: NativeOCRAcceptedSource.PacketTable) -> Bool {
        let packets = first + second
        guard !first.isEmpty, !second.isEmpty,
              packets.allSatisfy({ $0.raw.orientation == .horizontal && !$0.ink.isEmpty }),
              let frame = sourceAlignmentFrame(packets,table:table,horizontal:true) else { return false }
        let boxes = packets.map { pointBounds($0.ink.map { $0.applying(frame) }) }
        guard boxes.allSatisfy({ !$0.isEmpty && !$0.isNull }) else { return false }
        let a = boxes.prefix(first.count).reduce(CGRect.null) { $0.union($1) }
        let b = boxes.dropFirst(first.count).reduce(CGRect.null) { $0.union($1) }
        let gap = max(a.minX,b.minX)-min(a.maxX,b.maxX)
        // High-threshold DB cores are thinner than the visible glyph (Latin
        // capitals can have only a few core rows). Use the atomic quad's normal
        // thickness for scale; endpoint padding is along the other axis.
        let glyph = packets.map { pointBounds($0.polygon.map { $0.applying(frame) }).width }.max()!
        let baselineOverlap = min(a.maxY,b.maxY)-max(a.minY,b.minY)
        return glyph > 0 && gap > glyph*3 && baselineOverlap >= min(a.height,b.height)*0.5
    }

    private static func separatedHorizontalRows(_ observation: ObservedSource) -> [ObservedSource] {
        guard let (membership, sequence, chunks) = observation.read,
              membership.readings.isEmpty, membership.unknownDedup.isEmpty,
              !membership.hasUntrackedInputs, sequence.count > 1,
              let packets = observation.packets,
              packets.allSatisfy({ $0.raw.orientation == .horizontal }),
              componentSupport(membership.table).independent.isSuperset(of: sequence) else { return [observation] }
        let atoms = Dictionary(uniqueKeysWithValues: packets.map { ($0.raw.index, $0.raw) })
        let inventory = Dictionary(uniqueKeysWithValues: packets.map { ($0.raw.index,$0) })
        var groups: [[Int]] = []
        for id in sequence {
            if let last = groups.last,
               !independentParagraphRows(last.map { inventory[$0]! }, [inventory[id]!], table: membership.table),
               !horizontalBlankBand(last.map { inventory[$0]! },[inventory[id]!],table:membership.table) {
                groups[groups.count - 1].append(id)
            } else {
                groups.append([id])
            }
        }
        guard groups.count > 1 else { return [observation] }
        let text = Dictionary(uniqueKeysWithValues: zip(sequence, chunks))
        let table = membership.table, aspect = CGFloat(table.width) / CGFloat(table.height)
        let rects = groups.map { ids in
            ids.map { atoms[$0]!.box }.reduce(CGRect.null) { $0.union($1) }
                .applying(CGAffineTransform(scaleX: 1, y: aspect))
        }
        func partition<Value>(_ values: [Value], box: (Value) -> CGRect) -> [Int: [Value]]? {
            var assigned: [Int: [Value]] = [:]
            for value in values {
                let bounds = box(value)
                let matches = rects.indices.filter { rects[$0].intersection(bounds).width > 0 && rects[$0].intersection(bounds).height > 0 }
                guard matches.count == 1 else { return nil }
                assigned[matches[0], default: []].append(value)
            }
            return assigned
        }
        guard let inkRects = partition(observation.region.auxiliaryInkRects, box: { $0 }),
              let inkPolygons = partition(observation.region.auxiliaryInkPolygons, box: pointBounds),
              let alternatives = partition(observation.region.sourceOCRAlternatives, box: { $0.rect }) else { return [observation] }
        guard groups.allSatisfy({ ids in
            let seeds = ids.map { table.packets[$0].detectorSeedEvidence }
            return NativeOCRDetectorSeedEvidence.preservingUnion(seeds) != nil || seeds.allSatisfy({ $0?.isEmpty ?? true })
        }) else { return [observation] }
        return groups.enumerated().map { index, ids in
            let originals = ids.map { table.packets[$0] }
            var region = sourceRevision(observation.region, id: observation.region.id + ".\(index)",
                rect: rects[index], source: ids.map { text[$0]! }.joined())
            region.confidence = originals.map(\.score).min() ?? observation.region.confidence
            region.detectorSeedEvidence = NativeOCRDetectorSeedEvidence.preservingUnion(originals.map(\.detectorSeedEvidence))
            let child = NativeOCRAcceptedSource.Membership(table: table, body: Set(ids), readings: [],
                unknownDedup: membership.unknownDedup, hasUntrackedInputs: membership.hasUntrackedInputs)
            region.acceptedSource = .init(child)
            preservingOriginalAngle(&region)
            region.auxiliaryInkRects = inkRects[index] ?? []
            region.auxiliaryInkPolygons = inkPolygons[index] ?? []
            region.sourceOCRAlternatives = alternatives[index] ?? []
            return observingSource(region, read: (child, ids, ids.map { text[$0]! }))
        }
    }

    /// Complete original packets certify local boundaries that paragraph-scale
    /// font estimates cannot: small terminal marks, centered rows and an
    /// independently detected fragment bracketed inside one interrupted column.
    private static func originalBoundaryLinks(_ sources: [ObservedSource]) -> (sources: [Edge], order: [ObjectIdentifier: [Edge]]) {
        var links: [Edge] = [], order: [ObjectIdentifier: [Edge]] = [:]
        for child in sources.indices {
            guard let read = sources[child].read, read.1.count == 1,
                  let fragment = sources[child].packets?.first?.raw,
                  !packetEvidence(read.0.table, fragment.index).isEmpty else { continue }
            var options: [(Int, [Edge])] = []
            for parent in sources.indices where parent != child {
                guard let primary = sources[parent].read, primary.0.table === read.0.table,
                      let scope = sources[child].scope, scope.owner == sources[parent].scope?.owner,
                      let columns = sources[parent].packets?.map(\.raw),
                      columns.allSatisfy({ !packetEvidence(read.0.table, $0.index).isEmpty }) else { continue }
                if let a = sources[parent].region.balloonInterior, let b = sources[child].region.balloonInterior,
                   a.contourVerified == true, b.contourVerified == true,
                   a.rect != b.rect || a.spans != b.spans { continue }
                let b = fragment.box
                if fragment.orientation == .horizontal, columns.count == 1, let row = columns.first,
                   row.orientation == .horizontal {
                    let a = row.box, glyph = min(a.height, b.height)
                    let gap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
                    let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                    if compatibleGlyphScale(a.height, b.height), gap >= 0, gap <= glyph * 0.75,
                       abs(a.midX - b.midX) <= glyph * 0.25, overlap >= min(a.width, b.width) * 0.8 {
                        let first = a.minY < b.minY ? row.index : fragment.index
                        let last = first == row.index ? fragment.index : row.index
                        options.append((parent, [.init(first: first, second: last, reason: "centered-original-rows")]))
                    }
                    continue
                }
                guard fragment.orientation == .vertical, columns.allSatisfy({ $0.orientation == .vertical }) else { continue }
                let marks = !fragment.source.isEmpty && fragment.source.unicodeScalars.allSatisfy {
                    CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
                }
                if marks {
                    let tails = columns.filter { column in
                        let a = column.box, glyph = a.width
                        return b.width <= glyph && b.height <= glyph * 2.5 &&
                            b.minY >= a.maxY - glyph * 0.1 && b.minY - a.maxY <= glyph * 0.5 &&
                            b.minX >= a.minX && b.maxX <= a.maxX
                    }
                    if tails.count == 1 {
                        options.append((parent, [.init(first: tails[0].index, second: fragment.index, reason: "original-terminal-mark")]))
                        continue
                    }
                    if columns.count == 1, let column = columns.first {
                        let a = column.box, glyph = min(a.width, b.width)
                        let cell = [column.index, fragment.index].flatMap { packetEvidence(read.0.table, $0) }
                            .map { CGFloat($0.sourceHeight) / CGFloat($0.mapFullHeight * $0.sourceWidth) }.max() ?? 0
                        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                        if gap >= 0, gap <= (a.width + b.width) * 0.375,
                           abs(a.minY - b.minY) <= glyph * 0.25,
                           overlap + cell >= max(a.height, b.height) * 0.8 {
                            let first = a.midX > b.midX ? column.index : fragment.index
                            let last = first == column.index ? fragment.index : column.index
                            options.append((parent, [.init(first: first, second: last, reason: "original-parallel-mark-column")]))
                        }
                    }
                    continue
                }
                guard columns.count > 1 else { continue }
                let lane = columns.sorted { $0.box.minY < $1.box.minY }
                let width = lane.map(\.box.width).min()!
                guard lane.allSatisfy({ abs($0.box.midX - lane[0].box.midX) <= width * 0.25 }),
                      b.width <= lane.map(\.box.width).max()! * 2,
                      abs(b.midX - lane[0].box.midX) <= width * 0.5 else { continue }
                let slots = zip(lane, lane.dropFirst()).filter { upper, lower in
                    b.minY >= upper.box.maxY && b.maxY <= lower.box.minY &&
                        b.minY - upper.box.maxY <= width * 0.75 && lower.box.minY - b.maxY <= width * 0.75
                }
                if slots.count == 1, let slot = slots.first {
                    options.append((parent, [.init(first: slot.0.index, second: fragment.index, reason: "closed-inline-order"),
                        .init(first: fragment.index, second: slot.1.index, reason: "closed-inline-order"),
                        .init(first: slot.0.index, second: slot.1.index, reason: "closed-inline-order")]))
                }
            }
            if options.count == 1, let option = options.first {
                links.append(.init(first: option.0, second: child, reason: "original-packet-boundary"))
                order[ObjectIdentifier(read.0.table), default: []] += option.1
            }
        }
        return (links, order)
    }


    private static func certifiedLineStrides(_ original: [Atom], owner: [Int: Int], sources: [ObservedSource],
        contexts: [Set<Int>: (cell: CGFloat?, pitch: CGSize?)], members: Set<Int>, horizontal: Bool,
        table: NativeOCRAcceptedSource.PacketTable) -> [Set<Int>: (cell: CGFloat, limit: CGFloat?)] {
        let accepted = Dictionary(grouping: original.filter { $0.orientation == .vertical }, by: { owner[$0.index]! })
        let cadence = accepted.map { source, lines in
            (members: Set(sources.indices.filter { $0 == source ||
                (sources[source].scope?.owner != nil && sources[$0].scope?.owner == sources[source].scope?.owner) }),
             lines: lines, cell: Optional<CGFloat>.none)
        } + contexts.compactMap { scope, value -> (members: Set<Int>, lines: [Atom], cell: CGFloat?)? in
            guard scope.isSubset(of: members), let cell = value.cell else { return nil }
            return (scope, original.filter { scope.contains(owner[$0.index]!) }, cell)
        }
        var bounds: [Int: CGFloat] = [:]
        for sample in cadence {
            let lines = sample.lines.sorted { $0.box.midX > $1.box.midX }
            let strides = zip(lines, lines.dropFirst()).compactMap { right, left -> CGFloat? in
                let overlap = max(0, min(right.box.maxY, left.box.maxY) - max(right.box.minY, left.box.minY)) /
                    min(right.box.height, left.box.height)
                return right.box.minX + 2 / CGFloat(table.width) >= left.box.maxX && overlap >= 0.75 ? right.box.midX - left.box.midX : nil
            }
            guard let longest = strides.max() else { continue }
            let continuations = zip(lines, lines.dropFirst()).filter { right, left in
                owner[right.index] == owner[left.index] && !columnRelations(atoms: [right, left]).isEmpty
            }.count
            guard sample.cell == nil || (lines.count >= 3 && strides.count + continuations == lines.count - 1) else { continue }
            // Four raster centers each contribute half an original-source pixel.
            let limit = longest + (sample.cell ?? (2 / CGFloat(table.width)))
            for member in sample.members { bounds[member] = max(bounds[member] ?? 0, limit) }
        }
        let cohort = members.sorted()
        var pairs: [Set<Int>: (cell: CGFloat, limit: CGFloat?)] = [:]
        for (i, first) in cohort.enumerated() { for second in cohort.dropFirst(i) {
            let pair = Set([first, second]), witnesses = contexts.filter { pair.isSubset(of: $0.key) }.values
            // Both endpoints need cadence; otherwise only finite co-member native pitch applies.
            let native = witnesses.compactMap(\.pitch).map { horizontal ? $0.height : $0.width }.max()
            let measured = bounds[first].flatMap { a in bounds[second].map { max(a, $0) } }
            var alignedHeads = false
            if let a = accepted[first], let b = accepted[second] {
                alignedHeads = abs(a.map { $0.box.minY }.min()! - b.map { $0.box.minY }.min()!) <=
                    min(a.map(\.glyph).min()!, b.map(\.glyph).min()!) * 0.5
            }
            let limit = alignedHeads ? [measured, native].compactMap { $0 }.max() : measured ?? native
            pairs[pair] = (witnesses.compactMap(\.cell).min() ?? 0, limit)
        } }
        return pairs
    }


    /// A horizontal atomic read can span the ends of several vertical columns.
    /// Keep its transcription intact: only packet-level ordering is certified,
    /// never inferred character locations or character re-recognition.
    /// Caller supplies a horizontal word and vertical parent observations.
    /// Clip observed runs to each column, then reuse its continuation geometry.
    private static func horizontalColumnTailLinks(_ head: Atom, parents: [Atom], ink endpoints: [CGPoint]) -> [Edge] {
        var edges: [Edge] = []
        for parent in parents {
            var ink = CGRect.null
            for offset in stride(from: 0, to: endpoints.count, by: 2) {
                let first = endpoints[offset], last = endpoints[offset + 1]
                let left = max(parent.box.minX, first.x), right = min(parent.box.maxX, last.x)
                if right >= left {
                    ink = ink.union(CGRect(x: left, y: first.y, width: max(right - left, .ulpOfOne), height: .ulpOfOne))
                }
            }
            guard !ink.isNull else { continue }
            let word = Atom(index: head.index, source: head.source,
                box: CGRect(x: parent.box.minX, y: ink.minY, width: parent.box.width,
                            height: max(ink.height, head.glyph)), orientation: .vertical,
                owner: head.owner, sourceColumnWidth: head.glyph)
            edges += columnRelations(atoms: [parent, word]).map {
                Edge(first: $0.first, second: $0.second, reason: "horizontal-column-boundary-word")
            }
        }
        return edges
    }

    /// Observe original words and columns once per complete source context.
    /// Packet direction, not parent paragraph hints, selects each observation.
    /// Unwitnessed words add no edges; the source DAG retains every original.
    private static func horizontalSourceLinks(_ original: [Atom], inventory: [PacketObservation]) -> [Edge] {
        let words = original.filter { $0.orientation == .horizontal }
        let columns = original.filter { $0.orientation == .vertical }
        let ink = Dictionary(uniqueKeysWithValues: inventory.map { ($0.raw.index, $0.ink) })
        return words.flatMap { word in
            horizontalColumnTailLinks(word, parents: columns, ink: ink[word.index]!)
        }
    }





    /// Stable packet-level topological order preserves every existing source's
    /// token sequence, allowing a broken column to be inserted between tokens.
    /// A cycle or an ambiguous transcription cannot authorize a source rewrite.
    /// The caller supplies stable parent order and cached geometry from the
    /// same immutable read inventory; packet count and order remain explicit proofs.
    private static func orderedPrimarySource(_ sources: [ObservedSource], precedence: [ObjectIdentifier: [Edge]]) -> (source: String, ids: [Int], chunks: [Substring])? {
        guard let table = sources.first?.read?.0.table,
              sources.allSatisfy({ $0.read!.0.table === table }) else { return nil }
        let ids = sources.flatMap { $0.read!.1 }, inventory = Set(ids)
        guard ids.count <= 256, inventory.count == ids.count else { return nil }
        let atoms = sources.flatMap { $0.packets!.map(\.raw) }
        var edges = (precedence[ObjectIdentifier(table)] ?? []).compactMap { edge -> (Int, Int)? in
            inventory.contains(edge.first) && inventory.contains(edge.second) ? (edge.first, edge.second) : nil
        }
        let closedOrder = (precedence[ObjectIdentifier(table)] ?? []).filter { $0.reason == "closed-inline-order" }
        edges += sources.lazy.flatMap { zip($0.read!.1, $0.read!.1.dropFirst()) }.filter { first, second in
            !closedOrder.contains { $0.first == second && $0.second == first }
        }
        let successors = Dictionary(grouping: edges, by: { $0.0 })
        var indegree = Dictionary(grouping: edges, by: { $0.1 }).mapValues(\.count)
        let chunks = sources.lazy.flatMap { $0.read!.2 }
        let frame = atoms.allSatisfy { $0.orientation == .horizontal } ?
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0) : .identity
        let nodes = Dictionary(uniqueKeysWithValues: zip(atoms, chunks).map { ($0.0.index, (box: $0.0.box.applying(frame), text: $0.1)) })
        var ready = nodes.filter { indegree[$0.key] == nil }, ordered: [Substring] = [], order: [Int] = []
        while let next = ready.min(by: { first, second in
            let a = first.value.box, b = second.value.box
            if a.midX != b.midX { return a.midX > b.midX }
            if a.minY != b.minY { return a.minY < b.minY }
            return first.key < second.key
        }) {
            ready.removeValue(forKey: next.key)
            ordered.append(next.value.text); order.append(next.key)
            for (_, end) in successors[next.key] ?? [] {
                indegree[end]! -= 1
                if indegree[end] == 0 { ready[end] = nodes[end] }
            }
        }
        return ordered.count == nodes.count ? (ordered.joined(), order, ordered) : nil
    }


    /// Only original accepted packets can reconstruct a block's transcription.
    /// Missing, modified or ambiguous body lineage leaves the unit untouched.
    /// Body packets must reconstruct the exact source in its certified order.
    /// Every body and auxiliary reading keeps its unique per-block provenance.
    private static func separatedOriginalBlocks(_ observation: ObservedSource, scopes: [TextScope]) -> [ObservedSource] {
        let supported = separatedSupportedParagraphs(observation, scopes: scopes)
        if supported.count > 1 { return supported }
        let bands=separatedParallelParagraphs(observation)
        if bands.count > 1 { return bands }
        let rows = separatedHorizontalRows(observation)
        if rows.count > 1 { return rows }
        let region = observation.region
        guard let (membership, sequence, chunks) = observation.read,
              sequence.count > 1 else { return [observation] }
        let table = membership.table, aspect = CGFloat(table.width) / CGFloat(table.height)
        guard let inventory = projectedPacketInventory(membership.body.union(membership.readings), table: table),
              inventory.allSatisfy({ $0.raw.orientation == .vertical }) else { return [observation] }
        let body = inventory.filter { membership.body.contains($0.raw.index) }.map(\.raw)
        let heads = body.map(\.box.minY)
        guard heads.max()! - heads.min()! > body.map(\.glyph).min()! * 0.25 else { return [observation] }
        let shared = body.map { $0.box.maxX }.min()! - body.map { $0.box.minX }.max()!
        guard shared < body.map(\.box.width).min()! * 0.75 else { return [observation] }
        let normalized = CGAffineTransform(scaleX: 1, y: aspect)
        let boxes = Dictionary(uniqueKeysWithValues: inventory.map { ($0.raw.index, $0.raw.box.applying(normalized)) })
        let supports = Dictionary(uniqueKeysWithValues: inventory.map { packet in
            (packet.raw.index, pointBounds(packet.ink).applying(normalized))
        })
        guard supports.values.allSatisfy({ !$0.isNull && !$0.isEmpty }) else { return [observation] }
        let common = owningScope(sequence.map { supports[$0]! }.reduce(CGRect.null) { $0.union($1) },
                                 scopes: scopes, minimumConfidence: 0.25)
        if common == nil {
            // Fragmented RF queries do not themselves prove separate
            // paragraphs. Require independently resolved writing directions;
            // true blank-band/row splits have already been handled above.
            let axes = sequence.map { id -> (CGPoint, CGFloat, CGFloat) in
                let q = table.packets[id].groupingPolygon
                let v = CGPoint(x:q[2].x+q[3].x-q[0].x-q[1].x,
                                y:q[2].y+q[3].y-q[0].y-q[1].y)
                let length = hypot(v.x,v.y)
                let glyph = min(hypot(q[1].x-q[0].x,q[1].y-q[0].y),
                                hypot(q[2].x-q[3].x,q[2].y-q[3].y))
                return (CGPoint(x:v.x/length,y:v.y/length),glyph,length/2)
            }
            let cell = sequence.flatMap { packetEvidence(table,$0) }.map {
                max(CGFloat($0.sourceWidth)/CGFloat($0.mapFullWidth),CGFloat($0.sourceHeight)/CGFloat($0.mapFullHeight))
            }.max() ?? .infinity
            guard axes.contains(where:{ a in axes.contains { b in
                a.2 >= a.1*3 && b.2 >= b.1*3 &&
                    abs(a.0.x*b.0.y-a.0.y*b.0.x)*min(a.1,b.1) > cell
            } }) else { return [observation] }
        }
        var nestedOwners: [Int:TextScope] = [:]
        if let common {
            // A broad paragraph query cannot erase independently measured,
            // nonparallel, staggered columns with distinct tighter RF owners.
            guard let frame = sourceAlignmentFrame(inventory, table: table) else { return [observation] }
            let projected = inventory.filter { membership.body.contains($0.raw.index) }.map {
                pointBounds($0.polygon.map { $0.applying(frame) })
            }
            let glyph = projected.map(\.width).min()!
            let heads = projected.map(\.minY), tails = projected.map(\.maxY)
            guard min(heads.max()! - heads.min()!, tails.max()! - tails.min()!) > glyph * 0.5 else { return [observation] }
            let axes = sequence.map { id -> (CGPoint, CGFloat, CGFloat) in
                let q = table.packets[id].groupingPolygon
                let v = CGPoint(x: q[2].x + q[3].x - q[0].x - q[1].x,
                                y: q[2].y + q[3].y - q[0].y - q[1].y)
                let length = hypot(v.x, v.y)
                let glyph = min(hypot(q[1].x - q[0].x, q[1].y - q[0].y),
                                hypot(q[2].x - q[3].x, q[2].y - q[3].y))
                return (CGPoint(x: v.x / length, y: v.y / length), glyph, length / 2)
            }
            let cell = sequence.flatMap { packetEvidence(table, $0) }.map {
                max(CGFloat($0.sourceWidth) / CGFloat($0.mapFullWidth), CGFloat($0.sourceHeight) / CGFloat($0.mapFullHeight))
            }.max() ?? .infinity
            guard axes.contains(where: { a in axes.contains { b in
                // Measure angular disagreement over one glyph, not a whole
                // long column where sub-cell detector jitter accumulates.
                // A one/two-glyph recovered fragment has too little baseline
                // to split its entire paragraph on a few pixels of quad tilt.
                // Long independently oriented columns still keep their owners.
                a.2 >= a.1 * 3 && b.2 >= b.1 * 3 &&
                    abs(a.0.x * b.0.y - a.0.y * b.0.x) * min(a.1, b.1) > cell
            } }) else { return [observation] }
            for id in sequence {
                let candidates = scopes.filter { owningScope(supports[id]!, scopes: [$0], minimumConfidence: 0.25) != nil }
                guard let owner = uniqueBest(candidates, score: { 1 / ($0.box.width * $0.box.height) }) else { return [observation] }
                nestedOwners[id] = owner
            }
            guard Set(nestedOwners.values.map(\.owner)).count > 1,
                  nestedOwners.values.contains(where: { $0.box.width * $0.box.height < common.box.width * common.box.height }) else { return [observation] }
        }
        var packetOwners: [Int:Int] = [:], owners: [Int:TextScope] = [:]
        for packet in inventory {
            guard let owner = nestedOwners[packet.raw.index] ?? owningScope(supports[packet.raw.index]!, scopes: scopes, minimumConfidence: 0.25)
                else { continue }
            packetOwners[packet.raw.index] = owner.owner
            owners[owner.owner] = owner
        }
        let adjacency = measuredColumnEdges(atoms: body)
        let directOwners = packetOwners
        for packet in inventory where packetOwners[packet.raw.index] == nil {
            let neighbors = adjacency.compactMap { edge -> Int? in
                if edge.first == packet.raw.index { return directOwners[edge.second] }
                if edge.second == packet.raw.index { return directOwners[edge.first] }
                return nil
            }
            guard Set(neighbors).count == 1, let owner = neighbors.first else { return [observation] }
            packetOwners[packet.raw.index] = owner
        }
        let grouped = Dictionary(grouping: sequence, by: { packetOwners[$0]! })
        guard grouped.count > 1, grouped.count <= 64,
              Set(packetOwners.values).isSubset(of: Set(grouped.keys)),
              componentSupport(table).independent.isSuperset(of: sequence) else { return [observation] }
        let keys = grouped.keys.sorted {
            let a = grouped[$0]!.map { boxes[$0]! }.reduce(CGRect.null) { $0.union($1) }
            let b = grouped[$1]!.map { boxes[$0]! }.reduce(CGRect.null) { $0.union($1) }
            return a.minY != b.minY ? a.minY < b.minY : a.minX > b.minX
        }
        func partition<Value>(_ values: [Value], box: (Value) -> CGRect) -> [Int:[Value]]? {
            var result: [Int:[Value]] = [:]
            for value in values {
                guard let owner = owningScope(box(value), scopes: keys.map { owners[$0]! }, minimumConfidence: 0.25)
                    else { return nil }
                result[owner.owner, default: []].append(value)
            }
            return result
        }
        guard let inkRects = partition(region.auxiliaryInkRects, box: { $0 }),
              let inkPolygons = partition(region.auxiliaryInkPolygons, box: pointBounds),
              let alternatives = partition(region.sourceOCRAlternatives, box: { $0.rect }) else { return [observation] }
        let text = Dictionary(uniqueKeysWithValues: zip(sequence, chunks))
        var output: [ObservedSource] = []
        for (index, owner) in keys.enumerated() {
            let ordered = grouped[owner]!, packets = ordered.map { table.packets[$0] }
            let seeds = packets.map(\.detectorSeedEvidence)
            let union = NativeOCRDetectorSeedEvidence.preservingUnion(seeds)
            guard union != nil || seeds.allSatisfy({ $0?.isEmpty ?? true }) else { return [observation] }
            let box = ordered.map { boxes[$0]! }.reduce(CGRect.null) { $0.union($1) }
            var block = sourceRevision(region, id: region.id + ".\(index)", rect: box,
                source: ordered.map { text[$0]! }.joined())
            block.confidence = packets.map(\.score).min() ?? region.confidence
            block.detectorSeedEvidence = union
            let child = NativeOCRAcceptedSource.Membership(table: table, body: Set(ordered),
                readings: membership.readings.filter { packetOwners[$0] == owner },
                unknownDedup: membership.unknownDedup, hasUntrackedInputs: membership.hasUntrackedInputs)
            block.acceptedSource = .init(child)
            preservingOriginalAngle(&block)
            block.auxiliaryInkRects = inkRects[owner] ?? []
            block.auxiliaryInkPolygons = inkPolygons[owner] ?? []
            block.sourceOCRAlternatives = alternatives[owner] ?? []
            block.isRecoveredLine = region.isRecoveredLine
            var observed = observingSource(block, read: (child, ordered, ordered.map { text[$0]! }))
            observed.scope = owners[owner]
            output.append(observed)
        }
        return output
    }

    /// Re-evaluate an existing aggregate against ORIGINAL packet-level RF
    /// owners. A broad aggregate envelope is not evidence that its children
    /// occupy one paragraph. Abstain on unowned packets rather than guessing.
    private static func separatedSupportedParagraphs(_ observation: ObservedSource, scopes: [TextScope]) -> [ObservedSource] {
        guard let read = observation.read, read.0.unknownDedup.isEmpty,
              let packets = observation.packets, packets.count > 1,
              packets.contains(where:{ !pointBounds($0.ink).isEmpty }),
              let frame = sourceAlignmentFrame(packets,table:read.0.table,
                horizontal:packets.allSatisfy { $0.raw.orientation == .horizontal }) else { return [observation] }
        let table = read.0.table, width = CGFloat(table.width), height = CGFloat(table.height)
        let horizontal = packets.allSatisfy { $0.raw.orientation == .horizontal }
        let boxes = Dictionary(uniqueKeysWithValues:packets.map {
            ($0.raw.index,pointBounds($0.polygon.map { $0.applying(frame) }))
        })
        // A disputed-only inline fragment can be bound to its uniquely
        // containing original shared-cell anchor. It is still not private
        // evidence, and cannot veto every other supported paragraph split.
        func claims(_ id:Int)->Set<SIMD3<Int>> {
            Set(packetEvidence(table,id).flatMap { e in
                (e.components+disputedComponents(e)).map {SIMD3(e.mapFullWidth,e.mapFullHeight,$0.seed)}
            })
        }
        var fragmentAnchors:[Int:Int]=[:]
        for packet in packets where pointBounds(packet.ink).isEmpty {
            let own=claims(packet.raw.index),box=boxes[packet.raw.index]!
            // An accepted seedless read retains its own quad and RF evidence.
            if own.isEmpty { continue }
            let cell=packetEvidence(table,packet.raw.index).map {
                hypot(1/CGFloat($0.mapFullWidth),CGFloat($0.sourceHeight)/CGFloat($0.mapFullHeight*$0.sourceWidth))
            }.max() ?? 0
            let anchors=packets.filter { host in
                guard host.raw.index != packet.raw.index,!pointBounds(host.ink).isEmpty,
                      !own.isEmpty,!own.isDisjoint(with:claims(host.raw.index)) else {return false}
                return boxes[host.raw.index]!.insetBy(dx:-cell*2,dy:-cell*2).contains(box)
            }
            guard anchors.count==1 else {return [observation]}
            fragmentAnchors[packet.raw.index]=anchors[0].raw.index
        }
        let owners = Dictionary(uniqueKeysWithValues:packets.compactMap { packet -> (Int,TextScope)? in
            let anchored=fragmentAnchors[packet.raw.index].flatMap {id in packets.first {$0.raw.index==id}}
            let ink = pointBounds(anchored?.ink ?? packet.ink).applying(.init(scaleX:1,y:width/height))
            let quad = pointBounds(packet.polygon).applying(.init(scaleX:1,y:width/height))
            let local = boxes[packet.raw.index]!
            let leading = CGRect(x:local.minX,y:local.minY,width:local.width,
                                 height:min(local.height,local.width*2))
            let head = pointBounds([CGPoint(x:leading.minX,y:leading.minY),CGPoint(x:leading.maxX,y:leading.minY),
                CGPoint(x:leading.maxX,y:leading.maxY),CGPoint(x:leading.minX,y:leading.maxY)].map {
                    $0.applying(frame.inverted())
                }).applying(.init(scaleX:1,y:width/height))
            guard let owner = owningScope(ink.isEmpty ? quad : ink,scopes:scopes,minimumConfidence:0.25) ??
                owningScope(head,scopes:scopes,minimumConfidence:0.25) else { return nil }
            return (packet.raw.index,owner)
        })
        guard owners.count == packets.count else { return [observation] }
        let nativeContour = observation.region.balloonInterior?.contourVerified == true
        let inlineBoundaries = Set(packets.flatMap { a in packets.compactMap { b -> Set<Int>? in
            guard a.raw.index < b.raw.index, independentInlineLabels(a.raw,b.raw) else { return nil }
            return Set([a.raw.index,b.raw.index])
        } })
        var graph = ObservationGraph(packets.map { $0.raw.index })
        for a in packets { for b in packets where b.raw.index > a.raw.index {
            if inlineBoundaries.contains(Set([a.raw.index,b.raw.index])) { continue }
            let x = boxes[a.raw.index]!, y = boxes[b.raw.index]!
            let glyph = min(x.width,y.width)
            let column=coherentColumn(x,y) && scopes.contains { scope in
                let ids=[a.raw.index,b.raw.index]
                return ids.allSatisfy { id in
                    let packet=packets.first { $0.raw.index == id }!
                    let ink=pointBounds(packet.ink).applying(.init(scaleX:1,y:width/height))
                    return owningScope(ink,scopes:[scope],minimumConfidence:0.25) != nil
                }
            }
            guard glyph > 0, max(x.width,y.width) <= glyph*2 || column else { continue }
            if opensUtterance(a.raw.source), opensUtterance(b.raw.source) { continue }
            let crossOverlap = min(x.maxX,y.maxX)-max(x.minX,y.minX)
            let alongGap = max(x.minY,y.minY)-min(x.maxY,y.maxY)
            let sameOwner = owners[a.raw.index]!.owner == owners[b.raw.index]!.owner
            let continued = crossOverlap >= glyph*0.6 && alongGap <= glyph*2 && sameOwner || column
            let leading = abs(x.minY-y.minY) <= glyph*0.5
            let gutter = max(x.minX,y.minX)-min(x.maxX,y.maxX)
            let differentScale = !horizontal && max(x.width,y.width) > glyph*1.5 &&
                min(x.height,y.height) < max(x.height,y.height)*0.65 && !column
            let neighboring = (sameOwner || nativeContour) && leading && gutter <= glyph*3 && !differentScale
            // Preserve a measured containing read/inline rail in its column;
            // never use a small inline fragment as a bridge between columns.
            let inline = sameOwner && (x.contains(y) || y.contains(x))
            if continued || neighboring || inline { graph.join(a.raw.index,b.raw.index) }
        } }
        for (fragment,anchor) in fragmentAnchors {graph.join(fragment,anchor)}
        let originalColumns=Array(graph.groups.values)
        for i in originalColumns.indices {for j in originalColumns.indices where j>i {
            let a=packets.filter {originalColumns[i].contains($0.raw.index)}
            let b=packets.filter {originalColumns[j].contains($0.raw.index)}
            if corroboratedNestedColumn(a,host:b,table:table,frame:frame,scopes:scopes) ||
                corroboratedNestedColumn(b,host:a,table:table,frame:frame,scopes:scopes),
                let first=originalColumns[i].first,let second=originalColumns[j].first {
                graph.join(first,second)
            }
        }}
        // Keep an already retained auxiliary source envelope intact when all
        // of its covered original packets fit it exactly. This binds existing
        // physical fragments; it grants no new source or erasure ownership.
        for polygon in observation.region.auxiliaryInkPolygons {
            let auxiliary=pointBounds(polygon)
            let covered=packets.filter { packet in
                let raw=pointBounds(table.packets[packet.raw.index].groupingPolygon).applying(.init(scaleX:1/width,y:1/height))
                return auxiliary.insetBy(dx:-1e-9,dy:-1e-9).contains(raw)
            }.map { $0.raw.index }
            // Auxiliary erasure envelopes can be produced by a previous
            // aggregate. They are not independent evidence of one paragraph
            // and must not override a measured split between RF text owners.
            let coveredOwners = covered.compactMap { owners[$0]?.owner }
            let ownerScopes = coveredOwners.compactMap { id in scopes.first { $0.owner == id } }
            // Coarse and fine RF queries can describe the same text context.
            // Require near-complete nesting of every distinct winning query;
            // disjoint owners still cannot use an auxiliary envelope to join.
            let nestedOwners = ownerScopes.count == coveredOwners.count && ownerScopes.allSatisfy { a in
                ownerScopes.allSatisfy { b in
                    if a.owner == b.owner { return true }
                    let shared = a.box.intersection(b.box)
                    let area = min(a.box.width * a.box.height, b.box.width * b.box.height)
                    return area > 0 && !shared.isNull && shared.width * shared.height >= area * 0.98
                }
            }
            if coveredOwners.count == covered.count, Set(coveredOwners).count == 1 || nestedOwners,
               !inlineBoundaries.contains(where: { $0.isSubset(of: Set(covered)) }), let first=covered.first {
                for id in covered.dropFirst() { graph.join(first,id) }
            }
        }
        let groups = Array(graph.groups.values)
        guard groups.count > 1 else { return [observation] }
        // Separate only when independent RF owners corroborate the partition,
        // or a large original font-scale break proves separate horizontal rows.
        let distinctOwners = Set(owners.values.map(\.owner)).count > 1
        let horizontalFontBreak = horizontal && boxes.values.map(\.width).max()! > boxes.values.map(\.width).min()!*2
        let quotedUnits = packets.filter { opensUtterance($0.raw.source) && closedUtterance($0.raw.source) }.count
        let quotedBreak = quotedUnits >= 2
        // RF may divide one already-read quoted utterance into several pieces.
        // Only independently complete quoted units prove a new quote boundary.
        if opensUtterance(observation.region.source), !quotedBreak { return [observation] }
        let starts = groups.map { ids in ids.map { boxes[$0]!.minY }.min()! }
        // A mixed-direction packet's long side is not its glyph thickness.
        let glyphs = boxes.values.map { min($0.width,$0.height) }.sorted()
        let glyph = glyphs[glyphs.count/2]
        let staggered = starts.max()!-starts.min()! > glyph*0.5
        let cohortBoxes = groups.map { ids in pointBounds(ids.flatMap { id in
            let box=boxes[id]!
            return [CGPoint(x:box.minX,y:box.minY),CGPoint(x:box.maxX,y:box.maxY)]
        }) }
        // A compact, smaller-font side note does not become body text merely
        // because one broad RF query also covers the neighboring full columns.
        let compactLateral = !horizontal && groups.indices.contains { small in groups.indices.contains { body in
            guard small != body,groups[body].count >= 2 else { return false }
            let x=cohortBoxes[small],y=cohortBoxes[body]
            let thin=groups[small].map { boxes[$0]!.width }.max()!
            let thick=groups[body].map { boxes[$0]!.width }.min()!
            let bodyBoxes=groups[body].map { boxes[$0]! }
            let columns=bodyBoxes.contains { a in bodyBoxes.contains { b in
                min(a.maxX,b.maxX)-max(a.minX,b.minX) <= min(a.width,b.width)*0.25
            } }
            return columns && thin <= thick*0.65 && x.height <= y.height*0.6 &&
                max(x.minX,y.minX)-min(x.maxX,y.maxX) >= thin*0.75
        } }
        let independentCohorts = groups.allSatisfy { $0.count >= 2 }
        let blankBreak = cohortBoxes.contains { a in cohortBoxes.contains { b in
            max(a.minY,b.minY)-min(a.maxY,b.maxY) > glyph*1.25
        } }
        let raisedCallout = !horizontal && cohortBoxes.contains { a in cohortBoxes.contains { b in
            a.height < glyph*2.5 && b.height >= glyph*2.5 && a.minY < b.minY &&
                b.minY-a.minY > glyph*0.5 && max(a.minX,b.minX)-min(a.maxX,b.maxX) > glyph*0.25
        } }
        let mixed = packets.contains { $0.raw.orientation == .horizontal } && packets.contains { $0.raw.orientation == .vertical }
        let horizontalArea = packets.filter { $0.raw.orientation == .horizontal }.reduce(CGFloat.zero) {
            let b=boxes[$1.raw.index]!;return $0+b.width*b.height
        }
        let verticalArea = packets.filter { $0.raw.orientation == .vertical }.reduce(CGFloat.zero) {
            let b=boxes[$1.raw.index]!;return $0+b.width*b.height
        }
        let dominantHorizontal = horizontalArea > verticalArea
        let dominant = pointBounds(packets.filter { ($0.raw.orientation == .horizontal) == dominantHorizontal }
            .flatMap(\.polygon).map { $0.applying(frame) })
        let mixedOutside = mixed && packets.contains { packet in
            (packet.raw.orientation == .horizontal) != dominantHorizontal &&
                !dominant.insetBy(dx:-glyph*0.25,dy:-glyph*0.25).contains(boxes[packet.raw.index]!)
        }
        // A separately RF-owned short utterance can start far below a
        // complete parallel paragraph, including overlapping sampling margins.
        // Require two long, distinct host columns and strong measured RF heads;
        // a broad aggregate/erasure envelope supplies no such certificate.
        let staggeredSingleton = !horizontal && groups.indices.contains { single in groups.indices.contains { host in
            guard single != host, groups[single].count == 1, !groups[host].isEmpty else { return false }
            let a = cohortBoxes[single], b = cohortBoxes[host]
            guard abs(a.minY - b.minY) > glyph * 2,
                  groups[single].allSatisfy({ (owners[$0]?.confidence ?? 0) >= 0.5 }),
                  groups[host].allSatisfy({ (owners[$0]?.confidence ?? 0) >= 0.5 }),
                  Set((groups[single] + groups[host]).compactMap { owners[$0]?.owner }).count > 1 else { return false }
            if groups[host].count == 1 {
                return a.height <= b.height * 0.75 && a.height >= glyph * 2
            }
            let columns = groups[host].map { boxes[$0]! }
            return columns.contains { x in columns.contains { y in
                min(x.height, y.height) >= glyph * 3 &&
                    min(x.maxX, y.maxX) - max(x.minX, y.minX) <= min(x.width, y.width) * 0.25
            } }
        } }
        guard distinctOwners && staggered && (independentCohorts || blankBreak || raisedCallout || staggeredSingleton) ||
            horizontalFontBreak || compactLateral || quotedBreak || mixedOutside || !inlineBoundaries.isEmpty else { return [observation] }
        let packetGroup = Dictionary(uniqueKeysWithValues:groups.enumerated().flatMap { index, ids in ids.map { ($0,index) } })
        let allAux = read.0.readings
        var readingGroups: [Int:Set<Int>] = [:]
        for id in allAux {
            let q = pointBounds(table.packets[id].groupingPolygon.map { CGPoint(x:$0.x/width,y:$0.y/width).applying(frame) })
            let candidates = groups.indices.filter { group in
                pointBounds(groups[group].flatMap { table.packets[$0].groupingPolygon }.map {
                    CGPoint(x:$0.x/width,y:$0.y/width).applying(frame)
                }).intersects(q)
            }
            guard candidates.count == 1 else { return [observation] }
            readingGroups[candidates[0],default:[]].insert(id)
        }
        // Erasure and rendering auxiliaries cannot be silently duplicated or
        // discarded while repartitioning physical OCR source membership.
        let groupBounds = groups.map { ids in pointBounds(ids.flatMap { table.packets[$0].groupingPolygon }).applying(
            .init(scaleX:1/width,y:1/height)) }
        func partition<Value>(_ values:[Value], bounds:(Value)->CGRect) -> [Int:[Value]]? {
            var result:[Int:[Value]] = [:]
            for value in values {
                let box = bounds(value)
                let owners = groupBounds.indices.filter { groupBounds[$0].insetBy(dx:-1e-9,dy:-1e-9).contains(box) }
                guard owners.count == 1 else { return nil }
                result[owners[0],default:[]].append(value)
            }
            return result
        }
        guard let rects = partition(observation.region.auxiliaryInkRects,bounds:{ $0 }),
              let polygons = partition(observation.region.auxiliaryInkPolygons,bounds:{ pointBounds($0) }),
              let alternatives = partition(observation.region.sourceOCRAlternatives,bounds:{ $0.rect }) else { return [observation] }
        let text = Dictionary(uniqueKeysWithValues:zip(read.1,read.2))
        return groups.enumerated().map { index, ids in
            let sequence = read.1.filter { packetGroup[$0] == index }
            let box = pointBounds(ids.flatMap { table.packets[$0].groupingPolygon })
            var part = sourceRevision(observation.region,id:observation.region.id+".paragraph\(index)",
                rect:CGRect(x:box.minX/width,y:box.minY/height,width:box.width/width,height:box.height/height),
                source:sequence.map { text[$0]! }.joined())
            let membership = NativeOCRAcceptedSource.Membership(table:table,body:Set(ids),
                readings:readingGroups[index] ?? [],unknownDedup:[],hasUntrackedInputs:false)
            part.acceptedSource = .init(membership)
            part.confidence = ids.map { table.packets[$0].score }.min()!
            part.detectorSeedEvidence = NativeOCRDetectorSeedEvidence.preservingUnion(
                membership.body.union(membership.readings).sorted().map { table.packets[$0].detectorSeedEvidence })
            part.balloonInterior = observation.region.balloonInterior
            part.auxiliaryInkRects = rects[index] ?? []
            part.auxiliaryInkPolygons = polygons[index] ?? []
            part.sourceOCRAlternatives = alternatives[index] ?? []
            preservingOriginalAngle(&part)
            return observingSource(part,read:(membership,sequence,sequence.map { text[$0]! }))
        }
    }

    /// A blank band across multiple independent columns is a paragraph break,
    /// not ordinary leading inside one interrupted column. Measure in the
    /// original common writing frame, never in the page's screen Y direction.
    private static func parallelParagraphBand(_ packets: [PacketObservation], table: NativeOCRAcceptedSource.PacketTable)
        -> (frame:CGAffineTransform,low:CGFloat,high:CGFloat)? {
        guard packets.count >= 4, packets.allSatisfy({ $0.raw.orientation == .vertical && !$0.ink.isEmpty }),
              let frame=sourceAlignmentFrame(packets,table:table) else { return nil }
        let boxes=packets.map { pointBounds($0.polygon.map { $0.applying(frame) }) }
        let widths=boxes.map(\.width).sorted(), glyph=widths[widths.count/2]
        guard glyph > 0 else { return nil }
        let sorted=boxes.sorted { $0.minY < $1.minY }
        var end=sorted[0].maxY
        for box in sorted.dropFirst() {
            if box.minY-end > glyph*1.25 {
                let above=boxes.filter { $0.maxY <= end }, below=boxes.filter { $0.minY >= box.minY }
                func independentColumns(_ rows:[CGRect]) -> Bool {
                    rows.count >= 2 && rows.contains { a in rows.contains { b in
                        min(a.maxX,b.maxX)-max(a.minX,b.minX) <= min(a.width,b.width)*0.25
                    } }
                }
                if independentColumns(above), independentColumns(below) { return (frame,end,box.minY) }
            }
            end=max(end,box.maxY)
        }
        return nil
    }

    private static func separatedParallelParagraphs(_ observation: ObservedSource) -> [ObservedSource] {
        guard let read=observation.read, let packets=observation.packets,
              let band=parallelParagraphBand(packets.filter { read.0.body.contains($0.raw.index) },table:read.0.table) else {
            return [observation]
        }
        let table=read.0.table, width=CGFloat(table.width), height=CGFloat(table.height)
        func side(_ polygon:[CGPoint]) -> Int? {
            let box=pointBounds(polygon.map { $0.applying(band.frame) })
            let epsilon=max(abs(box.minY),abs(box.maxY),1)*0.000000000001
            if box.maxY <= band.low+epsilon { return 0 }
            if box.minY >= band.high-epsilon { return 1 }
            return nil
        }
        var owners:[Int:Int]=[:]
        for id in read.0.body.union(read.0.readings).union(read.0.unknownDedup) {
            guard let owner=side(table.packets[id].groupingPolygon.map { CGPoint(x:$0.x/width,y:$0.y/width) }) else { return [observation] }
            owners[id]=owner
        }
        func partition<Value>(_ values:[Value], polygon:(Value)->[CGPoint]) -> [Int:[Value]]? {
            var result:[Int:[Value]]=[:]
            for value in values {
                let points=polygon(value).map { CGPoint(x:$0.x,y:$0.y*height/width) }
                guard let owner=side(points) else { return nil }
                result[owner,default:[]].append(value)
            }
            return result
        }
        let region=observation.region
        guard let rects=partition(region.auxiliaryInkRects,polygon:{ r in
            [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)]
        }), let polygons=partition(region.auxiliaryInkPolygons,polygon:{ $0 }),
           let alternatives=partition(region.sourceOCRAlternatives,polygon:{ r in
               [CGPoint(x:r.rect.minX,y:r.rect.minY),CGPoint(x:r.rect.maxX,y:r.rect.maxY)]
           }) else { return [observation] }
        let text=Dictionary(uniqueKeysWithValues:zip(read.1,read.2))
        return (0...1).compactMap { owner in
            let ids=read.1.filter { owners[$0] == owner }
            guard !ids.isEmpty else { return nil }
            let box=pointBounds(ids.flatMap { table.packets[$0].groupingPolygon })
            var part=sourceRevision(region,id:region.id+".band\(owner)",
                rect:CGRect(x:box.minX/width,y:box.minY/height,width:box.width/width,height:box.height/height),
                source:ids.map { text[$0]! }.joined())
            let membership=NativeOCRAcceptedSource.Membership(table:table,body:Set(ids),
                readings:read.0.readings.filter { owners[$0] == owner },
                unknownDedup:read.0.unknownDedup.filter { owners[$0] == owner },hasUntrackedInputs:false)
            part.acceptedSource = .init(membership)
            part.detectorSeedEvidence=NativeOCRDetectorSeedEvidence.preservingUnion(
                membership.body.union(membership.readings).sorted().map { table.packets[$0].detectorSeedEvidence })
            part.confidence=ids.map { table.packets[$0].score }.min()!
            part.auxiliaryInkRects=rects[owner] ?? [];part.auxiliaryInkPolygons=polygons[owner] ?? []
            part.sourceOCRAlternatives=alternatives[owner] ?? []
            preservingOriginalAngle(&part)
            return observingSource(part,read:(membership,ids,ids.map { text[$0]! }))
        }
    }

    /// Reject absent or ambiguous ownership without constructing a full match list.
    private static func uniqueIndex(_ indices: Range<Int>, matching matches: @escaping (Int) -> Bool) -> Int? {
        var iterator = indices.lazy.filter(matches).makeIterator()
        guard let only = iterator.next(), iterator.next() == nil else { return nil }
        return only
    }

    /// A conservative adapter: ambiguous original-to-live ownership is not a
    /// merge permission. Existing transcription, ruby and detector owners survive.
    @available(iOS 18.0, *)
    static func applying(_ input: [ReaderTranslationRegion], lines: [NativeCoreMLOCRLine],
                         ownerHints: [ReaderTranslationRegion], image: CGImage,
                         separates: (CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool) -> [ReaderTranslationRegion] {
        guard input.count >= 2, Set(input.map(\.id)).count == input.count,
              input.allSatisfy({ $0.translation == nil }), lines.count <= 4096 else { return input }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func normalized(_ box: CGRect) -> CGRect {
            .init(x: box.minX / width, y: box.minY / height, width: box.width / width, height: box.height / height)
        }
        func owner(_ box: CGRect, in regions: [ReaderTranslationRegion]) -> Int? {
            return uniqueIndex(regions.indices) { i in
                let r = regions[i], supports = r.unitMemberRects.isEmpty ? [r.rect] : r.unitMemberRects
                return r.rect == box || supports.contains { support in
                    let intersection = box.intersection(support)
                    return !intersection.isNull && intersection.width * intersection.height >= box.width * box.height * 0.9
                }
            }
        }
        var atoms: [Atom] = [], assignment: [Int: Int] = [:]
        for (i, line) in lines.enumerated() {
            guard line.polygon.count == 4, let box = NativeOCRScopeGeometry.bounds(for: line.polygon),
                  box.width > 0, box.height > 0, !line.text.isEmpty,
                  line.orientation == .vertical || line.orientation == .horizontal else { continue }
            // v6 was fitted to upright axes. Do not replace a slanted quad with its envelope.
            let p = line.polygon, glyph = line.orientation == .vertical ? box.width : box.height
            guard abs(p[1].y - p[0].y) <= glyph * 0.15,
                  abs(p[3].x - p[0].x) <= glyph * 0.15,
                  let slot = owner(normalized(box), in: input), !input[slot].isOccludedFinePrint else { continue }
            atoms.append(.init(index: i, source: line.text, box: box, orientation: line.orientation,
                               owner: owner(normalized(box), in: ownerHints)))
            assignment[i] = slot
        }
        // Skip a region with any unaccounted original member. Partial evidence
        // may not reclassify a larger live paragraph as a short singleton.
        let completeSlots = Set(input.indices.filter { i in
            let assigned = atoms.filter { assignment[$0.index] == i }
            guard !assigned.isEmpty else { return false }
            let supports = input[i].unitMemberRects.isEmpty ? [input[i].rect] : input[i].unitMemberRects
            return supports.allSatisfy { support in
                coveredArea(support, by: assigned.map { normalized($0.box) }) >= support.width * support.height * 0.9
            }
        })
        atoms = atoms.filter { completeSlots.contains(assignment[$0.index]!) }
        let groups = Dictionary(grouping: atoms, by: { assignment[$0.index]! }).values.map { $0.map(\.index) }
        var cache: [Int: Ink?] = [:]
        let inferred = infer(atoms: atoms, groups: groups, separates: { a, b in
            if separates(a.box, b.box, .vertical) { return true }
            let ra = input[assignment[a.index]!], rb = input[assignment[b.index]!]
            if let x = ra.balloonInterior, let y = rb.balloonInterior,
               x.contourVerified == true, y.contourVerified == true,
               (x.rect != y.rect || x.center != y.center || x.spans != y.spans) { return true }
            return false
        }, ink: { atom in
            if let value = cache[atom.index] { return value }
            let value = sampleInk(lines[atom.index].detectorSeedEvidence, image: image)
            cache[atom.index] = .some(value)
            return value
        })
        guard !inferred.edges.isEmpty else { return input }
        var regions = Dictionary(uniqueKeysWithValues: input.indices.map { ($0, input[$0]) })
        var graph = ObservationGraph(Array(input.indices))
        let byID = Dictionary(uniqueKeysWithValues: atoms.map { ($0.index, $0) })
        for edge in inferred.edges {
            let ai = graph.root(assignment[edge.first]!), bi = graph.root(assignment[edge.second]!)
            guard ai != bi, let a = regions[ai], let b = regions[bi],
                  let aa = byID[edge.first], let bb = byID[edge.second] else { continue }
            let source: String
            if edge.reason == "overlapping-single-glyph" {
                let h = aa.orientation == .horizontal ? aa : bb, v = aa.orientation == .vertical ? aa : bb
                let fragment = h.index == aa.index ? a : b, body = h.index == aa.index ? b : a
                // Insert only at the uniquely identified original column substring.
                // Concatenating a stray glyph at the paragraph's end changes meaning.
                guard fragment.source == h.source, body.source.components(separatedBy: v.source).count == 2,
                      let range = body.source.range(of: v.source) else { continue }
                var value = body.source
                value.replaceSubrange(range, with: h.box.minY <= v.box.minY ? h.source + v.source : v.source + h.source)
                source = value
            } else {
                source = aa.box.midX > bb.box.midX ? a.source + b.source : b.source + a.source
            }
            let seeds = NativeOCRDetectorSeedEvidence.preservingUnion([a.detectorSeedEvidence, b.detectorSeedEvidence])
            guard seeds != nil || [a.detectorSeedEvidence, b.detectorSeedEvidence].allSatisfy({ $0?.isEmpty ?? true }) else { continue }
            let anchor = min(ai, bi), other = max(ai, bi), box = a.rect.union(b.rect)
            var merged = sourceRevision(input[anchor], rect: box, source: source)
            merged.confidence = min(a.confidence, b.confidence)
            merged.sourceImageAspectRatio = a.sourceImageAspectRatio ?? b.sourceImageAspectRatio ?? Double(width / height)
            merged.unitMemberRects = (a.unitMemberRects.isEmpty ? [a.rect] : a.unitMemberRects) +
                (b.unitMemberRects.isEmpty ? [b.rect] : b.unitMemberRects)
            merged.auxiliaryInkRects = a.auxiliaryInkRects + b.auxiliaryInkRects
            merged.auxiliaryInkPolygons = a.auxiliaryInkPolygons + b.auxiliaryInkPolygons +
                [a.polygon, b.polygon].filter { $0.count >= 3 }
            merged.detectorSeedEvidence = seeds
            merged.acceptedSource = .union([a.acceptedSource, b.acceptedSource])
            preservingOriginalAngle(&merged)
            merged.sourceOCRAlternatives = a.sourceOCRAlternatives + b.sourceOCRAlternatives
            merged.isRecoveredLine = a.isRecoveredLine || b.isRecoveredLine
            // The semantic attachment does not certify one measured balloon.
            merged.balloonInterior = nil
            regions[anchor] = merged; regions.removeValue(forKey: other); graph.join(anchor, other)
        }
        return input.indices.compactMap { regions[$0] }
    }

    /// Rectangle union coverage is an ownership completeness check, not a mask.
    /// Merely touching a member cannot account for its unobserved remainder.

    /// Rectangle union coverage is an ownership completeness check, not a mask.
    /// Merely touching a member cannot account for its unobserved remainder.
    private static func coveredArea(_ support: CGRect, by boxes: [CGRect]) -> CGFloat {
        let clipped = boxes.map { $0.intersection(support) }.filter { !$0.isNull && !$0.isEmpty }
        let xs = Set(clipped.flatMap { [$0.minX, $0.maxX] }).sorted()
        guard xs.count >= 2 else { return 0 }
        var area: CGFloat = 0
        for (left, right) in zip(xs, xs.dropFirst()) {
            let intervals = clipped.filter { $0.minX <= left && $0.maxX >= right }.sorted { $0.minY < $1.minY }
            var low: CGFloat?, high: CGFloat = 0, length: CGFloat = 0
            for box in intervals {
                if let start = low {
                    if box.minY <= high { high = max(high, box.maxY) }
                    else { length += high - start; low = box.minY; high = box.maxY }
                } else { low = box.minY; high = box.maxY }
            }
            if let start = low { length += high - start }
            area += (right - left) * length
        }
        return area
    }

    /// Same bounded minority-contrast proxy used by the v6 experiment. Unknown
    /// probability cells remain merely sampling support, never erasure WRITE.
    static func sampleInk(_ evidence: [NativeOCRDetectorSeedEvidence]?, image: CGImage) -> Ink? {
        var rgb: [[Double]] = []
        for owner in (evidence ?? []).prefix(16) {
            guard let roi = owner.sourceProbabilityROI, roi.isValid,
                  roi.sourceWidth == image.width, roi.sourceHeight == image.height else { continue }
            let indices = roi.upperBounds.enumerated().compactMap { $0.element >= 230 ? $0.offset : nil }
            guard !indices.isEmpty else { continue }
            let count = min(256, indices.count), box = roi.roi
            guard let crop = image.cropping(to: CGRect(x: box.x, y: box.y, width: box.width, height: box.height)) else { continue }
            var bytes = [UInt8](repeating: 0, count: box.width * box.height * 4)
            let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: box.width, height: box.height, bitsPerComponent: 8,
                                              bytesPerRow: box.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.translateBy(x: 0, y: CGFloat(box.height)); context.scaleBy(x: 1, y: -1)
                context.draw(crop, in: CGRect(x: 0, y: 0, width: box.width, height: box.height))
                return true
            }
            guard drawn else { continue }
            for k in 0..<count {
                let index = count == 1 ? indices[0] : indices[k * (indices.count - 1) / (count - 1)], offset = index * 4
                rgb.append([Double(bytes[offset]), Double(bytes[offset + 1]), Double(bytes[offset + 2])])
            }
        }
        guard !rgb.isEmpty else { return nil }
        let luminance = rgb.map { $0[0] * 0.2126 + $0[1] * 0.7152 + $0[2] * 0.0722 }, sorted = luminance.sorted()
        func percentile(_ q: Double) -> Double {
            let index = Double(sorted.count - 1) * q, lo = Int(index), hi = min(lo + 1, sorted.count - 1)
            return sorted[lo] + (sorted[hi] - sorted[lo]) * (index - Double(lo))
        }
        let low = percentile(0.1), high = percentile(0.9)
        guard high - low >= 65 else { return nil }
        let dark = rgb.indices.filter { luminance[$0] < low + 0.25 * (high - low) }
        let light = rgb.indices.filter { luminance[$0] > high - 0.25 * (high - low) }
        let chosen = dark.count <= light.count ? dark : light
        guard chosen.count >= 8 else { return nil }
        let median = (0..<3).map { channel -> Double in
            let values = chosen.map { rgb[$0][channel] }.sorted(), n = values.count
            return n % 2 == 0 ? (values[n / 2 - 1] + values[n / 2]) / 2 : values[n / 2]
        }
        return .init(rgb: median, samples: chosen.count)
    }
}
