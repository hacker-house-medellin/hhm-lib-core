#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TLA_VERSION="1.7.4"
TLA_SHA1="bee4a54f3ee3d4afc347c3240ec2d9e93b075104"
TLA_SHA256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
TLA_URL="https://github.com/tlaplus/tlaplus/releases/download/v${TLA_VERSION}/tla2tools.jar"
MODEL="AdminActionQueue"
MODEL_DIR="formal/admin-action-queue"
EVIDENCE_DIR="target/formal-admin-action"

fail() {
  printf 'formal-admin-action: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$EVIDENCE_DIR"

while IFS=$'\t' read -r path expected scope; do
  [[ -z "$path" || "$path" == \#* ]] && continue
  [[ -n "$expected" && -n "$scope" ]] || fail "malformed source binding for $path"
  [[ -f "$path" ]] || fail "bound source is missing: $path"
  actual="$(git hash-object -- "$path")"
  [[ "$actual" == "$expected" ]] ||
    fail "stale model for $path: expected blob $expected, found $actual; update model and binding together"
done < "$MODEL_DIR/source-blobs.tsv"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$MODEL_DIR/$MODEL.tla" "$MODEL_DIR/$MODEL.cfg" "$work/"

if [[ -n "${TLA_TOOLS_JAR:-}" ]]; then
  [[ -f "$TLA_TOOLS_JAR" ]] || fail "TLA_TOOLS_JAR does not name a file"
  cp "$TLA_TOOLS_JAR" "$work/tla2tools.jar"
else
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    --output "$work/tla2tools.jar" "$TLA_URL"
fi
printf '%s  %s\n' "$TLA_SHA1" "$work/tla2tools.jar" | sha1sum --check
printf '%s  %s\n' "$TLA_SHA256" "$work/tla2tools.jar" | sha256sum --check

(
  cd "$work"
  java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC \
    -workers 1 \
    -config "$MODEL.cfg" \
    "$MODEL.tla"
) 2>&1 | tee "$EVIDENCE_DIR/$MODEL.log"

source_commit="$(git rev-parse HEAD)"
model_sha256="$(sha256sum "$MODEL_DIR/$MODEL.tla" | awk '{print $1}')"
config_sha256="$(sha256sum "$MODEL_DIR/$MODEL.cfg" | awk '{print $1}')"
log_sha256="$(sha256sum "$EVIDENCE_DIR/$MODEL.log" | awk '{print $1}')"
cat > "$EVIDENCE_DIR/receipt.json" <<EOF
{
  "schema": "hhm.admin-action-formal-evidence.v1",
  "sourceCommit": "$source_commit",
  "tlaToolsVersion": "$TLA_VERSION",
  "tlaToolsSha256": "$TLA_SHA256",
  "modelSha256": "$model_sha256",
  "configSha256": "$config_sha256",
  "logSha256": "$log_sha256",
  "status": "passed"
}
EOF

printf 'formal-admin-action: model passed; receipt=%s\n' "$EVIDENCE_DIR/receipt.json"
