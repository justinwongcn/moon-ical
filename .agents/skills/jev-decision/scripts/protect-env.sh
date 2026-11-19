#!/usr/bin/env bash
# Lock down .env so only the current Windows user can access it.
# Run once after writing the real API key:  bash scripts/protect-env.sh
# To edit .env again, restore first:        icacls .env /reset   (then re-run this script)
# Note: MSYS_NO_PATHCONV=1 stops Git Bash from rewriting icacls's /switch arguments into paths.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo ".env not found" >&2
  exit 1
fi

# Prefer Windows USERNAME; Git Bash's whoami may return an MSYS-style name icacls cannot resolve.
user="${USERNAME:-$(whoami)}"
MSYS_NO_PATHCONV=1 icacls .env /inheritance:r
MSYS_NO_PATHCONV=1 icacls .env /remove "NT AUTHORITY\\SYSTEM" "BUILTIN\\Administrators"
MSYS_NO_PATHCONV=1 icacls .env /grant:r "${user}:F"
echo ".env locked down: only ${user} can access it."
