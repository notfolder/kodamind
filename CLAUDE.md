# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

**rpi-voice-agent** — Raspberry Pi 5 上で動作する完全ローカルの音声アシスタントスタック。クラウド不要・推論用 API キー不要。

```text
ウェイクワード ("ok nabu") → openWakeWord → Whisper (STT) → Hermes Agent + Ollama → Piper (TTS) → スピーカー
```

対象ハードウェア: Raspberry Pi 5（8GB RAM）、arm64、Raspberry Pi OS Bookworm 64-bit

## よく使うコマンド

```bash
# 初回セットアップ
cp .env.example .env          # HERMES_API_KEY を必ず設定
bash setup.sh                 # Raspberry Pi 5 (arm64)
bash setup.sh --mac           # Mac (Apple Silicon) 開発検証

# 日常操作（Pi / Mac 共通）
docker compose up -d          # 全サービス起動
docker compose down           # 全サービス停止
docker compose logs -f        # 全ログをストリーミング
docker compose logs -f hermes # 特定サービスのログ
docker compose restart hermes # 特定サービスの再起動

# Ollama モデルの追加
bash pull-model.sh qwen2.5:3b

# イメージ更新
bash update.sh
```

## アーキテクチャ

`docker-compose.yml` で定義される 8 つの Docker サービス:

| サービス | イメージ | ポート | 役割 |
| --- | --- | --- | --- |
| `ollama` | `ollama/ollama:0.30.7` | 11434 | ローカル LLM 推論（Pi 5 は CPU のみ） |
| `ollama-pull` | `ollama/ollama:0.30.7` | — | 初回起動時に `OLLAMA_DEFAULT_MODEL` を pull するワンショット（`restart: "no"`） |
| `homeassistant` | `ghcr.io/home-assistant/home-assistant:2026.6.2` | 8123 | 音声パイプライン統合ハブ。mDNS のため `network_mode: host` |
| `openwakeword` | `rhasspy/wyoming-openwakeword:2.1.0` | 10400 TCP | Wyoming Protocol でウェイクワード検出 |
| `wyoming-whisper` | `rhasspy/wyoming-whisper:3.1.0` | 10300 TCP | STT（音声→テキスト）。モデルは初回起動時に自動 DL |
| `voicevox-engine` | `voicevox/voicevox_engine:cpu-0.26.0-dev` | 50021（内部） | VOICEVOX 日本語 TTS HTTP API |
| `wyoming-voicevox` | `wyoming-voicevox/Dockerfile`（ローカルビルド） | 10200 TCP | VOICEVOX → Wyoming アダプター。voicevox-engine healthy 後に起動 |
| `hermes` | `nousresearch/hermes-agent:v2026.6.5` | 8642 | 記憶・スキル付き自律エージェント。ollama の healthcheck 通過後に起動 |
| `setup` | `setup/Dockerfile`（ローカルビルド） | — | HA 初期化・Wyoming 統合・Hermes Agent 統合・Assist パイプライン作成（ワンショット）。全依存サービス healthy 後に実行 |

### コンテナ間通信

- Home Assistant は `network_mode: host` → openWakeWord に `localhost:10400` で直接アクセス
- Hermes → Ollama は Docker 内部 DNS で `http://ollama:11434` にアクセス

### データ永続化

| データ | 保存先 | 管理方法 |
| --- | --- | --- |
| Ollama モデルファイル | Docker volume `ollama_data` | volume で永続化 |
| Whisper モデルファイル | Docker volume `whisper_data` | volume で永続化 |
| Hermes 記憶・スキル・セッション | Docker volume `hermes_data` | volume で永続化 |
| HA 設定ファイル | `./config/homeassistant/` | Git 管理 |
| カスタムウェイクワードモデル | `./config/openwakeword/custom_models/` | Git 管理 |
| 認証情報 | `.env` | **Git 管理対象外** |

## 環境変数（`.env`）

| 変数名 | 必須 | デフォルト | 説明 |
| --- | --- | --- | --- |
| `HERMES_API_KEY` | **必須** | — | Hermes API 認証キー。`openssl rand -hex 32` で生成 |
| `HA_PASSWORD` | **必須** | — | HA 管理者パスワード（setup.sh が自動作成） |
| `HA_USERNAME` | 任意 | `admin` | HA 管理者ユーザー名 |
| `HA_DISPLAY_NAME` | 任意 | `Admin` | HA 表示名 |
| `OLLAMA_DEFAULT_MODEL` | 任意 | `qwen2.5:3b` | 初回起動時に pull するモデル |
| `WAKE_WORD` | 任意 | `ok_nabu` | openWakeWord に渡すウェイクワード名 |
| `TZ` | 任意 | `Asia/Tokyo` | 全サービスのタイムゾーン |
| `OLLAMA_KEEP_ALIVE` | 任意 | `5m` | モデルをメモリに保持する時間 |
| `OLLAMA_NUM_PARALLEL` | 任意 | `1` | 並列推論数（Pi 5 では 1 推奨） |
| `WHISPER_MODEL` | 任意 | `tiny-int8` | Whisper モデルサイズ（`base-int8` で精度向上） |
| `WHISPER_LANGUAGE` | 任意 | `ja` | Whisper 認識言語 |
| `VOICEVOX_SPEAKER` | 任意 | `3` | VOICEVOX 話者 ID（3=四国めたん, 2=ずんだもん, 8=春日部つむぎ） |
| `PULSE_SERVER` | 任意 | — | PulseAudio サーバーアドレス（`setup.sh --mac` が `tcp:host.docker.internal:4713` を自動設定） |
| `DBUS_RUN_DIR` | 任意 | `/run/dbus` | dbus ソケットのホストパス（`setup.sh --mac` が `~/.rpi-voice-agent/dbus` を自動設定） |

## Pi 5 推奨モデル

| モデル | サイズ | 速度 | 備考 |
| --- | --- | --- | --- |
| `qwen2.5:3b` | 1.9 GB | ~5 t/s | デフォルト推奨 |
| `qwen2.5:1.5b` | 1.0 GB | ~8 t/s | 軽量・高速 |
| `gemma3:1b` | 0.8 GB | ~10 t/s | 最軽量 |
| `llama3.2:3b` | 2.0 GB | ~5 t/s | 英語タスク向け |

Pi 5 は GPU アクセラレーション非対応かつ RAM 8GB のため、3B 以下のモデルを使用すること。

## セットアップ後の確認

`setup.sh` が全工程（オンボーディング・Wyoming Integration・Assist パイプライン）を自動実行する。
手動作業は不要。以下を確認するだけ:

1. `http://<Pi の IP>:8123` を開く（ログイン: `HA_USERNAME` / `HA_PASSWORD`）
2. Settings → Voice Assistants → `rpi-voice-agent` パイプラインが存在することを確認
3. 存在しない場合は `/config/voice-assistants/pipelines` から手動作成（フォールバック）

## カスタムウェイクワードの追加

1. `.tflite` ファイルを `config/openwakeword/custom_models/` に配置
2. `.env` の `WAKE_WORD=<モデル名（拡張子なし）>` を変更
3. `docker compose restart openwakeword`

## 主要ドキュメント

- [docs/hermes-ha-integration.md](docs/hermes-ha-integration.md) — Whisper・Piper の設定変数と HA 側の Wyoming Integration 追加手順
- [docs/design.md](docs/design.md) — 詳細設計書（コンポーネント仕様・ネットワーク図・ヘルスチェック設計）
- [docs/requirements.md](docs/requirements.md) — 要件定義書
