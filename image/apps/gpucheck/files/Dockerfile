# Built by docker_wrapper on the volunteer's host. The slot directory is mounted at /app.
# No RUN steps: they fail under the BOINC client service (see app-base/Containerfile).
# nvidia-smi and the driver libraries are injected by the NVIDIA container toolkit (--gpus all).
FROM ghcr.io/mblenn/boinc-app-base:trixie
WORKDIR /app
CMD ["sh", "./main.sh"]
