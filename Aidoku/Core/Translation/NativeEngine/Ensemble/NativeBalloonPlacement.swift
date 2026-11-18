import CoreGraphics
import CoreFoundation
import Foundation

/// Predicted balloon body, excluding its narrow tail. Never a clipping certificate.
struct NativeBalloonPlacement: Codable, Equatable, Sendable {
    enum Flow: String, Codable, Sendable { case row, column }
    enum CrossAlignment: String, Codable, Sendable { case start, center, end }
    var crossAlignment: CrossAlignment? = nil
    let bodyID: String
    var rectNormalized: [Double]
    var preserveSourceOffsets: Bool? = nil
    /// Operational final-paint policy; never used while choosing glyph wraps.
    var finalReadabilityGaps: Bool? = nil
    let biasNormalized: [Double]
    var flow: Flow
    let paddingEm: Double
    let gapEm: Double
    let maskSHA256: String
    var order: Int
    var valid: Bool {
        !bodyID.isEmpty && bodyID.count <= 128 && rectNormalized.count == 4 &&
        rectNormalized.allSatisfy(\.isFinite) && rectNormalized[2] > 0 && rectNormalized[3] > 0 &&
        CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx:-1e-9,dy:-1e-9).contains(rect(in: CGRect(x: 0, y: 0, width: 1, height: 1))) &&
        biasNormalized.count == 2 && biasNormalized.allSatisfy { $0.isFinite && abs($0) <= 0.6 } &&
        paddingEm.isFinite && (0...2).contains(paddingEm) && gapEm.isFinite && (0...2).contains(gapEm) &&
        order >= 0 && maskSHA256.count == 64
    }
    func rect(in page: CGRect) -> CGRect {
        CGRect(x: rectNormalized[0] * page.width, y: rectNormalized[1] * page.height,
               width: rectNormalized[2] * page.width, height: rectNormalized[3] * page.height)
    }
    static func decode(_ value: Any?) throws -> Self? {
        guard let value, !(value is NSNull) else { return nil }
        let packet = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        guard packet.valid else { throw NativeSourceClusterAlignment.Failure.invalidPacket }
        return packet
    }
    /// Entire block has one body-relative center, one em gap, and source reading order.
    /// Oversized blocks explicitly fall back; they are never clipped or shrunk here.
    static func targets(_ packets: [Self?], bounds: [CGRect], fonts: [CGFloat], page: CGRect, guides:[NativeTextPlacementGuide?]? = nil) throws -> [CGPoint?] {
        guard packets.count == bounds.count, fonts.count == bounds.count,guides == nil || guides!.count == bounds.count else { throw NativeSourceClusterAlignment.Failure.invalidPacket }
        var result = [CGPoint?](repeating: nil, count: packets.count)
        var groups: [String: [Int]] = [:]
        for (i, p) in packets.enumerated() {
            guard let p else { continue }
            guard p.valid else { throw NativeSourceClusterAlignment.Failure.invalidPacket }
            groups[p.bodyID, default: []].append(i)
        }
        for members in groups.values {
            let first = packets[members[0]]!
            guard members.allSatisfy({ i in
                let p = packets[i]!
                return p.rectNormalized == first.rectNormalized && p.flow == first.flow &&
                    p.biasNormalized == first.biasNormalized && p.paddingEm == first.paddingEm &&
                    p.gapEm == first.gapEm && p.preserveSourceOffsets == first.preserveSourceOffsets &&
                    p.finalReadabilityGaps == first.finalReadabilityGaps && p.crossAlignment == first.crossAlignment && p.maskSHA256 == first.maskSHA256
            }), Set(members.map { packets[$0]!.order }).count == members.count else {
                throw NativeSourceClusterAlignment.Failure.inconsistentGroup
            }
            let ordered = members.sorted { packets[$0]!.order < packets[$1]!.order }
            let em = members.map { fonts[$0] }.max()!
            if first.preserveSourceOffsets == true,let guides,members.allSatisfy({ guides[$0] != nil }) {
                let body=first.rect(in:page),row=first.flow == .row
                guard members.allSatisfy({ bounds[$0].width<=body.width && bounds[$0].height<=body.height }) else { continue }
                let fraction:CGFloat=(first.crossAlignment ?? .start) == .center ? 0.5 : (first.crossAlignment == .end ? 1 : 0)
                let sourceCross=ordered.map { i -> CGFloat in
                    let r=guides[i]!.rect(in:page)
                    return row ? r.minY+r.height*fraction : r.minX+r.width*fraction
                }.sorted()
                let align=(sourceCross.last!-sourceCross.first!)<=em*0.5
                let n=sourceCross.count,anchor=n%2==1 ? sourceCross[n/2] : (sourceCross[n/2-1]+sourceCross[n/2])/2
                for i in ordered {
                    let desired=guides[i]!.preferredShift(bounds:bounds[i],page:page)
                    var x=bounds[i].minX+desired.x,y=bounds[i].minY+desired.y
                    if align { if row { y=(anchor-bounds[i].height*fraction).rounded() } else { x=(anchor-bounds[i].width*fraction).rounded() } }
                    x=min(max(ceil(body.minX),x.rounded()),floor(body.maxX-bounds[i].width))
                    y=min(max(ceil(body.minY),y.rounded()),floor(body.maxY-bounds[i].height))
                    result[i]=CGPoint(x:x-bounds[i].minX,y:y-bounds[i].minY)
                }
                if first.finalReadabilityGaps == true {
                    // Reflow widens source columns. Keeping independent source
                    // origins must not erase the boundary between two paragraphs.
                    // Derive the same bounded ordered targets during final verify.
                    var runs:[[Int]]=[]
                    for i in ordered {
                        if let previous=runs.last?.last,let a=result[previous],let b=result[i] {
                            let A=bounds[previous].offsetBy(dx:a.x,dy:a.y),B=bounds[i].offsetBy(dx:b.x,dy:b.y)
                            let overlap=row ? min(A.maxY,B.maxY)-max(A.minY,B.minY):min(A.maxX,B.maxX)-max(A.minX,B.minX)
                            let cross=row ? min(A.height,B.height):min(A.width,B.width)
                            if overlap>=cross*0.5 {runs[runs.count-1].append(i);continue}
                        }
                        runs.append([i])
                    }
                    let trace=ProcessInfo.processInfo.environment["AIDOKU_TRACE_COHORT"] == "1"
                    if trace {fputs("body-gutter-input \(first.bodyID) row=\(row) runs=\(runs) body=\(body) bounds=\(bounds) offsets=\(result)\n",stderr)}
                    for run in runs where run.count>1 {
                        let targets=run.map {i -> CGRect in bounds[i].offsetBy(dx:result[i]!.x,dy:result[i]!.y)}
                        let desired=zip(run,run.dropFirst()).map {a,b -> CGFloat in
                            let A=guides[a]!.rect(in:page),B=guides[b]!.rect(in:page),font=max(fonts[a],fonts[b])
                            let observed=max(0,row ? B.minX-A.maxX:B.minY-A.maxY)
                            return ceil(max(font*0.35,min(observed*0.65,font*1.25)))
                        }
                        let gaps=zip(targets,targets.dropFirst()).map {row ? $1.minX-$0.maxX:$1.minY-$0.maxY}
                        if trace {fputs("body-gutter-gaps \(first.bodyID) before=\(gaps) desired=\(desired)\n",stderr)}
                        guard zip(gaps,desired).contains(where:{$0+0.01<$1})else{continue}
                        let options=run.enumerated().map {n,i -> NativeSourceCohortPacking.Option in
                            let target=targets[n],preferred=row ? target.minX:target.minY
                            let extent=row ? target.width:target.height,limit=fonts[i]*1.25
                            return .init(index:i,extent:extent,
                                lower:max(row ? body.minX:body.minY,preferred-limit),
                                upper:min((row ? body.maxX:body.maxY)-extent,preferred+limit),
                                preferred:preferred,unit:fonts[i],cost:0)
                        }
                        let relaxation=Int(ceil(desired.max() ?? 0))
                        for step in 0...relaxation {
                            let proposed=zip(gaps,desired).map {old,target in max(old,max(ceil(em*0.35),target-CGFloat(step)))}
                            guard let packed=NativeSourceCohortPacking.quadraticOrigins(options,gaps:proposed)else{continue}
                            if trace {fputs("body-gutter-packed \(first.bodyID) origins=\(packed) gaps=\(proposed)\n",stderr)}
                            for (n,i)in run.enumerated() {
                                let origin=packed[n],point=targets[n].origin
                                result[i]=CGPoint(x:(row ? origin:point.x)-bounds[i].minX,
                                    y:(row ? point.y:origin)-bounds[i].minY)
                            }
                            break
                        }
                    }
                }
                continue
            }
            let pad = ceil(CGFloat(first.paddingEm) * em), gap = ceil(CGFloat(first.gapEm) * em)
            let body = first.rect(in: page).insetBy(dx: pad, dy: pad)
            let row = first.flow == .row
            let width = row ? ordered.reduce(0) { $0 + bounds[$1].width } + gap * CGFloat(ordered.count - 1)
                : ordered.map { bounds[$0].width }.max()!
            let height = row ? ordered.map { bounds[$0].height }.max()!
                : ordered.reduce(0) { $0 + bounds[$1].height } + gap * CGFloat(ordered.count - 1)
            guard width <= body.width, height <= body.height else { continue }
            let x = (body.midX - width / 2 + CGFloat(first.biasNormalized[0]) * (body.width - width) / 2).rounded()
            let y = (body.midY - height / 2 + CGFloat(first.biasNormalized[1]) * (body.height - height) / 2).rounded()
            var cursor: CGFloat = 0
            for i in ordered {
                let free = row ? height - bounds[i].height : width - bounds[i].width
                let cross: CGFloat
                switch first.crossAlignment ?? .start {
                case .start: cross = 0
                case .center: cross = (free / 2).rounded()
                case .end: cross = free.rounded()
                }
                result[i] = CGPoint(x: x + (row ? cursor : cross) - bounds[i].minX,
                                    y: y + (row ? cross : cursor) - bounds[i].minY)
                cursor += (row ? bounds[i].width : bounds[i].height) + gap
            }
        }
        return result
    }
    static func sourceNearPackets(_ input:[Self?],guides:[NativeTextPlacementGuide?],fonts:[CGFloat],
                                  capacities:[[Double]?],page:CGRect)->[Self?] {
        guard input.count==guides.count,input.count==fonts.count,input.count==capacities.count else { return input }
        var result=input,groups:[String:[Int]]=[:]
        for (i,p) in input.enumerated() { if let p { groups[p.bodyID,default:[]].append(i) } }
        for members in groups.values where members.count>1 {
            let first=input[members[0]]!
            guard first.preserveSourceOffsets == nil,members.allSatisfy({ guides[$0] != nil }) else { continue }
            guard members.allSatisfy({ input[$0]!.flow==first.flow }),
                  Set(members.map { input[$0]!.order }).count==members.count else { continue }
            // Unequal line lengths move their centres sideways; that is not
            // evidence that vertically stacked source paragraphs form a row.
            let flow=sourceFlow(members.map { guides[$0]!.rect(in:page) },fallback:first.flow)
            let row=flow == .row,ordered=members.sorted {
                let a=guides[$0]!.rect(in:page),b=guides[$1]!.rect(in:page)
                let x=row ? a.minX : a.minY,y=row ? b.minX : b.minY
                return x == y ? input[$0]!.order<input[$1]!.order : x<y
            }
            for (order,i) in ordered.enumerated() {
                result[i]!.flow=flow;result[i]!.order=order
            }
            let em=members.map { fonts[$0] }.max()!,sources=ordered.map { guides[$0]!.rect(in:page) }
            let gaps=zip(sources,sources.dropFirst()).map { row ? $1.minX-$0.maxX : $1.minY-$0.maxY }
            let cross=sources.map { row ? $0.midY : $0.midX }
            guard gaps.contains(where: { $0>em*1.5 || $0 < -em*0.25 }) || cross.max()!-cross.min()!>em*2 else { continue }
            let available=members.compactMap { capacities[$0] }.map { r in CGRect(x:r[0],y:r[1],width:r[2],height:r[3]) }
            let capacity=available.reduce(CGRect.null) { $0.union($1) }
            for i in members {
                var p=result[i]!;p.preserveSourceOffsets=true
                if !capacity.isNull { p.rectNormalized=[Double(capacity.minX),Double(capacity.minY),Double(capacity.width),Double(capacity.height)] }
                result[i]=p
            }
        }
        return result
    }

    static func sourceFlow(_ rects:[CGRect],fallback:Flow)->Flow {
        var rows=0,columns=0
        for i in rects.indices {
            for j in rects.indices where j>i {
                let a=rects[i],b=rects[j]
                let x=min(a.maxX,b.maxX)-max(a.minX,b.minX)
                let y=min(a.maxY,b.maxY)-max(a.minY,b.minY)
                if x>=0.5*min(a.width,b.width) && y<=0.15*min(a.height,b.height) { columns+=1 }
                if y>=0.5*min(a.height,b.height) && x<=0.15*min(a.width,b.width) { rows+=1 }
            }
        }
        if columns>0 && rows==0 { return .column }
        if rows>0 && columns==0 { return .row }
        return fallback
    }

}

