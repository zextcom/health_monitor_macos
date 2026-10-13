#!/usr/bin/env bash
# Server-side web client release steps, run by .github/workflows/deploy.yml over SSH.
#
#   check <dir>          Fail unless <dir>/index.html exists and every local asset it references
#                        (src="/…", href="/…") exists in <dir>. Run on the upload before going live.
#   swap <site-root>     check <site-root>/_client_upload, then make it live:
#                        public → public.prev, _client_upload → public. Two same-filesystem renames
#                        instead of `rm -rf public/* && cp`, so the site is never served empty or
#                        half-copied, and the previous release is kept for rollback.
#   rollback <site-root> public → public.failed, public.prev → public.
set -eu

usage() {
  echo "usage: web-client-release.sh check <dir> | swap <site-root> | rollback <site-root>" >&2
  exit 2
}

check() {
  local dir="$1"
  if [ ! -f "$dir/index.html" ]; then
    echo "::error::$dir/index.html is missing"
    return 1
  fi
  local missing=0 ref
  # Root-relative src/href only ("/x", not "//cdn" or "https://…"); query/fragment stripped.
  while IFS= read -r ref; do
    ref="${ref%%[?#]*}"
    if [ ! -e "$dir$ref" ]; then
      echo "::error::index.html references $ref, which is missing from the upload"
      missing=1
    fi
  done < <(grep -oE '(src|href)="/[^/"][^"]*"' "$dir/index.html" | sed -E 's/^(src|href)="//; s/"$//')
  [ "$missing" -eq 0 ] || return 1
  echo "Web client upload complete: $(find "$dir" -type f | wc -l | tr -d ' ') files"
}

swap() {
  local root="$1"
  local upload="$root/_client_upload" live="$root/public" prev="$root/public.prev"
  check "$upload"
  rm -rf "$prev"
  if [ -e "$live" ]; then
    mv "$live" "$prev"
  fi
  mv "$upload" "$live"
  if [ -d "$prev" ]; then
    echo "Web client live; previous release kept at $prev"
  else
    echo "Web client live (no previous release to keep)"
  fi
}

rollback() {
  local root="$1"
  local live="$root/public" prev="$root/public.prev" failed="$root/public.failed"
  if [ ! -d "$prev" ]; then
    echo "::error::No previous release at $prev to roll back to"
    return 1
  fi
  rm -rf "$failed"
  if [ -e "$live" ]; then
    mv "$live" "$failed"
  fi
  mv "$prev" "$live"
  echo "Rolled back the web client; the failed release is at $failed"
}

[ $# -eq 2 ] || usage
case "$1" in
  check) check "$2" ;;
  swap) swap "$2" ;;
  rollback) rollback "$2" ;;
  *) usage ;;
esac
