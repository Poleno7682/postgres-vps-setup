#!/usr/bin/env bash
# Regenerates docs/screenshots/*.svg from the real UI code of pg_server_setup.sh
# (sample data, no server needed). Requires bash and python3.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/docs/screenshots"
mkdir -p "$OUT"
PY="${PYTHON:-$(command -v python3 || command -v python)}"

for lang in ru en; do
  for screen in menu setup resume network creds; do
    bash "$ROOT/tools/demo_screens.sh" "$lang" "$screen" 2>&1 \
      | "$PY" "$ROOT/tools/ansi2svg.py" "$OUT/${screen}.${lang}.svg" --title "root@pg-server-01: ~ (pg_server_setup.sh)"
    echo "wrote docs/screenshots/${screen}.${lang}.svg"
  done
done
