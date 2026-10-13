#!/usr/bin/env bash
# Post-deploy gate, run on the server by .github/workflows/deploy.yml after `pm2 restart`.
# Fails (exit 1) unless, within the timeout:
#   - GET <base-url>/health answers HTTP 200 (a `fail` status is 503 and never passes),
#   - its body is the Zext Health Standard with status `pass` or `warn`,
#   - its `releaseId` equals <expected-release> — i.e. the restarted process is really running the
#     commit we just pulled (releaseId is resolved once at startup, so a stale process reports the
#     old SHA),
#   - and, when pm2 is available, every app listed in PM2_APPS is `online`.
#
# Usage: verify-deploy.sh <base-url> <expected-release> [timeout-seconds]
# Env:   PM2_APPS (default "health-api health-worker"; empty skips the pm2 check)
set -eu

BASE_URL="${1:?usage: verify-deploy.sh <base-url> <expected-release> [timeout-seconds]}"
EXPECTED_RELEASE="${2:?usage: verify-deploy.sh <base-url> <expected-release> [timeout-seconds]}"
TIMEOUT="${3:-60}"
PM2_APPS="${PM2_APPS-health-api health-worker}"

deadline=$(( $(date +%s) + TIMEOUT ))
last_problem="no response yet"

while :; do
  body=""
  if body=$(curl -fsS --max-time 5 "$BASE_URL/health" 2>&1); then
    # node is always present on the server (the backend runs on it); no jq dependency.
    verdict=$(EXPECTED="$EXPECTED_RELEASE" node -e '
      let raw = "";
      process.stdin.on("data", (chunk) => (raw += chunk));
      process.stdin.on("end", () => {
        let health;
        try { health = JSON.parse(raw); } catch { console.log("body is not JSON"); return; }
        if (health.status !== "pass" && health.status !== "warn") {
          console.log(`status is ${JSON.stringify(health.status)}`);
        } else if (health.releaseId !== process.env.EXPECTED) {
          console.log(`releaseId is ${JSON.stringify(health.releaseId)}, expected ${process.env.EXPECTED}`);
        } else {
          console.log("ok");
        }
      });
    ' <<< "$body")
    if [ "$verdict" = "ok" ]; then
      break
    fi
    last_problem="$verdict"
  else
    last_problem="request failed: $body"
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::Deploy verification failed after ${TIMEOUT}s: $last_problem"
    echo "Last /health body: ${body:-<none>}"
    exit 1
  fi
  sleep 2
done
echo "Health OK: $body"

if [ -n "$PM2_APPS" ] && command -v pm2 >/dev/null 2>&1; then
  not_online=$(pm2 jlist | APPS="$PM2_APPS" node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => (raw += chunk));
    process.stdin.on("end", () => {
      const procs = JSON.parse(raw);
      const bad = process.env.APPS.split(/\s+/).filter(Boolean).filter((name) => {
        const p = procs.find((x) => x.name === name);
        return !p || p.pm2_env.status !== "online";
      });
      console.log(bad.join(" "));
    });
  ')
  if [ -n "$not_online" ]; then
    echo "::error::pm2 apps not online: $not_online"
    pm2 status || true
    exit 1
  fi
  echo "pm2 apps online: $PM2_APPS"
fi
