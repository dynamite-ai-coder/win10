#!/usr/bin/env bash
set -euo pipefail

KEY_PATH="${1:-$HOME/.ssh/id_ed25519}"

if [ -f "$KEY_PATH" ]; then
  echo "Klucz juz istnieje: $KEY_PATH"
else
  mkdir -p "$(dirname "$KEY_PATH")"
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "render-ssh-service"
  echo "Wygenerowano klucz: $KEY_PATH"
fi

echo
echo "Dodaj ponizszy klucz publiczny do Render:"
echo "  Dashboard -> Account Settings -> SSH Public Keys -> Add SSH Key"
echo
cat "${KEY_PATH}.pub"
