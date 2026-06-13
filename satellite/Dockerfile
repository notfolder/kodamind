FROM python:3.11-slim-bookworm

# ALSA ツール + PulseAudio クライアント + ALSA pulse プラグイン
RUN apt-get update && apt-get install -y --no-install-recommends \
    alsa-utils \
    libasound2-plugins \
    pulseaudio-utils \
    && rm -rf /var/lib/apt/lists/*

# ALSA のデフォルトデバイスを PulseAudio にルーティング
# PULSE_SERVER 環境変数で PulseAudio サーバーアドレスを指定
RUN printf 'pcm.!default pulse\nctl.!default pulse\n' > /etc/asound.conf

RUN pip install --no-cache-dir wyoming-satellite

# Patch _send_run_pipeline: add restart_on_end=True so HA auto-restarts
# the pipeline after TTS without waiting for another RunSatellite.
COPY satellite/patch_satellite.py /tmp/patch_satellite.py
RUN python3 /tmp/patch_satellite.py

EXPOSE 10700
