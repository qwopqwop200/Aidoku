import CoreGraphics
import Foundation

/// Terminal, owner-local refinement. The factory paints at retained typography;
/// this helper never shapes, draws, changes a source packet, or retries a page.
enum NativeBalloonReadabilityReflow {
    typealias Primitive = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    typealias Footprint = NativeFinalTextPaintAdmission.Footprint
    /// True means complete source observation; nil is never admission.
    typealias ShapeGate = (String, Footprint, Footprint) -> (allowed: Bool?, audit: [String:Any])
    private final class InteriorSearch {
        let original: [String:Footprint]
        let gate: ShapeGate
        var origins: [String:Int] = [:]
        init(original:[String:Footprint], gate:@escaping ShapeGate) { self.original=original;self.gate=gate }
        func reserve(_ owner:String,_ width:CGFloat)->Bool {
            let key=owner+"|"+String(Double(width)),count=origins[key,default:0]
            guard count<8 else{return false};origins[key]=count+1;return true
        }
    }
    struct Descriptor {
        let text: String
        let ranges: [NSRange]
    }
    struct Candidate {
        var fill: Primitive
        let ranges: [NSRange]
        var metadata: [String: Any] = [:]
    }
    struct Result {
        var fills: [Primitive]
        var audit: [[String: Any]]
        var selected: [String: Candidate]
        var diagnostics: [String: Any] = [:]
    }

    private static let interiorOutcomeLimit = 768
    private static let interiorOwnerFailureLimit = 256

