import Testing
@testable import Aidoku

struct ReauditSourceIntegrationTests {
    private enum Mutation: CaseIterable, Sendable, Equatable {
        case disable
        case remove
        case update
    }

    /// Handshake explicitly stops a load after ticket capture, without clocks or shared stores.
    private actor Suspension {
        private var pending: CheckedContinuation<Void, Never>?
        private var observers: [CheckedContinuation<Void, Never>] = []

        func suspend() async {
            await withCheckedContinuation { continuation in
                pending = continuation
                let observers = observers
                self.observers = []
                observers.forEach { $0.resume() }
            }
        }

        func waitUntilSuspended() async {
            if pending != nil { return }
            await withCheckedContinuation { observers.append($0) }
        }

        func resume() {
            let pending = pending
            self.pending = nil
            pending?.resume()
        }
    }

    /// Uses the production admission helper under actual actor reentrancy.
    private actor IsolatedSources {
        private var ownership = SourceLoadOwnership()
        private(set) var sources: [String: String] = ["a": "installed", "b": "installed"]
        private(set) var reasons: [String: String] = [:]

        func load(key: String, returnedKey: String? = nil, failure: Bool = false, at suspension: Suspension) async -> Bool {
            let ticket = ownership.capture(sourceKey: key)
            await suspension.suspend()
            guard ownership.isCurrent(ticket, sourceKey: returnedKey ?? key) else { return false }
            if failure {
                reasons[key] = "obsolete error"
            } else {
                sources[key] = "obsolete source"
            }
            return true
        }

        func reload(at suspension: Suspension) async -> Bool {
            let ticket = ownership.beginSnapshot()
            let oldSources = sources
            let oldReasons = ["a": "obsolete error"]
            await suspension.suspend()
            guard ownership.isCurrent(ticket) else { return false }
            sources = oldSources
            reasons = oldReasons
            return true
        }

        func mutate(key: String, action: Mutation) {
            ownership.invalidate(sourceKey: key)
            sources[key] = action == .update ? "updated" : nil
            reasons[key] = nil
        }

        func clear() {
            ownership.invalidateAll()
            sources = [:]
            reasons = [:]
        }
    }

    @Test(arguments: Mutation.allCases)
    private func suspendedEnableCannotResurrectDisabledRemovedOrUpdatedSource(action: Mutation) async {
        let sources = IsolatedSources()
        let suspension = Suspension()
        let load = Task { await sources.load(key: "a", at: suspension) }
        await suspension.waitUntilSuspended()
        await sources.mutate(key: "a", action: action)
        await suspension.resume()
        #expect(await load.value == false)
        let finalSources = await sources.sources
        #expect(finalSources["a"] == (action == .update ? "updated" : nil))
    }

    @Test
    func mutationCompletionRejectsLoadsCapturedDuringPersistence() async {
        let sources = IsolatedSources()
        await sources.mutate(key: "a", action: .update)
        let suspension = Suspension()
        let load = Task { await sources.load(key: "a", at: suspension) }
        await suspension.waitUntilSuspended()
        // SourceManager invalidates again when its persistence operation exits.
        await sources.mutate(key: "a", action: .update)
        await suspension.resume()
        #expect(await load.value == false)
        #expect(await sources.sources["a"] == "updated")
    }

    @Test
    func suspendedFailureCannotReplaceNewSourceReason() async {
        let sources = IsolatedSources()
        let suspension = Suspension()
        let load = Task { await sources.load(key: "a", failure: true, at: suspension) }
        await suspension.waitUntilSuspended()
        await sources.mutate(key: "a", action: .update)
        await suspension.resume()
        #expect(await load.value == false)
        #expect(await sources.reasons.isEmpty)
    }

    @Test
    func unrelatedMutationPreservesEnableAdmissionAndRejectsOldWholeSnapshot() async {
        let sources = IsolatedSources()
        let enableSuspension = Suspension()
        let reloadSuspension = Suspension()
        let enable = Task { await sources.load(key: "a", at: enableSuspension) }
        let reload = Task { await sources.reload(at: reloadSuspension) }
        await enableSuspension.waitUntilSuspended()
        await reloadSuspension.waitUntilSuspended()
        await sources.mutate(key: "b", action: .remove)
        await reloadSuspension.resume()
        #expect(await reload.value == false)
        await enableSuspension.resume()
        #expect(await enable.value)
        #expect(await sources.sources["b"] == nil)
        #expect(await sources.reasons.isEmpty)
    }

    @Test
    func clearRejectsBothPendingEnableAndSnapshot() async {
        let sources = IsolatedSources()
        let enableSuspension = Suspension()
        let reloadSuspension = Suspension()
        let enable = Task { await sources.load(key: "a", at: enableSuspension) }
        let reload = Task { await sources.reload(at: reloadSuspension) }
        await enableSuspension.waitUntilSuspended()
        await reloadSuspension.waitUntilSuspended()
        await sources.clear()
        await enableSuspension.resume()
        await reloadSuspension.resume()
        #expect(await enable.value == false)
        #expect(await reload.value == false)
        #expect(await sources.sources.isEmpty)
        #expect(await sources.reasons.isEmpty)
    }

    @Test
    func returnedIdentityMustMatchCapturedInstalledIdentity() async {
        let sources = IsolatedSources()
        let suspension = Suspension()
        let load = Task { await sources.load(key: "a", returnedKey: "b", at: suspension) }
        await suspension.waitUntilSuspended()
        await suspension.resume()
        #expect(await load.value == false)
        #expect(await sources.sources["a"] == "installed")
    }

    @Test
    func changedSnapshotCanRetryButSupersededReloadCannot() throws {
        var ownership = SourceLoadOwnership()
        let first = ownership.beginSnapshot()
        ownership.invalidate(sourceKey: "a")
        #expect(!ownership.isCurrent(first))
        let retry = try #require(ownership.refreshedSnapshot(first))
        #expect(ownership.isCurrent(retry))
        let second = ownership.beginSnapshot()
        #expect(!ownership.isCurrent(retry))
        #expect(ownership.refreshedSnapshot(first) == nil)
        #expect(ownership.isCurrent(second))
    }
}
