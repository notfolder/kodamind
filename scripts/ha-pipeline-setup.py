#!/usr/bin/env python3
"""
ha-pipeline-setup.py
Home Assistant Assist パイプラインを WebSocket API で自動作成する。
外部ライブラリ不要（Python3 stdlib のみ）。

使い方: python3 ha-pipeline-setup.py <access_token>
環境変数: HA_URL, WAKE_WORD, WHISPER_LANGUAGE, PIPER_VOICE
"""

import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.request
import urllib.error

# ─── 設定 ─────────────────────────────────────────────────────────────
HA_URL        = os.environ.get("HA_URL", "http://localhost:8123")
WAKE_WORD     = os.environ.get("WAKE_WORD", "ok_nabu")
WHISPER_LANG  = os.environ.get("WHISPER_LANGUAGE", "ja")
PIPER_VOICE   = os.environ.get("PIPER_VOICE", "ja_JP-takumi-medium")
PIPELINE_NAME = "rpi-voice-agent"

if len(sys.argv) < 2 or not sys.argv[1]:
    print("ERROR: access_token required as first argument", file=sys.stderr)
    sys.exit(1)

ACCESS_TOKEN = sys.argv[1]


# ─── REST ヘルパー ────────────────────────────────────────────────────
def ha_get(path):
    req = urllib.request.Request(
        f"{HA_URL}{path}",
        headers={"Authorization": f"Bearer {ACCESS_TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


# ─── WebSocket 実装（stdlib のみ）─────────────────────────────────────
def _parse_host_port(url):
    url = url.replace("http://", "").replace("https://", "")
    if ":" in url:
        host, port = url.rsplit(":", 1)
        return host, int(port)
    return url, 8123


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("WebSocket connection closed unexpectedly")
        buf += chunk
    return buf


def ws_connect(host, port):
    """HTTP Upgrade ハンドシェイクを行い、接続済みソケットを返す。"""
    sock = socket.create_connection((host, port), timeout=30)
    sock.settimeout(30)
    key = base64.b64encode(os.urandom(16)).decode()
    handshake = (
        "GET /api/websocket HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    )
    sock.sendall(handshake.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("WebSocket handshake failed: server closed connection")
        buf += chunk
    status_line = buf.split(b"\r\n")[0]
    if b"101" not in status_line:
        raise ConnectionError(f"WebSocket upgrade rejected: {status_line.decode()}")
    return sock


def ws_send(sock, obj):
    """JSON オブジェクトをマスク済みテキストフレームで送信する。"""
    payload = json.dumps(obj).encode("utf-8")
    n = len(payload)
    mask = os.urandom(4)

    hdr = bytearray([0x81])  # FIN=1, opcode=1(text)
    if n < 126:
        hdr.append(n | 0x80)
    elif n < 65536:
        hdr.append(126 | 0x80)
        hdr.extend(struct.pack(">H", n))
    else:
        hdr.append(127 | 0x80)
        hdr.extend(struct.pack(">Q", n))
    hdr.extend(mask)

    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(hdr) + masked)


def ws_recv(sock):
    """完全な WebSocket フレームを受信して JSON に変換する（継続フレーム対応）。"""
    accumulated = b""
    while True:
        b0, b1 = _recv_exact(sock, 2)
        fin    = (b0 & 0x80) != 0
        opcode = b0 & 0x0F
        masked = (b1 & 0x80) != 0
        length = b1 & 0x7F

        if length == 126:
            length = struct.unpack(">H", _recv_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack(">Q", _recv_exact(sock, 8))[0]

        mask_key = _recv_exact(sock, 4) if masked else b""
        data = _recv_exact(sock, length)
        if masked:
            data = bytes(b ^ mask_key[i % 4] for i, b in enumerate(data))

        if opcode == 0x8:  # close
            raise ConnectionError("Server sent WebSocket close frame")
        if opcode == 0x9:  # ping → pong
            pong_hdr = bytes([0x8A, len(data)])
            sock.sendall(pong_hdr + data)
            continue
        if opcode == 0xA:  # pong
            continue

        accumulated += data
        if fin:
            return json.loads(accumulated.decode("utf-8")) if accumulated else {}


def ws_call(sock, msg_id, msg_type, **kwargs):
    """コマンドを送信し、対応する id の返答が来るまで待って返す。"""
    ws_send(sock, {"id": msg_id, "type": msg_type, **kwargs})
    while True:
        reply = ws_recv(sock)
        if reply.get("id") == msg_id:
            return reply
        # 別 id のイベントは無視して次のフレームへ


# ─── Wyoming エンティティ発見 ──────────────────────────────────────────
def discover_wyoming_entities(sock):
    """entity registry WS API で Wyoming プラットフォームのエンティティを探す。"""
    reply = ws_call(sock, 10, "config/entity_registry/list")
    if not reply.get("success"):
        print("  WARN: entity_registry/list failed, falling back to /api/states")
        return _discover_via_states()

    entities = reply.get("result", [])
    wyoming = [e for e in entities if e.get("platform") == "wyoming"]

    stt_e = next((e["entity_id"] for e in wyoming if e["entity_id"].startswith("stt.")), None)
    tts_e = next((e["entity_id"] for e in wyoming if e["entity_id"].startswith("tts.")), None)
    ww_e  = next((e["entity_id"] for e in wyoming if e["entity_id"].startswith("wake_word.")), None)
    return stt_e, tts_e, ww_e


def _discover_via_states():
    """フォールバック: /api/states から STT/TTS エンティティを推測する。"""
    try:
        states = ha_get("/api/states")
    except Exception as e:
        print(f"  WARN: /api/states failed: {e}")
        return None, None, None

    stt_e = next(
        (s["entity_id"] for s in states if s["entity_id"].startswith("stt.")
         and any(k in s["entity_id"] for k in ("whisper", "faster"))),
        None,
    )
    tts_e = next(
        (s["entity_id"] for s in states if s["entity_id"].startswith("tts.")
         and "piper" in s["entity_id"]),
        None,
    )
    ww_e = next(
        (s["entity_id"] for s in states if s["entity_id"].startswith("wake_word.")),
        None,
    )
    return stt_e, tts_e, ww_e


# ─── Wyoming エンティティ登録待ち ─────────────────────────────────────
def wait_for_wyoming_entities(timeout=90):
    """STT と TTS エンティティが HA の states に現れるまでポーリングする。"""
    print("Waiting for Wyoming entities to register in HA...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            states = ha_get("/api/states")
            has_stt = any(s["entity_id"].startswith("stt.") for s in states)
            has_tts = any(s["entity_id"].startswith("tts.") for s in states)
            if has_stt and has_tts:
                print("  Wyoming entities are ready")
                return True
        except urllib.error.URLError:
            pass
        time.sleep(5)
    print("  WARN: Timed out waiting for Wyoming entities. Proceeding anyway.")
    return False


# ─── メイン ───────────────────────────────────────────────────────────
def main():
    wait_for_wyoming_entities()

    host, port = _parse_host_port(HA_URL)
    print(f"Connecting to HA WebSocket ({host}:{port})...")

    try:
        sock = ws_connect(host, port)
    except Exception as e:
        print(f"ERROR: Could not connect to HA WebSocket: {e}", file=sys.stderr)
        sys.exit(1)

    # 認証
    auth_req = ws_recv(sock)
    if auth_req.get("type") != "auth_required":
        print(f"ERROR: Expected auth_required, got: {auth_req}", file=sys.stderr)
        sys.exit(1)

    ws_send(sock, {"type": "auth", "access_token": ACCESS_TOKEN})
    auth_resp = ws_recv(sock)
    if auth_resp.get("type") != "auth_ok":
        print(f"ERROR: WebSocket auth failed: {auth_resp}", file=sys.stderr)
        sys.exit(1)
    print("  WebSocket authenticated")

    # Wyoming エンティティを entity registry から発見
    print("Discovering Wyoming entity IDs...")
    stt_entity, tts_entity, ww_entity = discover_wyoming_entities(sock)
    print(f"  STT       : {stt_entity or 'not found'}")
    print(f"  TTS       : {tts_entity or 'not found'}")
    print(f"  Wake word : {ww_entity or 'not found'}")

    # Assist パイプライン作成
    # スキーマ上は null 許容だが全フィールドを明示的に送る
    print(f"Creating Assist pipeline '{PIPELINE_NAME}'...")
    result = ws_call(sock, 20, "assist_pipeline/pipeline/create",
        name=PIPELINE_NAME,
        language=WHISPER_LANG,
        conversation_engine="conversation.home_assistant",
        conversation_language=WHISPER_LANG,
        stt_engine=stt_entity,
        stt_language=WHISPER_LANG if stt_entity else None,
        tts_engine=tts_entity,
        tts_language=WHISPER_LANG if tts_entity else None,
        tts_voice=PIPER_VOICE if tts_entity else None,
        wake_word_entity=ww_entity,
        wake_word_id=WAKE_WORD if ww_entity else None,
    )

    if not result.get("success"):
        err = result.get("error", {})
        print(f"ERROR: Pipeline creation failed: {err.get('code')} – {err.get('message')}", file=sys.stderr)
        sock.close()
        sys.exit(1)

    pipeline_id = result["result"]["id"]
    print(f"  Pipeline created (id: {pipeline_id})")

    # 優先パイプラインとして設定
    pref = ws_call(sock, 21, "assist_pipeline/pipeline/set_preferred",
        pipeline_id=pipeline_id)
    if pref.get("success"):
        print("  Set as preferred pipeline")
    else:
        err = pref.get("error", {})
        print(f"  WARN: set_preferred failed: {err.get('code')} – {err.get('message')}")

    sock.close()
    print("Assist pipeline setup complete")


if __name__ == "__main__":
    main()
