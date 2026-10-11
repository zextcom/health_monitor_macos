# Health Standard in Health Monitor

How Health Monitor (the macOS app and the backend worker) reads endpoints that implement the
[Zext Health Standard v1](health-standard.md) (`zext-health/v1`). It is an opt-in flag per
endpoint. Endpoints without the flag behave exactly as before.

## Configuration (Endpoint form → Details)

| Field | Notes |
|---|---|
| Uses Zext Health Standard | Toggle, HTTP endpoints only. When on, the *Expected HTTP status code* field is hidden and ignored (its old value is kept). Saving a TCP endpoint always turns it off. |
| Test Connection hint | If the test response looks standard (`Content-Type: application/health+json`, or a top-level `status` of `pass`/`warn`/`fail`), the form shows the parsed status, version and component count, plus a *Use Health Standard* button that turns the toggle on. With the toggle on, the same line shows how the response would be read, or why it is invalid. |
| JSON assertions | Still available and ANDed on top of the standard evaluation. |

## Evaluation

The same rules run on macOS (`HealthStandard.evaluate`) and in the backend worker
(`evaluateStandardHttpCheck`):

- **HTTP status:** `expectedStatusCode` is ignored. Only HTTP **200** and **503** are readable. Any other status is down with `Unexpected HTTP <code>`.
- **Body:** must be JSON with a valid `status`, otherwise down with `Invalid health response: …` (`body is not valid JSON`, `body is not a JSON object`, `missing "status"`, `invalid status "ok"`).
- **Contradictions:** HTTP 503 with a `pass`/`warn` body is treated as invalid (down), because a load balancer reading the 503 would already have pulled the service.
- **Status mapping:**
  - `pass` → healthy
  - `warn` → healthy but **degraded**
  - `fail` → down
- **Overall status:** the monitor trusts the declared overall `status` even if the checks disagree. The validator flags that mismatch, the monitor doesn't second-guess it.
- **Reason** (warn or fail): the top-level `output` if present, else the first non-pass check as `"<key>: <status>[ — output]"`, else `Health status "<status>"`. For a degraded result the reason is stored in `failureReason`.
- **JSON assertions:** applied after a `pass`/`warn` body (AND). A failing assertion makes the result down with the assertion's reason. A `fail` body keeps its own reason.
- **Leniency:** malformed check entries are skipped rather than failing the endpoint. Strict checking is the validator's job (see *API*).

## Degraded

- Degraded counts as **up** for uptime, incidents and daily stats.
- **macOS:** `HealthCheckResult.isDegraded` (decodeIfPresent, default `false`).
- **Backend:** `health_check_results.health_status` (`pass` / `warn` / `fail`, `null` for non-standard endpoints or unreadable bodies).
- **Indicator:** yellow/orange, with a shape distinct from healthy and down so it doesn't depend on color alone:

  | Where | Healthy | Degraded | Down |
  |---|---|---|---|
  | Popover row / backend row / menu bar | `checkmark.circle.fill` | `exclamationmark.triangle.fill` | `exclamationmark.circle.fill` |
  | Sparkline | full-height green bar | shorter orange bar | full-height red bar |
  | Detail chart point | circle | triangle | square |
  | Widget (small headline icon, medium rows) | `checkmark.circle.fill` | `exclamationmark.triangle.fill` | `exclamationmark.circle.fill` |
  | Exported status page dot | green circle | orange diamond | red circle |

- **Menu bar:** `down` > `degraded` > `healthy`. In backend mode this comes from `summary.degradedEndpoints` / `unhealthyEndpoints`.
- **Widget:** `WidgetEndpointStatus.isDegraded` (decodeIfPresent, so a snapshot written by an older app still loads). The small widget shows the worst state and a headline such as `3/3 Healthy`, `1/3 Degraded` or `1/3 Down · 1 Degraded`; the medium widget shows each endpoint's state.
- **History export:** JSON includes `isDegraded`; CSV adds an `isDegraded` column at the end so positional readers keep working.
- **Status page export:** `EndpointStatusSummary.isDegraded` (also in the JSON). Degraded rows read *Degraded*, and the summary line excludes them from the healthy count, e.g. `2 of 4 endpoints healthy · 1 degraded`.
- **Rows:** popover rows (local and backend mode) show a *Degraded* label with the reason as its tooltip. Local rows also use the reason in the accessibility label.

## Notifications

| Transition | Notification | Gated by |
|---|---|---|
| healthy → degraded | "\<name\> degraded" + reason (backend: 🟠 Endpoint Degraded) | macOS: notifications enabled + snooze. Backend: `notifyOnDown`. |
| degraded → healthy | "\<name\> is healthy again" (backend: 🟢 Endpoint Healthy) | + *Notify when recovered* / `notifyOnRecovery` |
| healthy or degraded → down | the existing *down* notification | unchanged |
| down → healthy | the existing *recovered* notification | unchanged |
| down → degraded | a single *recovered* notification, worded "back up, but degraded" + reason. No separate *degraded* notification. | *Notify when recovered* / `notifyOnRecovery` |

