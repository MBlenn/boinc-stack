# Built by docker_wrapper on the volunteer's host. The slot directory is mounted at /app.
# nvidia-smi and the driver libraries are injected by the NVIDIA container toolkit (--gpus all).
FROM docker.io/library/debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends procps \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
CMD ["sh", "./main.sh"]
