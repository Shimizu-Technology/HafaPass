#!/usr/bin/env bash
# Preflight for the hosted rush test. Read-only: a handful of GETs against the isolated copy.
# Refuses production hosts and live payment mode; requires HAFAPASS_RUSH_TARGET (the exact
# host you intend to load) to match BASE_URL. Run it from the machine that will run k6.
#
#   HAFAPASS_RUSH_TARGET=rush-copy.onrender.com scripts/rush_test/preflight.sh
#
# Optional: BASE_URL (default https://$HAFAPASS_RUSH_TARGET; use http://localhost:3108 with
# FORWARDED_PROTO=https for a local server), EXPECTED_REVISION (commit the copy must run),
# EVENT_SLUG / PAID_EVENT_SLUG (fixture events to look up), READINESS_TOKEN (detail), K6_BIN.
set -uo pipefail

fail=0
ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }
info() { printf 'info  %s\n' "$*"; }

target="${HAFAPASS_RUSH_TARGET:-}"
if [[ -z "$target" ]]; then
  echo "FAIL  HAFAPASS_RUSH_TARGET is not set. Set it to the isolated API's exact host, e.g. rush-copy.onrender.com" >&2
  exit 2
fi
if [[ "$target" == *"://"* || "$target" == */* ]]; then
  echo "FAIL  HAFAPASS_RUSH_TARGET must be a bare host (no scheme, path or port-less URL): got '$target'" >&2
  exit 2
fi
target="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')"
base_url="${BASE_URL:-https://$target}"
base_url="${base_url%/}"
host="$(printf '%s' "$base_url" | sed -E 's#^https?://([^/?#]*@)?([^/?#:]+).*#\2#' | sed 's/\.*$//' | tr '[:upper:]' '[:lower:]')"

is_production_host() {
  local h="$1" extra
  case "$h" in
    hafapass-api.onrender.com|hafapass.netlify.app) return 0 ;;
    *.hafapass.com|hafapass.com|*.shimizu-technology.com|shimizu-technology.com) return 0 ;;
  esac
  IFS=',' read -r -a extra <<< "${HAFAPASS_PRODUCTION_HOSTS:-}"
  for item in "${extra[@]:-}"; do
    [[ -n "$item" && "$h" == "$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]' | xargs)" ]] && return 0
  done
  return 1
}

if is_production_host "$host" || is_production_host "$target"; then
  echo "FAIL  '$host' is a production host. This test only runs against an isolated copy." >&2
  exit 2
fi
if [[ "$host" != "$target" ]]; then
  echo "FAIL  HAFAPASS_RUSH_TARGET '$target' does not match the BASE_URL host '$host'." >&2
  exit 2
fi
ok "target $host is not a production host and matches HAFAPASS_RUSH_TARGET"

curl_args=(-sS --max-time 20)
if [[ "${FORWARDED_PROTO:-}" == "https" ]]; then curl_args+=(-H "X-Forwarded-Proto: https"); fi

code="$(curl "${curl_args[@]}" -o /dev/null -w '%{http_code}' "$base_url/up" 2>/dev/null || true)"
[[ "$code" == "200" ]] && ok "/up returns 200" || bad "/up returned '$code'"

health="$(curl "${curl_args[@]}" "$base_url/api/v1/health" 2>/dev/null || true)"
revision="$(printf '%s' "$health" | python3 -c 'import json,sys
try: print((json.load(sys.stdin).get("revision") or ""))
except Exception: print("")')"
if [[ -n "$revision" ]]; then
  ok "revision is ${revision:0:12}"
  if [[ -n "${EXPECTED_REVISION:-}" && "${revision:0:${#EXPECTED_REVISION}}" != "$EXPECTED_REVISION" ]]; then
    bad "revision ${revision:0:12} is not the expected ${EXPECTED_REVISION}"
  fi
else
  bad "/api/v1/health returned no revision"
fi

config="$(curl "${curl_args[@]}" "$base_url/api/v1/config" 2>/dev/null || true)"
read -r payment_mode environment <<<"$(printf '%s' "$config" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); print(d.get("payment_mode","?"), d.get("environment","?"))
except Exception: print("? ?")')"
case "$payment_mode" in
  simulate|test) ok "payment_mode is $payment_mode (not live)" ;;
  live) bad "payment_mode is LIVE. Never load a live environment." ;;
  *) bad "could not read payment_mode from /api/v1/config" ;;
esac
[[ "$environment" == "staging" ]] && ok "environment is staging (StageSafety applies)" || bad "environment is '$environment'; the isolated copy must run RAILS_ENV=staging"

ready="$(curl "${curl_args[@]}" -o /dev/null -w '%{http_code}' "$base_url/api/v1/readiness" 2>/dev/null || true)"
[[ "$ready" == "200" ]] && ok "readiness returns 200 (queue actors and recent ticks are healthy)" || bad "readiness returned '$ready'"
if [[ -n "${READINESS_TOKEN:-}" ]]; then
  detail="$(curl "${curl_args[@]}" -H "X-Readiness-Token: $READINESS_TOKEN" "$base_url/api/v1/readiness" 2>/dev/null || true)"
  info "readiness detail: $(printf '%s' "$detail" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); print("status=%s keys=%s" % (d.get("status"), ",".join(sorted(k for k in d if k not in ("status","timestamp")))[:140]))
except Exception: print("unreadable")')"
fi

for var in EVENT_SLUG PAID_EVENT_SLUG; do
  slug="${!var:-}"
  [[ -z "$slug" ]] && continue
  title="$(curl "${curl_args[@]}" "$base_url/api/v1/events/$slug" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("title",""))
except Exception: print("")')"
  [[ "$title" == "[LOAD TEST]"* ]] && ok "$var fixture found: $title" || bad "$var '$slug' is missing or not a [LOAD TEST] event (title '$title')"
done

k6_bin="${K6_BIN:-}"
if [[ -z "$k6_bin" ]]; then
  if command -v k6 >/dev/null 2>&1; then k6_bin="$(command -v k6)"
  elif command -v mise >/dev/null 2>&1 && k6_bin="$(mise exec k6@2.4.0 -- which k6 2>/dev/null)" && [[ -n "$k6_bin" ]]; then :
  else k6_bin=""; fi
fi
if [[ -n "$k6_bin" ]]; then ok "k6 found: $("$k6_bin" version 2>/dev/null | head -1)"; else bad "k6 not found (brew install k6)"; fi
[[ "${ISOLATED_LOAD_TARGET_ACK:-}" == "I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT" ]] \
  && ok "ISOLATED_LOAD_TARGET_ACK is set" || info "ISOLATED_LOAD_TARGET_ACK is not set yet (run_k6.sh will require it)"

load="$(uptime | sed -E 's/.*load averages?: ([0-9.]+).*/\1/')"
info "this machine's 1-minute load average is $load (a busy laptop skews k6 timings; close heavy apps)"

if [[ "$fail" -ne 0 ]]; then echo; echo "Preflight FAILED. Do not start the load."; exit 1; fi
echo; echo "Preflight passed for $host."
