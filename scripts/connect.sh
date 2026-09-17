#!/usr/bin/env bash
set -euo pipefail

SERVICE_ID="${1:-}"
REGION="${2:-frankfurt}"

if [ -z "$SERVICE_ID" ]; then
  echo "Uzycie: $0 <srv-xxxxx|srv-xxxxx-instancja> [region]"
  echo "Regiony: oregon | ohio | virginia | frankfurt | singapore"
  exit 1
fi

case "$REGION" in
  oregon|ohio|virginia|frankfurt|singapore) ;;
  *)
    echo "Nieznany region: $REGION"
    exit 1
    ;;
esac

exec ssh "${SERVICE_ID}@ssh.${REGION}.render.com"
