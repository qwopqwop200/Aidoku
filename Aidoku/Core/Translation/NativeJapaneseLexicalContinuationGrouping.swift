import Foundation
import CoreGraphics

/// Provisional request semantics from bounded Japanese continuation and nearby local columns.
/// This groups source text once. It asserts neither one speaker nor a measured connected body.
/// Original physical boxes, polygons and DB evidence remain separate erasure owners.
enum NativeJapaneseLexicalContinuationGrouping {
    enum Relation: String, Codable, Sendable {
        case politeWordCompletion, interruptedLimitStatement, dependentBenefactiveCompletion, requestFinalParticle, demonstrativeLocativeCompletion
    }
    struct Result { let regions: [ReaderTranslationRegion] }

    static func relation(head: String, tail: String) -> Relation? {
        let a=head.filter{!$0.isWhitespace},b=tail.filter{!$0.isWhitespace}
        guard (4...120).contains(a.count),(1...60).contains(b.count),
              !a.contains(where:{"。！？!?「」『』“”".contains($0)}),
              !b.contains(where:{"。！？!?「」『』“”".contains($0)}),
              a.unicodeScalars.contains(where:{(0x3040...0x30ff).contains($0.value)}),
              b.unicodeScalars.contains(where:{(0x3040...0x30ff).contains($0.value)}) else{return nil}
        let marks=CharacterSet(charactersIn:"…‥.ー〜～♡♥❤")
        let stem=a.trimmingCharacters(in:marks)
        if ["ありがとうござい","お願いし","申し上げ","お世話になり"].contains(where:stem.hasSuffix),
           b.range(of:"^(ます|ました|ません)[…‥.ー〜～]*(っ|つ)?[♡♥❤]?[…‥.ー〜～]*$",options:.regularExpression) != nil {
            return .politeWordCompletion
        }
        if a.range(of:"^(あ[…‥.]+|え[…‥.]+)?(あの[…‥.]+|その[…‥.]+|ええと[…‥.]+)?もう[…‥.]+$",options:.regularExpression) != nil,
           b.range(of:"^([げ限][…‥.]+)?限界[…‥.ー〜～]*$",options:.regularExpression) != nil {
            return .interruptedLimitStatement
        }
        // Retain a bounded original OCR Latin-looking suffix verbatim; do not correct its bytes.
        if a.range(of:"して[A-Za-z]{0,4}[…‥.ー〜～]*$",options:.regularExpression) != nil,
           b.range(of:"^いただけ[ぁ-ん一-龯…‥.ー〜～♡♥❤]{0,12}$",options:.regularExpression) != nil {
            return .dependentBenefactiveCompletion
        }
        if (stem.hasSuffix("下さい") || stem.hasSuffix("ください")),
           b.range(of:"^[…‥.ー〜～]*ね[…‥.ー〜～]*[♡♥❤][…‥.ー〜～]*$",options:.regularExpression) != nil {
            return .requestFinalParticle
        }
        // An elliptic demonstrative is an incomplete prenominal modifier.
        // Admit only a bounded genitive modifier followed by a locative noun;
        // this is lexical continuation evidence, never speaker/body/style proof.
        if a.range(of:"^(こんな|そんな|あんな)[…‥.]+$",options:.regularExpression) != nil,
           b.range(of:"^(人通り|人目)の[一-龯ぁ-ん]{1,8}(ところ|場所)(で|に)",options:.regularExpression) != nil {
            return .demonstrativeLocativeCompletion
        }
        return nil
    }

