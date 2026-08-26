# Health Monitor

A native SwiftUI macOS app that periodically checks the health-check endpoints of multiple web services/APIs and shows their live status in the menu bar.

## Requirements

- macOS 13 (Ventura) or later
- Xcode 16.x (CI selects the latest available Xcode 16 runner image)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (the project file is generated from `project.yml`)

```bash
brew install xcodegen
```

## Build & Run

```bash
cd health_monitor_ios
xcodegen generate
open ProjeHealthMonitor.xcodeproj
```

Once Xcode opens, select the `ProjeHealthMonitor` scheme and run with Cmd+R. The app doesn't appear in the Dock (`LSUIElement = true`); it shows up as a colored dot icon in the menu bar.

Build/test from the command line:

```bash
xcodebuild -project ProjeHealthMonitor.xcodeproj -scheme ProjeHealthMonitor -configuration Debug build
xcodebuild -project ProjeHealthMonitor.xcodeproj -scheme ProjeHealthMonitor -configuration Debug test
```

## Usage

1. On first launch, notification permission is requested — allow it (can be changed later in Settings).
2. Click the menu bar icon to open **Settings** (or, if the popover has no endpoints yet, use the "Add in Settings" button).
3. Use **Add Endpoint** to define a new service:
   - **Name**: e.g. `Trelivelli API`
   - **URL**: e.g. `https://api.trelivelli.app/health`
   - **Expected HTTP status code**: defaults to `200`
   - **Custom check interval** (optional): overrides the global setting for this endpoint
   - **JSON field match(es)** (optional): different APIs return different fields in their health body. For example, `api.trelivelli.app/health` responds like this:
     ```json
     {"success":true,"data":{"status":"healthy","database":true,"redis":true}}
     ```
     In this case, set the **JSON field** to `data.status` and the **Expected value** to `healthy` — dot notation reaches into nested fields. You can add multiple assertions, all of which must match (AND). Leave the list empty to check only the HTTP status code.
4. Use the **General** tab to manage the global check interval (30s / 1min / 5min / custom seconds), request timeout, notification preferences, and "Launch at Login". Custom intervals must be at least 10 seconds; request timeout is limited to 1-60 seconds.
5. Click the menu bar icon again to see each endpoint's current status (green/red dot), last check time, and a sparkline of its last ~30 checks.

### Status colors

- 🟢 Green: all endpoints healthy
- 🔴 Red: at least one endpoint down
- ⚪️ Gray: no results yet / endpoint list is empty

## Tested

Manually verified against `https://api.trelivelli.app/health` (a real endpoint) for both healthy and down scenarios:
- Correct `data.status` / `healthy` match produces a healthy result with the right response time/status code recorded
- A wrong expected value produces a down result with a readable `failureReason` (`"data.status" = healthy, expected ...`)
- Periodic re-checks respect the global interval (verified the gap between consecutive requests)

Automated tests (`ProjeHealthMonitorTests/HealthCheckServiceTests.swift`) use a `URLProtocol` mock to cover: status code match/mismatch, nested JSON field match/mismatch, network timeout, and dot-path resolution (`extractValue`).

## Architecture

- `Models/`: `Endpoint`, `HealthCheckResult` — Codable data models
- `Services/EndpointStore`: endpoint list + settings, JSON-encoded persistence in `UserDefaults`
- `Services/HealthHistoryStore`: last 100 results per endpoint, stored as `history.json` under Application Support (ring buffer)
- `Services/HealthCheckService`: `@MainActor` central scheduler — periodic `URLSession` GET requests per the global/override interval, status code + optional JSON field checks, healthy↔down transition detection
- `Services/NotificationService`: transition notifications via `UserNotifications`
- `Services/SecretStore`: `Security`/Keychain wrapper for endpoint auth secrets — never stored as plain text in `UserDefaults`
- `Services/UpdaterViewModel`: SwiftUI-friendly wrapper around Sparkle's `SPUStandardUpdaterController`
- `Views/`: `MenuBarIconView`, `SparklineView`, `EndpointRowView`, `PopoverContentView`, `SettingsView`, `EndpointFormView`

## Automatic Updates (Sparkle)

The app supports automatic updates via [Sparkle](https://sparkle-project.org/). Since the repo is public, no extra authentication is needed — check for updates via the "Automatically check for updates" toggle or the "Check for Updates Now" button under Settings → **Updates**.

### Releasing

To cut a new release:

```bash
git tag v1.1.0
git push origin v1.1.0
```

`.github/workflows/release.yml` runs automatically on any `vX.Y.Z` tag push: it selects the latest available Xcode 16 runner image, builds the project, zips the `.app`, generates an EdDSA-signed `appcast.xml` via Sparkle's `generate_appcast` (reading the private key from the `SPARKLE_PRIVATE_KEY` GitHub Actions secret), and publishes the zip + appcast.xml as a GitHub Release. `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` are derived from the tag — no need to update `project.yml` by hand.

The EdDSA key pair was generated once via `generate_keys` (bundled with Sparkle's SPM package, at `SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`); the public key lives in `project.yml`'s `SUPublicEDKey`, and the private key exists only in the `SPARKLE_PRIVATE_KEY` GitHub Actions secret and the generating machine's Keychain — it's never committed to the repo.

## Out of Scope (v1)

Remote/cloud sync, multi-user support, Grafana/Prometheus integration, iOS companion app. No Apple Developer Program membership is planned in this phase (no Developer ID signing or notarization) — Sparkle still verifies update integrity with the EdDSA appcast signature, but downloaded builds remain ad-hoc signed and Gatekeeper may show a warning on first launch.

## License

[MIT](LICENSE)
