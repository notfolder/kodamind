# 詳細設計書

**プロジェクト名:** rpi-voice-agent  
**作成日:** 2026-06-11  
**バージョン:** 1.0.0

-----

## 1. システム構成概要

### 1.1 アーキテクチャ図

```
                        ┌─────────────────────────────────────────┐
                        │          Raspberry Pi 5 (arm64)          │
                        │                                          │
  マイク ────────────→  │  ┌──────────────┐                       │
                        │  │ openWakeWord │  Wyoming TCP :10400   │
                        │  └──────┬───────┘                       │
                        │         ↓ ウェイクワード検出              │
                        │  ┌──────────────┐                       │
                        │  │   Whisper    │  Wyoming TCP :10300   │
                        │  │    (STT)     │                       │
                        │  └──────┬───────┘                       │
                        │         ↓ テキスト                       │
                        │  ┌──────────────────────┐               │
                        │  │   Home Assistant     │               │
                        │  │   Core  :8123        │               │
                        │  │  (Assist Pipeline)   │               │
                        │  └──────────┬───────────┘               │
                        │             │ HTTP / WebSocket           │
                        │  ┌──────────↓───────────┐               │
                        │  │   Hermes Agent       │               │
                        │  │   :8642              │               │
                        │  └──────────┬───────────┘               │
                        │             │ HTTP                       │
                        │  ┌──────────↓───────────┐               │
                        │  │     Ollama           │               │
                        │  │     :11434           │               │
                        │  └──────────────────────┘               │
                        │                                          │
                        │  ┌──────────────┐                       │
                        │  │    Piper     │  Wyoming TCP :10200   │
                        │  │    (TTS)     │                       │
                        │  └──────┬───────┘                       │
                        │         ↓                               │
  スピーカー ←──────────│                                          │
                        └─────────────────────────────────────────┘
```

### 1.2 音声パイプライン（完成形）

```
マイク
  ↓
openWakeWord（ウェイクワード検出）  ← Wyoming TCP :10400
  ↓ 検出
Whisper STT（音声→テキスト）       ← Wyoming TCP :10300
  ↓ テキスト
Hermes Agent（LLM 推論・ツール実行） ← HTTP :8642
  ↓ 応答テキスト     ↑↓ Ollama HTTP :11434
Piper TTS（テキスト→音声）         ← Wyoming TCP :10200
  ↓
スピーカー
```

-----

## 2. コンポーネント詳細

### 2.1 Ollama

|項目         |値                                            |
|-----------|---------------------------------------------|
|Docker イメージ|`ollama/ollama:latest`                       |
|コンテナ名      |`ollama`                                     |
|公開ポート      |`11434`                                      |
|データ永続化     |Docker volume `ollama_data` → `/root/.ollama`|
|ヘルスチェック    |`GET /api/tags` (30s interval)               |
|再起動ポリシー    |`unless-stopped`                             |

**環境変数**

|変数名                       |デフォルト|説明                |
|--------------------------|-----|------------------|
|`OLLAMA_KEEP_ALIVE`       |`5m` |モデルをメモリに保持する時間    |
|`OLLAMA_NUM_PARALLEL`     |`1`  |同時推論数（Pi 5 は 1 推奨）|
|`OLLAMA_MAX_LOADED_MODELS`|`1`  |同時ロードモデル数         |

**Pi 5 での推奨モデル**

|モデル           |パラメーター数|ダウンロードサイズ|推定速度   |用途     |
|--------------|-------|---------|-------|-------|
|`qwen2.5:3b`  |3B     |1.9GB    |~5 t/s |デフォルト推奨|
|`qwen2.5:1.5b`|1.5B   |1.0GB    |~8 t/s |高速・軽量  |
|`llama3.2:3b` |3B     |2.0GB    |~5 t/s |英語タスク  |
|`gemma3:1b`   |1B     |0.8GB    |~10 t/s|最軽量    |

**初回モデルダウンロード（ollama-pull サービス）**

`restart: "no"` のワンショットコンテナとして定義。`ollama` の healthcheck 通過後に起動し、`.env` の `OLLAMA_DEFAULT_MODEL` で指定したモデルを pull する。2回目以降の起動では既にモデルが存在するため実質的に何もしない。

-----

### 2.2 Home Assistant Core

