import Foundation
@main struct PriorityRegression {
 static func main() async throws {
  for priority in [TaskPriority.background, .low, .medium, .high] {
   let observed: (TaskPriority,TaskPriority) = await withCheckedContinuation { continuation in
    Task.detached(priority: priority) {
     let caller = Task.currentPriority
     let operation = BlockingTask { () -> TaskPriority in
      await Task.yield()
      return Task.currentPriority
     }
     let first = operation.get()
     precondition(operation.get() == first)
     continuation.resume(returning:(caller,first))
    }
   }
   precondition(observed.0 == priority && observed.1 == priority, "task priority mismatch")
  }
  let override:TaskPriority = await withCheckedContinuation { continuation in
   Task.detached(priority:.high) {
    continuation.resume(returning:BlockingTask(priority: .background) {Task.currentPriority}.get())
   }
  }
  precondition(override == .background, "explicit priority overridden")
  for (qos, priority) in [(DispatchQoS.QoSClass.background,TaskPriority.background),(.utility,.low),(.default,.medium),(.userInitiated,.high),(.userInteractive,TaskPriority(rawValue:33))] {
   let actual:TaskPriority = await withCheckedContinuation { continuation in
    DispatchQueue.global(qos:qos).async(execute: DispatchWorkItem(qos: DispatchQoS(qosClass: qos, relativePriority: 0), flags: .enforceQoS) {
     precondition(withUnsafeCurrentTask { $0 == nil })
     continuation.resume(returning:BlockingTask {Task.currentPriority}.get())
    })
   }
   precondition(actual == priority, "dispatch priority mismatch: \(actual.rawValue) != \(priority.rawValue)")
  }
  let nilResult=BlockingTask<Int?> {nil}
  precondition(nilResult.get()==nil && nilResult.get()==nil)
  #if APP_BLOCKING_THROWING_TESTS
  let throwingPriority:TaskPriority = await withCheckedContinuation { continuation in
   Task.detached(priority:.high) {
    let operation = BlockingThrowingTask { Task.currentPriority }
    let first = try! operation.get()
    precondition(try! operation.get() == first)
    continuation.resume(returning:first)
   }
  }
  precondition(throwingPriority == .high)
  enum Expected:Error {case failure}
  let failure = BlockingThrowingTask<Int> {throw Expected.failure}
  for _ in 0..<2 {
   do {_ = try failure.get();preconditionFailure("failure was lost")}
   catch Expected.failure {} catch {preconditionFailure("unexpected failure")}
  }
  let optional = BlockingThrowingTask<Int?> {nil}
  precondition(try! optional.get()==nil && optional.get()==nil)
  #endif
  print("Blocking task Swift priority, explicit priority, five thread QoS and repeated nil PASS")
 }
}
