#!/usr/bin/env bash
# scripts/ha-setup.sh
# Home Assistant オンボーディングと Wyoming Integration を REST API で自動設定する。
# setup.sh から呼び出す（.env が source 済みであること）。
#
# 自動化する処理:
#   1. HA 管理者ユーザー作成 (/api/onboarding/users)
#   2. アクセストークン取得 (/auth/token)
#   3. オンボーディング完了マーク
#   4. Wyoming Integration 追加 × 3 (openWakeWord / Whisper / VOICEVOX)
#   5. Assist パイプライン作成 (ha-pipeline-setup.py)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[ha-setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

HA_URL="http://localhost:8123"
HA_USERNAME="${HA_USERNAME:-admin}"
HA_PASSWORD="${HA_PASSWORD:-}"
HA_DISPLAY_NAME="${HA_DISPLAY_NAME:-Admin}"

[[ -z "${HA_PASSWORD:-}" || "${HA_PASSWORD}" == "your-ha-password-here" ]] \
  && err "HA_PASSWORD is not set or is using the default value. Set a secure password in .env."

# ─── 1. HA 起動待ち ───────────────────────────────────
log "Waiting for Home Assistant to be ready..."
max_wait=300
elapsed=0
until curl -sf "${HA_URL}/" > /dev/null 2>&1; do
  sleep 5; elapsed=$((elapsed + 5)); printf "."
  [[ $elapsed -ge $max_wait ]] && echo "" && err "Home Assistant did not become ready within ${max_wait}s"
done
echo ""
log "Home Assistant is ready"

# ─── 2. オンボーディング: 管理者ユーザー作成 ────────────
log "Creating HA admin user (username: ${HA_USERNAME})..."
onboarding_response=$(curl -sf -X POST "${HA_URL}/api/onboarding/users" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"${HA_DISPLAY_NAME}\",
    \"username\": \"${HA_USERNAME}\",
    \"password\": \"${HA_PASSWORD}\",
    \"client_id\": \"${HA_URL}/\",
    \"language\": \"ja\"
  }") || err "Onboarding failed. If HA was already onboarded, skip ha-setup.sh and configure manually."

auth_code=$(echo "$onboarding_response" | jq -r '.auth_code')
[[ "$auth_code" == "null" || -z "$auth_code" ]] && err "Failed to get auth_code from onboarding response"

# ─── 3. auth_code → access_token ─────────────────────
log "Exchanging auth_code for access token..."
token_response=$(curl -sf -X POST "${HA_URL}/auth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code&code=${auth_code}&client_id=${HA_URL}/")

ACCESS_TOKEN=$(echo "$token_response" | jq -r '.access_token')
[[ "$ACCESS_TOKEN" == "null" || -z "$ACCESS_TOKEN" ]] && err "Failed to get access_token"

# ─── 4. オンボーディング残ステップを完了 ─────────────────
log "Completing onboarding steps..."

curl -sf -X POST "${HA_URL}/api/onboarding/core_config" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}' > /dev/null

curl -sf -X POST "${HA_URL}/api/onboarding/integration" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"client_id\": \"${HA_URL}/\", \"redirect_uri\": \"${HA_URL}/\"}" > /dev/null

# analytics は任意エンドポイントのため失敗しても続行
curl -sf -X POST "${HA_URL}/api/onboarding/analytics" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{}' > /dev/null 2>&1 || true

log "Onboarding complete"

# ─── 5. Wyoming サービスの起動待ち ───────────────────────
# Wyoming は HTTP ヘルスチェックを持たないため nc で確認
log "Waiting for Wyoming services..."
wait_tcp() {
  local port="$1" label="$2"
  local elapsed=0
  echo -n "  ${label} (TCP:${port})..."
  until nc -z localhost "$port" 2>/dev/null; do
    sleep 3; elapsed=$((elapsed + 3)); printf "."
    if [[ $elapsed -ge 120 ]]; then
      echo " TIMEOUT"
      warn "${label} did not become ready. Wyoming integration for port ${port} will be skipped."
      return 1
    fi
  done
  echo " OK"
  return 0
}

wyoming_10400_ready=false
wyoming_10300_ready=false
wyoming_10200_ready=false
wait_tcp 10400 "openWakeWord" && wyoming_10400_ready=true
wait_tcp 10300 "Whisper STT"  && wyoming_10300_ready=true
wait_tcp 10200 "VOICEVOX TTS" && wyoming_10200_ready=true