    /// Reviewed terminal lexical repair; explicit OFF performs no raster work.
    static var interiorWordsEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_INTERIOR_WORD_REFLOW"] != "0"
    }

    static var interiorMeasuredWidthsEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_INTERIOR_MEASURED_WIDTHS"] != "0"
    }

    /// Preserve the complete retained-width result before attempting measured
    /// widths. New geometry cannot invalidate a previously accepted owner.
    static func refineInteriorWords(_ input: (fills:[Primitive],audit:[[String:Any]]),
        descriptors:[String:Descriptor],page:CGRect,completePeerContext:Bool,restored:CGImage?=nil,
        outerWidths:(String)throws->CGFloat?,extraOuterWidths:((String)throws->[CGFloat])?=nil,
        allowRowReduction:Bool=false,shapeGate:ShapeGate?=nil,
        makeContour:((String,CGFloat,CGRect)throws->Candidate?)?=nil,
        make:(String,CGFloat,CGRect)throws->Candidate?)throws->Result {
        let legacy=try interiorWordsOneFamily(input,descriptors:descriptors,page:page,
            completePeerContext:completePeerContext,restored:restored,outerWidths:outerWidths,
            extraOuterWidths:extraOuterWidths,allowRowReduction:allowRowReduction,shapeGate:shapeGate,make:make)
        // Contour-aware breaks supplement the COMPLETE fixed-width search.
        // Never replace its winners or feed their new glyphs back as source
        // evidence. Each factory family retains its own bounded origin budget.
        guard let makeContour,let shapeGate else{return legacy}
        let remaining=descriptors.filter {legacy.selected[$0.key]==nil}
        guard !remaining.isEmpty else{return legacy}
        var contour=try interiorWordsOneFamily((legacy.fills,legacy.audit),descriptors:remaining,page:page,
            completePeerContext:completePeerContext,restored:restored,outerWidths:outerWidths,
            extraOuterWidths:extraOuterWidths,allowRowReduction:allowRowReduction,shapeGate:shapeGate,make:makeContour)
        let contourOwners=contour.selected.keys.sorted()
        contour.selected=legacy.selected.merging(contour.selected){old,_ in old}
        let oldDiagnostics=legacy.diagnostics,newDiagnostics=contour.diagnostics
        for key in ["candidateOutcomes","originOutcomes"] {
            let a=(oldDiagnostics[key]as?[[String:Any]] ?? []).map {row->[String:Any] in
                var value=row;value["shapeFamily"]="fixed-width";return value
            }
            let b=(newDiagnostics[key]as?[[String:Any]] ?? []).map {row->[String:Any] in
                var value=row;value["shapeFamily"]="contour-widths";return value
            }
            contour.diagnostics[key]=Array((a+b).prefix(interiorOutcomeLimit))
        }
        for key in ["candidateOutcomeCount","originOutcomeCount","shapeCalls","fixedOriginAdmissionCalls","actualFactoryCalls"] {
            contour.diagnostics[key]=(oldDiagnostics[key]as?Int ?? 0)+(newDiagnostics[key]as?Int ?? 0)
        }
        for (array,count) in [("candidateOutcomes","candidateOutcomeCount"),("originOutcomes","originOutcomeCount")] {
            let stored=(contour.diagnostics[array]as?[[String:Any]])?.count ?? 0
            let total=contour.diagnostics[count]as?Int ?? 0
            contour.diagnostics[array+"Truncated"]=total>stored
            contour.diagnostics[array+"TruncatedCount"]=max(0,total-stored)
        }
        var rejected=oldDiagnostics["rejections"]as?[String:Int] ?? [:]
        for (reason,count) in newDiagnostics["rejections"]as?[String:Int] ?? [:]{rejected[reason,default:0]+=count}
        contour.diagnostics["rejections"]=rejected
        var statuses=oldDiagnostics["candidateOutcomeStatusCounts"]as?[String:Int] ?? [:]
        for (status,count) in newDiagnostics["candidateOutcomeStatusCounts"]as?[String:Int] ?? [:]{statuses[status,default:0]+=count}
        contour.diagnostics["candidateOutcomeStatusCounts"]=statuses
        contour.diagnostics["contourFallbackOwners"]=contourOwners
        contour.diagnostics["fixedWidthWinnerOwners"]=legacy.selected.keys.sorted()
        contour.diagnostics["fixedWidthWinnersPreserved"]=true
        contour.diagnostics["shapeFamilyLimit"]=2
        contour.diagnostics["originBudgetPerOwnerWidthPerShapeFamily"]=8
        return contour
    }

    private static func interiorWordsOneFamily(_ input: (fills:[Primitive],audit:[[String:Any]]),
        descriptors:[String:Descriptor],page:CGRect,completePeerContext:Bool,restored:CGImage?=nil,
        outerWidths:(String)throws->CGFloat?,extraOuterWidths:((String)throws->[CGFloat])?=nil,
        allowRowReduction:Bool=false,shapeGate:ShapeGate?=nil,
        make:(String,CGFloat,CGRect)throws->Candidate?)throws->Result {
        guard let shapeGate else {
            return try interiorWordsSequence(input,descriptors:descriptors,page:page,completePeerContext:completePeerContext,
                restored:restored,outerWidths:outerWidths,extraOuterWidths:extraOuterWidths,allowRowReduction:allowRowReduction,make:make)
        }
        guard interiorWordsEnabled,completePeerContext else{return .init(fills:input.fills,audit:input.audit,selected:[:])}
        var original:[String:Footprint]=[:]
        guard input.fills.count<=256,input.fills.count==input.audit.count else{return .init(fills:input.fills,audit:input.audit,selected:[:])}
        do {
            var work=0
            for fill in input.fills {
                try Task.checkCancellation()
                guard let owner=fill.ownerID,original[owner]==nil else{return .init(fills:input.fills,audit:input.audit,selected:[:])}
                let support=try NativeFinalTextPaintAdmission.retainedFootprint(fill)
                work+=support.runs.count
                guard work<=1_000_000 else{return .init(fills:input.fills,audit:input.audit,selected:[:])}
                original[owner]=support
            }
        } catch {
            if error is CancellationError{throw error}
            return .init(fills:input.fills,audit:input.audit,selected:[:])
        }
        let search=InteriorSearch(original:original,gate:shapeGate)
        var factoryCount=0
        func countedMake(_ owner:String,_ width:CGFloat,_ bounds:CGRect)throws->Candidate? {
            factoryCount+=1;return try make(owner,width,bounds)
        }
        var legacy=try interiorWordsSequence(input,descriptors:descriptors,page:page,completePeerContext:completePeerContext,
            restored:restored,outerWidths:outerWidths,extraOuterWidths:extraOuterWidths,allowRowReduction:allowRowReduction,
            search:search,make:countedMake)
        legacy.diagnostics["actualFactoryCalls"]=factoryCount
        legacy.diagnostics["shapeGateBeforeAuthority"]="immutable-original-outer-input"
        legacy.diagnostics["originAttemptsByOwnerWidth"]=search.origins
        legacy.diagnostics["legacyWinnerPriority"]=true
        let remaining=descriptors.filter {legacy.selected[$0.key]==nil}
        guard !remaining.isEmpty else{return legacy}
        var expanded=try interiorWordsSequence((legacy.fills,legacy.audit),descriptors:remaining,page:page,
            completePeerContext:completePeerContext,restored:restored,outerWidths:outerWidths,
            extraOuterWidths:extraOuterWidths,allowRowReduction:allowRowReduction,search:search,expandedSearch:true,make:countedMake)
        expanded.selected=legacy.selected.merging(expanded.selected){old,_ in old}
        var summary=expanded.diagnostics
        for key in ["candidateOutcomes","originOutcomes","ownerFailures"]{summary.removeValue(forKey:key)}
        for key in ["candidateOutcomes","originOutcomes","ownerFailures"] {
            let a=legacy.diagnostics[key]as?[[String:Any]] ?? [],b=expanded.diagnostics[key]as?[[String:Any]] ?? []
            expanded.diagnostics[key]=Array((a+b).prefix(interiorOutcomeLimit))
        }
        for key in ["candidateOutcomeCount","ownerFailureCount","shapeCalls","fixedOriginAdmissionCalls","actualFactoryCalls"] {
            expanded.diagnostics[key]=(legacy.diagnostics[key]as?Int ?? 0)+(summary[key]as?Int ?? 0)
        }
        let stored=(expanded.diagnostics["candidateOutcomes"]as?[[String:Any]])?.count ?? 0
        let total=expanded.diagnostics["candidateOutcomeCount"]as?Int ?? 0
        expanded.diagnostics["candidateOutcomesTruncated"]=total>stored
        expanded.diagnostics["candidateOutcomesTruncatedCount"]=max(0,total-stored)
        var rejections=legacy.diagnostics["rejections"]as?[String:Int] ?? [:]
        for (key,n) in summary["rejections"]as?[String:Int] ?? [:]{rejections[key,default:0]+=n}
        expanded.diagnostics["rejections"]=rejections
        var statuses=legacy.diagnostics["candidateOutcomeStatusCounts"]as?[String:Int] ?? [:]
        for (key,n) in summary["candidateOutcomeStatusCounts"]as?[String:Int] ?? [:]{statuses[key,default:0]+=n}
        expanded.diagnostics["candidateOutcomeStatusCounts"]=statuses
        expanded.diagnostics["actualFactoryCalls"]=factoryCount
        expanded.diagnostics["legacySearchDiagnostics"]=legacy.diagnostics
        expanded.diagnostics["expandedSearchDiagnostics"]=summary
        expanded.diagnostics["legacyWinnerPriority"]=true
        expanded.diagnostics["shapeGateBeforeAuthority"]="immutable-original-outer-input"
        expanded.diagnostics["originBudgetPerOwnerWidth"]=8
        expanded.diagnostics["originAttemptsByOwnerWidth"]=search.origins
        expanded.diagnostics["originOutcomeCount"]=(legacy.diagnostics["originOutcomeCount"]as?Int ?? 0)+(summary["originOutcomeCount"]as?Int ?? 0)
        expanded.diagnostics["originOutcomesTruncated"]=((expanded.diagnostics["originOutcomes"]as?[[String:Any]])?.count ?? 0)<(expanded.diagnostics["originOutcomeCount"]as?Int ?? 0)
        return expanded
    }

    private static func interiorWordsSequence(_ input: (fills: [Primitive], audit: [[String: Any]]),
                                    descriptors: [String: Descriptor], page: CGRect, completePeerContext: Bool,
                                    restored: CGImage? = nil, outerWidths: (String) throws -> CGFloat?,
                                    extraOuterWidths: ((String) throws -> [CGFloat])? = nil,
                                    allowRowReduction: Bool = false,
                                    search: InteriorSearch? = nil, expandedSearch: Bool = false,
                                    make: (String, CGFloat, CGRect) throws -> Candidate?) throws -> Result {
        guard interiorMeasuredWidthsEnabled,extraOuterWidths != nil else {
            return try refineInteriorWordsPass(input,descriptors:descriptors,page:page,
                completePeerContext:completePeerContext,restored:restored,outerWidths:outerWidths,
                measuredWidths:false,search:search,expandedSearch:expandedSearch,make:make)
        }
        var cached:[String:(width:CGFloat,bounds:CGRect,value:Candidate?)]=[:]
        var factoryCalls=0
        let incumbent=try refineInteriorWordsPass(input,descriptors:descriptors,page:page,
            completePeerContext:completePeerContext,restored:restored,outerWidths:outerWidths,
            measuredWidths:false,search:search,expandedSearch:expandedSearch) {owner,width,bounds in
                factoryCalls+=1
                let value=try make(owner,width,bounds)
                cached[owner]=(width,bounds,value)
                return value
            }
        var remaining=descriptors
        for (owner,candidate) in incumbent.selected {
            if let descriptor=descriptors[owner] {
                remaining[owner]=Descriptor(text:descriptor.text,ranges:candidate.ranges)
            }
        }
        var refined=try refineInteriorWordsPass((incumbent.fills,incumbent.audit),
            descriptors:remaining,page:page,completePeerContext:completePeerContext,
            restored:restored,outerWidths:outerWidths,extraOuterWidths:extraOuterWidths,
            allowRowReduction:allowRowReduction,measuredWidths:true,
            skipInitialOwners:Set(incumbent.selected.keys),search:search,expandedSearch:expandedSearch) {owner,width,bounds in
                if let entry=cached[owner],entry.width==width,entry.bounds==bounds {return entry.value}
                factoryCalls+=1
                return try make(owner,width,bounds)
            }
        // Keep failures from BOTH passes, even when the measured pass has no
        // eligible owners. One page-wide cap; nested summaries omit duplicates.
        let superseded = Set(incumbent.selected.keys).intersection(refined.selected.keys)
        var incumbentOutcomes = incumbent.diagnostics["candidateOutcomes"] as? [[String:Any]] ?? []
        for i in incumbentOutcomes.indices where incumbentOutcomes[i]["status"] as? String == "selected" &&
            superseded.contains(incumbentOutcomes[i]["owner"] as? String ?? "") {
            incumbentOutcomes[i]["status"] = "admissible-not-selected"
            incumbentOutcomes[i]["reason"] = "superseded-by-measured-pass"
        }
        let measuredOutcomes = refined.diagnostics["candidateOutcomes"] as? [[String:Any]] ?? []
        let totalOutcomes = (incumbent.diagnostics["candidateOutcomeCount"] as? Int ?? 0) +
            (refined.diagnostics["candidateOutcomeCount"] as? Int ?? 0)
        let combinedOutcomes = Array((incumbentOutcomes + measuredOutcomes).prefix(interiorOutcomeLimit))
        var statuses = incumbent.diagnostics["candidateOutcomeStatusCounts"] as? [String:Int] ?? [:]
        for (key,count) in refined.diagnostics["candidateOutcomeStatusCounts"] as? [String:Int] ?? [:] {
            statuses[key,default:0] += count
        }
        if !superseded.isEmpty {
            statuses["selected",default:0] -= superseded.count
            statuses["admissible-not-selected",default:0] += superseded.count
        }
        var rejections = incumbent.diagnostics["rejections"] as? [String:Int] ?? [:]
        for (key,count) in refined.diagnostics["rejections"] as? [String:Int] ?? [:] { rejections[key,default:0] += count }
        let ownerFailures = (incumbent.diagnostics["ownerFailures"] as? [[String:Any]] ?? []) +
            (refined.diagnostics["ownerFailures"] as? [[String:Any]] ?? [])
        let ownerFailureCount = (incumbent.diagnostics["ownerFailureCount"] as? Int ?? 0) +
            (refined.diagnostics["ownerFailureCount"] as? Int ?? 0)
        var incumbentSummary = incumbent.diagnostics
        incumbentSummary.removeValue(forKey:"candidateOutcomes")
        incumbentSummary.removeValue(forKey:"ownerFailures")
        if search != nil{incumbentSummary.removeValue(forKey:"originOutcomes")}
        refined.selected=incumbent.selected.merging(refined.selected) {_,new in new}
        if search != nil {
        let originRecords=(incumbent.diagnostics["originOutcomes"]as?[[String:Any]] ?? []) + (refined.diagnostics["originOutcomes"]as?[[String:Any]] ?? [])
        let originCount=(incumbent.diagnostics["originOutcomeCount"]as?Int ?? 0)+(refined.diagnostics["originOutcomeCount"]as?Int ?? 0)
        refined.diagnostics["originOutcomes"]=Array(originRecords.prefix(interiorOutcomeLimit))
        refined.diagnostics["originOutcomeCount"]=originCount
        refined.diagnostics["originOutcomesTruncated"]=originRecords.count>interiorOutcomeLimit || originCount>originRecords.count
        }
        refined.diagnostics["retainedWidthIncumbentDiagnostics"]=incumbentSummary
        refined.diagnostics["candidateOutcomes"]=combinedOutcomes
        refined.diagnostics["candidateOutcomeCount"]=totalOutcomes
        refined.diagnostics["candidateOutcomesTruncatedCount"]=totalOutcomes-combinedOutcomes.count
        refined.diagnostics["candidateOutcomesTruncated"]=totalOutcomes>combinedOutcomes.count
        refined.diagnostics["candidateOutcomeLimit"]=interiorOutcomeLimit
        refined.diagnostics["candidateOutcomeStatusCounts"]=statuses
        refined.diagnostics["rejections"]=rejections
        refined.diagnostics["ownerFailures"]=Array(ownerFailures.prefix(interiorOwnerFailureLimit))
        refined.diagnostics["ownerFailureCount"]=ownerFailureCount
        refined.diagnostics["ownerFailuresTruncatedCount"]=ownerFailureCount-min(ownerFailures.count,interiorOwnerFailureLimit)
        refined.diagnostics["retainedWidthIncumbentOwners"]=incumbent.selected.keys.sorted()
        refined.diagnostics["actualFactoryCalls"]=factoryCalls
        refined.diagnostics["retainedWidthIncumbentPreserved"]=true
        return refined
    }

    private static func refineInteriorWordsPass(_ input: (fills: [Primitive], audit: [[String: Any]]),
                                    descriptors: [String: Descriptor], page: CGRect, completePeerContext: Bool,
                                    restored: CGImage? = nil, outerWidths: (String) throws -> CGFloat?,
                                    extraOuterWidths: ((String) throws -> [CGFloat])? = nil,
                                    allowRowReduction: Bool = false,measuredWidths:Bool,
                                    skipInitialOwners:Set<String>=[],search:InteriorSearch?=nil,expandedSearch:Bool=false,
                                    make: (String, CGFloat, CGRect) throws -> Candidate?) throws -> Result {
        var current = Result(fills: input.fills, audit: input.audit, selected: [:])
        guard interiorWordsEnabled else { return current }
        try Task.checkCancellation()
        let owners = input.fills.compactMap(\.ownerID)
        guard completePeerContext, !page.isEmpty, page == page.integral,
              [page.minX, page.minY, page.width, page.height].allSatisfy(\.isFinite),
              owners.count == input.fills.count, Set(owners).count == owners.count,
              input.audit.count == owners.count,
              input.audit.indices.allSatisfy({ input.audit[$0]["owner"] as? String == owners[$0] }) else { return current }
        let eligible = input.fills.indices.filter { i in
            let fill = input.fills[i]
            guard let descriptor = descriptors[owners[i]], validOwnership(descriptor.text, descriptor.ranges),
                  let policy = fill.textExpansionPolicy, policy.valid, policy.insideBalloon,
                  let guide = fill.textPlacementGuide, guide.valid,
                  abs(guide.sourceRotationRadians ?? 0) <= 1e-6,
                  fill.fontOutputPixels.isFinite, fill.fontOutputPixels > 0,
                  ceil(fill.fontOutputPixels * 0.35) <= 512 else { return false }
            return !NativeRenderWrapQuality.wordCutOffsets(descriptor.text, ranges: descriptor.ranges).isEmpty
        }
        guard !eligible.isEmpty else { return current }
        var supports: [NativeFinalTextPaintAdmission.Footprint]
        do {
            supports = try input.fills.map {
                try Task.checkCancellation()
                return try NativeFinalTextPaintAdmission.retainedFootprint($0)
            }
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            return current
        }
        var widthCalls = 0, shapeCalls = 0, admissions = 0, widthAttempts = 0
        let expandedWidths = measuredWidths && extraOuterWidths != nil
        let reductionsAllowed = expandedWidths && allowRowReduction
        var retainedAnchors:[String:CGFloat]=[:]
        if expandedWidths || expandedSearch {
            let groups=Dictionary(grouping:input.fills.indices.filter {input.fills[$0].sourceClusterAlignment != nil},
                by:{input.fills[$0].sourceClusterAlignment!.groupID})
            for (group,members) in groups where members.count>1 {
                let packet=input.fills[members[0]].sourceClusterAlignment!
                let cross:CGFloat=packet.axis == .top ? supports[members[0]].bounds.minY:supports[members[0]].bounds.minX
                if members.allSatisfy({j in
                    input.fills[j].textExpansionPolicy?.insideBalloon == true &&
                    input.fills[j].sourceClusterAlignment?.axis == packet.axis &&
                    input.audit[j]["sourceClusterID"]as?String == group &&
                    (input.audit[j]["sourceClusterAnchorOutputPixels"]as?NSNumber).map {abs(CGFloat($0.doubleValue)-cross)<0.01} == true &&
                    abs((packet.axis == .top ? supports[j].bounds.minY:supports[j].bounds.minX)-cross)<0.01
                }) {retainedAnchors[group]=cross}
            }
        }
        var failures: [[String: Any]] = []
        var rejected: [String: Int] = [:], attempts: [[String: Any]] = []
        var outcomes: [[String:Any]] = [], outcomeStatuses: [String:Int] = [:]
        var outcomeCount = 0, ownerFailureCount = 0, originOutcomeCount = 0
        var originOutcomes:[[String:Any]]=[]
        var ownerFailures: [[String:Any]] = []
        let pass = measuredWidths ? "measured-width":"retained-width"
        func reject(_ reason: String) { rejected[reason, default: 0] += 1 }
        func ownerFailure(_ owner:String, _ stage:String, _ reason:String, _ values:[String:Any] = [:]) {
            ownerFailureCount += 1
            guard ownerFailures.count < interiorOwnerFailureLimit else { return }
            var value: [String:Any] = ["owner":owner,"pass":pass,"stage":stage,"status":"rejected","reason":reason,
                "outerWidthPixels":NSNull(),"rowsBefore":descriptors[owner]?.ranges.count as Any? ?? NSNull(),
                "rowsAfter":NSNull(),"cutsAfter":NSNull()]
            if let descriptor=descriptors[owner] {
                value["cutsBefore"]=NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:descriptor.ranges).count
            }
            value.merge(values) {_,new in new};ownerFailures.append(value)
        }
        for i in eligible {
            try Task.checkCancellation()
            var ownerStage = "outer-width-provider"
            do {
                let owner = owners[i], fill = current.fills[i], descriptor = descriptors[owner]!
                let policy = fill.textExpansionPolicy!, old = supports[i]
                widthCalls += 1
                guard let initialWidth = try outerWidths(owner), initialWidth.isFinite, initialWidth > 0 else {
                    reject("outer-width");ownerFailure(owner,ownerStage,"outer-width");continue
                }
                var widths:[CGFloat] = skipInitialOwners.contains(owner) ? []:[initialWidth]
                let widthBudget=skipInitialOwners.contains(owner) ? 2:3
                if expandedWidths, let extraOuterWidths {
                    ownerStage="extra-width-provider"
                    for width in try extraOuterWidths(owner) where width.isFinite && width > initialWidth + 0.01 {
                        if !widths.contains(where: {abs($0-width)<=0.01}) {widths.append(width)}
                        if widths.count == widthBudget {break}
                    }
                }
                ownerStage="palette-capability"
                guard let palette = try exteriorPaletteReceipt(fill, restored: restored) else {
                    reject("palette-capability");ownerFailure(owner,ownerStage,"palette-capability",
                        ["outerWidthPixels":Double(initialWidth),"widthsAvailable":widths.count]);continue
                }
                var best: (candidate: Candidate, audit: [String:Any], support: NativeFinalTextPaintAdmission.Footprint, rank: [Double])?
                var bestOutcomeOrdinal: Int?
                for width in widths {
                try Task.checkCancellation()
                widthAttempts += 1
                if attempts.count < 32 { attempts.append(["owner": owner, "outerWidthPixels": Double(width)]) }
                var stage="factory"
                let ordinal = widthAttempts
                var outcome: [String:Any] = ["owner":owner,"pass":pass,"candidateOrdinal":ordinal,
                    "outerWidthPixels":Double(width),"rowsBefore":descriptor.ranges.count,"rowsAfter":NSNull(),
                    "cutsBefore":NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:descriptor.ranges).count,
                    "cutsAfter":NSNull(),"status":"rejected","reason":"uncompleted-candidate",
                    "beforeBounds":interiorDiagnosticRect(old.bounds)]
                func candidateReject(_ reason:String) { reject(reason);outcome["reason"]=reason }
                defer {
                    outcome["stage"]=stage;outcomeCount += 1
                    outcomeStatuses[outcome["status"] as? String ?? "rejected",default:0] += 1
                    if outcomes.count < interiorOutcomeLimit { outcomes.append(outcome) }
                }
                do {
                shapeCalls += 1
                guard var candidate = try make(owner, width, old.bounds) else { candidateReject("factory-unavailable"); continue }
                outcome["rowsAfter"]=candidate.ranges.count
                outcome["cutsAfter"]=NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:candidate.ranges).count
                outcome["candidateFrame"]=interiorDiagnosticRect(candidate.fill.frame)
                outcome["fontPixelsBefore"]=interiorDiagnosticNumber(fill.fontOutputPixels)
                outcome["fontPixelsAfter"]=interiorDiagnosticNumber(candidate.fill.fontOutputPixels)
                if let last=attempts.indices.last, attempts[last]["owner"] as? String == owner {
                    attempts[last]["rowsBefore"]=descriptor.ranges.map {[$0.location,$0.length]}
                    attempts[last]["rowsAfter"]=candidate.ranges.map {[$0.location,$0.length]}
                    attempts[last]["cutsAfter"]=NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:candidate.ranges).count
                }
                // Same short-circuit order as the original combined guard.
                // Diagnostics never relax a gate or invoke another factory.
                stage="inherited-carrier"
                guard inherited(fill,candidate.fill) else {candidateReject("inherited-carrier");continue}
                if search != nil {
                    guard fill.sourceContourOnly==candidate.fill.sourceContourOnly,
                        (fill.sourceAppearance == nil && candidate.fill.sourceAppearance == nil) ||
                        (fill.sourceAppearance != nil && candidate.fill.sourceAppearance != nil &&
                         NSDictionary(dictionary:fill.sourceAppearance!).isEqual(to:candidate.fill.sourceAppearance!)) else {
                        candidateReject("source-paint-binding");continue
                    }
                }
                stage="ownership"
                guard validOwnership(descriptor.text,candidate.ranges) else {candidateReject("ownership");continue}
                stage="row-budget"
                let cutsBefore=NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:descriptor.ranges).count
                let rowAllowance=expandedSearch && search != nil ? min(4,max(1,cutsBefore)):1
                outcome["maximumRows"]=descriptor.ranges.count+rowAllowance
                outcome["minimumRows"]=reductionsAllowed ? 1:descriptor.ranges.count
                guard candidate.ranges.count <= descriptor.ranges.count+rowAllowance else {candidateReject("row-budget-increase");continue}
                guard reductionsAllowed || candidate.ranges.count >= descriptor.ranges.count else {
                    candidateReject("row-budget-reduction");continue
                }
                stage="quality"
                guard interiorWordQualityAllows(descriptor,candidate.ranges) else {
                    let detail=interiorWordQualityRejection(descriptor,candidate.ranges)
                    outcome.merge(detail) {_,new in new}
                    candidateReject(detail["reason"] as? String ?? "quality");continue
                }
                stage="image-geometry"
                outcome["imageWidthPixels"]=candidate.fill.image.width
                outcome["imageHeightPixels"]=candidate.fill.image.height
                guard candidate.fill.frame == candidate.fill.frame.integral else {candidateReject("frame-integrality");continue}
                guard candidate.fill.frame.width == CGFloat(candidate.fill.image.width) else {
                    candidateReject("image-width-binding");continue
                }
                guard candidate.fill.frame.height == CGFloat(candidate.fill.image.height) else {
                    candidateReject("image-height-binding");continue
                }
                stage="footprint"
                candidate.fill.placementDomain = fill.placementDomain
                let support = try NativeFinalTextPaintAdmission.retainedFootprint(candidate.fill)
                // Match the established interior helper: center exact paint,
                // locking the shared source top/left edge for multi-owner groups.
                var origin = CGPoint(x: (old.bounds.midX - support.bounds.width / 2).rounded(),
                                     y: (old.bounds.midY - support.bounds.height / 2).rounded())
                if let cluster = fill.sourceClusterAlignment,
                   current.fills.filter({ $0.sourceClusterAlignment?.groupID == cluster.groupID }).count > 1 {
                    if cluster.axis == .top { origin.y = old.bounds.minY }
                    else { origin.x = old.bounds.minX }
                }
                var strictMulti=false
                if (expandedWidths || expandedSearch),let packet=fill.balloonPlacement,!fill.balloonTargetRelaxed {
                    stage="body-peer-residual"
                    // Changing an odd width/height can change rounded body
                    // centres by one pixel. Retain the fixed peers' common
                    // residual, rather than accepting a tuple final paint
                    // would subsequently reject in its entirety.
                    var bounds=supports.map(\.bounds)
                    bounds[i]=CGRect(origin:origin,size:support.bounds.size)
                    let targets=try NativeBalloonPlacement.targets(current.fills.map(\.balloonPlacement),
                        bounds:bounds,fonts:current.fills.map(\.fontOutputPixels),page:page,
                        guides:current.fills.map(\.textPlacementGuide))
                    let peers=current.fills.indices.filter {$0 != i &&
                        current.fills[$0].balloonPlacement?.bodyID==packet.bodyID}
                    strictMulti = !peers.isEmpty && targets[i] != nil
                    if let target=targets[i],let peer=peers.first,let residual=targets[peer] {
                        guard peers.allSatisfy({j in targets[j].map {
                            abs($0.x-residual.x)<0.01 && abs($0.y-residual.y)<0.01
                        } == true}) else {
                            outcome["bodyPeerCount"]=peers.count
                            outcome["referenceBodyResidualPixels"]=[interiorDiagnosticNumber(residual.x),interiorDiagnosticNumber(residual.y)]
                            candidateReject("fixed-body-peer-residual");continue
                        }
                        origin.x += target.x-residual.x
                        origin.y += target.y-residual.y
                    }
                }
                let source = fill.textPlacementGuide!.rect(in: page)
                let retainedAxis:NativeSourceClusterAlignment.Axis?=fill.sourceClusterAlignment.flatMap {
                    retainedAnchors[$0.groupID] == nil ? nil:$0.axis
                }
                func anchorDistance(_ rect:CGRect)->CGFloat {
                    let dx=retainedAxis == .left ? rect.minX-source.minX:rect.midX-source.midX
                    let dy=retainedAxis == .top ? rect.minY-source.minY:rect.midY-source.midY
                    return hypot(dx,dy)
                }
                let lockedAxis=fill.sourceClusterAlignment.flatMap { packet -> NativeSourceClusterAlignment.Axis? in
                    current.fills.filter {$0.sourceClusterAlignment?.groupID==packet.groupID}.count>1 ? packet.axis:nil
                }
                let projected = expandedSearch && search != nil && !strictMulti
                    ? interiorOriginProposals(first:origin,old:old.bounds,support:support.bounds,fill:fill,page:page,locked:lockedAxis):([origin],false)
                let origins=projected.0
                let baseOutcome=outcome
                for (originIndex,proposedOrigin) in origins.enumerated() {
                outcome=baseOutcome
                if search != nil {
                    outcome["expandedSearch"]=expandedSearch;outcome["originOrdinal"]=originIndex+1
                    outcome["originBudget"]=8;outcome["originProposalsTruncated"]=projected.1
                    outcome["strictMultiBodyResidualOnly"]=strictMulti
                }
                if let search,!search.reserve(owner,width){candidateReject("origin-budget");break}
                defer {
                    if search != nil {
                        var record=outcome;record["stage"]=stage;originOutcomeCount+=1
                        if originOutcomes.count<interiorOutcomeLimit{originOutcomes.append(record)}
                    }
                }
                do {
                let proposed=CGRect(origin:proposedOrigin,size:support.bounds.size)
                let origin=proposedOrigin
                outcome["proposedBounds"]=interiorDiagnosticRect(proposed)
                stage="page"
                guard page.contains(proposed) else {
                    outcome["pageBounds"]=interiorDiagnosticRect(page);candidateReject("page");continue
                }
                stage="source-anchor"
                let anchorBefore=anchorDistance(old.bounds),anchorAfter=anchorDistance(proposed)
                outcome["anchorDistanceBeforePixels"]=interiorDiagnosticNumber(anchorBefore)
                outcome["anchorDistanceAfterPixels"]=interiorDiagnosticNumber(anchorAfter)
                outcome["anchorGrowthLimitPixels"]=Double(fill.fontOutputPixels*0.25+1e-7)
                guard anchorAfter <= anchorBefore + fill.fontOutputPixels * 0.25 + 1e-7 else {
                    candidateReject("source-anchor");continue
                }
                let projectedSupport=support.translated(CGPoint(x:origin.x-support.bounds.minX,y:origin.y-support.bounds.minY))
                if let search {
                    stage="assigned-alpha-domain"
                    guard projectedSupport.runs.allSatisfy({r in
                        let box=CGRect(x:r.left,y:r.y,width:r.right-r.left,height:1)
                        return policy.allows(box,page:page) && (fill.placementDomain?(box) ?? true)
                    }) else{candidateReject("assigned-alpha-domain");continue}
                    stage="source-shape-gate"
                    guard let before=search.original[owner] else{candidateReject("source-shape-original-unavailable");continue}
                    let check=search.gate(owner,before,projectedSupport)
                    try Task.checkCancellation()
                    outcome["shapeGate"]=check.audit
                    guard check.allowed == true else{candidateReject(check.allowed == nil ? "source-shape-unknown":"source-shape-veto");continue}
                }
                var fixed = Dictionary(uniqueKeysWithValues: owners.indices.map { (owners[$0], supports[$0].bounds.origin) })
                fixed[owner] = origin
                var replacements = current.fills
                replacements[i] = candidate.fill
                admissions += 1
                stage="fixed-origin-admission"
                var admitted = try NativeFinalTextPaintAdmission.place(replacements, page: page, fixedOrigins: fixed,
                    retainedClusterAnchors:retainedAnchors)
                stage="body-peer-state"
                guard admitted.fills.count == current.fills.count else {candidateReject("admitted-fill-inventory");continue}
                guard admitted.audit.count == current.audit.count else {candidateReject("admitted-audit-inventory");continue}
                var stateReason: String?
                let statePreserved=admitted.fills.indices.allSatisfy { j in
                    func failed(_ reason:String)->Bool {
                        stateReason=reason;outcome["stateOwner"]=owners[j];return false
                    }
                    guard admitted.audit[j]["owner"] as? String == owners[j] else {return failed("admitted-owner-binding")}
                    guard inherited(current.fills[j],admitted.fills[j]) else {return failed("admitted-inherited-carrier")}
                    guard (current.audit[j]["balloonBodyPlaced"] as? Bool) == (admitted.audit[j]["balloonBodyPlaced"] as? Bool) else {
                        outcome["bodyPlacedBefore"]=current.audit[j]["balloonBodyPlaced"] ?? NSNull()
                        outcome["bodyPlacedAfter"]=admitted.audit[j]["balloonBodyPlaced"] ?? NSNull()
                        return failed("body-target-state")
                    }
                    if j != i {
                        guard auditBounds(admitted.audit[j]) == supports[j].bounds else {
                            outcome["peerBoundsBefore"]=interiorDiagnosticRect(supports[j].bounds)
                            outcome["peerBoundsAfter"]=auditBounds(admitted.audit[j]).map {interiorDiagnosticRect($0)} as Any? ?? NSNull()
                            return failed("peer-support-bound")
                        }
                        guard admitted.audit[j]["paintedPixels"] as? Int == supports[j].pixels else {
                            outcome["peerPixelsBefore"]=supports[j].pixels
                            outcome["peerPixelsAfter"]=admitted.audit[j]["paintedPixels"] ?? NSNull()
                            return failed("peer-painted-pixels")
                        }
                    }
                    return true
                }
                guard statePreserved else {candidateReject(stateReason ?? "body-peer-state");continue}
                stage="admitted-footprint"
                var next = supports
                next[i] = try NativeFinalTextPaintAdmission.retainedFootprint(admitted.fills[i])
                if expandedWidths || search != nil {
                    stage="final-placement-invariants"
                    try NativeFinalTextPaintAdmission.verifyRetainedPlacement(admitted.fills,
                        footprints:next,page:page,retainedClusterAnchors:retainedAnchors)
                }
                let limit = Int(ceil(fill.fontOutputPixels * 0.35))
                let beforeMargin = margin(old, policy: policy, page: page, limit: limit)
                let afterMargin = margin(next[i], policy: policy, page: page, limit: limit)
                outcome["marginBeforePixels"]=beforeMargin;outcome["marginAfterPixels"]=afterMargin
                outcome["actualBounds"]=interiorDiagnosticRect(next[i].bounds)
                stage="support-bound"
                guard next[i].bounds == proposed else {candidateReject("support-bound");continue}
                if search != nil {
                    stage="gated-alpha-binding"
                    guard next[i].pixels==projectedSupport.pixels,next[i].runs.count==projectedSupport.runs.count,
                        zip(next[i].runs,projectedSupport.runs).allSatisfy({$0.y==$1.y && $0.left==$1.left && $0.right==$1.right}) else {
                        candidateReject("gated-alpha-changed");continue
                    }
                }
                stage="contour-margin"
                let requiredMargin=expandedSearch && search != nil ? min(beforeMargin,Int(ceil(fill.fontOutputPixels*0.12))):beforeMargin
                outcome["requiredMarginPixels"]=requiredMargin
                guard afterMargin >= requiredMargin else {candidateReject("contour-margin");continue}
                stage="assigned-alpha-domain"
                guard next[i].runs.allSatisfy({ policy.allows(CGRect(x:$0.left,y:$0.y,
                    width:$0.right-$0.left,height:1),page:page) }) else {candidateReject("assigned-alpha-domain");continue}
                stage="body-order"
                guard preservesOrder(admitted.fills,supports:next,owner:i) else {candidateReject("body-order");continue}
                stage="cohort-order"
                guard exteriorOrderAllows(current.fills,old:supports,new:next,owner:i) else {
                    candidateReject("cohort-order");continue
                }
                stage="peer-gutter"
                guard peerClearanceAllows(supports,next,fills:current.fills,owner:i) else {
                    outcome.merge(interiorWordGutterRejection(supports,next,fills:current.fills,owner:i)) {_,new in new}
                    candidateReject("peer-gutter");continue
                }
                stage="final-palette"
                guard let finalPalette = try exteriorPaletteReceipt(admitted.fills[i], restored: restored),
                      NSDictionary(dictionary: palette).isEqual(to: finalPalette) else { candidateReject("final-palette"); continue }
                try Task.checkCancellation()
                if search != nil {
                    stage="retained-state-lineage"
                    admitted.audit=try NativeBalloonPlacement.RetainedState.preservingKnownSnapshots(
                        priorAudit:current.audit,admittedAudit:admitted.audit,unknownPolicy:.preservePriorUncertainty)
                }
                var diagnostics: [String: Any] = [
                    "interiorWordReflow": true, "interiorWordTerminalOnly": true,
                    "interiorWordOuterWidthPixels": Double(width), "interiorWordBoundedAttempts": widths.count,
                    "interiorWordOuterWidthBeforePixels": Double(initialWidth),
                    "interiorWordWidthExpanded": width > initialWidth + 0.01,
                    "interiorWordAnchorDistanceBeforePixels":Double(anchorDistance(old.bounds)),
                    "interiorWordAnchorDistanceAfterPixels":Double(anchorDistance(proposed)),
                    "interiorWordCentreDistanceBeforePixels":Double(distance(old.bounds,source)),
                    "interiorWordCentreDistanceAfterPixels":Double(distance(proposed,source)),
                    "interiorWordRowsBefore": descriptor.ranges.count, "interiorWordRowsAfter": candidate.ranges.count,
                    "interiorWordCutsBefore": NativeRenderWrapQuality.wordCutOffsets(descriptor.text, ranges: descriptor.ranges).count,
                    "interiorWordCutsAfter": NativeRenderWrapQuality.wordCutOffsets(descriptor.text, ranges: candidate.ranges).count,
                    "interiorWordMarginBeforePixels": beforeMargin, "interiorWordMarginAfterPixels": afterMargin,
                    "interiorWordFinalPalette": finalPalette, "interiorWordRetainedFontOutputPixels": Double(fill.fontOutputPixels),
                    "interiorWordOriginalRanges": descriptor.ranges.map { [$0.location, $0.length] },
                    "placementDeltaOutputPixels": [Double(proposed.minX - support.bounds.minX), Double(proposed.minY - support.bounds.minY)]
                ]
                if search != nil {
                    diagnostics["interiorWordExpandedSearch"]=expandedSearch
                    diagnostics["interiorWordOriginOrdinal"]=originIndex+1
                    diagnostics["interiorWordShapeGateBefore"]="immutable-original-outer-input"
                    diagnostics["interiorWordShapeGate"]=outcome["shapeGate"]
                }
                candidate.fill = admitted.fills[i]
                candidate.metadata.merge(diagnostics) { _, new in new }
                // Retain original peer primitives and audits bit-for-bit. Only
                // the reshaped owner's fresh admission replaces glyph proofs.
                var audit = admitted.audit[i]
                audit["preInteriorWordReflowPlacement"] = current.audit[i]
                audit.merge(diagnostics) { _, new in new }
                let rank = [Double(NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:candidate.ranges).count),
                    Double(candidate.ranges.count),Double(proposed.width*proposed.height),Double(width)]
                stage="ranking"
                outcome["rank"]=rank;outcome["status"]="admissible-not-selected"
                outcome["reason"]="rank-not-better"
                if let best, !rank.lexicographicallyPrecedes(best.rank) {break}
                outcome["reason"]="superseded-by-final-rank"
                best=(candidate,audit,next[i],rank)
                bestOutcomeOrdinal=ordinal
                break // First admissible placement wins this width.
                } catch {
                    if error is CancellationError{throw error}
                    try Task.checkCancellation();candidateReject("candidate-error")
                    outcome["error"]=String(String(describing:error).prefix(512))
                    outcome["errorType"]=String(String(reflecting:type(of:error)).prefix(256))
                    if failures.count<32{failures.append(["owner":owner,"outerWidthPixels":Double(width),"stage":stage,"error":String(describing:error)])}
                }
                }
                } catch {
                    if error is CancellationError {throw error}
                    try Task.checkCancellation();candidateReject("candidate-error")
                    outcome["error"]=String(String(describing:error).prefix(512))
                    outcome["errorType"]=String(String(reflecting:type(of:error)).prefix(256))
                    if failures.count<32 {failures.append(["owner":owner,"outerWidthPixels":Double(width),
                        "stage":stage,"error":String(describing:error),"errorType":String(reflecting:type(of:error))])}
                }
                }
                if let best {
                    current.fills[i]=best.candidate.fill;current.audit[i]=best.audit
                    current.selected[owner]=best.candidate;supports[i]=best.support
                    outcomeStatuses["admissible-not-selected",default:0] -= 1
                    outcomeStatuses["selected",default:0] += 1
                    if let originOrdinal=best.candidate.metadata["interiorWordOriginOrdinal"]as?Int,
                       let index=originOutcomes.firstIndex(where:{$0["owner"]as?String==owner &&
                           $0["candidateOrdinal"]as?Int==bestOutcomeOrdinal && $0["originOrdinal"]as?Int==originOrdinal}) {
                        originOutcomes[index]["status"]="selected";originOutcomes[index]["reason"]="best-admissible-rank"
                    }
                    if let index=outcomes.firstIndex(where:{$0["candidateOrdinal"] as? Int == bestOutcomeOrdinal}) {
                        outcomes[index]["status"]="selected";outcomes[index]["reason"]="best-admissible-rank"
                    }
                }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                reject("owner-error")
                ownerFailure(owners[i],ownerStage,"owner-error",["error":String(String(describing:error).prefix(512))])
            }
        }
        try Task.checkCancellation()
        current.diagnostics = ["eligibleOwners": eligible.count, "outerWidthProviderCalls": widthCalls,
            "shapeCalls": shapeCalls, "fixedOriginAdmissionCalls": admissions, "rejections": rejected,
            "outerWidthAttempts": attempts, "outerWidthAttemptsTruncated": widthAttempts > attempts.count,
            "candidateFailures": failures, "maxOuterWidthsPerOwner": expandedWidths ? 3:1,
            "candidateOutcomes":outcomes,"candidateOutcomeCount":outcomeCount,
            "candidateOutcomeLimit":interiorOutcomeLimit,"candidateOutcomesTruncated":outcomeCount>outcomes.count,
            "candidateOutcomesTruncatedCount":outcomeCount-outcomes.count,"candidateOutcomeStatusCounts":outcomeStatuses,
            "ownerFailures":ownerFailures,"ownerFailureCount":ownerFailureCount,
            "ownerFailuresTruncatedCount":ownerFailureCount-ownerFailures.count]
        if search != nil {
            current.diagnostics["originOutcomes"]=originOutcomes
            current.diagnostics["originOutcomeCount"]=originOutcomeCount
            current.diagnostics["originOutcomesTruncated"]=originOutcomeCount>originOutcomes.count
            current.diagnostics["originBudgetPerOwnerWidth"]=8
        }
        return current
    }

    private static func interiorOriginProposals(first:CGPoint,old:CGRect,support:CGRect,fill:Primitive,page:CGRect,locked:NativeSourceClusterAlignment.Axis?)->([CGPoint],Bool) {
        guard let policy=fill.textExpansionPolicy,let guide=fill.textPlacementGuide else{return ([first],false)}
        let centre=CGPoint(x:(old.midX-support.width/2).rounded(),y:(old.midY-support.height/2).rounded())
        let basis=CGRect(origin:centre,size:support.size),shift=guide.preferredShift(bounds:basis,page:page)
        var desired=CGPoint(x:centre.x+shift.x,y:centre.y+shift.y)
        var values=[centre,desired]
        // Respect the same retained cohort lock for EVERY additional origin.
        if let locked {
            if locked == .top{desired.y=first.y}else{desired.x=first.x}
        }
        let rows=(policy.maskSpansNormalized?.count ?? 0)/2
        var intervals=0,maximum=0
        if rows<=512 {
            for row in 0..<rows{let n=policy.maskIntervals(row:row).count/2;intervals+=n;maximum=max(maximum,n)}
        }
        let projectionSafe=rows<=512 && intervals<=4096 && maximum<=64 &&
            13*max(1,rows)*max(1,intervals)*max(1,maximum)<=2_000_000
        if projectionSafe {
            let preferred=CGPoint(x:desired.x-basis.minX,y:desired.y-basis.minY)
            values += policy.projectedShifts(bounds:basis,page:page,preferred:preferred,font:fill.fontOutputPixels)
                .map {CGPoint(x:basis.minX+$0.x,y:basis.minY+$0.y)}
        }
        var unique:[CGPoint]=[]
        for var point in values {
            if let locked {
                if locked == .top{point.y=first.y}else{point.x=first.x}
            }
            point=CGPoint(x:point.x.rounded(),y:point.y.rounded())
            if point != first && !unique.contains(point){unique.append(point)}
        }
        unique.sort {a,b in
            let x=hypot(a.x-first.x,a.y-first.y),y=hypot(b.x-first.x,b.y-first.y)
            if x != y{return x<y};return a.y==b.y ? a.x<b.x:a.y<b.y
        }
        return ([first]+Array(unique.prefix(7)),!projectionSafe || unique.count>7)
    }

    private static func interiorDiagnosticNumber(_ value:CGFloat)->Any {
        value.isFinite ? Double(value) as Any:NSNull()
    }

    private static func interiorDiagnosticRect(_ rect:CGRect)->[Any] {
        [rect.minX,rect.minY,rect.width,rect.height].map {interiorDiagnosticNumber($0)}
    }

    // Called only AFTER the unchanged quality predicate rejects. Pure scalar
    // diagnostics cannot trigger another paint, admission or candidate search.
    private static func interiorWordQualityRejection(_ descriptor:Descriptor,_ ranges:[NSRange])->[String:Any] {
        let old=NativeRenderWrapQuality.evaluate(descriptor.text,ranges:descriptor.ranges)
        let new=NativeRenderWrapQuality.evaluate(descriptor.text,ranges:ranges)
        let oldCuts=NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:descriptor.ranges)
        let newCuts=NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:ranges)
        let oldTails=NativeRenderWrapQuality.shortTailOffsets(descriptor.text,ranges:descriptor.ranges).intersection(oldCuts).count
        let newTails=NativeRenderWrapQuality.shortTailOffsets(descriptor.text,ranges:ranges).intersection(newCuts).count
        let oldFragments=NativeRenderWrapQuality.singleCharacterFragmentRows(descriptor.text,ranges:descriptor.ranges)
        let newFragments=NativeRenderWrapQuality.singleCharacterFragmentRows(descriptor.text,ranges:ranges)
        let reason: String
        if new.illegal>old.illegal {reason="quality-illegal-breaks"}
        else if new.orphans>old.orphans {reason="quality-punctuation-orphans"}
        else if newCuts.count>=oldCuts.count {reason="quality-word-cuts-not-improved"}
        else if newTails>oldTails {reason="quality-fragment-tails"}
        else if newFragments>oldFragments {reason="quality-single-character-fragments"}
        else {reason="quality"}
        return ["reason":reason,"illegalBefore":old.illegal,"illegalAfter":new.illegal,
            "punctuationOrphansBefore":old.orphans,"punctuationOrphansAfter":new.orphans,
            "cutsBefore":oldCuts.count,"cutsAfter":newCuts.count,
            "fragmentTailsBefore":oldTails,"fragmentTailsAfter":newTails,
            "singleCharacterFragmentsBefore":oldFragments,"singleCharacterFragmentsAfter":newFragments]
    }

    // Reproduce only the first failed peer's numerical evidence, after the
    // existing predicate has rejected. No peer state or clearance rule changes.
    private static func interiorWordGutterRejection(_ old:[NativeFinalTextPaintAdmission.Footprint],
        _ new:[NativeFinalTextPaintAdmission.Footprint],fills:[Primitive],owner:Int)->[String:Any] {
        for j in fills.indices where j != owner {
            let desired=ceil(min(fills[owner].fontOutputPixels,fills[j].fontOutputPixels)*0.35)
            let peer=fills[j].ownerID ?? ""
            guard desired.isFinite,desired>0,desired<=512 else {
                return ["peer":peer,"gutterGate":"target-budget","gutterTargetPixels":interiorDiagnosticNumber(desired)]
            }
            let before=NativeAdaptiveTextGutter.clearance(old[owner].readableBounds ?? old[owner].bounds,
                old[j].readableBounds ?? old[j].bounds) ?? desired
            let after=NativeAdaptiveTextGutter.clearance(new[owner].readableBounds ?? new[owner].bounds,
                new[j].readableBounds ?? new[j].bounds) ?? desired
            if after+0.01<min(before,desired) {
                return ["peer":peer,"gutterGate":"readable-clearance","gutterBeforePixels":interiorDiagnosticNumber(before),
                    "gutterAfterPixels":interiorDiagnosticNumber(after),"gutterRequiredPixels":interiorDiagnosticNumber(min(before,desired))]
            }
            let oldRows=NativeInkContourClearance.envelope(old[owner].runs.map {.init(y:$0.y,left:$0.left,right:$0.right)})
            let newRows=NativeInkContourClearance.envelope(new[owner].runs.map {.init(y:$0.y,left:$0.left,right:$0.right)})
            let peerRows=NativeInkContourClearance.envelope(old[j].runs.map {.init(y:$0.y,left:$0.left,right:$0.right)})
            let oldGap=NativeInkContourClearance.peerMargin(rows:oldRows,peer:peerRows,limit:Int(desired))
            let newGap=NativeInkContourClearance.peerMargin(rows:newRows,peer:peerRows,limit:Int(desired))
            if newGap+0.01<min(oldGap,desired) {
                return ["peer":peer,"gutterGate":"alpha-envelope","gutterBeforePixels":interiorDiagnosticNumber(oldGap),
                    "gutterAfterPixels":interiorDiagnosticNumber(newGap),"gutterRequiredPixels":interiorDiagnosticNumber(min(oldGap,desired))]
            }
        }
        return [:]
    }

    private static func interiorWordQualityAllows(_ descriptor: Descriptor, _ ranges: [NSRange]) -> Bool {
        let old=NativeRenderWrapQuality.evaluate(descriptor.text,ranges:descriptor.ranges)
        let new=NativeRenderWrapQuality.evaluate(descriptor.text,ranges:ranges)
        return new.illegal<=old.illegal && new.orphans<=old.orphans &&
            NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:ranges).count <
                NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:descriptor.ranges).count &&
            NativeRenderWrapQuality.shortTailOffsets(descriptor.text,ranges:ranges).intersection(
                NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:ranges)).count <=
                NativeRenderWrapQuality.shortTailOffsets(descriptor.text,ranges:descriptor.ranges).intersection(
                    NativeRenderWrapQuality.wordCutOffsets(descriptor.text,ranges:descriptor.ranges)).count &&
            NativeRenderWrapQuality.singleCharacterFragmentRows(descriptor.text,ranges:ranges) <=
                NativeRenderWrapQuality.singleCharacterFragmentRows(descriptor.text,ranges:descriptor.ranges)
    }

    static var exteriorEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_EXTERIOR_READABILITY_REFLOW"] != "0"
    }

    /// A sibling of the interior pass, never an extension of its contour search.
    /// Widths are CONTENT widths; each factory owns its outer-width conversion.
    static func refineExterior(_ input: (fills: [Primitive], audit: [[String: Any]]),
                               descriptors: [String: Descriptor], page: CGRect, completePeerContext: Bool,
                               restored: CGImage? = nil, widths: (String) throws -> [CGFloat],
                               make: (String, CGFloat, CGRect) throws -> Candidate?) throws -> Result {
        var current = Result(fills: input.fills, audit: input.audit, selected: [:])
        let owners = input.fills.compactMap(\.ownerID)
        guard exteriorEnabled, completePeerContext, !page.isEmpty, page == page.integral,
              owners.count == input.fills.count, Set(owners).count == owners.count,
              input.audit.count == owners.count,
              input.audit.indices.allSatisfy({ input.audit[$0]["owner"] as? String == owners[$0] }) else { return current }
        let eligible = input.fills.indices.filter { i in
            let fill = input.fills[i]
            guard let descriptor = descriptors[owners[i]], validOwnership(descriptor.text, descriptor.ranges),
                  fill.textExpansionPolicy?.valid == true,
                  fill.textExpansionPolicy?.kind == "source-near-limited-expansion",
                  fill.balloonPlacement == nil, let guide = fill.textPlacementGuide, guide.valid,
                  abs(guide.sourceRotationRadians ?? 0) <= 1e-6,
                  fill.fontOutputPixels.isFinite, fill.fontOutputPixels > 0,
                  ceil(fill.fontOutputPixels * 0.35) <= 512 else { return false }
            return !NativeRenderWrapQuality.wordCutOffsets(descriptor.text, ranges: descriptor.ranges).isEmpty
        }
        guard !eligible.isEmpty else { return current }
        let start = Date()
        var requests = 0, admissions = 0, rejected: [String: Int] = [:]
        var requestedWidths: [String: [Double]] = [:]
        var failures: [[String: Any]] = []
        func reject(_ reason: String) { rejected[reason, default: 0] += 1 }
        var supports: [NativeFinalTextPaintAdmission.Footprint]
        do {
            supports = try input.fills.map {
                try Task.checkCancellation()
                return try NativeFinalTextPaintAdmission.retainedFootprint($0)
            }
        }
        catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            return current
        }
        for i in eligible {
            try Task.checkCancellation()
            do {
                let fill = current.fills[i], owner = owners[i], descriptor = descriptors[owner]!
                let old = supports[i], source = fill.textPlacementGuide!.rect(in: page)
                guard let palette = try exteriorPaletteReceipt(fill, restored: restored) else { reject("palette-capability"); continue }
                // A misbehaving width provider cannot turn this into a frontier.
                var paletteWidths: [CGFloat] = []
                for width in try widths(owner) where width.isFinite && width > 0 {
                    if !paletteWidths.contains(where: { abs($0 - width) <= 0.01 }) { paletteWidths.append(width) }
                    if paletteWidths.count == 3 { break }
                }
                requestedWidths[owner] = paletteWidths.map(Double.init)
                var best: (candidate: Candidate, audit: [String: Any], support: NativeFinalTextPaintAdmission.Footprint, rank: [Double])?
                for width in paletteWidths {
                    try Task.checkCancellation()
                    requests += 1
                    var stage = "factory"
                    var geometry: [String: Any] = [:]
                    do {
                        guard var candidate = try make(owner, width, old.bounds), inherited(fill, candidate.fill),
                              validOwnership(descriptor.text, candidate.ranges),
                              // Fewer rows do not expand the vertical budget.
                              // Complete ownership, strict cut reduction and final
                              // peer/domain admission remain mandatory below.
                              candidate.ranges.count <= descriptor.ranges.count + 2,
                              exteriorQualityAllows(descriptor, candidate.ranges),
                              candidate.fill.frame == candidate.fill.frame.integral,
                              candidate.fill.frame.width == CGFloat(candidate.fill.image.width),
                              candidate.fill.frame.height == CGFloat(candidate.fill.image.height) else { reject("shape-or-quality"); continue }
                        stage = "footprint"
                        candidate.fill.placementDomain = fill.placementDomain
                        let support = try NativeFinalTextPaintAdmission.retainedFootprint(candidate.fill)
                        let origin = exteriorOrigin(fill, old: old.bounds, size: support.bounds.size)
                        let proposed = CGRect(origin: origin, size: support.bounds.size)
                        geometry["proposedFootprint"] = [Double(proposed.minX), Double(proposed.minY),
                            Double(proposed.width), Double(proposed.height)]
                        geometry["rows"] = candidate.ranges.map { [$0.location, $0.length] }
                        geometry["overlappingPeerOwners"] = owners.indices.filter {
                            $0 != i && proposed.intersects(supports[$0].bounds)
                        }.map { owners[$0] }
                        guard exteriorAnchorDistance(proposed, source: source, fill: fill) <=
                                exteriorAnchorDistance(old.bounds, source: source, fill: fill) + fill.fontOutputPixels * 0.25 + 1e-7,
                              page.contains(proposed) else { reject("source-near-or-page"); continue }
                        var fixed = Dictionary(uniqueKeysWithValues: owners.indices.map { (owners[$0], supports[$0].bounds.origin) })
                        fixed[owner] = origin
                        var replacements = current.fills
                        replacements[i] = candidate.fill
                        admissions += 1
                        stage = "fixed-origin-admission"
                        let admitted = try NativeFinalTextPaintAdmission.place(replacements, page: page, fixedOrigins: fixed)
                        guard admitted.fills.count == current.fills.count, admitted.audit.count == current.audit.count,
                              admitted.fills.indices.allSatisfy({ j in
                                  inherited(current.fills[j], admitted.fills[j]) &&
                                  (current.audit[j]["balloonBodyPlaced"] as? Bool) == (admitted.audit[j]["balloonBodyPlaced"] as? Bool) &&
                                  (j == i || auditBounds(admitted.audit[j]) == supports[j].bounds &&
                                   admitted.audit[j]["paintedPixels"] as? Int == supports[j].pixels)
                              }) else { reject("state-or-peer"); continue }
                        stage = "admitted-footprint"
                        var next = supports
                        next[i] = try NativeFinalTextPaintAdmission.retainedFootprint(admitted.fills[i])
                        guard next[i].bounds == proposed,
                              exteriorOrderAllows(current.fills, old: supports, new: next, owner: i),
                              peerClearanceAllows(supports, next, fills: current.fills, owner: i) else { reject("anchor-order-or-gutter"); continue }
                        stage = "final-palette"
                        guard let finalPalette = try exteriorPaletteReceipt(admitted.fills[i], restored: restored),
                              NSDictionary(dictionary: palette).isEqual(to: finalPalette) else { reject("final-palette"); continue }
                        let cuts = NativeRenderWrapQuality.wordCutOffsets(descriptor.text, ranges: candidate.ranges).count
                        let rank = [Double(cuts), Double(NativeRenderWrapQuality.shortTailOffsets(descriptor.text, ranges: candidate.ranges).count),
                                    Double(abs(candidate.ranges.count - descriptor.ranges.count)),
                                    Double(hypot(proposed.midX - old.bounds.midX, proposed.midY - old.bounds.midY)), Double(width)]
                        if let best, !rank.lexicographicallyPrecedes(best.rank) { continue }
                        let delta = [Double(proposed.minX - support.bounds.minX), Double(proposed.minY - support.bounds.minY)]
                        let diagnostics: [String: Any] = ["exteriorReadabilityReflow": true,
                            "exteriorContentWidthPixels": Double(width), "exteriorRowsBefore": descriptor.ranges.count,
                            "exteriorRowsAfter": candidate.ranges.count,
                            "exteriorWordCutsBefore": NativeRenderWrapQuality.wordCutOffsets(descriptor.text, ranges: descriptor.ranges).count,
                            "exteriorWordCutsAfter": cuts, "exteriorFinalPalette": finalPalette,
                            "exteriorRetainedFontOutputPixels": Double(fill.fontOutputPixels),
                            "exteriorSourceAnchorDistanceBefore": Double(exteriorAnchorDistance(old.bounds, source: source, fill: fill)),
                            "exteriorSourceAnchorDistanceAfter": Double(exteriorAnchorDistance(proposed, source: source, fill: fill)),
                            "exteriorSourceCenterDistanceBefore": Double(distance(old.bounds, source)),
                            "exteriorSourceCenterDistanceAfter": Double(distance(proposed, source)),
                            "exteriorPalettePreflight": true, "placementDeltaOutputPixels": delta]
                        candidate.fill = admitted.fills[i]
                        candidate.metadata.merge(diagnostics) { _, new in new }
                        var audit = admitted.audit[i]
                        audit["preExteriorReadabilityPlacement"] = current.audit[i]
                        audit.merge(diagnostics) { _, new in new }
                        best = (candidate, audit, next[i], rank)
                    } catch {
                        if error is CancellationError { throw error }
                        try Task.checkCancellation(); reject("candidate-error")
                        failures.append(["owner": owner, "contentWidthPixels": Double(width),
                            "stage": stage, "errorType": String(reflecting: type(of: error)),
                            "error": String(describing: error), "geometry": geometry])
                    }
                }
                if let best {
                    // Never retain tightened/re-encoded peer rasters from place.
                    current.fills[i] = best.candidate.fill; current.audit[i] = best.audit
                    current.selected[owner] = best.candidate; supports[i] = best.support
                }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation(); reject("owner-error")
            }
        }
        current.diagnostics = ["eligibleOwners": eligible.count, "widthRequests": requests,
            "shapeCalls": requests, "fixedOriginAdmissionCalls": admissions, "rejections": rejected,
            "contentWidthRequestsByOwner": requestedWidths,
            "candidateFailures": failures,
            "elapsedSeconds": Date().timeIntervalSince(start), "maxContentWidthsPerOwner": 3]
        return current
    }

    static func exteriorQualityAllows(_ descriptor: Descriptor, _ ranges: [NSRange]) -> Bool {
        qualityAllows(descriptor, ranges) &&
            NativeRenderWrapQuality.wordCutOffsets(descriptor.text, ranges: ranges).count <
                NativeRenderWrapQuality.wordCutOffsets(descriptor.text, ranges: descriptor.ranges).count &&
            NativeRenderWrapQuality.shortTailOffsets(descriptor.text, ranges: ranges).count <=
                NativeRenderWrapQuality.shortTailOffsets(descriptor.text, ranges: descriptor.ranges).count
    }

    /// Raw live fills use the actual mandatory final palette selection. Already
    /// styled corpus rasters cannot be outlined again: conservatively require
    /// the exact opaque RGB palette, including the mandatory BW endpoint.
    static func exteriorPaletteReceipt(_ fill: Primitive, restored: CGImage?) throws -> [String: Any]? {
        if fill.hasFinalEffects {
            let bytes = try NativeMandatoryDisplayStroke.rgba(fill.image)
            var colors = Set<Int>()
            for p in stride(from: 0, to: bytes.count, by: 4) where bytes[p + 3] == 255 {
                colors.insert(Int(bytes[p]) << 16 | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2]))
                if colors.count > 512 { return nil }
            }
            guard !colors.isEmpty, colors.contains(0) || colors.contains(0xffffff) else { return nil }
            return ["kind": "prepainted-exact-opaque-RGB", "opaqueRGB": colors.sorted()]
        }
        guard let restored else { return nil }
        let prepared = try NativeMandatoryDisplayStroke.prepare(fill: fill.image, restored: restored,
            fontOutputPixels: fill.fontOutputPixels, outwardEm: fill.displayStrokeRatio ?? 0.20,
            fillFrame: fill.frame, forcedEndpoint: fill.displayStrokeEndpoint, recheckFinalEndpoint: fill.recheckFinalEndpoint,
            minimumFillStrokeContrast: fill.minimumFillStrokeContrast, minimumCoverageGain: fill.minimumCoverageGain,
            sourceAppearance: fill.sourceAppearance, sourceContourOnly: fill.sourceContourOnly)
        guard let rgb = prepared.endpointDecision["displayFillRGB"] as? [Int] else { return nil }
        if fill.sourceContourOnly {
            guard let style = fill.sourceStyle, style.bands.count == 1, style.shadow == nil else { return nil }
            let band = style.bands[0]
            return ["kind":"source-contour-only", "displayFillRGB":rgb,
                "sourceOutlineRGB":band.rgb,"sourceOutlineWidthPixels":band.width * Double(fill.fontOutputPixels) / style.sourceFontPixels,
                "syntheticGuardPainted":false,"outwardPixels":Double(prepared.outwardPixels)]
        }
        return ["kind": "mandatory-final-palette", "displayFillRGB": rgb,
                "finalEndpoint": Int(prepared.endpoint), "outwardPixels": Double(prepared.outwardPixels)]
    }

    /// A coloured source contour has no BW endpoint. Require an explicit
    /// source mode and a real retained source band instead of nil==nil equality.
    static func paintDecisionMatches(_ decision: [String: Any], palette: [String: Any]) -> Bool {
        guard let rgb = palette["displayFillRGB"] as? [Int],
              decision["displayFillRGB"] as? [Int] == rgb else { return false }
        if palette["kind"] as? String == "source-contour-only" {
            guard let color = palette["sourceOutlineRGB"] as? [Double], color.count == 3,
                  color.allSatisfy({ $0.isFinite && (0...255).contains($0) }),
                  let width = palette["sourceOutlineWidthPixels"] as? Double, width.isFinite, width > 0,
                  palette["syntheticGuardPainted"] as? Bool == false,
                  palette["outwardPixels"] as? Double == 0 else { return false }
            return decision["paintMode"] as? String == "source-contour-only" &&
                decision["guardPainted"] as? Bool == false && !(decision["finalEndpoint"] is Int)
        }
        guard let expected = palette["finalEndpoint"] as? Int else { return false }
        return decision["finalEndpoint"] as? Int == expected &&
            decision["paintMode"] as? String != "source-contour-only"
    }

    /// A wider left-anchored paragraph moves its center without moving its
    /// placement. Measure the same anchors that exteriorOrigin preserves.
    static func exteriorAnchorDistance(_ rect: CGRect, source: CGRect, fill: Primitive) -> CGFloat {
        guard let guide = fill.textPlacementGuide else { return distance(rect, source) }
        var dx = guide.horizontal == .left ? rect.minX - source.minX :
            guide.horizontal == .right ? rect.maxX - source.maxX : rect.midX - source.midX
        var dy = guide.vertical == .top ? rect.minY - source.minY :
            guide.vertical == .bottom ? rect.maxY - source.maxY : rect.midY - source.midY
        if let cluster = fill.sourceClusterAlignment {
            if cluster.axis == .top {
                dy = rect.minY - source.minY
                if cluster.anchorsToSourceStart == true { dx = rect.minX - source.minX }
            } else {
                dx = rect.minX - source.minX
                if cluster.anchorsToSourceStart == true { dy = rect.minY - source.minY }
            }
        }
        return hypot(dx, dy)
    }

    private static func exteriorOrigin(_ fill: Primitive, old: CGRect, size: CGSize) -> CGPoint {
        let guide = fill.textPlacementGuide!
        var x = guide.horizontal == .left ? old.minX : guide.horizontal == .right ? old.maxX - size.width : old.midX - size.width / 2
        var y = guide.vertical == .top ? old.minY : guide.vertical == .bottom ? old.maxY - size.height : old.midY - size.height / 2
        if let cluster = fill.sourceClusterAlignment {
            if cluster.axis == .top { y = old.minY; if cluster.anchorsToSourceStart == true { x = old.minX } }
            else { x = old.minX; if cluster.anchorsToSourceStart == true { y = old.minY } }
        }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    private static func exteriorOrderAllows(_ fills: [Primitive], old: [NativeFinalTextPaintAdmission.Footprint],
                                           new: [NativeFinalTextPaintAdmission.Footprint], owner: Int) -> Bool {
        guard let cluster = fills[owner].sourceClusterAlignment else { return true }
        for j in fills.indices where j != owner && fills[j].sourceClusterAlignment?.groupID == cluster.groupID {
            let before = cluster.axis == .top ? old[owner].bounds.midX - old[j].bounds.midX : old[owner].bounds.midY - old[j].bounds.midY
            let after = cluster.axis == .top ? new[owner].bounds.midX - new[j].bounds.midX : new[owner].bounds.midY - new[j].bounds.midY
            if before == 0 || before * after <= 0 { return false }
        }
        return true
    }

    static func refine(_ input: (fills: [Primitive], audit: [[String: Any]]),
                       descriptors: [String: Descriptor], page: CGRect,
                       make: (String, CGFloat, CGRect) throws -> Candidate?) throws -> Result {
        var current = Result(fills: input.fills, audit: input.audit, selected: [:])
        let tracing = ProcessInfo.processInfo.environment["AIDOKU_BALLOON_REFLOW_TRACE"] == "1"
        func trace(_ event:String,_ values:[String:Any]) {
            guard tracing,let data=try? JSONSerialization.data(withJSONObject:values,options:[.sortedKeys])else{return}
            fputs("balloon-reflow-\(event) "+String(decoding:data,as:UTF8.self)+"\n",stderr)
        }
        let owners = input.fills.compactMap(\.ownerID)
        guard input.fills.count == input.audit.count, owners.count == input.fills.count,
              Set(owners).count == owners.count, !page.isEmpty, page == page.integral else { return current }
        guard input.fills.contains(where: {
            $0.ownerID.flatMap { descriptors[$0] } != nil &&
                $0.textExpansionPolicy?.insideBalloon == true && $0.textPlacementGuide?.valid == true
        }) else { return current }
        // Measuring fill-only owners also paints their bands/shadows. Cache the
        // page once; admission fixes every peer's exact retained origin.
        var cachedSupports: [NativeFinalTextPaintAdmission.Footprint]
        do {
            try Task.checkCancellation()
            cachedSupports = try input.fills.map { try NativeFinalTextPaintAdmission.retainedFootprint($0) }
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            return current
        }
        for i in input.fills.indices {
            try Task.checkCancellation()
            do {
                let fill = current.fills[i]
                guard let owner = fill.ownerID, let descriptor = descriptors[owner],
                      validOwnership(descriptor.text, descriptor.ranges),
                      let policy = fill.textExpansionPolicy, policy.valid, policy.insideBalloon,
                      let guide = fill.textPlacementGuide, guide.valid,
                      fill.fontOutputPixels.isFinite, fill.fontOutputPixels > 0,
                      ceil(fill.fontOutputPixels * 0.35) <= 512 else { continue }
                let font = fill.fontOutputPixels, source = guide.rect(in: page)
                let oldSupports = cachedSupports
                let old = oldSupports[i], target = Int(ceil(font * 0.35))
                guard source.height >= 2 * font, source.height >= source.width * 0.8,
                      old.bounds == old.bounds.integral,
                      old.bounds.width > max(source.width * 1.25, font * 3.5) else { continue }
                let oldMargin = margin(old, policy: policy, page: page, limit: target)
                trace("eligibility",["owner":owner,"oldMargin":oldMargin,"target":target])
                guard oldMargin < target else { continue }
                let requiredGain = max(2, Int(ceil(font * 0.1)))
                let oldDistance = distance(old.bounds, source)
                var attempted = Set<CGFloat>(), attempts = 0
                var best: (result: Result, candidate: Candidate, margin: Int, movement: CGFloat,
                           support: NativeFinalTextPaintAdmission.Footprint)?
                for factor: CGFloat in [0.85, 0.75, 0.65] {
                    try Task.checkCancellation()
                    let width = floor(old.bounds.width * factor)
                    guard width > 0, width < old.bounds.width, attempted.insert(width).inserted else { continue }
                    attempts += 1
                    trace("attempt",["owner":owner,"width":Double(width)])
                    let frame = CGRect(x: old.bounds.midX - width / 2, y: old.bounds.minY,
                                       width: width, height: old.bounds.height)
                    do {
                        guard var candidate = try make(owner, width, frame),
                              inherited(fill, candidate.fill),
                              candidate.fill.frame == candidate.fill.frame.integral,
                              candidate.fill.frame.width == CGFloat(candidate.fill.image.width),
                              candidate.fill.frame.height == CGFloat(candidate.fill.image.height),
                              validOwnership(descriptor.text, candidate.ranges),
                              (1...2).contains(candidate.ranges.count - descriptor.ranges.count),
                              qualityAllows(descriptor, candidate.ranges) else { continue }
                        trace("shaped",["owner":owner,"width":Double(width),"rows":candidate.ranges.count])
                        // A closure is not comparable. Keep the original mandatory domain,
                        // even if a factory accidentally supplies a weaker one.
                        candidate.fill.placementDomain = fill.placementDomain
                        let support = try NativeFinalTextPaintAdmission.retainedFootprint(candidate.fill)
                        guard support.bounds.width < old.bounds.width else { continue }
                        var origin = CGPoint(x: (old.bounds.midX - support.bounds.width / 2).rounded(),
                                             y: (old.bounds.midY - support.bounds.height / 2).rounded())
                        if let cluster = fill.sourceClusterAlignment,
                           current.fills.filter({ $0.sourceClusterAlignment?.groupID == cluster.groupID }).count > 1 {
                            if cluster.axis == .top { origin.y = old.bounds.minY }
                            else { origin.x = old.bounds.minX }
                        }
                        let proposed = CGRect(origin: origin, size: support.bounds.size)
                        guard distance(proposed, source) <= oldDistance + font * 0.25 + 1e-7 else { continue }
                        trace("source-near",["owner":owner,"width":Double(width)])
                        var fixed = Dictionary(uniqueKeysWithValues: current.fills.indices.map {
                            (owners[$0], oldSupports[$0].bounds.origin)
                        })
                        fixed[owner] = origin
                        var replacements = current.fills
                        replacements[i] = candidate.fill
                        // One fixed-origin admission per width; internal relaxation may
                        // run, but packet changes and target relaxation are rejected below.
                        let admitted = try NativeFinalTextPaintAdmission.place(replacements, page: page, fixedOrigins: fixed)
                        trace("admitted",["owner":owner,"width":Double(width),
                            "bodyPacketEqual":fill.balloonPlacement==admitted.fills[i].balloonPlacement,
                            "relaxedBefore":fill.balloonTargetRelaxed,"relaxedAfter":admitted.fills[i].balloonTargetRelaxed,
                            "bodyPlacedBefore":current.audit[i]["balloonBodyPlaced"]as?Bool ?? false,
                            "bodyPlacedAfter":admitted.audit[i]["balloonBodyPlaced"]as?Bool ?? false])
                        guard admitted.fills.count == current.fills.count,
                              admitted.audit.count == current.audit.count else { continue }
                        var supports = oldSupports
                        supports[i] = try NativeFinalTextPaintAdmission.retainedFootprint(admitted.fills[i])
                        // An oversized raster has no body target. A narrower raster
                        // may restore that same singleton target without relaxing it.
                        let existingBodyFitRestored: Bool = {
                            guard current.audit[i]["balloonBodyPlaced"] as? Bool == false,
                                  admitted.audit[i]["balloonBodyPlaced"] as? Bool == true,
                                  let body = fill.balloonPlacement, body.valid,
                                  admitted.fills[i].balloonPlacement == body,
                                  !fill.balloonTargetRelaxed, !admitted.fills[i].balloonTargetRelaxed,
                                  current.fills.filter({ $0.balloonPlacement?.bodyID == body.bodyID }).count == 1,
                                  body.rect(in: page).contains(supports[i].bounds) else { return false }
                            return true
                        }()
                        guard supports[i].bounds == proposed,
                              admitted.fills.indices.allSatisfy({ j in
                                  inherited(current.fills[j], admitted.fills[j]) &&
                                  ((current.audit[j]["balloonBodyPlaced"] as? Bool) ==
                                      (admitted.audit[j]["balloonBodyPlaced"] as? Bool) ||
                                      j == i && existingBodyFitRestored) &&
                                  (j == i || auditBounds(admitted.audit[j]) == oldSupports[j].bounds &&
                                      admitted.audit[j]["paintedPixels"] as? Int == oldSupports[j].pixels)
                              }), preservesOrder(admitted.fills, supports: supports, owner: i),
                              peerClearanceAllows(oldSupports, supports, fills: current.fills, owner: i) else { continue }
                        trace("relationships",["owner":owner,"width":Double(width)])
                        let newMargin = margin(supports[i], policy: policy, page: page, limit: target)
                        trace("margin",["owner":owner,"width":Double(width),"before":oldMargin,"after":newMargin])
                        guard newMargin >= oldMargin + requiredGain else { continue }
                        let movement = hypot(proposed.midX - old.bounds.midX, proposed.midY - old.bounds.midY)
                        if let best, newMargin < best.margin || newMargin == best.margin &&
                            (candidate.ranges.count > best.candidate.ranges.count ||
                             candidate.ranges.count == best.candidate.ranges.count && movement >= best.movement) { continue }
                        var result = current
                        result.fills = admitted.fills
                        // New glyphs cannot inherit immutable-glyph translation
                        // proofs. Peers retain their unchanged historical audit.
                        result.audit[i] = admitted.audit[i]
                        result.audit[i]["preReadabilityReflowPlacement"] = current.audit[i]
                        candidate.fill = admitted.fills[i]
                        var diagnostics: [String: Any] = [
                            "placementDeltaOutputPixels": [Double(supports[i].bounds.minX - support.bounds.minX),
                                                           Double(supports[i].bounds.minY - support.bounds.minY)],
                            "balloonReadabilityReflow": true,
                            "balloonReadabilityRowsBefore": descriptor.ranges.count,
                            "balloonReadabilityRowsAfter": candidate.ranges.count,
                            "balloonReadabilityMarginBeforePixels": oldMargin,
                            "balloonReadabilityMarginAfterPixels": newMargin,
                            "balloonReadabilityRequestedWidthPixels": Double(width)
                        ]
                        if existingBodyFitRestored {
                            diagnostics["balloonReadabilityExistingBodyFitRestored"] = true
                        }
                        candidate.metadata.merge(diagnostics) { _, new in new }
                        result.audit[i].merge(diagnostics) { _, new in new }
                        best = (result, candidate, newMargin, movement, supports[i])
                    } catch {
                        if error is CancellationError { throw error }
                        try Task.checkCancellation()
                    }
                }
                if var best {
                    best.candidate.metadata["balloonReadabilityBoundedAttempts"] = attempts
                    best.result.audit[i]["balloonReadabilityBoundedAttempts"] = attempts
                    best.result.selected[owner] = best.candidate
                    current = best.result
                    cachedSupports[i] = best.support
                }
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
            }
        }
        return current
    }

    private static func auditBounds(_ audit: [String: Any]) -> CGRect? {
        guard let values = audit["finalFootprintOutputPixels"] as? [NSNumber], values.count == 4 else { return nil }
        let v = values.map(\.doubleValue)
        guard v.allSatisfy(\.isFinite) else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    static func validOwnership(_ text: String, _ ranges: [NSRange]) -> Bool {
        guard !text.isEmpty, !ranges.isEmpty else { return false }
        var boundaries: Set<Int> = [0], hardEnds = Set<Int>(), count = 0
        for character in text {
            count += String(character).utf16.count
            boundaries.insert(count)
            if NativeLineBreakPolicy.isBreak(character) { hardEnds.insert(count) }
        }
        var cursor = 0
        for range in ranges {
            guard range.location == cursor, range.length > 0, range.length <= count - cursor else { return false }
            cursor += range.length
            guard boundaries.contains(cursor) else { return false }
        }
        return cursor == count && hardEnds.isSubset(of: Set(ranges.map(NSMaxRange)))
    }

    static func qualityAllows(_ descriptor: Descriptor, _ ranges: [NSRange]) -> Bool {
        let old = NativeRenderWrapQuality.evaluate(descriptor.text, ranges: descriptor.ranges)
        let new = NativeRenderWrapQuality.evaluate(descriptor.text, ranges: ranges)
        return new.illegal <= old.illegal && new.orphans <= old.orphans &&
            NativeRenderWrapQuality.wordCutOffsets(descriptor.text, ranges: ranges).count <=
                NativeRenderWrapQuality.wordCutOffsets(descriptor.text, ranges: descriptor.ranges).count &&
            NativeRenderWrapQuality.singleCharacterRows(descriptor.text, ranges: ranges) <=
                NativeRenderWrapQuality.singleCharacterRows(descriptor.text, ranges: descriptor.ranges)
    }

    private static func inherited(_ a: Primitive, _ b: Primitive) -> Bool {
        a.ownerID == b.ownerID && a.fontOutputPixels == b.fontOutputPixels &&
            a.sourceClusterAlignment == b.sourceClusterAlignment && a.balloonPlacement == b.balloonPlacement &&
            a.balloonTargetRelaxed == b.balloonTargetRelaxed && a.textPlacementGuide == b.textPlacementGuide &&
            a.textExpansionPolicy == b.textExpansionPolicy && a.hasFinalEffects == b.hasFinalEffects &&
            a.displayStrokeEndpoint == b.displayStrokeEndpoint && a.displayStrokeRatio == b.displayStrokeRatio &&
            a.recheckFinalEndpoint == b.recheckFinalEndpoint &&
            a.minimumFillStrokeContrast == b.minimumFillStrokeContrast && a.minimumCoverageGain == b.minimumCoverageGain &&
            sameStyle(a.sourceStyle, b.sourceStyle)
    }

    private static func sameStyle(_ a: NativeSourceStylePaint.Style?, _ b: NativeSourceStylePaint.Style?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return NativeSourceStylePaint.sameRoundedContour(a,b) &&
            a.sourceFontPixels == b.sourceFontPixels && a.bands.count == b.bands.count &&
            zip(a.bands, b.bands).allSatisfy { $0.rgb == $1.rgb && $0.width == $1.width } &&
            a.shadow?.rgb == b.shadow?.rgb && a.shadow?.offset == b.shadow?.offset
    }

    private static func margin(_ support: NativeFinalTextPaintAdmission.Footprint,
                               policy: NativeTextExpansionPolicy, page: CGRect, limit: Int) -> Int {
        let rows = NativeInkContourClearance.envelope(support.runs.map { .init(y: $0.y, left: $0.left, right: $0.right) })
        return NativeInkContourClearance.margin(rows: rows, bounds: support.bounds, policy: policy, page: page, limit: limit)
    }

    private static func distance(_ bounds: CGRect, _ source: CGRect) -> CGFloat {
        hypot(bounds.midX - source.midX, bounds.midY - source.midY)
    }

    private static func peerClearanceAllows(_ old: [NativeFinalTextPaintAdmission.Footprint],
                                           _ new: [NativeFinalTextPaintAdmission.Footprint],
                                           fills: [Primitive], owner: Int) -> Bool {
        for j in fills.indices where j != owner {
            let desired = ceil(min(fills[owner].fontOutputPixels, fills[j].fontOutputPixels) * 0.35)
            guard desired.isFinite, desired > 0, desired <= 512 else { return false }
            let before = NativeAdaptiveTextGutter.clearance(old[owner].readableBounds ?? old[owner].bounds,
                                                         old[j].readableBounds ?? old[j].bounds) ?? desired
            let after = NativeAdaptiveTextGutter.clearance(new[owner].readableBounds ?? new[owner].bounds,
                                                        new[j].readableBounds ?? new[j].bounds) ?? desired
            if after + 0.01 < min(before, desired) { return false }
            let oldRows = NativeInkContourClearance.envelope(old[owner].runs.map { .init(y: $0.y, left: $0.left, right: $0.right) })
            let newRows = NativeInkContourClearance.envelope(new[owner].runs.map { .init(y: $0.y, left: $0.left, right: $0.right) })
            let peerRows = NativeInkContourClearance.envelope(old[j].runs.map { .init(y: $0.y, left: $0.left, right: $0.right) })
            // Preserve meaningful spacing, not arbitrary distant whitespace.
            let oldGap = NativeInkContourClearance.peerMargin(rows: oldRows, peer: peerRows, limit: Int(desired))
            let newGap = NativeInkContourClearance.peerMargin(rows: newRows, peer: peerRows, limit: Int(desired))
            if newGap + 0.01 < min(oldGap, desired) { return false }
        }
        return true
    }

    private static func preservesOrder(_ fills: [Primitive], supports: [NativeFinalTextPaintAdmission.Footprint], owner: Int) -> Bool {
        guard let body = fills[owner].balloonPlacement else { return true }
        for j in fills.indices where j != owner && fills[j].balloonPlacement?.bodyID == body.bodyID {
            guard let peer = fills[j].balloonPlacement, peer.order != body.order else { return false }
            let a = body.flow == .row ? supports[owner].bounds.midX : supports[owner].bounds.midY
            let b = body.flow == .row ? supports[j].bounds.midX : supports[j].bounds.midY
            if peer.order < body.order ? b >= a : b <= a { return false }
        }
        return true
    }
}
