# Zext Health Standard v1

**ID:** `zext-health/v1` · **Media type:** `application/health+json`

This standard defines a single health endpoint that every Zext service implements, so one monitor
(Health Monitor) can tell, for any service, whether it is up, degraded, or down, and which version is
deployed. It follows the IETF draft
[Health Check Response Format for HTTP APIs](https://datatracker.ietf.org/doc/html/draft-inadarei-api-health-check)
(draft-inadarei-api-health-check). Any tool that understands that draft understands this standard.

The key words **MUST**, **MUST NOT**, **SHOULD** and **MAY** are used as in RFC 2119.

The same rules, examples and a JSON Schema are published (no account needed) at:

- `GET https://health.zext.dev/api/standards/health`: rules, examples and schema as JSON
- `GET https://health.zext.dev/api/standards/health/schema.json`: the JSON Schema (draft 2020-12) alone

## Principle: the endpoint is public, so publish the minimum

`/health` needs no authentication, so anyone on the internet can read it. Treat every field as a
public page and publish **only what the monitor needs to decide**: the overall status and the running
version. The service decides its own status internally (it checks its database, cache and so on, and
reports a single `pass`, `warn` or `fail`). It does **not** publish per-component details such as
dependency names, response times, disk usage or the versions of its runtime. That detail belongs in
your own logs and dashboards, not in a public response.

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
- Report the running `version` and `releaseId` (git SHA or build number) of **your application**.
- Nothing else is needed. No `checks`, no runtime or library versions, no counts, no hostnames.
- No auth. Respond in under 1 second. No secrets, paths, internal hosts or stack traces.

## 1. Endpoint

| Rule | Level |
|---|---|
| Serve the endpoint at `GET /health`. | SHOULD |
| The endpoint does not require authentication: no API key, cookie or IP allow-list that the monitor can't satisfy. | MUST |
| Respond within **1 second**. | SHOULD |
| Cache your internal dependency probes for **at most 30 seconds**, and give each one its own timeout so that one slow dependency can't stall the whole response. | SHOULD |
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
consumers, but because the endpoint is public the validator warns about them (see 4.3).

### 4.1 Fields

| Field | Type | Level | Description |
|---|---|---|---|
| `status` | `"pass"` \| `"warn"` \| `"fail"` | **MUST** | Overall health. Lowercase, exactly one of these three values. |
| `version` | string | SHOULD | Human-readable version of **your application**, e.g. `"1.4.2"`. Not the version of PHP, Node, the framework or any library. |
| `releaseId` | string | SHOULD | Identifier of this specific deploy, e.g. the git SHA or CI build number. |
| `serviceId` | string | MAY | Stable identifier of the service, e.g. `"billing-api"`. |
| `description` | string | MAY | Human-readable name of the service. |
| `notes` | array of strings | MAY | Free-form notes. |
| `output` | string | MAY (SHOULD when `warn`/`fail`) | One short, fixed, human-readable reason, e.g. `"Database unreachable"`. **Never** a stack trace or raw error dump. |

`version` and `releaseId` MUST come from the build or deploy. Don't send placeholders such as
`"unknown"` or `"..."`: leave the field out instead.

### 4.2 Overall status

The service decides `status` itself, from whatever it needs to be healthy:

- A dependency the service cannot work without (database, primary cache) is down: `fail`.
- An optional dependency is down (the service still works, maybe with reduced features), or a
  dependency is slow or a resource is running low: `warn`.
- Otherwise: `pass`.

When the status is `warn` or `fail`, put one short, **fixed** message in `output` (for example
`"Database unreachable"`, never the exception text). That single line is how the monitor and your
team learn which part is unhealthy. Anything more detailed goes to your logs.

### 4.3 What not to publish

The monitor only needs the fields in 4.1. Everything else is public information with no benefit.
In particular:

- **`checks`, or any per-component list.** Earlier drafts of this standard had an optional `checks`
  object. It was removed: it exposed dependency names, response times and resource usage to anyone.
  Services that still send it keep working (the monitor ignores it), and the validator warns.
- **Technology stack details:** runtime, framework, OS or library versions (`"php": "8.3.23"`), which
  help an attacker pick known exploits.
- Record or user counts, configuration values, queue sizes, and infrastructure topology (replica
  counts, regions, host names).

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
  "description": "Billing API"
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
  "output": "Cache unavailable"
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
  "output": "Database unreachable"
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
  "version": "unknown",                           <- placeholder: leave it out instead
  "releaseId": "...",                             <- placeholder: leave it out instead
  "checks": {                                     <- per-component detail is public
    "php:version": [{ "status": "pass", "observedValue": "8.3.23" }]   <- runtime version
  },
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
- details of the technology stack and infrastructure: runtime, framework, OS or library versions,
  record counts, configuration values, topology (see 4.3)

Catch dependency errors and replace them with a fixed message such as `"Database unreachable"`.
Exception messages often contain hostnames, IPs or credentials. The validator scans for these
patterns and reports them as warnings (heuristics can have false positives), but the rule itself is a
MUST.

## 7. Performance rules

- The whole response SHOULD take **under 1 second**. Monitors hit it every minute or so, sometimes
  several monitors at once.
- Run your internal dependency probes **in parallel**, each with its own timeout (e.g. 500–800 ms). A
  probe that times out makes the service `fail` (or `warn` if the dependency is optional).
- **Cache** the probe results for at most **30 seconds** and serve the cached result in between.
- Use cheap probes: `SELECT 1`, Redis `PING`, a `HEAD` on a dependency's own `/health`. Never run a
  real query, a migration check or anything that writes.
- Keep the body small (it is a handful of fields). The validator rejects bodies over 256 KB.

## 8. How to implement

Framework-agnostic pseudo-code:

```text
CACHE_TTL = 15s
cache = null

function probe(name, fn, timeout = 800ms, warnAfter = 250ms):
    started = now()
    try:
        run fn() with timeout
        return (now() - started) > warnAfter ? ("warn", name + " is slow") : ("pass", null)
    catch (any error):
        log(error)                                   # full details go to logs only
        return ("fail", name + " unreachable")

function computeHealth():
    results = run in parallel:
        probe("database", () => db.query("SELECT 1"))
        probe("cache",    () => redis.ping())
    status = worst(all statuses)                     # fail > warn > pass
    body = { status, version: APP_VERSION, releaseId: GIT_SHA, serviceId: "billing-api" }
    if status != "pass": body.output = message of the first non-pass probe
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
a `message`. Aim for `"valid": true` with no warnings. A `checks` field, or any field this standard
doesn't define, produces a warning (`no-checks`, `known-fields`).

You can also validate the body offline against the JSON Schema with any draft 2020-12 validator.
The schema covers the body only, not the HTTP status/header rules.

## 10. Checklist

- [ ] `GET /health` responds without authentication
- [ ] `status` is `pass` / `warn` / `fail`, and HTTP is 200 / 200 / 503
- [ ] `version` and `releaseId` are set from the build or deploy (no placeholders)
- [ ] `version` is your application's version, not a runtime, framework or library version
- [ ] The body has no `checks` and no other fields beyond the ones in 4.1
- [ ] `output` gives a short, fixed reason for `warn`/`fail`
- [ ] `Content-Type: application/health+json`, `Cache-Control: no-store`
- [ ] Under 1 s, with internal probes cached ≤ 30 s and individually time-limited
- [ ] No secrets, paths, internal hosts/IPs, connection strings, stack traces, user data or stack/infrastructure details
- [ ] The validate endpoint returns `"valid": true` with no warnings
