FROM python:3.11-slim

RUN pip install --no-cache-dir "wyoming>=1.5" aiohttp

COPY wyoming-voicevox/wyoming_voicevox.py /app/wyoming_voicevox.py

ENTRYPOINT ["python3", "/app/wyoming_voicevox.py"]
