#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"

echo "Running repository hygiene checks"
"$repository_root/scripts/check_hygiene.sh"

echo "Running backend tests, lint, and security scans"
(
  cd "$repository_root/hafapass_api"
  bundle exec rspec
  bundle exec rubocop
  bundle exec brakeman --no-pager --quiet
  bundle exec bundler-audit check --update
)

echo "Running frontend tests, lint, build, and production audit"
(
  cd "$repository_root/hafapass_frontend"
  npm test
  npm run lint
  npm run build
  npm run audit:prod
)

if [[ "${SKIP_E2E:-0}" != "1" ]]; then
  echo "Running browser smoke tests"
  (
    cd "$repository_root/hafapass_frontend"
    npm run test:e2e
  )
fi

echo "All HåfaPass quality gates passed."
