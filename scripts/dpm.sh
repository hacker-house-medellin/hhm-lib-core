#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
schema_file="$repo_dir/schema/schema.sql"

case "${1:-}" in
  bootstrap)
    shadow_url=${2:?usage: scripts/dpm.sh bootstrap <shadow-url> <output-file>}
    output_file=${3:?usage: scripts/dpm.sh bootstrap <shadow-url> <output-file>}
    exec dpm bootstrap --source-sql "$schema_file" --shadow "$shadow_url" --out "$output_file"
    ;;
  diff)
    target_url=${2:?usage: scripts/dpm.sh diff <target-url> <shadow-url> [output-file]}
    shadow_url=${3:?usage: scripts/dpm.sh diff <target-url> <shadow-url> [output-file]}
    output_file=${4:-}
    if [[ -n "$output_file" ]]; then
      exec dpm diff --source-sql "$schema_file" --target "$target_url" --shadow "$shadow_url" --out "$output_file"
    fi
    exec dpm diff --source-sql "$schema_file" --target "$target_url" --shadow "$shadow_url"
    ;;
  verify)
    target_url=${2:?usage: scripts/dpm.sh verify <target-url> <shadow-url>}
    shadow_url=${3:?usage: scripts/dpm.sh verify <target-url> <shadow-url>}
    exec dpm verify --source-sql "$schema_file" --target "$target_url" --shadow "$shadow_url"
    ;;
  *)
    echo "usage: scripts/dpm.sh {bootstrap <shadow> <out>|diff <target> <shadow> [out]|verify <target> <shadow>}" >&2
    exit 64
    ;;
esac
