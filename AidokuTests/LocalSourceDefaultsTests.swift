import Testing
import Foundation
@testable import Aidoku

@Suite(.serialized)
struct LocalSourceDefaultsTests {
    @Test func defaultInstallDeletionAndExplicitReinstall() async {
        let manager = SourceManager.shared
        await manager.waitForSourcesLoad()
        await manager.remove(sourceKey: LocalSourceRunner.sourceKey)
        UserDefaults.standard.removeObject(forKey: SourceManager.localDefaultRegistrationKey)
        await manager.reloadSources()
        #expect(await manager.source(for: LocalSourceRunner.sourceKey) != nil)
        await manager.reloadSources()
        let count = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getSources(context: context).filter { $0.id == LocalSourceRunner.sourceKey }.count
        }
        #expect(count == 1)
        await manager.remove(sourceKey: LocalSourceRunner.sourceKey)
        await manager.reloadSources()
        #expect(await manager.source(for: LocalSourceRunner.sourceKey) == nil)
        #expect(await manager.ensureLocalSourceForImport())
        #expect(await manager.source(for: LocalSourceRunner.sourceKey) != nil)
        await manager.disable(sourceKey: LocalSourceRunner.sourceKey)
        await manager.reloadSources()
        #expect(await manager.source(for: LocalSourceRunner.sourceKey) == nil)
        await manager.enable(sourceKey: LocalSourceRunner.sourceKey)
    }
}
