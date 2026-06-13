#!/usr/bin/env bash
# rpi-voice-agent / setup.sh
# =============================================================
# Raspberry Pi 5 (Raspberry Pi OS Bookworm 64-bit) 向け
# ゼロから全コンポーネントを自動セットアップするスクリプト
#
# 使い方:
#   git clone https://github.com/YOUR_USER/rpi-voice-agent.git
#   cd rpi-voice-agent
#   cp .env.example .env        # ← 認証情報を編集
#   bash setup.sh               # Raspberry Pi 5
#   bash setup.sh --mac         # Mac (Apple Silicon) 開発検証
# =============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# .env の変数を追記または上書きする（BSD sed / GNU sed 両対応）
set_env_var() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${val}|" .env
    rm -f .env.bak
  else
    echo "${key}=${val}" >> .env
  fi
}

# ─── オプション解析 ────────────────────────────
MAC_MODE=false
for arg in "$@"; do
  case "$arg" in
    --mac) MAC_MODE=true ;;
    -h|--help)
      echo "Usage: bash setup.sh [--mac]"
      echo "  --mac   Mac (Apple Silicon) 開発検証モード（PulseAudio TCP 音声）"
      exit 0
      ;;
  esac
done

# ─── 前提チェック ─────────────────────────────
step "Checking prerequisites"

if [[ "$MAC_MODE" == "false" ]]; then
  [[ "$(uname -m)" == "aarch64" ]] || err "This script is for arm64 (Raspberry Pi 5). Current arch: $(uname -m). Use --mac for macOS."
fi

[[ -f ".env" ]]                  || err ".env file not found. Run: cp .env.example .env  and fill in the values."

source .env

[[ -z "${HERMES_API_KEY:-}" || "${HERMES_API_KEY}" == "your-strong-api-key-here" ]] \
  && err "HERMES_API_KEY is not set in .env. Generate one with: openssl rand -hex 32"

[[ -z "${HA_PASSWORD:-}" || "${HA_PASSWORD}" == "your-ha-password-here" ]] \
  && err "HA_PASSWORD is not set in .env. Set a secure password for the HA admin account."

log "Prerequisites OK"

# ─── 1. システムパッケージ更新 (Pi のみ) ──────────
if [[ "$MAC_MODE" == "false" ]]; then
  step "Updating system packages"
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    curl \
    git \
    ca-certificates \
    gnupg \
    lsb-release \
    netcat-openbsd \
    avahi-daemon \
    jq
else
  step "Checking macOS prerequisites"
  command -v docker &>/dev/null \
    || err "Docker Desktop not found. Install from https://www.docker.com/products/docker-desktop/"
  docker compose version &>/dev/null \
    || err "docker compose plugin not found. Update Docker Desktop."
  log "Docker: $(docker --version)"
fi

# ─── 2. Docker インストール (Pi のみ) ─────────────
if [[ "$MAC_MODE" == "false" ]]; then
  step "Installing Docker"
  if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
  else
    log "Installing Docker via official script..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER"
    warn "Docker group added. You may need to log out and back in."
    warn "If docker commands fail, run: newgrp docker"
  fi

  if ! docker compose version &>/dev/null; then
    log "Installing docker-compose-plugin..."
    sudo apt-get install -y -qq docker-compose-plugin
  fi
  log "Docker Compose: $(docker compose version --short)"
fi

# ─── 3. 音声デバイス確認 ────────────────────────
step "Checking audio"
if [[ "$MAC_MODE" == "false" ]]; then
  if aplay -l 2>/dev/null | grep -q "card"; then
    log "Audio output device found:"
    aplay -l 2>/dev/null | grep "^card" | head -5
  else
    warn "No audio output device found. TTS playback will not work without a speaker."
  fi
  if arecord -l 2>/dev/null | grep -q "card"; then
    log "Audio input (microphone) found:"
    arecord -l 2>/dev/null | grep "^card" | head -5
  else
    warn "No microphone found. Wake word detection requires a USB microphone."
  fi
