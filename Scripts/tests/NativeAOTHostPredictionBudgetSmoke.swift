import Foundation

final class BudgetCounter: @unchecked Sendable {
    private let lock=NSLock()
    private var count=0
    func increment(){lock.lock();count+=1;lock.unlock()}
    var value:Int {lock.lock();defer{lock.unlock()};return count}
}
enum FakeForwardFailure:Error {case failed}
@main struct HostBudgetSmoke {
    static func main() async throws {
        let mode=CommandLine.arguments[1],counter=BudgetCounter()
        let source=try String(contentsOfFile:CommandLine.arguments[2],encoding:.utf8)
        precondition(source.components(separatedBy:"model.prediction(from: provider)").count==2)
        precondition(source.contains("NativeAOTHostPredictionBudget.perform(forward)"))
        @Sendable func fakeForward()throws->Int {try NativeAOTHostPredictionBudget.perform {counter.increment();return 9}}
        @Sendable func fakeRoute(empty:Bool=false,replayHit:Bool=false,tensorHit:Bool=false)throws->Int {
            if empty{return 0}
            if replayHit || tensorHit{return 7}
            return try fakeForward()
        }
        if mode=="normal" {
            let first=try fakeForward(),second=try fakeForward()
            precondition(first==9 && second==9)
            precondition(!NativeAOTHostPredictionBudget.snapshot().budgetEnforcedBeforePrediction)
            var refused=false
            do {try NativeAOTHostPredictionBudget.configure(maximumFreshPredictions:1)}
            catch NativeAOTHostPredictionBudget.Failure.alreadyConfigured {refused=true}
            precondition(refused && counter.value==2)
        } else {
            var invalid=false
            do {try NativeAOTHostPredictionBudget.configure(maximumFreshPredictions:2)}
            catch NativeAOTHostPredictionBudget.Failure.invalidRequest {invalid=true}
            precondition(invalid && !NativeAOTHostPredictionBudget.snapshot().configured)
            if mode=="zero" {try NativeAOTHostPredictionBudget.configure()}
            else {try NativeAOTHostPredictionBudget.configure(maximumFreshPredictions:1)}
            let empty=try fakeRoute(empty:true),replay=try fakeRoute(replayHit:true),tensor=try fakeRoute(tensorHit:true)
            precondition(empty==0 && replay==7 && tensor==7 && NativeAOTHostPredictionBudget.snapshot().actualCalls==0)
            var reset=false
            do {try NativeAOTHostPredictionBudget.configure(maximumFreshPredictions:1)}
            catch NativeAOTHostPredictionBudget.Failure.alreadyConfigured {reset=true}
            precondition(reset)
            let cancelled=Task {
                withUnsafeCurrentTask{$0?.cancel()}
                do {_ = try fakeForward();return false}catch is CancellationError{return true}catch{return false}
            }
            let didCancel=await cancelled.value
            precondition(didCancel && counter.value==0 && NativeAOTHostPredictionBudget.snapshot().actualCalls==0)
            if mode=="error" {
                do {let _:Int = try NativeAOTHostPredictionBudget.perform {counter.increment();throw FakeForwardFailure.failed}}
                catch FakeForwardFailure.failed {}
            }
            DispatchQueue.concurrentPerform(iterations:64) {_ in
                do {_ = try fakeRoute()}catch NativeAOTHostPredictionBudget.Failure.exhausted {}
                catch {preconditionFailure("Unexpected error: \(error)")}
            }
            let state=NativeAOTHostPredictionBudget.snapshot(),expected=mode=="zero" ? 0:1
            precondition(counter.value==expected && state.actualCalls==expected && state.remaining==0)
            precondition(state.configured && state.budgetEnforcedBeforePrediction)
        }
        print("PASS host process AOT budget \(mode): actual fake forwards\(counter.value); no model loads/predictions")
    }
}