/// Synchronize only explicit source-similar typography families; preserve weight.
enum NativeTypographyConsistency {
    static func harmonized(_ input: [[String: Any]]) -> [[String: Any]] {
        var result = input, groups: [String: [Int]] = [:]
        func reference(_ i: Int) -> Double {
            ((input[i]["sourceRequestedDisplayFontSize"] ?? input[i]["fontSize"]) as? NSNumber)?.doubleValue ?? 0
        }
        for i in input.indices {
            guard let group = input[i]["typographyGroupID"] as? String, !group.isEmpty,
                  reference(i).isFinite, reference(i) > 0 else { continue }
            let weight = input[i]["sourceFontWeight"] as? String ?? "unknown"
            let bold = (input[i]["renderBold"] as? Bool).map(String.init) ?? "unknown"
            groups[group + "|" + weight + "|" + bold, default: []].append(i)
        }
        for members in groups.values {
            var bands: [[Int]] = []
            for i in members.sorted(by: { reference($0) < reference($1) }) {
                if bands.isEmpty || reference(i) > reference(bands.last!.first!) * 1.08 { bands.append([]) }
                bands[bands.count - 1].append(i)
            }
            for band in bands where band.count > 1 {
                let sorted = band.map(reference).sorted(), n = band.count
                let median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
                let pitch = max(1.4, band.map { i in
                    (input[i]["lineHeightEm"] as? Double) ?? 1.4
                }.filter { $0.isFinite && (1...4).contains($0) }.max() ?? 1.4)
                for i in band {
                    result[i]["sourceRequestedDisplayFontSize"] = median
                    result[i]["fontSize"] = median
                    result[i]["lineHeight"] = median * pitch
                    result[i]["lineHeightEm"] = pitch
                    result[i]["trackingEm"] = 0
                }
            }
        }
        return result
    }
}

