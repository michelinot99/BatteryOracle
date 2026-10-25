#!/bin/zsh
# Installs the Mistral Timestral forecasting engine in a private virtualenv:
#   ~/Library/Application Support/BatteryOracle/engine
# Usage: setup-engine.sh [huggingface-model-id]
set -euo pipefail

MODEL="${1:-mistralai/Timestral-5M}"
ENGINE="$HOME/Library/Application Support/BatteryOracle/engine"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# PyTorch wheels lag behind the newest Python, so prefer 3.13 → 3.10.
PY=""
for v in 3.13 3.12 3.11 3.10; do
  if command -v "python$v" >/dev/null 2>&1; then PY="$(command -v "python$v")"; break; fi
done
if [[ -z "$PY" ]]; then
  echo "Serve Python 3.10–3.13. Installalo con: brew install python@3.13" >&2
  exit 1
fi

echo "Uso $("$PY" --version) da $PY"
if [[ ! -x "$ENGINE/bin/python" ]]; then
  echo "Creo l'ambiente in $ENGINE"
  mkdir -p "$(dirname "$ENGINE")"
  "$PY" -m venv "$ENGINE"
fi

echo "Installo PyTorch e Timestral (qualche minuto la prima volta)…"
"$ENGINE/bin/python" -m pip install --quiet --upgrade pip
"$ENGINE/bin/python" -m pip install --progress-bar off --quiet torch numpy safetensors huggingface_hub
"$ENGINE/bin/python" -m pip install --progress-bar off --quiet "git+https://github.com/mistralai/timestral.git"

echo "Scarico i pesi di $MODEL…"
HF_HUB_DISABLE_TELEMETRY=1 "$ENGINE/bin/python" -I -c "
import sys
from timestral import TimestralForecaster
TimestralForecaster.from_pretrained(sys.argv[1])
" "$MODEL"

echo "Motore pronto ✓"
