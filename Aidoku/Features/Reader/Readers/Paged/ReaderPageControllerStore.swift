import UIKit

/// Stable, indexed page descriptors. UIKit objects are created only on demand;
/// identity lookups never instantiate the rest of a chapter.
@MainActor
final class ReaderPageControllerStore {
    private enum Slot {
        case ready(ReaderPageViewController)
        case deferred(() -> ReaderPageViewController)
        var controller: ReaderPageViewController? {
            if case .ready(let controller) = self { return controller }
            return nil
        }
    }
    private var slots: [Slot] = []
    private var indicesByIdentity: [ObjectIdentifier: Int] = [:]

    init(_ controllers: [ReaderPageViewController] = []) {
        for controller in controllers { append(controller) }
    }
    var count: Int { slots.count }
    var indices: Range<Int> { slots.indices }
    var first: ReaderPageViewController? { slots.isEmpty ? nil : self[0] }
    var last: ReaderPageViewController? { slots.isEmpty ? nil : self[slots.count - 1] }
    var materialized: [(Int, ReaderPageViewController)] {
        indicesByIdentity.values.sorted().compactMap { index in existing(at: index).map { (index, $0) } }
    }
    subscript(index: Int) -> ReaderPageViewController {
        switch slots[index] {
        case .ready(let controller): return controller
        case .deferred(let make):
            let controller = make()
            slots[index] = .ready(controller)
            indicesByIdentity[ObjectIdentifier(controller)] = index
            return controller
        }
    }
    func existing(at index: Int) -> ReaderPageViewController? {
        slots.indices.contains(index) ? slots[index].controller : nil
    }
    func append(_ controller: ReaderPageViewController) {
        indicesByIdentity[ObjectIdentifier(controller)] = slots.count
        slots.append(.ready(controller))
    }
    func appendDeferred(_ make: @escaping () -> ReaderPageViewController) {
        slots.append(.deferred(make))
    }
    func firstIndex(of controller: ReaderPageViewController) -> Int? {
        indicesByIdentity[ObjectIdentifier(controller)]
    }
    func contains(_ controller: ReaderPageViewController) -> Bool { firstIndex(of: controller) != nil }
    func insert(contentsOf controllers: [ReaderPageViewController], at index: Int) {
        slots.insert(contentsOf: controllers.map { .ready($0) }, at: index)
        indicesByIdentity = Dictionary(uniqueKeysWithValues: slots.enumerated().compactMap { index, slot in
            slot.controller.map { (ObjectIdentifier($0), index) }
        })
    }
}
