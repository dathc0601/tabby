# syntax=docker/dockerfile:1
#
# tabby-sync-server image. The server depends on ../tabby-macos (TabbySyncProtocol), so the
# build context is the repository root:
#
#   docker build -f tabby-sync-server/Dockerfile -t tabby-sync-server .
#
# Dockerfile.dockerignore (next to this file) keeps the context to the two Swift packages.

# ---- Build -------------------------------------------------------------------------------
FROM swift:6.2-noble AS build
WORKDIR /src

# Manifests first so dependency resolution is cached across source changes. Loading the
# tabby-macos manifest needs its target directories, so its sources come along.
COPY tabby-macos/Package.swift tabby-macos/Package.resolved tabby-macos/
COPY tabby-macos/Sources tabby-macos/Sources
COPY tabby-macos/Tests tabby-macos/Tests
COPY tabby-sync-server/Package.swift tabby-sync-server/Package.resolved tabby-sync-server/
RUN cd tabby-sync-server && swift package resolve

# The manifest declares the test target, so its directory has to exist as well.
COPY tabby-sync-server/Sources tabby-sync-server/Sources
COPY tabby-sync-server/Tests tabby-sync-server/Tests
RUN cd tabby-sync-server \
    && swift build -c release --static-swift-stdlib --product tabby-sync-server \
    && mkdir -p /staging \
    && cp "$(swift build -c release --show-bin-path)/tabby-sync-server" /staging/ \
    && cp /usr/libexec/swift/linux/swift-backtrace-static /staging/

# ---- Run ---------------------------------------------------------------------------------
FROM ubuntu:noble

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update -q \
    && apt-get install -q -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system --user-group --create-home --home-dir /app tabbysync \
    && mkdir -p /app/data \
    && chown tabbysync:tabbysync /app/data
WORKDIR /app
COPY --from=build --chown=tabbysync:tabbysync /staging /app

USER tabbysync:tabbysync
ENV PORT=8080 \
    HOSTNAME=0.0.0.0 \
    SQLITE_PATH=/app/data/sync.sqlite \
    SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static
EXPOSE 8080
VOLUME ["/app/data"]
ENTRYPOINT ["./tabby-sync-server"]
