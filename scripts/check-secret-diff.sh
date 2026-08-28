#!/usr/bin/env bash
set -euo pipefail

base="${1:-}"
if [[ -z "$base" ]]; then
  printf '%s\n' 'secret-diff: a trusted base commit is required' >&2
  exit 2
fi

if [[ "$base" =~ ^0+$ ]]; then
  while IFS= read -r root_commit; do
    base="$root_commit"
    break
  done < <(git rev-list --max-parents=0 HEAD)
fi

if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  printf '%s\n' 'secret-diff: base commit is unavailable' >&2
  exit 2
fi

pattern='(gh[pousr]_[A-Za-z0-9]{20,}|lin_api_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'
if grep -E -q "$pattern" < <(git diff --no-ext-diff --unified=0 "${base}...HEAD" --); then
  printf '%s\n' 'secret-diff: credential-shaped content detected' >&2
  exit 1
fi

printf '%s\n' 'secret-diff: no credential-shaped content detected'
