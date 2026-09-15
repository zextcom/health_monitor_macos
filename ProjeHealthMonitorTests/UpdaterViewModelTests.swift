import XCTest
import Combine
@testable import ProjeHealthMonitor

@MainActor
private final class MockUpdateController: UpdateControlling {
    let canCheckForUpdatesSubject = CurrentValueSubject<Bool, Never>(false)
    var automaticallyChecksForUpdates = false
    private(set) var checkForUpdatesCallCount = 0

    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        canCheckForUpdatesSubject.eraseToAnyPublisher()
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }
}

@MainActor
final class UpdaterViewModelTests: XCTestCase {
    private var controller: MockUpdateController!
    private var viewModel: UpdaterViewModel!

    override func setUp() {
        super.setUp()
        controller = MockUpdateController()
        viewModel = UpdaterViewModel(controller: controller)
    }

    override func tearDown() {
        controller = nil
        viewModel = nil
        super.tearDown()
    }

    func testCanCheckForUpdatesStartsFalse() {
        XCTAssertFalse(viewModel.canCheckForUpdates)
    }

    func testCanCheckForUpdatesReflectsControllerPublisher() async {
        controller.canCheckForUpdatesSubject.send(true)
        await waitUntilMainQueueDrained()
        XCTAssertTrue(viewModel.canCheckForUpdates)

        controller.canCheckForUpdatesSubject.send(false)
        await waitUntilMainQueueDrained()
        XCTAssertFalse(viewModel.canCheckForUpdates)
    }

    /// `receive(on: DispatchQueue.main)` delivers asynchronously even when already on the main
    /// queue, so a value published above needs a round trip through the queue before it lands.
    private func waitUntilMainQueueDrained() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testCheckForUpdatesDelegatesToController() {
        viewModel.checkForUpdates()
        XCTAssertEqual(controller.checkForUpdatesCallCount, 1)
    }

    func testAutomaticallyChecksForUpdatesReadsFromController() {
        controller.automaticallyChecksForUpdates = true
        XCTAssertTrue(viewModel.automaticallyChecksForUpdates)
    }

    func testAutomaticallyChecksForUpdatesWritesThroughToController() {
        viewModel.automaticallyChecksForUpdates = true
        XCTAssertTrue(controller.automaticallyChecksForUpdates)
    }
}