|項目         |値                                             |
|-----------|----------------------------------------------|
|Docker イメージ|`ghcr.io/home-assistant/home-assistant:stable`|
|コンテナ名      |`homeassistant`                               |
|ネットワーク     |`host`（mDNS・デバイス検出に必要）                        |
|公開ポート      |`8123`（host モードのため直接公開）                       |
|設定ディレクトリ   |`./config/homeassistant` → `/config`          |
|権限         |`privileged: true`（デバイスアクセスに必要）               |
|ヘルスチェック    |`GET http://localhost:8123/` (60s interval)   |

**マウントするホストパス**

|ホストパス                   |コンテナパス               |用途                |
|------------------------|---------------------|------------------|
|`./config/homeassistant`|`/config`            |設定ファイル（git 管理）    |
|`/etc/localtime`        |`/etc/localtime` (ro)|タイムゾーン同期          |
|`/run/dbus`             |`/run/dbus` (ro)     |Bluetooth 等のデバイス通信|

**初期 configuration.yaml の構成**

```yaml
homeassistant:
  name: "RPi Voice Agent"
  time_zone: Asia/Tokyo
  language: ja

default_config:   # 標準コンポーネント一括有効化

logger:
  default: warning
  logs:
    homeassistant.components.wyoming: info
    homeassistant.components.assist_pipeline: info
```

**Wyoming Integration の設定（手動）**

初回起動後に Web UI から設定する：

- Settings → Devices & Services → Add Integration → “Wyoming Protocol”
- Host: `localhost` / Port: `10400`（openWakeWord 用）

-----

### 2.3 wyoming-openwakeword

|項目         |値                                                |
|-----------|-------------------------------------------------|
|Docker イメージ|`rhasspy/wyoming-openwakeword:latest`            |
|コンテナ名      |`openwakeword`                                   |
|公開ポート      |`10400` (TCP)                                    |
|通信プロトコル    |Wyoming Protocol over TCP                        |
|カスタムモデルDir |`./config/openwakeword/custom_models` → `/custom`|

**起動引数**

```
--uri tcp://0.0.0.0:10400     # リスンアドレス
--preload-model ok_nabu       # .env の WAKE_WORD で変更可能
--custom-model-dir /custom    # カスタムモデル配置先
--debug                       # デバッグログ有効
```

**利用可能なデフォルトウェイクワード**

|ワード名         |発話例          |
|-------------|-------------|
|`ok_nabu`    |“OK Nabu”    |
|`hey_jarvis` |“Hey Jarvis” |
|`alexa`      |“Alexa”      |
|`hey_mycroft`|“Hey Mycroft”|

**カスタムウェイクワードの追加手順**

1. `.tflite` モデルファイルを `config/openwakeword/custom_models/` に配置
1. `.env` の `WAKE_WORD` をモデル名（拡張子なし）に変更
1. `docker compose restart openwakeword`

-----

### 2.4 Hermes Agent

|項目         |値                                          |
|-----------|-------------------------------------------|
|Docker イメージ|`nousresearch/hermes-agent:latest`         |
|コンテナ名      |`hermes`                                   |
|公開ポート      |`8642` (HTTP / WebSocket)                  |
|データ永続化     |Docker volume `hermes_data` → `/opt/data`  |
|設定マウント     |`./config/hermes` → `/opt/data/config` (ro)|
|依存関係       |`ollama` の healthcheck 通過後に起動              |

**環境変数**

|変数名                  |値                        |説明                         |
|---------------------|-------------------------|---------------------------|
|`HERMES_LLM_PROVIDER`|`ollama`                 |LLM プロバイダー                 |
|`HERMES_LLM_BASE_URL`|`http://ollama:11434`    |Ollama の URL（Docker 内部名前解決）|
|`HERMES_LLM_MODEL`   |`qwen2.5:3b`             |使用モデル（`.env` で変更可能）        |
|`API_SERVER_HOST`    |`0.0.0.0`                |API バインドアドレス               |
|`API_SERVER_PORT`    |`8642`                   |API ポート                    |
|`API_SERVER_KEY`     |`.env` の `HERMES_API_KEY`|認証キー（必須）                   |

**データ永続化の構造**

```
hermes_data (Docker volume)
└── /opt/data/
    ├── config/          ← ./config/hermes がマウントされる
    ├── memory/          ← セッション記憶（volume 内）
    ├── skills/          ← 学習済みスキル（volume 内）
    └── sessions/        ← セッション履歴（volume 内）
```

-----

### 2.5 wyoming-faster-whisper（STT）

