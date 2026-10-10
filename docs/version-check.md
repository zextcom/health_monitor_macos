# Version Check

Optional, per-endpoint secondary check. Every N health checks, fetch JSON from a separate URL,
read a version value from it, and validate it with assertions — the same way health checks parse
JSON. A version check **never** affects the endpoint's health, uptime, or incidents.

## Configuration (Endpoint form → Advanced)

| Field | Notes |
|---|---|
| Version check | Toggle. Turning it off keeps the settings (paused) so re-enabling needs no retyping. |
| Version URL | Full http(s) URL, independent of the health URL (may be another host). |
| Run every N health checks | Default 5, range 1–1000. Also runs on the first health check after the config is set or changed. |
| Version field | Dot-path to the version, e.g. `data.version`. Required. Strings, numbers and booleans are accepted. |
| Auth | Separate from the endpoint's own auth (none / bearer / basic / custom header). macOS stores the secret in the Keychain under `<endpointId>.version`; the backend keeps it encrypted in `endpoint_version_secrets`. |
| Version assertions | Optional, ANDed, same path/value/match-mode semantics as health JSON assertions. |
| Test Version Check | Fires one request, shows the result, and lists JSON fields to pick as the version field or as an assertion. |

## Behaviour

- **Success:** any 2xx, a JSON body, the version field present, and every assertion passing.
- **Version observed:** the version is recorded whenever the field can be read, even if an assertion then fails.
- **History:** stores only changes, up to 50 per endpoint. Consecutive identical values collapse into one entry with `firstSeenAt`/`lastSeenAt`.
- **Notifications:**
  - *Version changed* (`1.4.2 → 1.5.0`) is compared against the last observed version, so a deploy that briefly fails still gets reported. The first observed version never triggers this.
  - *Version check failed* fires once, on a success → failure transition.
  - *Version check resolved* fires once, on a failure → success transition.
  - The very first result never notifies.
- **Notification gating:**
  - *Version changed* has its own toggle ("Notify on version change", default on).
  - *Failed* and *resolved* follow "Notify when down" and "Notify when recovered".
  - On macOS, all of them respect snooze.

## UI (macOS)

- **Popover row:** a `v1.5.0` badge, shown in orange with a warning icon when the latest version check failed. Backend-mode rows show the same badge from the dashboard response.
- **Endpoint detail:** a *Versions* section with the current version, the last check or failure reason, and the change timeline.

## Backend

- **Schema:**
  - `endpoints.version_check`: jsonb holding `VersionCheckConfig`, `null` when not configured.
  - `endpoint_version_secrets`
  - `endpoint_version_state`: cadence counter and latest result.
  - `version_history`
  - `notification_preferences.notify_on_version_change`
  - Migration: `0001_version_check.sql`.
- **API:**
  - `POST`/`PUT /api/endpoints` accept `versionCheck` (`null` removes it, along with its secret) and `versionAuthSecret`. The secret is never returned.
  - Changing `versionCheck` resets the cadence counter.
  - `POST /api/endpoints/import` accepts the macOS export shape (camelCase auth types).
  - `GET /api/endpoints/:id/versions` returns `{ current, history }`, newest first.
  - `GET /api/dashboard` adds a `version` field to each endpoint: `{ isEnabled, current, isFailing, failureReason, lastCheckedAt }`, or `null`.
  - `PUT /api/notifications/preferences` accepts `notifyOnVersionChange`.
- **Worker:** after each health check job, `runVersionCheckIfDue` increments the counter and, on every Nth check, fetches, records and pushes notifications. It runs in a separate `try`, so a version check error can never mask or alter a health result.

## Not in this iteration

- The mobile (Expo) client form for editing version checks. The backend API is ready for it.
- Editing backend endpoints from macOS. Backend mode stays read-only there.
