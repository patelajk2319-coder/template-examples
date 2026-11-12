#!/usr/bin/env bash
# Pushes one template directory to Coder via `coder templates push`.
# Usage: scripts/push.sh <template-dir> [vars-file]
set -euo pipefail

TEMPLATE="${1:?Usage: scripts/push.sh <template-dir> [vars-file]}"
VARS_FILE="${2:-}"

if [[ ! -d "${TEMPLATE}" ]]; then
  echo "[error] no such template directory: ${TEMPLATE}" >&2
  exit 1
fi

cmd=(coder templates push "${TEMPLATE}" -d "./${TEMPLATE}" --yes)
if [[ -n "${VARS_FILE}" ]]; then
  cmd+=(--variables-file "${VARS_FILE}")
fi

echo "[push] ${cmd[*]}"
"${cmd[@]}"
