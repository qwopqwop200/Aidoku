import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeStyledRowGapV3Tests {
    typealias G = NativeStyledRowGap
    typealias N = NativeFinalTextPaintAdmission
    @Test func columnEnvelopeDoesNotUseWholeBBoxBottom() throws {
        let upper=N.Footprint(runs:[.init(y:0,left:0,right:2),.init(y:100,left:3,right:4)],
            bounds:CGRect(x:0,y:0,width:4,height:101),pixels:3,readableBounds:nil)
        let lower=N.Footprint(runs:[.init(y:107,left:0,right:2)],
            bounds:CGRect(x:0,y:107,width:2,height:1),pixels:2,readableBounds:nil)
        #expect(lower.bounds.minY-upper.bounds.maxY==6)
        let actual=try #require(G.horizontal(try G.columns(upper),try G.columns(lower)))
        #expect(actual.gap==106 && actual.rows==2)
    }
    @Test func columnEnvelopeMissingCommonColumnsDoesNotInventGap() throws {
        let a=N.Footprint(runs:[.init(y:0,left:0,right:1)],bounds:CGRect(x:0,y:0,width:1,height:1),pixels:1,readableBounds:nil)
        let b=N.Footprint(runs:[.init(y:3,left:2,right:3)],bounds:CGRect(x:2,y:3,width:1,height:1),pixels:1,readableBounds:nil)
        #expect(try G.horizontal(G.columns(a),G.columns(b))==nil)
    }
    @Test func memoSharesOnlyExactCanonicalInputAndHonorsFourAttemptCap() throws {
        let context=try #require(CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let image=try #require(context.makeImage())
        let layer=NativeAOTTranslationPageComposer.TextLayer(image:image,expectedItems:0,paintedItems:0,complete:true,audit:[:])
        let memo=G.AttemptMemo();var calls=0
        func operation()->NativeAOTTranslationPageComposer.TextLayer {calls+=1;return layer}
        _=try memo.run(legacy:false,raw:["owner":["a":1,"b":2]],operation:operation)
        _=try memo.run(legacy:false,raw:["owner":["b":2,"a":1]],operation:operation)
        #expect(calls==1 && memo.hits==1)
        _=try memo.run(legacy:true,raw:["owner":["a":1,"b":2]],operation:operation)
        _=try memo.run(legacy:false,raw:["owner":["a":3]],operation:operation)
        _=try memo.run(legacy:false,raw:["owner":["a":4]],operation:operation)
        #expect(throws:G.AttemptMemo.Failure.self) {
            _=try memo.run(legacy:false,raw:["owner":["a":5]],operation:operation)
        }
        #expect(calls==4 && memo.nativeAttempts==4)
    }
}
