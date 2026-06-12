# Hermes Agent × Home Assistant 統合ガイド

## 1. Home Assistant のオンボーディング（自動）

`setup.sh` を実行すると `setup` コンテナ（`scripts/ha-setup.sh`）が自動的に以下を処理します。

- `/api/onboarding/users` で管理者ユーザー作成（`.env` の `HA_USERNAME` / `HA_PASSWORD` を使用）
- Wyoming Integration (openWakeWord / Whisper STT / Piper TTS) を `/api/config/config_entries/flow` で追加

手動操作は不要です。

## 2. Wyoming Integration（自動）

`setup` コンテナが以下の Wyoming Integration を自動追加します。

| サービス | ポート |
| --- | --- |
| openWakeWord | 10400 |
| Whisper STT | 10300 |
| Piper TTS | 10200 |

## 3. Assist パイプラインの設定（自動）

`setup` コンテナ（`scripts/ha-setup.sh`）が `scripts/ha-pipeline-setup.py` を呼び出して自動設定します。

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

## 6. Hermes Agent を HA の Conversation Agent として接続（自動）

`setup.sh` が以下を自動処理します。

1. `git submodule update --init` で `config/homeassistant/custom_components/hermes_agent/` を配置（HA 起動前）
2. HA 起動時に custom_component を自動ロード
3. `setup` コンテナが `/api/config/config_entries/flow` で Hermes Agent インテグレーションを自動追加

バージョン管理は git submodule（`.gitmodules`）で行います。コミットハッシュが固定されるため、意図しないアップデートが起きません。

**確認方法**: Settings → Integrations に "Hermes Agent" が表示されていれば成功です。

**自動設定に失敗した場合**（custom component が読み込まれていないケース）:

```bash
# submodule を初期化してから HA を再起動
git submodule update --init --recursive
docker compose restart homeassistant
```

その後 Settings → Integrations → Add Integration → "Hermes Agent" を選択して手動追加:

- Hermes API URL: `http://localhost:8642`
- API Key: `.env` の `HERMES_API_KEY`

**submodule を最新版に更新する場合**:

```bash
git submodule update --remote config/homeassistant/custom_components/hermes_agent
git add config/homeassistant/custom_components/hermes_agent
git commit -m "chore: update hermes-voice-ha-integration"
docker compose restart homeassistant
```

## 7. 音声パイプライン全体像

```text
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

## setup コンテナを単独で再実行する場合

HA が既にオンボーディング済みの場合、`ha-setup.sh` は onboarding API でエラーになります。
Wyoming Integration または Hermes Agent Integration の追加だけを再実行したい場合は、
access token を手動取得して `/api/config/config_entries/flow` を直接呼び出してください。

**Wyoming Integration の再追加**（handler: `wyoming`、host/port を指定）:

```bash
curl -X POST http://localhost:8123/api/config/config_entries/flow \
  -H "Authorization: Bearer <ACCESS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"handler": "wyoming"}'
# → flow_id を取得後、host と port を送信
```

**Hermes Agent Integration の再追加**（handler: `hermes_agent`）:

```bash
curl -X POST http://localhost:8123/api/config/config_entries/flow \
  -H "Authorization: Bearer <ACCESS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"handler": "hermes_agent"}'
# → flow_id を取得後、url と api_key を送信
curl -X POST http://localhost:8123/api/config/config_entries/flow/<FLOW_ID> \
  -H "Authorization: Bearer <ACCESS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"url": "http://localhost:8642", "api_key": "<HERMES_API_KEY>"}'
```

または Settings → Integrations → Add Integration → "Hermes Agent" から手動追加してください。
