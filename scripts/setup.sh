#!/usr/bin/env bash
# One-time local wiring for a Nearby Share checkout.
#
# core.hooksPath is local config, not something a clone carries, so this has to
# run once per machine. Idempotent: safe to re-run after every update.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if [[ -d .git ]]; then
  git config core.hooksPath .githooks
  echo "Hooks enabled: dependencies install on pull."
else
  echo "Not a git checkout; skipped hook wiring." >&2
fi

chmod +x .githooks/* scripts/*.sh 2>/dev/null || true

if ! ./scripts/dependencies.sh --check >/dev/null; then
  echo
  ./scripts/dependencies.sh --install
fi
