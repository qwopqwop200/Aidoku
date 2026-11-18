import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeStyledRowGapV31MemoTests {
    typealias G = NativeStyledRowGap
    typealias Layer = NativeAOTTranslationPageComposer.TextLayer
    private func layer() throws -> Layer {
        let c=try #require(CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(gray:0,alpha:1));c.fill(CGRect(x:0,y:0,width:2,height:2))
        return Layer(image:try #require(c.makeImage()),expectedItems:0,paintedItems:0,complete:true,audit:[:])
    }
    @Test func lowRetentionBudgetReturnsNativeSuccessAndStillCapsFourCalls() throws {
        let value=try layer();let memo=G.AttemptMemo(byteLimit:0);var calls=0
        for _ in 0..<4 {
            let returned=try memo.run(legacy:false,raw:["owner":["x":1]]) {calls+=1;return value}
            #expect(returned.image === value.image)
        }
        #expect(throws:G.AttemptMemo.Failure.self) {
            _=try memo.run(legacy:false,raw:["owner":["x":1]]) {calls+=1;return value}
        }
        #expect(calls==4 && memo.nativeAttempts==4)
        #expect(memo.successfulNativeCalls==4 && memo.failedNativeCalls==0)
        #expect(memo.chargedBytes==0 && memo.retentionBypasses==4 && memo.hits==0)
    }
    @Test func exhaustedRemainingMemoBytesDoNotTurnSuccessIntoFailure() throws {
        let value=try layer();let charge=value.image.bytesPerRow*value.image.height
        let memo=G.AttemptMemo(byteLimit:charge);var calls=0
        _=try memo.run(legacy:false,raw:["owner":["x":1]]) {calls+=1;return value}
        let returned=try memo.run(legacy:false,raw:["owner":["x":2]]) {calls+=1;return value}
        #expect(returned.image === value.image)
        _=try memo.run(legacy:false,raw:["owner":["x":1]]) {calls+=1;return value}
        #expect(calls==2 && memo.hits==1 && memo.chargedBytes==charge)
        #expect(memo.failedNativeCalls==0 && memo.retentionBypasses==1)
    }
    @Test func nonJSONRawIsUnkeyedButNativeResultStillReturns() throws {
        let value=try layer();let memo=G.AttemptMemo();let raw:[String:[String:Any]]=["owner":["opaque":NSObject()]]
        var calls=0
        for _ in 0..<4 {
            let returned=try memo.run(legacy:false,raw:raw) {calls+=1;return value}
            #expect(returned.image === value.image)
        }
        #expect(throws:G.AttemptMemo.Failure.self) {
            _=try memo.run(legacy:false,raw:raw) {calls+=1;return value}
        }
        #expect(calls==4 && memo.nativeAttempts==4 && memo.failedNativeCalls==0)
        #expect(memo.chargedBytes==0 && memo.hits==0 && memo.retentionBypasses==4)
    }
    @Test func oversizedCanonicalKeyRunsUncachedUnderSameNativeCap() throws {
        let value=try layer();let memo=G.AttemptMemo(keyByteLimit:1);var calls=0
        for _ in 0..<4 {
            let returned=try memo.run(legacy:false,raw:["owner":["x":1]]) {calls+=1;return value}
            #expect(returned.image === value.image)
        }
        #expect(throws:G.AttemptMemo.Failure.self) {
            _=try memo.run(legacy:false,raw:["owner":["x":1]]) {calls+=1;return value}
        }
        #expect(calls==4 && memo.maximumCanonicalKeyBytes>1 && memo.failedNativeCalls==0)
        #expect(memo.retentionBypasses==4 && memo.chargedBytes==0)
    }
    @Test func actualNativeFailureRemainsActualFailureAndCanBeMemoized() throws {
        enum NativeError:Error {case expected}
        let memo=G.AttemptMemo();var calls=0
        for _ in 0..<2 {
            #expect(throws:NativeError.self) {
                _=try memo.run(legacy:false,raw:["owner":["x":1]]) {calls+=1;throw NativeError.expected}
            }
        }
        #expect(calls==1 && memo.failedNativeCalls==1 && memo.successfulNativeCalls==0)
        #expect(memo.hits==1 && memo.retentionBypasses==0 && memo.chargedBytes==0)
    }
    @Test func cancellationPropagatesAndIsNotMemoizedAsFailure() throws {
        let memo=G.AttemptMemo()
        #expect(throws:CancellationError.self) {
            _=try memo.run(legacy:false,raw:["owner":["x":1]]) {throw CancellationError()}
        }
        #expect(memo.cancelledNativeCalls==1 && memo.failedNativeCalls==0)
        #expect(memo.audit["memoFailureEntries"]as?Int==0)
    }
}
