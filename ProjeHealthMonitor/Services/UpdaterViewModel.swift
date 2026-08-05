import Foundation
import Combine
import Sparkle

/// Thin SwiftUI-friendly wrapper around Sparkle's `SPUStandardUpdaterController`, following
/// Sparkle's documented programmatic-setup pattern (https://sparkle-project.org/documentation/programmatic-setup/).
///
/// While the GitHub repo hosting releases stays private, the appcast/download requests need a
/// GitHub Personal Access Token attached as an `Authorization` header — Sparkle exposes exactly
/// this via `SPUUpdater.httpHeaders`. The token itself lives in the Keychain via `SecretStore`
/// (never in `UserDefaults`/Info.plist), entered by the user in Settings → Updates.
@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?

    var updater: SPUUpdater { controller.updater }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        applyStoredToken()
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Called when the user saves a new GitHub PAT in Settings — re-applies it to the live
    /// updater immediately, no restart required.
    func updateToken(_ token: String?) {
        if let token, !token.isEmpty {
            SecretStore.setSecret(token, for: SecretStore.updateTokenAccount)
        } else {
            SecretStore.deleteSecret(for: SecretStore.updateTokenAccount)
        }
        applyStoredToken()
    }

    private func applyStoredToken() {
        if let token = SecretStore.secret(for: SecretStore.updateTokenAccount), !token.isEmpty {
            controller.updater.httpHeaders = ["Authorization": "token \(token)"]
        } else {
            controller.updater.httpHeaders = nil
        }
    }
}