else
  if ! command -v pulseaudio &>/dev/null; then
    warn "PulseAudio not found. Install: brew install pulseaudio"
    warn "PulseAudio is required for microphone/speaker access on macOS."
  elif ! pulseaudio --check 2>/dev/null; then
    log "Starting PulseAudio with TCP module..."
    pulseaudio \
      --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1;172.16.0.0/12 auth-anonymous=1" \
      --exit-idle-time=-1 \
      --daemon
    log "PulseAudio started (TCP port 4713)"
  else
    log "PulseAudio is already running"
  fi

  # Mac 固有設定を .env に書き込む（docker compose が自動で読む）
  DBUS_DIR="${HOME}/.rpi-voice-agent/dbus"
  mkdir -p "${DBUS_DIR}"
  set_env_var "DBUS_RUN_DIR" "${DBUS_DIR}"
  set_env_var "PULSE_SERVER" "tcp:host.docker.internal:4713"
  log "Mac settings written to .env (PULSE_SERVER, DBUS_RUN_DIR)"

  # PulseAudio のデフォルト入力ソースをマイクに設定
  # .env の PULSE_MIC_SOURCE が設定されていればそれを使用、未設定なら自動検出
  log "Setting PulseAudio default source to microphone..."
  if [[ -n "${PULSE_MIC_SOURCE:-}" ]]; then
    MIC_SOURCE="${PULSE_MIC_SOURCE}"
    log "  Using PULSE_MIC_SOURCE from .env: ${MIC_SOURCE}"
  else
    MIC_SOURCE=$(pactl list sources 2>/dev/null \
      | grep -B1 'Description:.*[Mm]ic\|Description:.*マイク' \
      | grep 'Name:' | head -1 | awk '{print $2}')
    [[ -n "$MIC_SOURCE" ]] && log "  Auto-detected: ${MIC_SOURCE}" \
      || warn "  Microphone not found. Set PULSE_MIC_SOURCE in .env manually."
    warn "  Tip: run 'pactl list sources short' to see available sources"
    warn "  Then set PULSE_MIC_SOURCE=<name> in .env"
  fi
  if [[ -n "$MIC_SOURCE" ]]; then
    pactl set-default-source "$MIC_SOURCE" 2>/dev/null && \
      log "  Default source set: ${MIC_SOURCE}" || \
      warn "  Could not set default source"
  fi

  # PulseAudio のデフォルト出力シンクをスピーカーに設定
  log "Setting PulseAudio default sink to speaker..."
  if [[ -n "${PULSE_SINK:-}" ]]; then
    SINK_NAME="${PULSE_SINK}"
    log "  Using PULSE_SINK from .env: ${SINK_NAME}"
  else
    SINK_NAME=$(pactl list sinks 2>/dev/null \
      | grep -B1 'Description:.*[Ss]peaker\|Description:.*スピーカー' \
      | grep 'Name:' | head -1 | awk '{print $2}')
    [[ -n "$SINK_NAME" ]] && log "  Auto-detected: ${SINK_NAME}" \
      || warn "  Speaker not found. Set PULSE_SINK in .env manually."
    warn "  Tip: run 'pactl list sinks short' to see available sinks"
  fi
  if [[ -n "$SINK_NAME" ]]; then
    pactl set-default-sink "$SINK_NAME" 2>/dev/null && \
      log "  Default sink set: ${SINK_NAME}" || \
      warn "  Could not set default sink"
  fi
fi

# ─── 4. HA 設定ファイルを初期化 ─────────────────
step "Initializing Home Assistant config"
mkdir -p config/homeassistant

if [[ ! -f config/homeassistant/configuration.yaml ]]; then
  log "Creating initial configuration.yaml..."
  cat > config/homeassistant/configuration.yaml << 'HACFG'
# Home Assistant Core configuration
# Generated by rpi-voice-agent setup.sh

homeassistant:
  name: "RPi Voice Agent"
  latitude: 35.6762
  longitude: 139.6503
  elevation: 0
  unit_system: metric
  currency: JPY
  country: JP
  language: ja
  time_zone: Asia/Tokyo

# 基本コンポーネント
default_config:

# ロギング
logger:
  default: warning
  logs:
    homeassistant.components.wyoming: info
    homeassistant.components.assist_pipeline: info
HACFG
  log "configuration.yaml created"
else
  log "configuration.yaml already exists, skipping"
fi

# ─── 5. openWakeWord カスタムモデルディレクトリ ──
step "Setting up openWakeWord directories"
mkdir -p config/openwakeword/custom_models
log "Custom wake word models directory: config/openwakeword/custom_models/"
log "Place .tflite model files here to use custom wake words."

# ─── 6. Hermes 設定ディレクトリ ─────────────────
step "Setting up Hermes config directory"
mkdir -p config/hermes

# ─── 7. git submodule 初期化（custom_components） ─
step "Initializing git submodules"
if git -C "$(dirname "$0")" rev-parse --is-inside-work-tree 2>/dev/null; then
  git -C "$(dirname "$0")" submodule update --init --recursive
  log "Submodules initialized (Hermes HA integration custom component)"
