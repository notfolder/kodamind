#!/usr/bin/env bash
# clean.sh — 環境をゼロからリセットして setup.sh を再実行できる状態にする。
#
# 使い方:
#   bash clean.sh          # ソフトクリーン（Ollama モデルを保持）
#   bash clean.sh --full   # フルクリーン（Ollama モデルも削除）

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FULL=false
[[ "${1:-}" == "--full" ]] && FULL=true

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  rpi-voice-agent 環境リセット${NC}"
if $FULL; then
  echo -e "${RED}  モード: フルクリーン（Ollama モデルも削除）${NC}"
else
  echo -e "${CYAN}  モード: ソフトクリーン（Ollama モデルを保持）${NC}"
fi
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ─── 1. 全コンテナ停止・削除 ──────────────────────────
echo "Stopping and removing all containers..."
docker compose down --remove-orphans 2>/dev/null || true

# ─── 2. Docker ボリューム削除 ─────────────────────────
echo "Removing Docker volumes..."

# Whisper モデル（数十 MB、再ダウンロード約 30 秒）
docker volume rm rpi-voice-agent_whisper_data 2>/dev/null && echo "  whisper_data removed" || true

# Hermes データ（設定・記憶・セッション）
docker volume rm rpi-voice-agent_hermes_data 2>/dev/null && echo "  hermes_data removed" || true

if $FULL; then
  # Ollama モデル（数 GB、再ダウンロードに 10 分以上かかる場合あり）
  docker volume rm rpi-voice-agent_ollama_data 2>/dev/null && echo "  ollama_data removed" || true
else
  echo "  ollama_data kept (use --full to also remove)"
fi

# ─── 3. HA 設定・ストレージをリセット ─────────────────
echo "Resetting Home Assistant state..."
HA_DIR="$(dirname "$0")/config/homeassistant"

rm -rf "${HA_DIR}/.storage"
rm -f  "${HA_DIR}/home-assistant.log"
rm -f  "${HA_DIR}/home-assistant.log.1"
rm -f  "${HA_DIR}/home-assistant_v2.db"
rm -f  "${HA_DIR}/home-assistant_v2.db-shm"
rm -f  "${HA_DIR}/home-assistant_v2.db-wal"
rm -f  "${HA_DIR}/.HA_VERSION"
rm -f  "${HA_DIR}/.ha_run.lock"
echo "  Home Assistant storage cleared"

# ─── 4. wyoming-voicevox イメージ再ビルドフラグ ────────
echo "Removing cached wyoming-voicevox image..."
docker rmi rpi-voice-agent-wyoming-voicevox 2>/dev/null && echo "  wyoming-voicevox image removed" || true
docker rmi rpi-voice-agent-setup 2>/dev/null && echo "  setup image removed" || true

# ─── 完了 ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  クリーン完了！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  次のコマンドで再セットアップ:"
echo -e "    ${CYAN}bash setup.sh --mac${NC}    # Mac (Apple Silicon)"
echo -e "    ${CYAN}bash setup.sh${NC}          # Raspberry Pi 5"
echo ""
