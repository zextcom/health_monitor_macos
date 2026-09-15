import Foundation
import Combine
import Sparkle

/// Narrow seam over Sparkle's updater — exposes only what `UpdaterViewModel` needs, so tests can
/// substitute a fake instead of standing up the real Sparkle machinery.
@MainActor
protocol UpdateControlling: AnyObject {
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
}

/// Follows Sparkle's documented programmatic-setup pattern
/// (https://sparkle-project.org/documentation/programmatic-setup/).
@MainActor
final class SparkleUpdateController: UpdateControlling {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        controller.updater.publisher(for: \.canCheckForUpdates).eraseToAnyPublisher()
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}

/// Thin SwiftUI-friendly wrapper around the update controller.
@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller: UpdateControlling
    private var cancellable: AnyCancellable?

    init(controller: UpdateControlling = SparkleUpdateController()) {
        self.controller = controller
        cancellable = controller.canCheckForUpdatesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    func checkForUpdates() {
        controller.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.automaticallyChecksForUpdates }
        set { controller.automaticallyChecksForUpdates = newValue }
    }
}
