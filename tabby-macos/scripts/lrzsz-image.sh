#!/bin/sh
# Builds tabbymac-lrzsz:1, a small Debian image with lrzsz (sz/rz). The ZMODEM interop tests
# use it when present (ZModemInteropTests), and the M11 walk runs `sz`/`rz` in it from a local
# tab (`docker run --rm -it tabbymac-lrzsz:1 bash`). Needs network once.
set -eu
docker build -t tabbymac-lrzsz:1 - <<'DOCKERFILE'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends lrzsz \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE
