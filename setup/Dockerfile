FROM python:3.12-slim
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends curl jq netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*
