# rpi-voice-agent

Raspberry Pi 5 上で動作する、完全ローカルの音声エージェントスタック。

```
ウェイクワード ("ok nabu") → STT → Hermes Agent + Ollama → TTS → スピーカー
```

クラウド不要・APIキー不要（LLM 推論はローカル Ollama）・GitHub でバージョン管理。

## スタック構成

| サービス | 役割 | ポート |
|---------|------|--------|
| **Ollama** | ローカル LLM 推論（CPU/arm64） | 11434 |
| **Home Assistant** | 音声パイプライン統合ハブ | 8123 |
| **wyoming-openwakeword** | ウェイクワード検出 | 10400 |
| **wyoming-faster-whisper** | 音声→テキスト（STT） | 10300 |
| **wyoming-piper** | テキスト→音声（TTS） | 10200 |
| **Hermes Agent** | 自律エージェント（記憶・スキル付き） | 8642 |
| **setup** | HA 初期化・Wyoming 統合・Hermes 統合・Assist パイプライン作成（ワンショット） | — |

## 必要なもの

- Raspberry Pi 5（8GB RAM 推奨）
- Raspberry Pi OS Bookworm 64-bit
- USB マイク
- スピーカー（3.5mm / USB / Bluetooth）
- インターネット接続（初回セットアップ時のみ）

## セットアップ

```bash
# 1. リポジトリをクローン
git clone https://github.com/YOUR_USER/rpi-voice-agent.git
cd rpi-voice-agent

# 2. 認証情報を設定（これだけ手動）
cp .env.example .env
nano .env   # HERMES_API_KEY と HA_PASSWORD を必ず設定

# 3. ワンコマンドセットアップ（HA オンボーディング・Wyoming 統合・Hermes 統合まで自動）
bash setup.sh          # Raspberry Pi 5
bash setup.sh --mac    # Mac (Apple Silicon) 開発検証
```

セットアップ完了後、`http://<PiのIP>:8123` → Settings → Voice Assistants で
`rpi-voice-agent` パイプラインが作成されていることを確認してください。
詳細は `docs/hermes-ha-integration.md` を参照。

## 日常操作

```bash
# ログ確認
docker compose logs -f

# 特定サービスのログ
docker compose logs -f hermes
docker compose logs -f ollama

# Ollama モデルの追加
bash pull-model.sh qwen2.5:3b
bash pull-model.sh llama3.2:3b   # より軽量

# イメージ更新
bash update.sh

# 停止 / 起動
docker compose down
docker compose up -d
```

## Pi 5 での推奨モデル

| モデル | サイズ | 速度（Pi 5） | 用途 |
|--------|--------|------------|------|
| `qwen2.5:3b` | 1.9GB | ~5 t/s | デフォルト推奨 |
| `llama3.2:3b` | 2.0GB | ~5 t/s | 英語タスク向け |
| `qwen2.5:1.5b` | 1.0GB | ~8 t/s | 超軽量・高速 |
| `gemma3:1b` | 0.8GB | ~10 t/s | 最軽量 |

## ディレクトリ構成

```
rpi-voice-agent/
├── docker-compose.yml          # 全サービス定義
├── .env.example                # 環境変数テンプレート（要コピー）
├── .gitignore                  # .env 等を除外
├── setup.sh                    # ワンショット初期化スクリプト（--mac オプションあり）
├── pull-model.sh               # Ollama モデル追加
├── update.sh                   # イメージ更新
├── setup/
│   └── Dockerfile              # setup コンテナイメージ定義
├── scripts/
│   ├── ha-setup.sh             # HA API 自動設定（setup コンテナ内で実行）
│   └── ha-pipeline-setup.py    # Assist パイプライン作成
├── config/
│   ├── homeassistant/          # HA 設定（一部 git 管理）
│   └── openwakeword/
│       └── custom_models/      # カスタムウェイクワード置き場
└── docs/
    ├── hermes-ha-integration.md  # HA 統合手順
    ├── design.md                 # 詳細設計書
    └── requirements.md           # 要件定義書
```

## ライセンス

MIT
