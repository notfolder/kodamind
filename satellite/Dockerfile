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

EXPOSE 10700
