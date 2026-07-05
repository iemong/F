#!/usr/bin/env bash
# CI署名・公証用の GitHub Secrets を一括登録する。
# 詳細: docs/RUNBOOK-signing.md
set -euo pipefail

P12="" P12_PW="" P8="" KEY_ID="" ISSUER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --p12) P12="$2"; shift 2 ;;
    --p12-password) P12_PW="$2"; shift 2 ;;
    --p8) P8="$2"; shift 2 ;;
    --key-id) KEY_ID="$2"; shift 2 ;;
    --issuer) ISSUER="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 1 ;;
  esac
done

fail=0
for v in P12 P12_PW P8 KEY_ID ISSUER; do
  if [ -z "${!v}" ]; then echo "必須: --${v}" >&2; fail=1; fi
done
[ "$fail" = 0 ] || { echo "使い方は docs/RUNBOOK-signing.md を参照" >&2; exit 1; }
[ -f "$P12" ] || { echo ".p12 が見つからない: $P12" >&2; exit 1; }
[ -f "$P8" ] || { echo ".p8 が見つからない: $P8" >&2; exit 1; }

echo "→ DEVELOPER_ID_CERT_P12"
base64 -i "$P12" | gh secret set DEVELOPER_ID_CERT_P12
echo "→ DEVELOPER_ID_CERT_PASSWORD"
printf '%s' "$P12_PW" | gh secret set DEVELOPER_ID_CERT_PASSWORD
echo "→ ASC_KEY_ID"
printf '%s' "$KEY_ID" | gh secret set ASC_KEY_ID
echo "→ ASC_ISSUER_ID"
printf '%s' "$ISSUER" | gh secret set ASC_ISSUER_ID
echo "→ ASC_KEY_P8"
base64 -i "$P8" | gh secret set ASC_KEY_P8

echo "完了。登録済みSecrets:"
gh secret list