else
  warn "Not a git repository — submodules skipped."
  warn "Clone with: git clone --recurse-submodules <repo-url>"
fi

# ─── 8. setup コンテナイメージをビルド ───────────
step "Building container images"
if [[ "$MAC_MODE" == "true" ]]; then
  docker compose --profile mac build setup wyoming-satellite
else
  docker compose build setup
fi

# ─── 9. Docker イメージを事前取得 ───────────────
step "Pulling Docker images (this may take several minutes on Pi 5)"
docker compose pull

# ─── 10. スタック起動 ───────────────────────────
step "Starting all services"
if [[ "$MAC_MODE" == "true" ]]; then
  docker compose --profile mac up -d
else
  docker compose up -d
fi

log "Waiting for services to start..."
sleep 15

# ─── 11. ヘルスチェック ─────────────────────────
step "Health checks"
check_service() {
  local name="$1"
  local url="$2"
  local max_wait="${3:-120}"
  local elapsed=0
  local interval=5

  echo -n "  Waiting for ${name}..."
  while ! curl -sf "$url" > /dev/null 2>&1; do
    sleep $interval
    elapsed=$((elapsed + interval))
    echo -n "."
    if [[ $elapsed -ge $max_wait ]]; then
      echo " TIMEOUT"
      warn "${name} did not respond within ${max_wait}s. Check: docker compose logs ${name}"
      return 1
    fi
  done
  echo " OK (${elapsed}s)"
}

check_service "ollama"        "http://localhost:11434/api/tags"  120
check_service "homeassistant" "http://localhost:8123/"           180
check_service "hermes"        "http://localhost:8642/health"     120

# openwakeword は HTTP エンドポイントがないので nc で確認
echo -n "  Waiting for openwakeword (TCP:10400)..."
elapsed=0
while ! nc -z localhost 10400 2>/dev/null; do
  sleep 5; elapsed=$((elapsed + 5)); echo -n "."
  [[ $elapsed -ge 60 ]] && { echo " TIMEOUT"; break; }
done
[[ $elapsed -lt 60 ]] && echo " OK" || warn "openwakeword may not be ready"

# ─── 12. setup コンテナ完了待ち ──────────────────
step "Waiting for initialization container to complete"
log "To monitor: docker compose logs -f setup"
elapsed=0
until docker inspect setup --format='{{.State.Status}}' 2>/dev/null | grep -q "exited"; do
  sleep 5; elapsed=$((elapsed + 5)); printf "."
  if [[ $elapsed -ge 600 ]]; then
    echo ""
    warn "Initialization timed out after 600s. Check: docker compose logs setup"
    break
  fi
done
echo ""
setup_exit=$(docker inspect setup --format='{{.State.ExitCode}}' 2>/dev/null || echo "1")
if [[ "$setup_exit" == "0" ]]; then
  log "Initialization complete"
else
  warn "Initialization failed (exit: ${setup_exit}). Check: docker compose logs setup"
fi

# ─── 13. 完了メッセージ ─────────────────────────
if [[ "$MAC_MODE" == "false" ]]; then
  HOST_IP=$(hostname -I | awk '{print $1}')
else
  HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "localhost")
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          rpi-voice-agent setup complete!             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Home Assistant  → ${CYAN}http://${HOST_IP}:8123${NC}"
echo -e "  Ollama API      → ${CYAN}http://${HOST_IP}:11434${NC}"
echo -e "  Hermes Agent    → ${CYAN}http://${HOST_IP}:8642${NC}"
echo -e "  Wake Word       → ${YELLOW}${WAKE_WORD:-ok_nabu}${NC} (TCP port 10400)"
echo ""
echo -e "  Verify: Settings → Voice Assistants → ${YELLOW}rpi-voice-agent${NC} pipeline"
echo -e "  Fallback: ${CYAN}http://${HOST_IP}:8123/config/voice-assistants/pipelines${NC}"
echo ""
echo -e "  Useful commands:"
echo -e "  ${CYAN}docker compose logs -f${NC}               # tail all logs"
echo -e "  ${CYAN}docker compose logs -f setup${NC}         # tail setup container"
echo -e "  ${CYAN}docker compose logs -f hermes${NC}        # tail Hermes only"
echo -e "  ${CYAN}docker compose restart hermes${NC}        # restart Hermes"
echo -e "  ${CYAN}bash pull-model.sh qwen2.5:3b${NC}        # pull a model"
echo ""