The first result for an endpoint never notifies for degraded (there is no previous state to
transition from). The backend's down notification for a first-ever down result is unchanged.

## Components

Only the **latest** parsed component list is kept per endpoint. It is not stored per result, so
history doesn't grow.

- **macOS:** `HealthDetailsStore`, an in-memory `@Published` store that is not persisted and refills on the first check after launch. `EndpointDetailView` shows a *Components* section for health-standard endpoints: the reported status and reason, then each check's key (plus `componentId`), a status icon, `observedValue` + unit, and `output`.
- **Backend:** the `endpoint_health_state` table (one row per endpoint, overwritten on every readable response) with `status`, `version`, `release_id`, `output`, `components` (jsonb) and `checked_at`.
- **Limits:** both sides cap the list at 50 entries and clip long text to 300 characters.

## Automatic version tracking

When `healthStandard` is on and the endpoint has **no enabled explicit version check**, every
check feeds the response's version into the existing version tracking (macOS `VersionStore.record`,
backend `recordVersionResult`) without an extra request:

- **Tracked value:**
  - `"<version> (<first 7 chars of releaseId>)"` when both exist, e.g. `1.4.2 (9f2c1ab)`
  - otherwise whichever one exists
  - a response with neither is skipped
- **Reuses:** change notifications ("Notify on version change"), the version badge and the history timeline. The detail sheet labels the section *From health response*.
- **Explicit check wins:** an explicit `versionCheck` that is enabled takes over. A disabled (paused) one does not.

## Backend

- **Schema** (migration `0002_health_standard.sql`):
  - `endpoints.health_standard boolean not null default false`
  - `health_check_results.health_status text` (nullable)
  - `endpoint_health_state` (latest components, cascades with the endpoint)
- **Endpoints API:**
  - `POST`/`PUT /api/endpoints` accept `healthStandard`. It is omitted on `PUT` = unchanged.
  - `POST /api/endpoints/import` accepts the macOS export shape (`healthStandard`).
  - `GET /api/endpoints/:id/health-details` returns `{ healthStandard, latest }`, where `latest` is `{ status, version, releaseId, output, checkedAt, components }` or `null`.
- **Dashboard** (`GET /api/dashboard`):
  - `latestCheck` gains `healthStatus` and `isDegraded`.
  - `summary` gains `degradedEndpoints` (a subset of `healthyEndpoints`).
  - Each endpoint gains `healthStandard` and `healthDetails` (the same shape as `latest`, `null` when the flag is off).
  - `version` gains `source`: `"versionCheck"`, or `"healthStandard"` for auto-tracked versions.
- **SSE:** check events gain `healthStatus`.
- **Standard API:**
  - `GET /api/standards/health` (public): `{ id, title, summary, mediaType, rules, examples, schema }`. All of it comes from one module, `src/modules/standards/health-standard.ts`.
  - `GET /api/standards/health/schema.json` (public): the JSON Schema (draft 2020-12) alone, as `application/schema+json`.
  - `POST /api/standards/health/validate` (authenticated):
    - **Request:** `{ url }`, which the backend fetches (10 s timeout, 256 KB body cap, http(s) only, redirects followed manually and never to a non-http(s) scheme). Or `{ response: { httpStatus, contentType?, cacheControl?, body } }` to check a pasted response without fetching.
    - **Response:** `{ standard, valid, errors, warnings, observed }`. MUST violations are `errors`, SHOULD violations and leak heuristics are `warnings`.
    - **Fetch failures:** an unreachable URL returns `valid: false` with a single `fetch` error, not an HTTP error.
    - **Pasted responses:** content-type and cache-control are only checked when supplied.
    - The validator is a pure function, `health-standard-validator.ts`.
- **Own `GET /health`:**
  - Follows the standard: `status`, `version` (from `package.json`), `releaseId` (`RELEASE_ID` env var, else the git SHA of the checkout, else omitted), `serviceId`, and `postgres:responseTime` / `redis:responseTime` checks.
  - Probes are cached for 10 s and time-limited to 800 ms each. Slower than 250 ms is `warn`.
  - Returns 503 when a dependency fails. The error message is never echoed.
- **Worker:**
  - The standard evaluation happens inside the health check job.
  - Storing components and the auto-tracked version runs in a separate `try` after the result is recorded, so it can never alter or mask the health result (same pattern as the version check).

## Not in this iteration

- The mobile (Expo) client form for the toggle. The backend API accepts `healthStandard` already.
- A client library for services. The standard is small enough to implement by hand (see [health-standard.md](health-standard.md#8-how-to-implement)).
