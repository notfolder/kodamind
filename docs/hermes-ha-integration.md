# Hermes Agent × Home Assistant 統合ガイド

## 1. Home Assistant のオンボーディング

`setup.sh` 完了後、`http://<Pi のIP>:8123` を開いてアカウント作成と初期設定を完了させてください。

## 2. Wyoming Integration（openWakeWord）の追加

1. Settings → Devices & Services → **Add Integration**
2. "Wyoming Protocol" を検索
3. Host: `localhost`、Port: `10400` を入力
4. openWakeWord が認識されたら完了

## 3. Assist パイプラインの設定

1. Settings → Voice Assistants → **Add Assistant**
2. Wake Word Engine: **openWakeWord**
3. Wake Word: `.env` の `WAKE_WORD` で指定したもの（デフォルト: `ok_nabu`）
4. Speech-to-text: Whisper（後述）
5. Text-to-speech: Piper（後述）

## 4. Whisper（STT）の設定

`wyoming-whisper` サービスは `docker-compose.yml` に組み込み済みです。`docker compose up -d` で自動起動します。

デフォルト設定（`.env` で変更可能）:

| 変数名 | デフォルト | 説明 |
| --- | --- | --- |
| `WHISPER_MODEL` | `tiny-int8` | モデルサイズ（`tiny-int8` / `base-int8` / `small-int8`） |
| `WHISPER_LANGUAGE` | `ja` | 認識言語 |

HA 側: Settings → Devices & Services → Add Integration → "Wyoming Protocol" → Host: `localhost`, Port: `10300`

## 5. Piper（TTS）の設定

`wyoming-piper` サービスは `docker-compose.yml` に組み込み済みです。`docker compose up -d` で自動起動します。

デフォルト設定（`.env` で変更可能）:

| 変数名 | デフォルト | 説明 |
| --- | --- | --- |
| `PIPER_VOICE` | `ja_JP-takumi-medium` | 使用する音声（[Piper 対応音声一覧](https://rhasspy.github.io/piper-samples/)） |

HA 側: Settings → Devices & Services → Add Integration → "Wyoming Protocol" → Host: `localhost`, Port: `10200`

## 6. Hermes Agent を HA の Conversation Agent として接続

コミュニティ製統合を使用します：

```bash
# HA の custom_components ディレクトリに配置
cd config/homeassistant
mkdir -p custom_components
git clone https://github.com/rusty4444/hermes-voice-ha-integration \
  custom_components/hermes_agent
```

その後 HA を再起動し、Settings → Integrations から "Hermes Agent" を追加。
Hermes API URL: `http://localhost:8642`
API Key: `.env` の `HERMES_API_KEY`

## 7. 音声パイプライン全体像

```
マイク → openWakeWord (10400)
         ↓ ウェイクワード検出
       Whisper (10300)
         ↓ 音声 → テキスト
       Hermes Agent (8642) ← Ollama (11434)
         ↓ 応答テキスト生成
       Piper (10200)
         ↓ テキスト → 音声
       スピーカー
```

## カスタムウェイクワードの追加

1. [openWakeWord トレーニング](https://github.com/dscripka/openWakeWord) でカスタムモデルを作成
2. `.tflite` ファイルを `config/openwakeword/custom_models/` に配置
3. `.env` の `WAKE_WORD` をモデル名に変更
4. `docker compose restart openwakeword`
