#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

application_paths=(hafapass_api hafapass_frontend)
excluded_paths=(':(exclude)hafapass_frontend/package-lock.json')

if git grep -nIE '(sk_live_[A-Za-z0-9]{16,}|rk_live_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16})' -- "${application_paths[@]}" "${excluded_paths[@]}"; then
  echo "Potential production credential found in a tracked application file." >&2
  exit 1
fi

if git grep -nIE '(console\.log|debugger;?|binding\.pry|byebug)' -- "${application_paths[@]}" "${excluded_paths[@]}"; then
  echo "Debug statement found in a tracked application file." >&2
  exit 1
fi

echo "Tracked application files passed secret and debug hygiene checks."
