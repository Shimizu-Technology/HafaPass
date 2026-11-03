#!/usr/bin/env bash
# Fails when production no longer matches main: an API change merged but not
# deployed (the API deploys by hand), a frontend change Netlify never published,
# or readiness not returning 200. Run from a full clone at main's head.
set -euo pipefail

SITE_URL="${SITE_URL:-https://hafapass.shimizu-technology.com}"
API_URL="${API_URL:-https://hafapass-api.onrender.com}"
# Netlify needs a few minutes to build; don't flag a merge that just landed.
GRACE_SECONDS="${GRACE_SECONDS:-1800}"
failures=0

revision_from() {
  curl -fsS --max-time 20 "$1" | sed -n 's/.*"revision":"\([0-9a-f]\{40,64\}\)".*/\1/p'
}

check_component() {
  local name="$1" revision="$2"
  shift 2
  if [[ -z "$revision" ]]; then
    echo "::error::$name revision could not be read."
    failures=$((failures + 1))
    return
  fi
  if ! git cat-file -e "${revision}^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$revision" HEAD; then
    echo "::error::$name runs $revision, which is not on main."
    failures=$((failures + 1))
    return
  fi
  local pending
  pending="$(git log --format='%h %ct %s' "$revision..HEAD" -- "$@")"
  if [[ -z "$pending" ]]; then
    echo "$name is current ($revision)."
    return
  fi
  # Judge the oldest missing change: a fresh merge must not hide an older one
  # that was never deployed.
  local oldest_age=$(( $(date +%s) - $(echo "$pending" | tail -1 | cut -d' ' -f2) ))
  if (( oldest_age < GRACE_SECONDS )); then
    echo "$name has changes from the last $((oldest_age / 60)) minutes; not flagging yet."
    return
  fi
  echo "::error::$name runs $revision but main has undeployed changes to $*:"
  echo "$pending" | cut -d' ' -f1,3-
  failures=$((failures + 1))
}

# Tests and docs ship nowhere, so only runtime paths count as undeployed.
check_component "API" "$(revision_from "$API_URL/api/v1/health")" \
  hafapass_api ':!hafapass_api/spec' ':!hafapass_api/**/*.md'
check_component "Frontend" "$(revision_from "$SITE_URL/release.json")" \
  hafapass_frontend netlify.toml ':!hafapass_frontend/**/*.test.*' ':!hafapass_frontend/e2e*' ':!hafapass_frontend/**/*.md'


status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$API_URL/api/v1/readiness" || true)"
if [[ "$status" == "200" ]]; then
  echo "API readiness is 200."
else
  echo "::error::API readiness returned $status."
  failures=$((failures + 1))
fi

exit $(( failures > 0 ))
