# Zext Health Standard v1

**ID:** `zext-health/v1` · **Media type:** `application/health+json`

This standard defines a single health endpoint that every Zext service implements, so one monitor
(Health Monitor) can tell, for any service, whether it is up, degraded, or down, which version is
deployed, and which dependency is the problem. It follows the IETF draft
[Health Check Response Format for HTTP APIs](https://datatracker.ietf.org/doc/html/draft-inadarei-api-health-check)
(draft-inadarei-api-health-check). Any tool that understands that draft understands this standard.

The key words **MUST**, **MUST NOT**, **SHOULD** and **MAY** are used as in RFC 2119.

The same rules, examples and a JSON Schema are published (no account needed) at:

- `GET https://health.zext.dev/api/standards/health`: rules, examples and schema as JSON
- `GET https://health.zext.dev/api/standards/health/schema.json`: the JSON Schema (draft 2020-12) alone

## TL;DR

```http
GET /health

HTTP/1.1 200 OK
Content-Type: application/health+json
Cache-Control: no-store
```

```json
{
  "status": "pass",
  "version": "1.4.2",
  "releaseId": "9f2c1ab7e4d3"
}
```

- `status` is `pass`, `warn` or `fail`. HTTP status is **200** for `pass` and `warn`, and **503** for `fail`.
- Report the running `version` and `releaseId` (git SHA or build number).
- Optionally list dependency checks under `checks`.
- No auth. Respond in under 1 second. No secrets, paths, internal hosts or stack traces.

## 1. Endpoint

| Rule | Level |
|---|---|
| Serve the endpoint at `GET /health`. | SHOULD |
| The endpoint does not require authentication: no API key, cookie or IP allow-list that the monitor can't satisfy. | MUST |
| Respond within **1 second**. | SHOULD |
| Cache dependency checks for **at most 30 seconds**, and give each one its own timeout so that one slow dependency can't stall the whole response. | SHOULD |
| Answer `HEAD /health` if your framework makes that free. Monitors use `GET`. | MAY |

`/health` describes the service as a whole. Use `/live` or `/ready` for Kubernetes-style
liveness/readiness probes. Those are separate concerns and are not covered here.

## 2. Response headers

| Header | Value | Level |
|---|---|---|
| `Content-Type` | `application/health+json` (`application/json` is tolerated) | SHOULD |
| `Cache-Control` | `no-store` | SHOULD |

## 3. HTTP status

| Body `status` | HTTP status | Meaning |
|---|---|---|
| `pass` | **200** | Healthy. |
| `warn` | **200** | Working, but something needs attention (degraded). Still serving traffic. |
| `fail` | **503** | Not able to serve correctly. |

The HTTP status MUST match the body. A `fail` body with HTTP 200, or a `pass` body with HTTP 503,
is an error. Any other HTTP status (401, 404, 500, …) means the health endpoint itself is broken.

## 4. Body

The body MUST be a single JSON object. Unknown extra fields are allowed and MUST be ignored by
consumers, so you can add more later without breaking anything.

### 4.1 Top-level fields

| Field | Type | Level | Description |
|---|---|---|---|
| `status` | `"pass"` \| `"warn"` \| `"fail"` | **MUST** | Overall health. Lowercase, exactly one of these three values. |
| `version` | string | SHOULD | Human-readable version of the running code, e.g. `"1.4.2"`. |
| `releaseId` | string | SHOULD | Identifier of this specific deploy, e.g. the git SHA or CI build number. |
| `serviceId` | string | MAY | Stable identifier of the service, e.g. `"billing-api"`. |
| `description` | string | MAY | Human-readable name of the service. |
| `notes` | array of strings | MAY | Free-form notes. |
| `output` | string | MAY (SHOULD when `warn`/`fail`) | One short, human-readable reason, e.g. `"Database unreachable"`. **Never** a stack trace or raw error dump. |
| `checks` | object | MAY | Dependency and component checks, see 4.2. |

### 4.2 `checks`

`checks` is an object. Each **key** names one measurement as `"component:measurement"`, for example
`"postgres:responseTime"`, `"redis:responseTime"`, `"disk:utilization"`, `"queue:backlog"`. Each
**value** is an **array** of check objects. It is usually a single entry. Use several entries when
the component has several instances (e.g. two replicas, told apart by `componentId`).

| Field | Type | Level | Description |
|---|---|---|---|
| `status` | `"pass"` \| `"warn"` \| `"fail"` | **MUST** | Status of this check. |
| `componentId` | string | MAY | Identifier of the instance, e.g. `"primary"`. Not a hostname or IP. |
| `componentType` | string | MAY | e.g. `"datastore"`, `"system"`, `"component"`. |
| `observedValue` | number \| string \| boolean | MAY | The measured value, e.g. `12`. |
| `observedUnit` | string | MAY | Unit of `observedValue`, e.g. `"ms"`, `"percent"`. |
| `time` | string | MAY | When this was measured (ISO 8601 with time zone, e.g. `"2026-10-11T09:30:00Z"`). Useful when cached. |
| `output` | string | MAY | Short reason when this check is `warn`/`fail`. |

### 4.3 Overall status

The overall `status` MUST be the **worst** status of all check entries, where `fail` is worse than
`warn`, which is worse than `pass`. A service with no `checks` simply reports its own state.

If a dependency is optional (the service still works without it, maybe with reduced features),
report that dependency as `warn` instead of `fail`.

## 5. Examples

### 5.1 Pass

```http
HTTP/1.1 200 OK
Content-Type: application/health+json
Cache-Control: no-store
```

```json
{
  "status": "pass",
  "version": "1.4.2",
  "releaseId": "9f2c1ab7e4d3",
  "serviceId": "billing-api",
  "description": "Billing API",
  "checks": {
    "postgres:responseTime": [
      {
        "componentType": "datastore",
        "status": "pass",
        "observedValue": 12,
        "observedUnit": "ms",
        "time": "2026-10-11T09:30:00Z"
      }
    ],
    "redis:responseTime": [
      {
        "componentType": "datastore",
        "status": "pass",
        "observedValue": 2,
        "observedUnit": "ms",
        "time": "2026-10-11T09:30:00Z"
      }
    ],
    "disk:utilization": [
      {
        "componentType": "system",
        "status": "pass",
        "observedValue": 41.5,
        "observedUnit": "percent",
        "time": "2026-10-11T09:30:00Z"
      }
    ]
  }
}
```

### 5.2 Warn (degraded, still HTTP 200)

```http
HTTP/1.1 200 OK
Content-Type: application/health+json
Cache-Control: no-store
```

```json
{
  "status": "warn",
  "version": "1.4.2",
  "releaseId": "9f2c1ab7e4d3",
  "serviceId": "billing-api",
  "output": "Disk usage above 85%",
  "checks": {
    "postgres:responseTime": [
      {
        "componentType": "datastore",
        "status": "pass",
        "observedValue": 14,
        "observedUnit": "ms",
        "time": "2026-10-11T09:30:00Z"
      }
    ],
    "disk:utilization": [
      {
        "componentType": "system",
        "status": "warn",
        "observedValue": 87.2,
        "observedUnit": "percent",
        "time": "2026-10-11T09:30:00Z",
        "output": "Disk usage above 85%"
      }
    ]
  }
}
```

### 5.3 Fail (HTTP 503)

```http
HTTP/1.1 503 Service Unavailable
Content-Type: application/health+json
Cache-Control: no-store
```

```json
{
  "status": "fail",
  "version": "1.4.2",
  "releaseId": "9f2c1ab7e4d3",
  "serviceId": "billing-api",
  "output": "Database unreachable",
  "checks": {
    "postgres:responseTime": [
      {
        "componentType": "datastore",
        "status": "fail",
        "time": "2026-10-11T09:30:00Z",
        "output": "Database unreachable"
      }
    ],
    "redis:responseTime": [
      {
        "componentType": "datastore",
        "status": "pass",
        "observedValue": 3,
        "observedUnit": "ms",
        "time": "2026-10-11T09:30:00Z"
      }
    ]
  }
}
```

### 5.4 Minimal

Valid, but the validator warns that `version` and `releaseId` are missing. Use this as a first
step only.

```json
{
  "status": "pass"
}
```

### 5.5 Don't do this

```text
HTTP/1.1 200 OK                                   <- says OK while reporting an error
Content-Type: text/html                           <- not JSON content type
{
  "status": "ok",                                 <- not pass/warn/fail
  "error": "Error: connect ECONNREFUSED 10.0.3.7:5432\n    at TCPConnectWrap...",  <- stack trace + internal IP
  "storage": "/var/www/vhosts/example/storage",   <- server file path
  "db": "postgres://app:s3cret@db.internal/app"   <- connection string with password
}
```

## 6. Security rules

The health endpoint is public and unauthenticated, so treat its body like a public web page. It
**MUST NOT** contain:

- secrets, API keys, tokens or passwords, including in key names such as `"dbPassword": "…"`
- file system paths (`/var/…`, `/home/…`, `/Users/…`, `C:\…`)
- internal hostnames or IP addresses (`10.x`, `172.16–31.x`, `192.168.x`, `db.internal`)
- connection strings (`postgres://user:pass@host/db`)
- stack traces or raw exception messages (log them, and put one short line in `output` instead)
- user data of any kind

Catch dependency errors and replace them with a fixed message such as `"Database unreachable"`.
Exception messages often contain hostnames, IPs or credentials. The validator scans for these
patterns and reports them as warnings (heuristics can have false positives), but the rule itself is a
MUST.

## 7. Performance rules

- The whole response SHOULD take **under 1 second**. Monitors hit it every minute or so, sometimes
  several monitors at once.
- Run dependency checks **in parallel**, each with its own timeout (e.g. 500–800 ms). A check that
  times out is `fail` (or `warn` if the dependency is optional).
- **Cache** the result of the dependency checks for at most **30 seconds** and serve the cached
  result in between. Put the measurement time in each check's `time`.
- Use cheap probes: `SELECT 1`, Redis `PING`, a `HEAD` on a dependency's own `/health`. Never run a
  real query, a migration check or anything that writes.
- Keep the body small (a few KB). The validator rejects bodies over 256 KB.

## 8. How to implement

Framework-agnostic pseudo-code:

```text
CACHE_TTL = 15s
cache = null

function probe(name, fn, timeout = 800ms, warnAfter = 250ms):
    started = now()
    try:
        run fn() with timeout
        elapsed = now() - started
        status = elapsed > warnAfter ? "warn" : "pass"
        return name + ":responseTime", { componentType: "datastore", status,
                                         observedValue: elapsed, observedUnit: "ms", time: iso(now()) }
    catch (any error):
        log(error)                                   # full details go to logs only
        return name + ":responseTime", { componentType: "datastore", status: "fail",
                                         time: iso(now()), output: name + " unreachable" }

function computeHealth():
    checks = run in parallel:
        probe("postgres", () => db.query("SELECT 1"))
        probe("redis",    () => redis.ping())
    status = worst(all check statuses)               # fail > warn > pass
    body = { status, version: APP_VERSION, releaseId: GIT_SHA, serviceId: "billing-api", checks }
    if status != "pass": body.output = output of the first non-pass check
    return body

handle GET /health:
    if cache is null or cache.age > CACHE_TTL:
        cache = computeHealth()
    respond(
        status: cache.body.status == "fail" ? 503 : 200,
        headers: { "Content-Type": "application/health+json", "Cache-Control": "no-store" },
        body: json(cache.body))
```

Tips:

- Inject `version` and `releaseId` at build or deploy time (e.g. from `package.json` and
  `GIT_SHA`/`RELEASE_ID` environment variables). Don't shell out to `git` on every request.
- Exclude `/health` from auth middleware, CSRF protection, maintenance mode and request logging.
- Don't put `/health` behind a CDN cache. `Cache-Control: no-store` helps, but check your CDN rules.

## 9. Check your implementation

Health Monitor validates any URL or pasted response against this standard. The validate endpoint
needs a Health Monitor account (it fetches arbitrary URLs).

```bash
# 1. Get an access token
TOKEN=$(curl -s https://health.zext.dev/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@zext.com","password":"…"}' | jq -r .accessToken)

# 2. Validate a live URL (fetched by the backend: 10 s timeout, 256 KB max, http(s) only)
curl -s https://health.zext.dev/api/standards/health/validate \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"url":"https://billing.example.com/health"}' | jq

# 3. Or validate a response you paste in (e.g. from a service that isn't reachable from the internet)
curl -s https://health.zext.dev/api/standards/health/validate \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"response":{"httpStatus":200,"contentType":"application/health+json","body":{"status":"pass","version":"1.4.2","releaseId":"9f2c1ab"}}}' | jq
```

The result lists MUST violations under `errors` (any error makes `valid` false) and SHOULD
violations under `warnings`. Each issue has a `path` (a JSON Pointer into the body, or `http.status`
/ `http.headers.content-type` / `http.headers.cache-control` / `http.responseTime`), a `rule` id and
a `message`. Aim for `"valid": true` with no warnings.

You can also validate the body offline against the JSON Schema with any draft 2020-12 validator.
The schema covers the body only, not the HTTP status/header rules.

## 10. Checklist

- [ ] `GET /health` responds without authentication
- [ ] `status` is `pass` / `warn` / `fail`, and HTTP is 200 / 200 / 503
- [ ] `version` and `releaseId` are set from the build or deploy
- [ ] Dependencies are listed under `checks` as `"component:measurement"` arrays
- [ ] Overall `status` is the worst check status
- [ ] `output` gives a short reason for `warn`/`fail`
- [ ] `Content-Type: application/health+json`, `Cache-Control: no-store`
- [ ] Under 1 s, with dependency checks cached ≤ 30 s and individually time-limited
- [ ] No secrets, paths, internal hosts/IPs, connection strings, stack traces or user data
- [ ] The validate endpoint returns `"valid": true` with no warnings
