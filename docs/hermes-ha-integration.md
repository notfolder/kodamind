# Hermes Agent × Home Assistant 統合ガイド

## 1. Home Assistant のオンボーディング（自動）

`setup.sh` を実行すると `scripts/ha-setup.sh` が自動的に以下を処理します。

- `/api/onboarding/users` で管理者ユーザー作成（`.env` の `HA_USERNAME` / `HA_PASSWORD` を使用）
- Wyoming Integration (openWakeWord / Whisper STT / Piper TTS) を `/api/config/config_entries/flow` で追加

手動操作は不要です。

## 2. Wyoming Integration（自動）

`scripts/ha-setup.sh` が以下の Wyoming Integration を自動追加します。

| サービス | ポート |
| --- | --- |
| openWakeWord | 10400 |
| Whisper STT | 10300 |
| Piper TTS | 10200 |

## 3. Assist パイプラインの設定（自動）

`scripts/ha-setup.sh` が `scripts/ha-pipeline-setup.py` を呼び出して自動設定します。

- WebSocket API (`assist_pipeline/pipeline/create`) でパイプライン `rpi-voice-agent` を作成
- `config/entity_registry/list` で Wyoming STT・TTS・WakeWord エンティティを自動発見
- 作成したパイプラインを優先パイプラインとして設定 (`set_preferred`)

設定内容（`.env` から読み取り）:

| 項目 | デフォルト |
| --- | --- |
| Wake Word | `WAKE_WORD`（デフォルト: `ok_nabu`） |
| STT | 自動発見した Wyoming Whisper エンティティ |
| TTS | 自動発見した Wyoming Piper エンティティ |
| TTS Voice | `PIPER_VOICE`（デフォルト: `ja_JP-takumi-medium`） |
| 言語 | `WHISPER_LANGUAGE`（デフォルト: `ja`） |

**確認方法**: `setup.sh` 完了後、`http://<Pi IP>:8123` → Settings → Voice Assistants で `rpi-voice-agent` パイプラインが表示されていれば成功です。

**自動設定に失敗した場合**: `http://<Pi IP>:8123/config/voice-assistants/pipelines` から手動で作成してください。

## 4. Whisper（STT）の設定

`wyoming-whisper` サービスは `docker-compose.yml` に組み込み済みです。`docker compose up -d` で自動起動します。

デフォルト設定（`.env` で変更可能）:

| 変数名 | デフォルト | 説明 |
| --- | --- | --- |
| `WHISPER_MODEL` | `tiny-int8` | モデルサイズ（`tiny-int8` / `base-int8` / `small-int8`） |
| `WHISPER_LANGUAGE` | `ja` | 認識言語 |

## 5. Piper（TTS）の設定

`wyoming-piper` サービスは `docker-compose.yml` に組み込み済みです。`docker compose up -d` で自動起動します。

デフォルト設定（`.env` で変更可能）:

| 変数名 | デフォルト | 説明 |
| --- | --- | --- |
| `PIPER_VOICE` | `ja_JP-takumi-medium` | 使用する音声（[Piper 対応音声一覧](https://rhasspy.github.io/piper-samples/)） |

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

## ha-setup.sh を単独で再実行する場合

HA が既にオンボーディング済みの場合、ha-setup.sh は onboarding API でエラーになります。
Wyoming Integration の追加だけを再実行したい場合は、access token を手動取得して
`/api/config/config_entries/flow` を直接呼び出してください。
