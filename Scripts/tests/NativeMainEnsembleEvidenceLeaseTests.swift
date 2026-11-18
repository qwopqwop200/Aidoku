import Foundation

@main enum NativeMainEnsembleEvidenceLeaseTests {
    typealias Lease = NativeMainEnsembleEvidenceLease

    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var pins = Lease.Registry()
        private var order: [String] = []
        private var values: [String: Int] = [:]

        func lease(_ identity: String) throws -> Lease {
            lock.lock(); defer { lock.unlock() }
            let token = try pins.acquire(identity: identity)
            return Lease { [self] in
                lock.lock(); defer { lock.unlock() }
                pins.release(token); trim()
            }
        }

        func put(_ identity: String, _ value: Int) {
            lock.lock(); defer { lock.unlock() }
            values[identity] = value
            order.removeAll { $0 == identity }; order.append(identity); trim()
        }

        func get(_ identity: String) -> Int? {
            lock.lock(); defer { lock.unlock() }
            return values[identity]
        }

        private func trim() {
            while order.count > 3 {
                guard let index = pins.evictionIndex(in: order) else { break }
                values.removeValue(forKey: order.remove(at: index))
            }
        }
    }

    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        var pins = Lease.Registry()
        let one = try pins.acquire(identity: "same-rgb")
        let two = try pins.acquire(identity: "same-rgb")
        check(pins.release(one), "first transaction released")
        check(pins.isPinned("same-rgb"), "other same-content transaction still active")
        check(!pins.release(one), "duplicate release cannot revoke another lease")
        check(pins.isPinned("same-rgb"), "duplicate release retained pin")
        check(pins.release(two) && !pins.isPinned("same-rgb"), "last transaction releases pin")
        do { _ = try pins.acquire(identity: ""); preconditionFailure("empty identity admitted") }
        catch Lease.Registry.Failure.emptyIdentity { checks += 1 }

        let cache = Cache()
        let a = try cache.lease("slow-A")
        var b: Lease? = try cache.lease("fast-B")
        let c = try cache.lease("slow-C")
        cache.put("slow-A", 11); cache.put("fast-B", 22); cache.put("slow-C", 33)
        // Three jobs, three-entry cache: B finishes first; D replaces B as a
        // job. Plain registration LRU would delete active A rather than B.
        b?.release(); b = nil
        let d = try cache.lease("new-D")
        cache.put("new-D", 44)
        check(cache.get("slow-A") == 11, "out-of-order completion cannot evict active original probability")
        check(cache.get("fast-B") == nil, "completed resident evicted at unchanged capacity")
        check(cache.get("slow-C") == 33 && cache.get("new-D") == 44, "other active jobs preserved")
        cache.put("unleased-recovery", 55)
        check(cache.get("unleased-recovery") == nil && cache.get("slow-A") == 11,
            "unleased extra recovery cannot evict active primary")
        let e = try cache.lease("fourth-active")
        cache.put("fourth-active", 66)
        check(cache.get("fourth-active") == 66 && cache.get("slow-A") == 11,
            "all-pinned entries retained until scope ends")
        a.release()
        check(cache.get("slow-A") == nil, "release triggers deferred trim")
        c.release(); d.release(); e.release()

        let auto = Cache()
        do {
            let temporary = try auto.lease("auto")
            auto.put("auto", 1)
            withExtendedLifetime(temporary) { auto.put("b", 2); auto.put("c", 3); auto.put("d", 4) }
            check(auto.get("auto") == 1, "lease retained through scope")
        }
        auto.put("e", 5)
        check(auto.get("auto") == nil, "deinit releases without permanent cache leak")
        let concurrent = try auto.lease("concurrent")
        auto.put("concurrent", 7)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in concurrent.release() }
        auto.put("f", 8); auto.put("g", 9); auto.put("h", 10)
        check(auto.get("concurrent") == nil, "concurrent release invokes store callback exactly once")
        print("{\"checks\":\(checks),\"failed\":0,\"modelCalls\":0,\"capacity\":3}")
    }
}
