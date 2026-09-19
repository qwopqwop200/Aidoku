import XCTest
@testable import Aidoku

final class PageTrackingQueueRegressionTests: XCTestCase {
    private func update(page: Int, failCount: Int = 0) -> PageTrackUpdate {
        .init(trackerId: "test", trackId: "book", chapterId: .init(sourceKey: "test", mangaKey: "book", chapterKey: "chapter"),
              progress: .init(completed: false, page: page), failCount: failCount)
    }

    func testSuccessfulOlderRequestPreservesNewProgress() {
        let sent = update(page: 2)
        let newer = update(page: 3)
        XCTAssertEqual(PageTrackUpdate.reconcile(pending: [newer], sent: [sent], failed: []), [newer])
    }

    func testFailedOlderRequestCannotReplaceNewProgress() {
        let sent = update(page: 2)
        let newer = update(page: 3)
        XCTAssertEqual(PageTrackUpdate.reconcile(pending: [newer], sent: [sent], failed: [update(page: 2, failCount: 1)]), [newer])
    }

    func testFailedUnchangedRequestRetainsRetryCount() {
        let sent = update(page: 2)
        let retry = update(page: 2, failCount: 1)
        XCTAssertEqual(PageTrackUpdate.reconcile(pending: [sent], sent: [sent], failed: [retry]), [retry])
    }

    func testSuccessfulRequestIsRemoved() {
        let sent = update(page: 2)
        XCTAssertTrue(PageTrackUpdate.reconcile(pending: [sent], sent: [sent], failed: []).isEmpty)
    }
}
