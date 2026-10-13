#!/usr/bin/env bash
# Runs on the GitHub runner after the web client swap, checking the site the way a visitor sees
# it. Passes once, within the timeout, <site-url>/ serves an index.html that references this
# build's entry bundle (its content hash changes every build, so this proves the new release is
# live), and that bundle itself loads.
#
# Usage: verify-web-client.sh <site-url> <local-dist-dir> [timeout-seconds]
set -eu

SITE_URL="${1:?usage: verify-web-client.sh <site-url> <local-dist-dir> [timeout-seconds]}"
DIST_DIR="${2:?usage: verify-web-client.sh <site-url> <local-dist-dir> [timeout-seconds]}"
TIMEOUT="${3:-60}"
SITE_URL="${SITE_URL%/}"

ENTRY=$(grep -oE 'src="/_expo/static/js/[^"]+\.js"' "$DIST_DIR/index.html" | head -1 | sed -E 's/^src="//; s/"$//')
if [ -z "$ENTRY" ]; then
  echo "::error::No entry bundle found in $DIST_DIR/index.html"
  exit 1
fi
echo "Expecting the live site to serve $ENTRY"

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  # Cache-busting query so an intermediate cache can't hand back the previous index.html.
  if page=$(curl -fsS --max-time 10 "$SITE_URL/?deploy-check=$(date +%s)" 2>&1); then
    if grep -qF "$ENTRY" <<< "$page"; then
      if curl -fsS --max-time 20 -o /dev/null "$SITE_URL$ENTRY"; then
        echo "Web client live: $SITE_URL serves $ENTRY"
        exit 0
      fi
      problem="index.html is new but $ENTRY failed to load"
    else
      problem="live index.html doesn't reference $ENTRY yet"
    fi
  else
    problem="request failed: $page"
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::Web client verification failed after ${TIMEOUT}s: $problem"
    exit 1
  fi
  sleep 3
done