# ─── 6. Wyoming Integration 追加 ─────────────────────
add_wyoming_integration() {
  local name="$1"
  local port="$2"

  log "Adding Wyoming integration: ${name} (port ${port})..."

  # config flow 開始
  local flow_response flow_id
  flow_response=$(curl -sf -X POST "${HA_URL}/api/config/config_entries/flow" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"handler": "wyoming"}') || { warn "Failed to start config flow for ${name}"; return 1; }

  flow_id=$(echo "$flow_response" | jq -r '.flow_id')
  [[ "$flow_id" == "null" || -z "$flow_id" ]] && { warn "No flow_id for ${name}"; return 1; }

  # host / port を送信して Integration を確定
  local result result_type
  result=$(curl -sf -X POST "${HA_URL}/api/config/config_entries/flow/${flow_id}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"host\": \"127.0.0.1\", \"port\": ${port}}") || { warn "Failed to submit config for ${name}"; return 1; }

  result_type=$(echo "$result" | jq -r '.type // "unknown"')

  if [[ "$result_type" == "create_entry" ]]; then
    log "  ${name}: added successfully"
  else
    warn "  ${name}: unexpected result type '${result_type}'. Check HA logs for details."
  fi
}

[[ "$wyoming_10400_ready" == "true" ]] && add_wyoming_integration "openWakeWord" 10400
[[ "$wyoming_10300_ready" == "true" ]] && add_wyoming_integration "Whisper STT"  10300
[[ "$wyoming_10200_ready" == "true" ]] && add_wyoming_integration "VOICEVOX TTS" 10200

# ─── 7. Hermes Agent Integration 追加 ────────────
HERMES_URL="${HERMES_URL:-http://localhost:8642}"
log "Adding Hermes Agent integration (custom_component: hermes_agent)..."

hermes_flow=$(curl -sf -X POST "${HA_URL}/api/config/config_entries/flow" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"handler": "hermes_agent"}') || true

hermes_flow_id=$(echo "${hermes_flow:-}" | jq -r '.flow_id // empty' 2>/dev/null || true)

if [[ -n "$hermes_flow_id" ]]; then
  hermes_result=$(curl -sf -X POST "${HA_URL}/api/config/config_entries/flow/${hermes_flow_id}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"url\": \"${HERMES_URL}\", \"api_key\": \"${HERMES_API_KEY:-}\"}") || true
  hermes_type=$(echo "${hermes_result:-}" | jq -r '.type // "unknown"' 2>/dev/null || echo "unknown")
  if [[ "$hermes_type" == "create_entry" ]]; then
    log "  Hermes Agent integration added"
  else
    warn "  Hermes Agent config flow result: '${hermes_type}'"
    warn "  If failed: Settings → Integrations → Add → Hermes Agent"
    warn "  URL: ${HERMES_URL}  /  API Key: (HERMES_API_KEY)"
  fi
else
  warn "  hermes_agent handler not found — custom component may not be loaded"
  warn "  Ensure git submodule is initialized: git submodule update --init"
fi

# ─── 8. Assist パイプライン自動作成 ─────────────────────
log "Creating Assist pipeline via WebSocket API..."
HA_URL="${HA_URL}" \
WAKE_WORD="${WAKE_WORD:-ok_nabu}" \
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-ja}" \
TTS_VOICE="${TTS_VOICE:-ja_JP-voicevox}" \
  python3 "$(dirname "$0")/ha-pipeline-setup.py" "${ACCESS_TOKEN}" \
  && log "Assist pipeline created and set as preferred" \
  || warn "Assist pipeline auto-setup failed. Configure manually at ${HA_URL}/config/voice-assistants/pipelines"

# ─── 完了 ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}┌──────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│   Home Assistant automated setup complete!           │${NC}"
echo -e "${GREEN}└──────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  Open ${CYAN}http://localhost:8123${NC} to verify:"
echo -e "    Settings → Voice Assistants → ${YELLOW}rpi-voice-agent${NC} pipeline"
echo -e "    Wake Word : ${YELLOW}${WAKE_WORD:-ok_nabu}${NC} / STT : Faster Whisper / TTS : VOICEVOX"
echo -e ""
echo -e "  If pipeline auto-setup failed, configure manually:"
echo -e "  ${CYAN}http://localhost:8123/config/voice-assistants/pipelines${NC}"
echo ""
