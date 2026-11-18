import CoreGraphics
import Foundation
import Darwin
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeNeutralWhiteSourceContourTests {
    private func raw(_ id: String) throws -> [String: Any] {
        // Synthetic unit producer/consumer bindings, not operational corpus proof.
        let binding = Dictionary(uniqueKeysWithValues: NativeOperationalAppearance.bindingKeys.map {
            ($0, String(repeating: "a", count: 64))
        })
        let prediction: [String: Any] = ["sourceOnly": true,
            "fill": ["rgb": [254.0,254.0,252.0]],
            "outline": ["present": true,"rgb": [1.0,0.0,0.0],"widthPx": 5.0,
                "probability": 0.99,"measurementEvidence": ["reliable": true,"usableRays": 100]],
            "shadow": ["present": false,"probability": 0.0],
            "background": ["rgb": [255.0,255.0,255.0]],
            "pixelRoleEvidence": ["GTAtInference": false,"featureContextPolicy": "source-independent-paint-feature-context-v1",
                "samples": 1000,"roles": [
                    "fill": ["confidentSamples": 100,"meanProbability": 0.12,
                        "observedColours": [["rgb": [254.0,254.0,252.0],"observedMass": 0.99]]],
                    "outline": ["confidentSamples": 300,"meanProbability": 0.32,
                        "observedColours": [["rgb": [1.0,0.0,0.0],"observedMass": 0.99]]]]]]
        let packet: [String: Any] = ["schema": "aidoku-live-source-appearance-v1",
            "sourceOnly": true,"freshInference": true,"GTAtInference": false,
            "cachedPredictionsRead": false,"binding": binding,"prediction": prediction]
        return try NativeOperationalAppearance.apply(packet: JSONSerialization.data(withJSONObject: packet),
            expectedBinding: binding, to: ["id": id,"sourceFontSize": 40.0,"sourceStyleGroupID": "unit-cohort"])
    }
    private var white: CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [255.0/255,254.0/255,250.0/255,1])! }
    private func enabled(_ operation: () throws -> Void) throws {
        let key="AIDOKU_SOURCE_CONTOUR_ONLY", old=getenv("AIDOKU_SOURCE_CONTOUR_ONLY").map {String(cString:$0)}
        setenv(key,"1",1);defer {if let old {setenv(key,old,1)}else{unsetenv(key)}}
        try operation()
    }
    private func changing(_ raw: [String: Any], _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var result=raw;var p=try #require(result["sourceAppearance"] as? [String: Any]);change(&p);result["sourceAppearance"]=p;return result
    }
    @Test func typedActualChoiceRequiredAndRawStampCannotAuthorize() throws {
        try enabled {
            var source=try raw("a")
            source["fill"]=[255.0,254.0,250.0];source["actualChosenFills"]=["a":[255,254,250]]
            source["sourceWhiteCoreCertified"]=true
            try #require(!NativeOperationalAppearance.sourceContourOnly(source))
            try NativeOperationalAppearance.withChosenFills([("a",CGColor(gray:0,alpha:1))]) {
                try #require(!NativeOperationalAppearance.sourceContourOnly(source))
            }
            try NativeOperationalAppearance.withChosenFills([("a",white)]) {
                try #require(NativeOperationalAppearance.sourceContourOnly(source))
            }
            try #require(!NativeOperationalAppearance.sourceContourOnly(source))
        }
    }
    @Test func nestedScopeAndThrowRestoreActualChoices() throws {
        enum Stop: Error {case expected}
        try enabled {
            let source=try raw("a")
            try NativeOperationalAppearance.withChosenFills([("a",white)]) {
                try #require(NativeOperationalAppearance.sourceContourOnly(source))
                do {
                    try NativeOperationalAppearance.withChosenFills([("a",CGColor(gray:0,alpha:1))]) {
                        try #require(!NativeOperationalAppearance.sourceContourOnly(source));throw Stop.expected
                    }
                } catch Stop.expected {}
                try #require(NativeOperationalAppearance.sourceContourOnly(source))
            }
            try #require(!NativeOperationalAppearance.sourceContourOnly(source))
        }
    }
    @Test func producerAuthorityAndCompleteCohortStillRequired() throws {
        try enabled {
            let a=try raw("a"),b=try raw("b")
            try NativeOperationalAppearance.withChosenFills([("a",white),("b",CGColor(gray:0,alpha:1))]) {
                let result=NativeOperationalAppearance.annotateContourPolicies([a,b])
                try #require(result.allSatisfy {$0["sourceContourCohortVeto"] as? Bool == true})
                try #require(result.allSatisfy {!NativeOperationalAppearance.sourceContourOnly($0)})
            }
            var unbound=a;unbound.removeValue(forKey:"sourceAppearanceBinding");unbound.removeValue(forKey:"sourceContourPaintBinding")
            try NativeOperationalAppearance.withChosenFills([("a",white)]) {
                try #require(!NativeOperationalAppearance.sourceContourOnly(unbound))
            }
        }
    }
    @Test func weakEvidenceAndStructuralChangesAbstain() throws {
        try enabled {
            let source=try raw("a")
            var variants=[[String: Any]]()
            variants.append(try changing(source) {$0.removeValue(forKey:"pixelRoleEvidence")})
            variants.append(try changing(source) {$0["shadow"]=["present":true,"probability":1.0]})
            variants.append(try changing(source) {p in
                var o=p["outline"] as! [String:Any];o["observedLayers"]=[["rgb":[0,0,0],"widthPx":2],["rgb":[255,255,255],"widthPx":2]];p["outline"]=o
            })
            for role in ["fill","outline"] {
                variants.append(try changing(source) {p in
                    var e=p["pixelRoleEvidence"] as! [String:Any];var roles=e["roles"] as! [String:Any];var r=roles[role] as! [String:Any]
                    var colors=r["observedColours"] as! [[String:Any]];colors[0]["observedMass"]=0.79;r["observedColours"]=colors
                    roles[role]=r;e["roles"]=roles;p["pixelRoleEvidence"]=e
                })
            }
            var mismatch=source;mismatch["renderSourceOutlineWidthPx"]=5.1;variants.append(mismatch)
            try NativeOperationalAppearance.withChosenFills([("a",white)]) {
                for x in variants {try #require(!NativeOperationalAppearance.sourceContourOnly(x))}
            }
        }
    }
    @Test func invalidOrMissingActualOwnerDoesNotBorrowWhite() throws {
        try enabled {
            let source=try raw("a")
            try NativeOperationalAppearance.withChosenFills([("b",white)]) {
                try #require(!NativeOperationalAppearance.sourceContourOnly(source))
            }
            try NativeOperationalAppearance.withChosenFills([("a",CGColor(gray:1,alpha:0.5))]) {
                try #require(!NativeOperationalAppearance.sourceContourOnly(source))
            }
            var rejected=false
            do {try NativeOperationalAppearance.withChosenFills([("a",white),("a",white)]) {}}
            catch {rejected=true}
            try #require(rejected)
        }
    }
    @Test func nativePreparePreservesWhiteRGBAAndObservedBlackBand() throws {
        try enabled {
            let source=try raw("a")
            try NativeOperationalAppearance.withChosenFills([("a",white)]) {
                let sourceOnly=NativeOperationalAppearance.sourceContourOnly(source);try #require(sourceOnly)
                let bytes:[UInt8]=(0..<64).flatMap {_ -> [UInt8] in [255,254,250,255]}
                let glyph=try NativeMandatoryDisplayStroke.image(bytes,width:8,height:8)
                let surface=try NativeMandatoryDisplayStroke.image([UInt8](repeating:255,count:32*32*4),width:32,height:32)
                let prepared=try NativeMandatoryDisplayStroke.prepare(fill:glyph,restored:surface,fontOutputPixels:40,
                    fillFrame:CGRect(x:8,y:8,width:8,height:8),sourceContourOnly:sourceOnly)
                try #require(try NativeMandatoryDisplayStroke.rgba(prepared.fill)==bytes)
                try #require(prepared.outwardPixels==0 && prepared.endpointDecision["whiteFillOverride"] as? Bool == false)
                try #require(prepared.endpointDecision["guardPainted"] as? Bool == false)
                let style=try #require(try NativeSourceStylePaint.style(source))
                try #require(style.bands.count==1 && style.bands[0].rgb==[1,0,0] && style.bands[0].width==5)
            }
        }
    }
    @Test func realPainterScopedChoicesEndAtReturn() throws {
        try enabled {
            let source=try raw("a"),size=CGSize(width:300,height:150)
            let surface=try NativeMandatoryDisplayStroke.image([UInt8](repeating:255,count:300*150*4),width:300,height:150)
            let item=NativeAOTRawTextPainter.Item(id:"a",text:"MW",frame:CGRect(x:30,y:30,width:200,height:80),
                fontSize:40,lineHeight:56,chosenFill:white,colorAuthority:"unit synthetic producer fixture")
            let layer=try NativeAOTRawTextPainter.renderCentered(items:[item],rawItems:[source],viewport:size,restored:surface)
            try #require(layer.complete && layer.paintedItems==1)
            let decisions=try #require(layer.audit["endpointDecisions"] as? [[String:Any]])
            try #require(decisions.count==1 && decisions[0]["paintMode"] as? String == "source-contour-only")
            try #require(decisions[0]["fillRGBAPreserved"] as? Bool == true)
            try #require(!NativeOperationalAppearance.sourceContourOnly(source))
        }
    }
}