extension NativeBalloonPlacement {
    /// Transaction state, not a physical-domain certificate. Kept in this file
    /// so existing explicit-source host consumers need no new dependency.
    enum RetainedState {
        static let auditKey = "retainedBalloonState"
        enum Failure: Error { case malformed, budget, binding, partialGroup, unsafeRevalidation }
        enum Presence: String, Codable { case present, absent }
        enum Target: String, Codable { case placed, fallback, absent, unknown }
        enum Provenance: String, Codable { case nativeAdmission, authenticatedLegacyCandidate, fixedOriginRevalidated }
        enum DeclaredRequest { case absent, packet(NativeBalloonPlacement) }
        struct Snapshot: Codable, Equatable {
            let schema: Int
            let owner: String
            let presence: Presence
            let inputPacket: NativeBalloonPlacement?
            let effectivePacket: NativeBalloonPlacement?
            let groupOwners: [String]
            let balloonTargetRelaxed: Bool?
            let target: Target
            let fallbackReason: String?
            let provenance: Provenance
            let requiresFixedOriginRevalidation: Bool
            let historicalStateExact: Bool
            let sourceIdentity: String?
        }
        enum Read { case missing, state(Snapshot) }
        /// The caller authenticates this complete request against its producer.
        /// This type validates structure/membership, not cryptographic authority.
        struct AuthenticatedRawGroup {
            let packets: [String:NativeBalloonPlacement]
            let sourceIdentity: String
            init(packets: [String:NativeBalloonPlacement], expectedOwnerIDs: Set<String>, sourceIdentity: String) throws {
                guard !sourceIdentity.isEmpty, sourceIdentity.utf8.count <= 4096,
                      !packets.isEmpty, packets.count <= 256,
                      Set(packets.keys) == expectedOwnerIDs else { throw Failure.partialGroup }
                try RetainedState.validateGroup(packets)
                self.packets = packets; self.sourceIdentity = sourceIdentity
            }
        }
        static func validOwner(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 512 }
        static func validPacket(_ p: NativeBalloonPlacement) -> Bool {
            p.valid && p.maskSHA256.utf8.count == 64 && p.maskSHA256.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        }
        static func validateGroup(_ packets: [String:NativeBalloonPlacement]) throws {
            guard let first = packets.values.first, packets.keys.allSatisfy(validOwner),
                  packets.values.allSatisfy({ validPacket($0) }),
                  Set(packets.values.map(\.order)).count == packets.count else { throw Failure.malformed }
            for p in packets.values {
                var a = p, b = first; a.order = 0; b.order = 0
                guard a == b else { throw Failure.binding }
            }
        }
        static func validate(_ s: Snapshot) throws {
            guard s.schema == 1, validOwner(s.owner), !s.groupOwners.isEmpty, s.groupOwners.count <= 256,
                  s.groupOwners.allSatisfy(validOwner), s.groupOwners == s.groupOwners.sorted(),
                  Set(s.groupOwners).count == s.groupOwners.count, s.groupOwners.contains(s.owner),
                  (s.fallbackReason?.utf8.count ?? 0) <= 512, (s.sourceIdentity?.utf8.count ?? 0) <= 4096,
                  s.inputPacket.map(validPacket) ?? true, s.effectivePacket.map(validPacket) ?? true else { throw Failure.malformed }
            if s.presence == .absent {
                guard s.effectivePacket == nil, s.inputPacket == nil, s.groupOwners == [s.owner],
                      (s.provenance == .authenticatedLegacyCandidate ? s.target == .unknown :
                        (s.balloonTargetRelaxed == false && s.target == .absent)) else { throw Failure.malformed }
            } else {
                guard let p = s.effectivePacket, let input = s.inputPacket,
                      p.bodyID == input.bodyID, p.maskSHA256 == input.maskSHA256,
                      s.target != .absent else { throw Failure.binding }
            }
            switch s.provenance {
            case .authenticatedLegacyCandidate:
                guard s.requiresFixedOriginRevalidation, !s.historicalStateExact, s.target == .unknown, s.balloonTargetRelaxed == nil,
                      s.sourceIdentity?.isEmpty == false else { throw Failure.malformed }
            case .nativeAdmission, .fixedOriginRevalidated:
                guard !s.requiresFixedOriginRevalidation, s.balloonTargetRelaxed != nil, s.target != .unknown,
                      s.provenance != .fixedOriginRevalidated || !s.historicalStateExact,
                      s.target != .placed || s.balloonTargetRelaxed == false else { throw Failure.malformed }
            }
        }
        /// Complete effective membership, never caller-supplied partitions.
        static func validateGroups(_ states: [String:Snapshot]) throws {
            guard states.count <= 256 else { throw Failure.budget }
            for (owner,state) in states { try validate(state); guard state.owner == owner else { throw Failure.binding } }
            let groups = Dictionary(grouping:states.values.filter { $0.presence == .present },by: { $0.effectivePacket!.bodyID })
            for members in groups.values {
                let first = members[0], actual = Set(members.map(\.owner))
                var packets: [String:NativeBalloonPlacement] = [:]
                for state in members {
                    guard Set(state.groupOwners) == actual, state.target == first.target,
                          state.balloonTargetRelaxed == first.balloonTargetRelaxed,
                          state.provenance == first.provenance, state.historicalStateExact == first.historicalStateExact,
                          state.requiresFixedOriginRevalidation == first.requiresFixedOriginRevalidation,
                          state.sourceIdentity == first.sourceIdentity else { throw Failure.partialGroup }
                    packets[state.owner] = state.effectivePacket!
                }
                try validateGroup(packets)
            }
        }
        static func capture(owner: String, inputPacket: NativeBalloonPlacement?, effectivePacket: NativeBalloonPlacement?,
                            groupOwners: [String], relaxed: Bool, targetPlaced: Bool, fallbackReason: String?) throws -> Snapshot {
            let state = Snapshot(schema:1,owner:owner,presence:effectivePacket == nil ? .absent:.present,
                inputPacket:inputPacket,effectivePacket:effectivePacket,groupOwners:groupOwners.sorted(),
                balloonTargetRelaxed:relaxed,target:effectivePacket == nil ? .absent:(targetPlaced ? .placed:.fallback),
                fallbackReason:fallbackReason,provenance:.nativeAdmission,requiresFixedOriginRevalidation:false,historicalStateExact:true,sourceIdentity:nil)
            try validate(state); return state
        }
        private static func packetObject(_ p: NativeBalloonPlacement?) throws -> Any {
            guard let p else { return NSNull() }
            var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any]
            // Explicit null preserves nil vs false for every optional policy flag.
            for key in ["preserveSourceOffsets","finalReadabilityGaps","crossAlignment"] where object[key] == nil { object[key] = NSNull() }
            return object
        }
        static func encode(_ s: Snapshot) throws -> [String:Any] {
            try validate(s)
            var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(s)) as! [String:Any]
            object["inputPacket"] = try packetObject(s.inputPacket)
            object["effectivePacket"] = try packetObject(s.effectivePacket)
            object["balloonTargetRelaxed"] = s.balloonTargetRelaxed as Any? ?? NSNull()
            object["fallbackReason"] = s.fallbackReason as Any? ?? NSNull()
            object["sourceIdentity"] = s.sourceIdentity as Any? ?? NSNull()
            guard try JSONSerialization.data(withJSONObject:object).count <= 65_536 else { throw Failure.budget }
            return object
        }
        /// Bound arbitrary untrusted JSON BEFORE serialization/JSONDecoder.
        private static func preflight(_ value: Any, depth: Int = 0, nodes: inout Int, bytes: inout Int) throws {
            nodes += 1; guard nodes <= 4096, depth <= 10 else { throw Failure.budget }
            if let s = value as? String { bytes += s.utf8.count; guard s.utf8.count <= 4096 else { throw Failure.budget } }
            else if let d = value as? [String:Any] {
                guard d.count <= 32 else { throw Failure.budget }
                for (k,v) in d { bytes += k.utf8.count; try preflight(v,depth:depth+1,nodes:&nodes,bytes:&bytes) }
            } else if let a = value as? [Any] {
                guard a.count <= 256 else { throw Failure.budget }
                for v in a { try preflight(v,depth:depth+1,nodes:&nodes,bytes:&bytes) }
            } else if let n = value as? NSNumber { guard n.doubleValue.isFinite else { throw Failure.malformed } }
            else if !(value is NSNull) { throw Failure.malformed }
            guard bytes <= 65_536 else { throw Failure.budget }
        }
        static func decode(_ value: Any, owner: String, declaredRequest: DeclaredRequest? = nil) throws -> Snapshot {
            var nodes = 0, bytes = 0; try preflight(value,nodes:&nodes,bytes:&bytes)
            guard let object = value as? [String:Any], Set(object.keys) == Set([
                "schema","owner","presence","inputPacket","effectivePacket","groupOwners","balloonTargetRelaxed",
                "target","fallbackReason","provenance","requiresFixedOriginRevalidation","historicalStateExact","sourceIdentity"]) else { throw Failure.malformed }
            let packetKeys: Set<String> = ["bodyID","rectNormalized","preserveSourceOffsets","finalReadabilityGaps",
                "crossAlignment","biasNormalized","flow","paddingEm","gapEm","maskSHA256","order"]
            for key in ["inputPacket","effectivePacket"] {
                if let packet = object[key] as? [String:Any] { guard Set(packet.keys) == packetKeys else { throw Failure.malformed } }
                else if !(object[key] is NSNull) { throw Failure.malformed }
            }
            let data = try JSONSerialization.data(withJSONObject:object)
            guard data.count <= 65_536 else { throw Failure.budget }
            let state = try JSONDecoder().decode(Snapshot.self,from:data)
            try validate(state); guard state.owner == owner else { throw Failure.binding }
            if let declaredRequest {
                switch declaredRequest {
                case .absent: guard state.presence == .absent else { throw Failure.binding }
                case .packet(let request):
                    guard validPacket(request), let p = state.effectivePacket,
                          p.bodyID == request.bodyID, p.maskSHA256 == request.maskSHA256 else { throw Failure.binding }
                }
            }
            return state
        }
        enum UnknownPolicy {
            /// Unknown/missing history is not an unchanged known transition.
            case reject
            /// Keep the prior candidate or missing state, never the fresh
            /// capture's manufactured historical certainty. No validation claim.
            case preservePriorUncertainty
        }
        enum ReadmissionInput {
            /// Fresh admission received the retained effective carrier packet.
            case retainedEffectivePacket
            /// Fresh admission received exactly the same declared input packet.
            case unchangedInputPacket
        }
        private static func lineageBool(_ value: Any?) -> Bool? {
            guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        }
        private static func bindKnownAudit(_ row: [String:Any], state: Snapshot) throws {
            guard row["owner"] as? String == state.owner,
                  lineageBool(row["balloonBodyPlaced"]) == (state.target == .placed),
                  lineageBool(row["balloonCapacityFallback"]) == (state.target == .fallback),
                  lineageBool(row["balloonTargetRelaxed"]) == state.balloonTargetRelaxed else { throw Failure.binding }
            if let packet = state.effectivePacket {
                guard row["balloonBodyID"] as? String == packet.bodyID else { throw Failure.binding }
            } else {
                guard row["balloonBodyID"] is NSNull else { throw Failure.binding }
            }
        }
        private static func lineageKnown(_ state: Snapshot) -> Bool {
            !state.requiresFixedOriginRevalidation && state.target != .unknown && state.provenance != .authenticatedLegacyCandidate
        }
        private static func lineageRows(_ rows: [[String:Any]]) throws -> [String:Int] {
            guard rows.count <= 256 else { throw Failure.budget }
            var indices: [String:Int] = [:]
            for (index,row) in rows.enumerated() {
                guard let owner = row["owner"] as? String, validOwner(owner),
                      indices.updateValue(index,forKey:owner) == nil else { throw Failure.malformed }
            }
            return indices
        }
        private static func lineageStates(_ rows: [[String:Any]], indices: [String:Int]) throws -> [String:Snapshot] {
            var states: [String:Snapshot] = [:]
            for (owner,index) in indices {
                if case .state(let state) = try read(rows[index],owner:owner) { states[owner] = state }
            }
            let known = states.filter { lineageKnown($0.value) }
            try validateGroups(known)
            // Known membership must include ALL observed peers, including an
            // unknown snapshot or a scalar-only peer of that same body.
            for state in known.values where state.presence == .present {
                let body = state.effectivePacket!.bodyID
                let actual = Set(indices.keys.filter { owner in
                    states[owner]?.effectivePacket?.bodyID == body || rows[indices[owner]!]["balloonBodyID"] as? String == body
                })
                guard actual == Set(state.groupOwners) else { throw Failure.partialGroup }
            }
            return states
        }
        /// Preserve lineage only for unchanged semantics after a NEW actual
        /// admission. This utility does not admit geometry, authorize a body
        /// relaxation, or turn an unknown packet into historical knowledge.
        /// Both arrays are immutable; returned rows follow admitted owner order.
        static func preservingKnownSnapshots(priorAudit: [[String:Any]], admittedAudit: [[String:Any]],
            unknownPolicy: UnknownPolicy, inputPolicy: ReadmissionInput = .retainedEffectivePacket) throws -> [[String:Any]] {
            let priorRows = try lineageRows(priorAudit), freshRows = try lineageRows(admittedAudit)
            guard Set(priorRows.keys) == Set(freshRows.keys) else { throw Failure.partialGroup }
            let priorStates = try lineageStates(priorAudit,indices:priorRows)
            let freshStates = try lineageStates(admittedAudit,indices:freshRows)
            var result = admittedAudit
            for (owner,index) in freshRows {
                let oldIndex = priorRows[owner]!, old = priorStates[owner], fresh = freshStates[owner]
                if let old, lineageKnown(old) {
                    guard let fresh, lineageKnown(fresh), old.presence == fresh.presence,
                          old.effectivePacket == fresh.effectivePacket, old.groupOwners == fresh.groupOwners,
                          old.target == fresh.target, old.balloonTargetRelaxed == fresh.balloonTargetRelaxed else { throw Failure.binding }
                    let expectedInput: NativeBalloonPlacement?
                    switch inputPolicy {
                    case .retainedEffectivePacket: expectedInput = old.effectivePacket
                    case .unchangedInputPacket: expectedInput = old.inputPacket
                    }
                    guard fresh.inputPacket == expectedInput else { throw Failure.binding }
                    try bindKnownAudit(priorAudit[oldIndex],state:old)
                    try bindKnownAudit(admittedAudit[index],state:fresh)
                    // Copy the exact original JSON object, NOT recapture or a
                    // partial field overlay. Generic inherited-relaxation must
                    // not erase an explicit earlier policy fallback reason.
                    result[index][auditKey] = priorAudit[oldIndex][auditKey]!
                    result[index]["balloonTargetFallbackReason"] = old.fallbackReason as Any? ?? NSNull()
                    try bindKnownAudit(result[index],state:old)
                } else {
                    switch unknownPolicy {
                    case .reject: throw Failure.unsafeRevalidation
                    case .preservePriorUncertainty:
                        if let old {
                            // A candidate remains uncertain, but cannot be
                            // silently rebound to a different packet/group.
                            if let fresh {
                                let expectedInput: NativeBalloonPlacement?
                                switch inputPolicy {
                                case .retainedEffectivePacket: expectedInput = old.effectivePacket
                                case .unchangedInputPacket: expectedInput = old.inputPacket
                                }
                                guard old.presence == fresh.presence, old.effectivePacket == fresh.effectivePacket,
                                      old.groupOwners == fresh.groupOwners, fresh.inputPacket == expectedInput else { throw Failure.binding }
                            }
                            result[index][auditKey] = priorAudit[oldIndex][auditKey]!
                        } else { result[index].removeValue(forKey:auditKey) }
                    }
                }
            }
            // Check all copied known groups again; no partial application can
            // escape by array reordering or splitting a same-body partition.
            _ = try lineageStates(result,indices:freshRows)
            return result
        }

        /// Explicit lineage transition for a caller-verified physical repair.
        /// This packet-only function cannot validate alpha, domains, risk gates
        /// or geometry: admittedAudit MUST come from that actual native place.
        /// It authorizes no unknown, reverse, partial or packet-changing body.
        static func preservingPhysicalReadmission(priorAudit: [[String:Any]], admittedAudit: [[String:Any]],
            transitionedBodyIDs: Set<String>, unknownPolicy: UnknownPolicy,
            inputPolicy: ReadmissionInput = .retainedEffectivePacket) throws -> [[String:Any]] {
            guard transitionedBodyIDs.count <= 256,
                  transitionedBodyIDs.allSatisfy({ !$0.isEmpty && $0.count <= 128 }) else { throw Failure.budget }
            let oldRows = try lineageRows(priorAudit), newRows = try lineageRows(admittedAudit)
            guard Set(oldRows.keys) == Set(newRows.keys) else { throw Failure.partialGroup }
            let oldStates = try lineageStates(priorAudit,indices:oldRows)
            let newStates = try lineageStates(admittedAudit,indices:newRows)
            let reason = "physical-readmission-body-relaxation"
            var staged = priorAudit, transitionedOwners = Set<String>()
            var markers: [String:[String:Any]] = [:]
            for body in transitionedBodyIDs.sorted() {
                let members = oldStates.values.filter { $0.effectivePacket?.bodyID == body }.map(\.owner).sorted()
                guard !members.isEmpty, let first = members.first,
                      oldStates[first]?.groupOwners == members else { throw Failure.partialGroup }
                for owner in members {
                    guard let old = oldStates[owner], let fresh = newStates[owner],
                          lineageKnown(old), lineageKnown(fresh), old.presence == .present, fresh.presence == .present,
                          old.balloonTargetRelaxed == false, fresh.balloonTargetRelaxed == true,
                          old.target == .placed || old.target == .fallback, fresh.target == .fallback,
                          fresh.provenance == .nativeAdmission,
                          old.effectivePacket == fresh.effectivePacket, old.groupOwners == fresh.groupOwners else { throw Failure.unsafeRevalidation }
                    let expectedInput: NativeBalloonPlacement?
                    switch inputPolicy {
                    case .retainedEffectivePacket: expectedInput = old.effectivePacket
                    case .unchangedInputPacket: expectedInput = old.inputPacket
                    }
                    guard fresh.inputPacket == expectedInput else { throw Failure.binding }
                    try bindKnownAudit(priorAudit[oldRows[owner]!],state:old)
                    try bindKnownAudit(admittedAudit[newRows[owner]!],state:fresh)
                    let state = Snapshot(schema:old.schema,owner:owner,presence:old.presence,inputPacket:old.inputPacket,
                        effectivePacket:old.effectivePacket,groupOwners:old.groupOwners,balloonTargetRelaxed:true,
                        target:.fallback,fallbackReason:reason,provenance:.nativeAdmission,
                        requiresFixedOriginRevalidation:false,historicalStateExact:old.historicalStateExact,sourceIdentity:old.sourceIdentity)
                    let index = oldRows[owner]!
                    staged[index][auditKey] = try encode(state)
                    staged[index]["balloonBodyPlaced"] = false
                    staged[index]["balloonCapacityFallback"] = true
                    staged[index]["balloonTargetRelaxed"] = true
                    staged[index]["balloonTargetFallbackReason"] = reason
                    markers[owner] = ["reason":reason,"bodyID":body,"members":members,"completeGroup":true,
                        "previousTarget":old.target.rawValue,"previousRelaxed":false,"newTarget":"fallback","newRelaxed":true,
                        "geometryAuthority":"caller-validated-native-admission","physicalContainmentMeasured":false]
                    transitionedOwners.insert(owner)
                }
            }
            // Explicit unknown policy may preserve uncertainty, but cannot hide
            // ANY observed target/flag/body transition of an unknown peer.
            for owner in oldRows.keys where !transitionedOwners.contains(owner) {
                if oldStates[owner].map({ lineageKnown($0) }) != true {
                    for key in ["balloonBodyID","balloonBodyPlaced","balloonCapacityFallback","balloonTargetRelaxed"] {
                        let old = priorAudit[oldRows[owner]!][key], fresh = admittedAudit[newRows[owner]!][key]
                        if old == nil && fresh == nil { continue }
                        if key != "balloonBodyID" {
                            let oldFlag = lineageBool(old), newFlag = lineageBool(fresh)
                            if oldFlag != nil || newFlag != nil {
                                guard let oldFlag, let newFlag, oldFlag == newFlag else { throw Failure.unsafeRevalidation }
                                continue
                            }
                        }
                        guard let old, let fresh,
                              NSDictionary(dictionary:[key:old]).isEqual(to:[key:fresh]) else { throw Failure.unsafeRevalidation }
                    }
                }
            }
            // Stage only the fully authorized state transition, then use the
            // exact same preservation/binding contract for every owner. All
            // changes remain local until this complete transaction succeeds.
            var result = try preservingKnownSnapshots(priorAudit:staged,admittedAudit:admittedAudit,
                unknownPolicy:unknownPolicy,inputPolicy:inputPolicy)
            for (owner,marker) in markers { result[newRows[owner]!]["retainedBalloonPhysicalReadmission"] = marker }
            return result
        }

        static func read(_ audit: [String:Any], owner: String, declaredRequest: DeclaredRequest? = nil) throws -> Read {
            guard let value = audit[auditKey] else { return .missing }
            return .state(try decode(value,owner:owner,declaredRequest:declaredRequest))
        }
    }
}
