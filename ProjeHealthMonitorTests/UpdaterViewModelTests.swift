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
    private func makeSUT() -> (controller: MockUpdateController, viewModel: UpdaterViewModel) {
        let controller = MockUpdateController()
        return (controller, UpdaterViewModel(controller: controller))
    }

    func testCanCheckForUpdatesStartsFalse() {
        let (_, viewModel) = makeSUT()
        XCTAssertFalse(viewModel.canCheckForUpdates)
    }

    func testCanCheckForUpdatesReflectsControllerPublisher() async {
        let (controller, viewModel) = makeSUT()
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
        let (controller, viewModel) = makeSUT()
        viewModel.checkForUpdates()
        XCTAssertEqual(controller.checkForUpdatesCallCount, 1)
    }

    func testAutomaticallyChecksForUpdatesReadsFromController() {
        let (controller, viewModel) = makeSUT()
        controller.automaticallyChecksForUpdates = true
        XCTAssertTrue(viewModel.automaticallyChecksForUpdates)
    }

    func testAutomaticallyChecksForUpdatesWritesThroughToController() {
        let (controller, viewModel) = makeSUT()
        viewModel.automaticallyChecksForUpdates = true
        XCTAssertTrue(controller.automaticallyChecksForUpdates)
    }
}
