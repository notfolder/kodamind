#!/usr/bin/env bash
# rpi-voice-agent / scripts/update.sh
# 全サービスのイメージを更新して再起動するスクリプト
#
# 使い方: bash scripts/update.sh

set -euo pipefail

echo "=== Pulling latest images ==="
docker compose pull

echo "=== Restarting services ==="
docker compose up -d --remove-orphans

echo "=== Pruning old images ==="
docker image prune -f

echo "=== Done. Current status ==="
docker compose ps
