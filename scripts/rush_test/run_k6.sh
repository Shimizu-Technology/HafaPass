#!/usr/bin/env bash
# Runs load_tests/fd_championship_rush.js against the isolated copy, after preflight.
# Writes the k6 summary JSON and the start/end timestamps (UTC) next to each other, so
# collect_results.py can fill the results sheet and you can line up Render, Neon and Sentry graphs.
#
#   export HAFAPASS_RUSH_TARGET=rush-copy.onrender.com
#   export ISOLATED_LOAD_TARGET_ACK=I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT
#   export SCENARIO=paid_holds PROFILE=burst RUN_LABEL=paid-burst-1 \
#          ORG_SLUG=... PAID_EVENT_SLUG=... PAID_TICKET_TYPE_ID=... PAID_VUS=200   # values from seed_fixture.rb
#   scripts/rush_test/run_k6.sh
#
# SCENARIO: free_saturation | paid_holds | both.  PROFILE: burst (all VUs at once) | ramp.
# Output goes to ./rush-results/<RUN_LABEL>.summary.json (override with RESULTS_DIR). Nothing is run
# if preflight fails. k6 itself refuses production hosts, a missing acknowledgement and live payment mode.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

"$here/preflight.sh"

: "${ISOLATED_LOAD_TARGET_ACK:?set ISOLATED_LOAD_TARGET_ACK (see load_tests/README.md)}"
label="${RUN_LABEL:-run-$(date -u +%m%d-%H%M%S)}"
label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9_-' '_')"
results_dir="${RESULTS_DIR:-./rush-results}"
mkdir -p "$results_dir"
export BASE_URL="${BASE_URL:-https://$HAFAPASS_RUSH_TARGET}"
export SUMMARY_OUT="$results_dir/$label.summary.json"
# A summary left by an earlier run with this label must never be mistaken for this run's.
rm -f "$SUMMARY_OUT" "$results_dir/$label.times.json"
export SCENARIO="${SCENARIO:-paid_holds}"
export PROFILE="${PROFILE:-burst}"

k6_bin="${K6_BIN:-}"
if [[ -z "$k6_bin" ]]; then
  if command -v k6 >/dev/null 2>&1; then k6_bin="$(command -v k6)"; else k6_bin="$(mise exec k6@2.4.0 -- which k6)"; fi
fi

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "k6 start $started  scenario=$SCENARIO profile=$PROFILE label=$label target=$HAFAPASS_RUSH_TARGET"
status=0
"$k6_bin" run "$repo/load_tests/fd_championship_rush.js" || status=$?
ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"label":"%s","scenario":"%s","profile":"%s","started_utc":"%s","ended_utc":"%s","k6_exit_status":%s}\n' \
  "$label" "$SCENARIO" "$PROFILE" "$started" "$ended" "$status" > "$results_dir/$label.times.json"
echo "k6 end   $ended  exit=$status (summary: $SUMMARY_OUT)"
exit "$status"