|項目|値|
|---|---|
|Docker イメージ|`rhasspy/wyoming-faster-whisper:latest`|
|コンテナ名|`wyoming-whisper`|
|公開ポート|`10300` (TCP)|
|通信プロトコル|Wyoming Protocol over TCP|
|データ永続化|Docker volume `whisper_data` → `/data`|
|ヘルスチェック|`nc -z localhost 10300` (30s interval)|

#### 起動引数

```
--uri tcp://0.0.0.0:10300
--model ${WHISPER_MODEL:-tiny-int8}   # 精度優先なら base-int8 / small-int8
--language ${WHISPER_LANGUAGE:-ja}
--beam-size 1                          # Pi 5 CPU 推論では速度優先で 1
--download-dir /data
```

#### モデル選定目安（Pi 5 / CPU）

|モデル|精度|初回ダウンロード|速度|
|---|---|---|---|
|`tiny-int8`|低〜中|約 40 MB|速い（デフォルト）|
|`base-int8`|中|約 140 MB|中程度|
|`small-int8`|高|約 470 MB|遅い|

-----

### 2.6 wyoming-piper（TTS）

|項目|値|
|---|---|
|Docker イメージ|`rhasspy/wyoming-piper:latest`|
|コンテナ名|`wyoming-piper`|
|公開ポート|`10200` (TCP)|
|通信プロトコル|Wyoming Protocol over TCP|
|データ永続化|Docker volume `piper_data` → `/data`|
|ヘルスチェック|`nc -z localhost 10200` (30s interval)|

#### Piper 起動引数

```
--uri tcp://0.0.0.0:10200
--voice ${PIPER_VOICE:-ja_JP-takumi-medium}
--download-dir /data
```

