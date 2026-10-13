#!/usr/bin/env bash
# Server-side backend deploy with automatic rollback, run by .github/workflows/deploy.yml right
# after `git pull` (the workflow records the pre-pull commit and passes it in).
#
#   1. install → build → migrate → pm2 restart, then verify-deploy.sh against the new commit.
#   2. If any of that fails, roll back: move `main` back to <previous-commit> (reset, not checkout,
#      so the checkout stays on `main` and the next `git pull` fast-forwards normally), reinstall,
#      rebuild, restart, and verify the previous commit is healthy again.
#   3. Exit 1 whenever the new release didn't make it — even after a clean rollback — so the job
#      goes red. A rollback that also fails is reported as needing manual intervention.
#
# Database migrations can't be rolled back (drizzle has no down migrations). If the failed release
# shipped new migration files they stay applied; this logs a warning. Migrations here are
# additive, so the previous code keeps working against the newer schema.
#
# Usage: deploy-backend.sh <repo-root> <previous-commit>
# Env:   HEALTH_URL (default http://localhost:3030), VERIFY_TIMEOUT (default 60 s),
#        PM2_APPS (default "health-api health-worker").
#
# Everything runs inside main(), which bash parses completely before running it: the rollback's
# `git reset` rewrites this very file on disk, and a bash script still being read line by line
# would otherwise continue from the old version's bytes. verify-deploy.sh is copied out of the
# checkout for the same reason (and because an old commit may not have it).
set -eu

main() {
  local root="$1" prev="$2"
  local health_url="${HEALTH_URL:-http://localhost:3030}"
  local timeout="${VERIFY_TIMEOUT:-60}"
  local apps="${PM2_APPS:-health-api health-worker}"
  export PM2_APPS="$apps"

  cd "$root"
  local new tools
  new=$(git rev-parse HEAD)
  tools=$(mktemp -d)
  cp backend/scripts/verify-deploy.sh "$tools/verify-deploy.sh"

  echo "Deploying $new (previous release $prev)"

  local failed_at=""
  if ! (cd backend && pnpm install --frozen-lockfile); then
    failed_at="install"
  elif ! (cd backend && pnpm run build); then
    failed_at="build"
  elif ! (cd backend && npx drizzle-kit migrate); then
    failed_at="migrate"
  elif ! pm2 restart $apps; then
    failed_at="restart"
  elif ! bash "$tools/verify-deploy.sh" "$health_url" "$new" "$timeout"; then
    failed_at="verification"
  fi

  if [ -z "$failed_at" ]; then
    echo "Deployed $new"
    rm -rf "$tools"
    return 0
  fi

  echo "::error::Deploy of $new failed at: $failed_at"
  pm2 logs $apps --lines 40 --nostream || true

  if [ "$new" = "$prev" ]; then
    echo "::error::Nothing to roll back to: $new was already the deployed commit. Manual intervention needed."
    return 1
  fi

  if ! git diff --quiet "$prev" "$new" -- backend/src/db/migrations; then
    echo "::warning::$new added database migrations; they stay applied after the rollback (no down migrations). Migrations here are additive, so $prev should still run, but check the schema."
  fi

  echo "Rolling back to $prev"
  git reset --hard "$prev"
  if (cd backend && pnpm install --frozen-lockfile) \
    && (cd backend && pnpm run build) \
    && pm2 restart $apps \
    && bash "$tools/verify-deploy.sh" "$health_url" "$prev" "$timeout"; then
    echo "::error::Deploy of $new failed at $failed_at; rolled back to $prev, which is healthy."
  else
    echo "::error::Deploy of $new failed at $failed_at, and the rollback to $prev also failed. Manual intervention needed."
    pm2 status || true
  fi
  rm -rf "$tools"
  return 1
}

[ $# -eq 2 ] || { echo "usage: deploy-backend.sh <repo-root> <previous-commit>" >&2; exit 2; }
main "$@"; exit $?
