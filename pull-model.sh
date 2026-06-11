#!/usr/bin/env bash
# rpi-voice-agent / scripts/pull-model.sh
# Ollama にモデルをプルするヘルパー
#
# 使い方:
#   bash scripts/pull-model.sh qwen2.5:3b
#   bash scripts/pull-model.sh llama3.2:3b

set -euo pipefail

MODEL="${1:-}"
[[ -z "$MODEL" ]] && { echo "Usage: $0 <model-name>  (e.g. qwen2.5:3b)"; exit 1; }

echo "Pulling model: ${MODEL}"
docker compose exec ollama ollama pull "$MODEL"
echo "Done. Current models:"
docker compose exec ollama ollama list