    static func applying(_ input: [ReaderTranslationRegion], width: CGFloat, height: CGFloat) -> Result {
        guard width.isFinite,height.isFinite,width>0,height>0,
              Set(input.map(\.id)).count==input.count else{return .init(regions:input)}
        func eligible(_ r:ReaderTranslationRegion)->Bool {
            r.translation==nil && r.sourceOrientation == .vertical && r.unitMemberRects.isEmpty &&
            !r.isOccludedFinePrint && r.rect.width>0 && r.rect.height>0 &&
            [r.rect.minX,r.rect.minY,r.rect.maxX,r.rect.maxY].allSatisfy{$0.isFinite && (0...1).contains($0)}
        }
        func pixels(_ r:CGRect)->CGRect {
            .init(x:r.minX*width,y:r.minY*height,width:r.width*width,height:r.height*height)
        }
        func nearJapaneseColumns(_ head:ReaderTranslationRegion,_ tail:ReaderTranslationRegion)->Bool {
            let a=pixels(head.rect),b=pixels(tail.rect),minWidth=min(a.width,b.width),minHeight=min(a.height,b.height)
            let gap=a.minX-b.maxX,overlap=min(a.maxY,b.maxY)-max(a.minY,b.minY)
            guard a.midX>b.midX,a.midX-b.midX>=minWidth*0.2,
                  gap>=(-minWidth),gap<=minWidth*0.75,
                  abs(a.minY-b.minY)<=minHeight*0.3,overlap>=minHeight*0.7,
                  max(a.width,b.width)<=minWidth*3,max(a.height,b.height)<=minHeight*3 else{return false}
            // A distinct original vertical owner between these columns defeats this local order.
            return !input.contains { other in
                guard other.id != head.id,other.id != tail.id,other.sourceOrientation == .vertical else{return false}
                let c=pixels(other.rect),vertical=min(c.maxY,min(a.maxY,b.maxY))-max(c.minY,max(a.minY,b.minY))
                return c.midX>b.midX && c.midX<a.midX && vertical>=min(c.height,minHeight)*0.5
            }
        }
        let candidates=input.indices.filter{eligible(input[$0])}
        var pairs:[(head:Int,tail:Int)]=[]
        for h in candidates {
            let possible=candidates.compactMap { t -> Int? in
                guard h != t,let semantic=relation(head:input[h].source,tail:input[t].source),
                      nearJapaneseColumns(input[h],input[t]) else{return nil}
                if semantic == .demonstrativeLocativeCompletion,
                   let a = input[h].balloonInterior, let b = input[t].balloonInterior,
                   a.contourVerified == true, b.contourVerified == true,
                   (a.rect != b.rect || a.center != b.center || a.spans != b.spans) {
                    // Two independently verified original contours defeat this
                    // new lexical edge. Missing bodies never assert one body.
                    return nil
                }
                return t
            }
            if possible.count==1 {pairs.append((h,possible[0]))}
        }
        let memberCounts=pairs.reduce(into:[Int:Int]()){counts,pair in counts[pair.head,default:0]+=1;counts[pair.tail,default:0]+=1}
        var replacement:[Int:ReaderTranslationRegion]=[:],consumed=Set<Int>()
        for pair in pairs where memberCounts[pair.head]==1 && memberCounts[pair.tail]==1 {
            let head=input[pair.head],tail=input[pair.tail],anchor=min(pair.head,pair.tail),box=head.rect.union(tail.rect)
            let originalSeeds=[head.detectorSeedEvidence,tail.detectorSeedEvidence]
            let sourceSeeds=NativeOCRDetectorSeedEvidence.preservingUnion(originalSeeds)
            // Existing original ownership may not disappear on a contradictory union.
            // This is source conservation only, not a body/style/semantic permission gate.
            guard sourceSeeds != nil || originalSeeds.allSatisfy({$0?.isEmpty ?? true}) else { continue }
            var joined=ReaderTranslationRegion(id:input[anchor].id,rect:box,source:head.source+tail.source)
            joined.confidence=min(head.confidence,tail.confidence)
            joined.sourceImageAspectRatio=head.sourceImageAspectRatio ?? tail.sourceImageAspectRatio ?? Double(width/height)
            joined.translationOrder=input[anchor].translationOrder
            joined.translationOrderVersion=input[anchor].translationOrderVersion
            joined.sourceOrientation = .vertical
            joined.sourceSingleVerticalColumn=false
            joined.unitMemberRects=[head.rect,tail.rect]
            joined.auxiliaryInkRects=head.auxiliaryInkRects+tail.auxiliaryInkRects
            joined.auxiliaryInkPolygons = head.auxiliaryInkPolygons + tail.auxiliaryInkPolygons + [head.polygon, tail.polygon].filter { $0.count >= 3 }
            joined.detectorSeedEvidence=sourceSeeds
            joined.acceptedSource = .union([head.acceptedSource, tail.acceptedSource])
            joined.sourceOCRAlternatives=head.sourceOCRAlternatives+tail.sourceOCRAlternatives
            joined.isRecoveredLine=head.isRecoveredLine || tail.isRecoveredLine
            joined.polygon=[CGPoint(x:box.minX,y:box.minY),CGPoint(x:box.maxX,y:box.minY),
                            CGPoint(x:box.maxX,y:box.maxY),CGPoint(x:box.minX,y:box.maxY)]
            joined.balloonInterior=nil // No body assertion; one visible translated card remains one request.
            replacement[anchor]=joined;consumed.formUnion([pair.head,pair.tail])
        }
        return .init(regions:input.indices.compactMap{replacement[$0] ?? (consumed.contains($0) ? nil : input[$0])})
    }
}
