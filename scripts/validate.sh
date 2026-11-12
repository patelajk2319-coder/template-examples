#!/usr/bin/env bash
# terraform fmt/validate for every template directory, or just one.
# Usage: scripts/validate.sh [template-dir]
set -euo pipefail

TARGET="${1:-}"
dirs=()

if [[ -n "${TARGET}" ]]; then
  if [[ ! -d "${TARGET}" ]]; then
    echo "[error] no such template directory: ${TARGET}" >&2
    exit 1
  fi
  dirs=("${TARGET}")
else
  # A template directory is any top-level dir containing a main.tf — this
  # skips non-template dirs like scripts/.
  while IFS= read -r d; do
    dirs+=("$(basename "$(dirname "${d}")")")
  done < <(find . -maxdepth 2 -mindepth 2 -name main.tf)
fi

for d in "${dirs[@]}"; do
  echo "[validate] ${d}"
  terraform -chdir="${d}" init -backend=false -input=false >/dev/null
  terraform -chdir="${d}" fmt -check -diff
  terraform -chdir="${d}" validate
  rm -rf "${d}/.terraform" "${d}/.terraform.lock.hcl"
done