音声ファイルは初回起動時に `/data` へ自動ダウンロードされる。利用可能な音声の一覧は [rhasspy.github.io/piper-samples](https://rhasspy.github.io/piper-samples/) を参照。

-----

## 3. ネットワーク設計

### 3.1 ポート一覧

|サービス            |ポート  |プロトコル        |アクセス元           |
|----------------|-----|-------------|----------------|
|Home Assistant  |8123 |HTTP         |LAN 全体          |
|Ollama API      |11434|HTTP         |LAN 全体（注意：認証なし） |
|Hermes Agent API|8642 |HTTP/WS      |LAN 全体（要 API キー）|
|openWakeWord    |10400|TCP (Wyoming)|localhost のみ    |
|Whisper (STT)   |10300|TCP (Wyoming)|localhost のみ    |
|Piper (TTS)     |10200|TCP (Wyoming)|localhost のみ    |


> **注意:** Ollama は認証機能を持たないため、必要であればファイアウォールで LAN 内に制限すること。

### 3.2 コンテナ間通信

```
hermes → ollama:11434    # HTTP（Docker 内部 DNS 解決）
HA     → localhost:10400 # Wyoming TCP（host ネットワーク、openWakeWord）
HA     → localhost:10300 # Wyoming TCP（host ネットワーク、Whisper STT）
HA     → localhost:10200 # Wyoming TCP（host ネットワーク、Piper TTS）
```

Home Assistant は `network_mode: host` のため、Wyoming コンテナ（openWakeWord / Whisper / Piper）には `localhost:<port>` で直接アクセスする。Hermes と Ollama は Docker の内部ネットワーク（デフォルトブリッジ）でコンテナ名 DNS 解決を使う。

-----

## 4. ファイル構成

```
rpi-voice-agent/
│
├── docker-compose.yml              # 全サービス定義
├── .env.example                    # 環境変数テンプレート
├── .env                            # 実際の認証情報（.gitignore 済み）
├── .gitignore
├── setup.sh                        # 初期セットアップスクリプト
│
├── scripts/
│   ├── pull-model.sh               # Ollama モデル追加
│   └── update.sh                   # イメージ更新・再起動
│
├── config/
│   ├── homeassistant/
│   │   └── configuration.yaml      # HA 設定（setup.sh で自動生成）
│   ├── hermes/                     # Hermes 追加設定（任意）
│   └── openwakeword/
│       └── custom_models/          # カスタムウェイクワードモデル置き場
│
└── docs/
    ├── requirements.md             # 要件定義書
    ├── design.md                   # 本ファイル（詳細設計書）
    └── hermes-ha-integration.md    # HA 統合手順
```

-----

## 5. セットアップフロー

### 5.1 setup.sh の処理フロー

```
start
  │
  ├─ 前提チェック
  │    ├─ アーキテクチャ確認（aarch64 のみ）
  │    ├─ .env ファイルの存在確認
  │    └─ HERMES_API_KEY の設定確認
  │
  ├─ システムパッケージ更新（apt-get）
  │
  ├─ Docker インストール（未インストールの場合のみ）
  │
  ├─ 音声デバイス確認（aplay / arecord）
  │
  ├─ HA 設定ファイル初期化（configuration.yaml 生成）
  │
  ├─ ディレクトリ作成
  │    ├─ config/openwakeword/custom_models/
  │    └─ config/hermes/
  │
  ├─ Docker イメージ pull（docker compose pull）
  │
  ├─ サービス起動（docker compose up -d）
  │
  ├─ ヘルスチェック（各サービスが応答するまで待機）
  │    ├─ ollama:11434/api/tags（最大 120s）
  │    ├─ homeassistant:8123（最大 180s）
  │    ├─ hermes:8642/health（最大 120s）
  │    └─ openwakeword:10400（TCP、最大 60s）
  │
  └─ 完了メッセージ（アクセス URL・次のステップを表示）
```

### 5.2 初回セットアップ後の手動作業

1. `http://<PiのIP>:8123` でHome Assistant のアカウント作成
1. Wyoming Integration の追加（openWakeWord: `localhost:10400`）
1. Assist パイプラインでウェイクワード設定
1. Whisper・Piper の追加（任意、`docs/hermes-ha-integration.md` 参照）

-----

## 6. 環境変数定義

|変数名                       |必須    |デフォルト       |説明             |
|--------------------------|------|------------|---------------|
|`TZ`                      |任意    |`Asia/Tokyo`|タイムゾーン         |
|`OLLAMA_DEFAULT_MODEL`    |任意    |`qwen2.5:3b`|デフォルト LLM モデル  |
|`OLLAMA_KEEP_ALIVE`       |任意    |`5m`        |モデルのメモリ保持時間    |
|`OLLAMA_NUM_PARALLEL`     |任意    |`1`         |並列推論数          |
|`OLLAMA_MAX_LOADED_MODELS`|任意    |`1`         |最大ロードモデル数      |
|`HERMES_API_KEY`          |**必須**|なし          |Hermes API 認証キー|
|`WAKE_WORD`               |任意    |`ok_nabu`   |ウェイクワード名       |

-----

## 7. ヘルスチェック設計

|サービス         |チェック方法                       |interval|timeout|retries|start_period|
|-------------|-----------------------------|--------|-------|-------|------------|
|ollama       |`curl /api/tags`             |30s     |10s    |5      |30s         |
|homeassistant|`curl http://localhost:8123/`|60s     |10s    |5      |60s         |
|openwakeword |`nc -z localhost 10400`      |30s     |5s     |3      |15s         |
|hermes       |`curl /health`               |30s     |10s    |5      |45s         |

-----

## 8. データ永続化

|データ種別               |保存先                                   |管理方法         |
|--------------------|--------------------------------------|-------------|
|Ollama モデルファイル      |Docker volume `ollama_data`           |volume で永続化  |
|Whisper モデルファイル     |Docker volume `whisper_data`          |volume で永続化  |
|Piper 音声ファイル        |Docker volume `piper_data`            |volume で永続化  |
|Hermes 記憶・スキル       |Docker volume `hermes_data`           |volume で永続化  |
|HA 設定ファイル           |`./config/homeassistant/`             |Git 管理（一部除外） |
|openWakeWord カスタムモデル|`./config/openwakeword/custom_models/`|Git 管理       |
|認証情報                |`.env`                                |**Git 管理対象外**|

-----

## 9. 既知の制約と対応方針

|制約|詳細|対応方針|
|---|---|---|
|Pi 5 GPU 非対応|Ollama は CPU のみ動作|3B 以下のモデルを使用|
|LLM 応答速度|3B モデルで約 5 tokens/sec|軽量モデル選定・量子化モデル使用|
|HA オンボーディング|初回のみ手動操作が必要|README・ドキュメントで手順を明示|
|Whisper 初回起動|モデルダウンロードに数分かかる|`start_period: 60s` を設定済み|
|Piper 初回起動|音声ファイルダウンロードに数分かかる|`start_period: 60s` を設定済み|
|Ollama 認証なし|デフォルトでは認証不要|ローカル LAN に限定、必要に応じてファイアウォール設定|
