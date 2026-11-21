# syntax=docker/dockerfile:1.7
ARG NODE_IMAGE=node:26.13.0-bookworm-slim@sha256:bc0a2afd3b74ce12222fc8bab99271e66257f021078f5f4a5d687a77d280c1d9
ARG RUST_BUILD_IMAGE=rust:1.96.0-slim-bookworm@sha256:4732ca96fd086cb9be682050c3f0176288eebaac2b80aa2bcefccfaf198e1950
ARG RUST_RUNTIME_IMAGE=ubuntu:24.04@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289
FROM ${NODE_IMAGE} AS web
WORKDIR /build/web
COPY web/package.json web/package-lock.json ./
# Optional registry mirror; package-lock integrity hashes still verify every tarball.
ARG NPM_REGISTRY=
RUN npm ci --ignore-scripts --no-audit --no-fund ${NPM_REGISTRY:+--registry=$NPM_REGISTRY}
COPY web/ ./
COPY fixtures/ /build/fixtures/
RUN npm run build
COPY web/licenses/ /licenses/
RUN node -e 'if (require("./node_modules/react-remove-scroll-bar/package.json").version !== "2.3.8") process.exit(1)'
RUN set -eu; npm ls --omit=dev --all --parseable > /tmp/runtime-dependencies; \
    while IFS= read -r dependency; do \
      case "$dependency" in /build/web/node_modules/*) ;; *) continue ;; esac; \
      relative="${dependency#/build/web/node_modules/}"; mkdir -p "/licenses/$relative"; \
      cd "$dependency"; \
      find . -type f \( -iname 'license*' -o -iname 'licence*' -o -iname 'notice*' -o -iname 'copying*' \) \
        -exec cp --parents --target-directory="/licenses/$relative" -- {} +; \
    done < /tmp/runtime-dependencies

FROM ${RUST_RUNTIME_IMAGE} AS verification-tools
# Optional Ubuntu mirror for this install only; the original sources are restored afterwards.
ARG APT_MIRROR=
RUN src=/etc/apt/sources.list.d/ubuntu.sources && cp "$src" /tmp/ubuntu.sources \
    && if [ -n "$APT_MIRROR" ]; then sed -i "s|http://archive.ubuntu.com/ubuntu|$APT_MIRROR|g; s|http://security.ubuntu.com/ubuntu|$APT_MIRROR|g" "$src"; fi \
    && (apt-get -o APT::Update::Error-Mode=any -o Acquire::https::Timeout=15 update && apt-get install -y --no-install-recommends libsqlite3-dev libzstd1 python3 openssl \
        || { cp /tmp/ubuntu.sources "$src"; rm -rf /var/lib/apt/lists/*; apt-get -o APT::Update::Error-Mode=any update && apt-get install -y --no-install-recommends libsqlite3-dev libzstd1 python3 openssl; }) \
    && rm -rf /var/lib/apt/lists/* && mv /tmp/ubuntu.sources "$src"
WORKDIR /build

FROM ${RUST_BUILD_IMAGE} AS backend-rust
WORKDIR /build
COPY rust/ rust/
ARG TARGETPLATFORM
ARG BUILD_JOBS=2
# Git archives preserve source timestamps that can predate cached Cargo build artifacts.
# When this source layer changes, refresh local inputs so Cargo recompiles the workspace crates.
RUN --mount=type=cache,id=codexone-cargo-1.96-registry,sharing=locked,target=/usr/local/cargo/registry \
    --mount=type=cache,id=codexone-rust-1.96-amd64-release,sharing=locked,target=/build/target \
    set -eu; test "$TARGETPLATFORM" = linux/amd64; \
    find rust -type f -exec touch {} +; \
    cargo vendor --locked --versioned-dirs --manifest-path rust/gateway/Cargo.toml /vendor > /tmp/vendor.toml; \
    cargo --config /tmp/vendor.toml build --locked --offline --release --jobs "$BUILD_JOBS" \
      --manifest-path rust/gateway/Cargo.toml --target-dir /build/target --bin codexone; \
    mkdir -p /output/licenses/rust; \
    strip --strip-debug -o /output/codexone /build/target/release/codexone; \
    cd /vendor; \
    find . -type f \( -iname 'license*' -o -iname 'licence*' -o -iname 'notice*' -o -iname 'copying*' \
      -o -iname 'copyright*' -o -iname 'unlicense*' \) \
      -exec cp --parents --target-directory=/output/licenses/rust -- {} +; \
    rm -rf /vendor /tmp/vendor.toml

FROM backend-rust AS rust-probe
RUN apt-get -o APT::Update::Error-Mode=any update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
COPY scripts/export_rust_probe.py scripts/export_rust_probe.py
# Export only the test harness selected by Cargo, never a glob of stale binaries.
RUN --mount=type=cache,id=codexone-cargo-1.96-registry,sharing=locked,target=/usr/local/cargo/registry \
    --mount=type=cache,id=codexone-rust-1.96-amd64-release,sharing=locked,target=/build/target \
    set -eu; \
    cargo vendor --locked --versioned-dirs --manifest-path rust/gateway/Cargo.toml /vendor > /tmp/vendor.toml; \
    cargo --config /tmp/vendor.toml test --locked --offline --release --jobs "$BUILD_JOBS" \
      --manifest-path rust/gateway/Cargo.toml --target-dir /build/target --bin codexone \
      --no-run --message-format=json > /tmp/probe-build.json; \
    python3 scripts/export_rust_probe.py /output/RustGatewayProbe < /tmp/probe-build.json; \
    rm -rf /vendor /tmp/vendor.toml /tmp/probe-build.json

FROM scratch AS verification-export
COPY --from=backend-rust /output/codexone /
COPY --from=rust-probe /output/RustGatewayProbe /

FROM ${RUST_RUNTIME_IMAGE} AS runtime-files
# Optional Ubuntu mirror for this install only; the original sources are restored afterwards.
ARG APT_MIRROR=
RUN src=/etc/apt/sources.list.d/ubuntu.sources && cp "$src" /tmp/ubuntu.sources \
    && if [ -n "$APT_MIRROR" ]; then sed -i "s|http://archive.ubuntu.com/ubuntu|$APT_MIRROR|g; s|http://security.ubuntu.com/ubuntu|$APT_MIRROR|g" "$src"; fi \
    && (export DEBIAN_FRONTEND=noninteractive; packages='libsqlite3-0 sqlite3 curl ca-certificates tzdata'; \
        apt-get -o APT::Update::Error-Mode=any -o Acquire::https::Timeout=15 update && apt-get install -y --no-install-recommends $packages \
        || { cp /tmp/ubuntu.sources "$src"; rm -rf /var/lib/apt/lists/*; apt-get -o APT::Update::Error-Mode=any update && apt-get install -y --no-install-recommends $packages; }) \
    && rm -rf /var/lib/apt/lists/* && mv /tmp/ubuntu.sources "$src" \
    && groupadd --gid 10001 codexone && useradd --uid 10001 --gid 10001 --no-create-home codexone \
    && mkdir -p /var/lib/codexone /run/codexone /opt/codexone/web \
    && chown 10001:10001 /var/lib/codexone && chmod 700 /var/lib/codexone
COPY deploy/assemble-runtime-root.sh /assemble-runtime-root.sh
RUN --mount=type=bind,from=backend-rust,source=/output/codexone,target=/codexone \
    sh /assemble-runtime-root.sh /codexone

FROM scratch AS runtime
COPY --from=runtime-files /runtime-root/ /
SHELL ["/bin/sh", "-c"]
ARG SOURCE_REVISION
ARG VERSION=0.0.0-dev
LABEL org.opencontainers.image.title="CodexOne" \
      org.opencontainers.image.source="https://github.com/ximatai/codexone" \
      org.opencontainers.image.description="Personal self-hosted gateway for subscription accounts and device keys" \
      org.opencontainers.image.version=${VERSION} \
      org.opencontainers.image.revision=${SOURCE_REVISION} \
      org.opencontainers.image.licenses="MIT" \
      net.ximatai.codexone.backend="rust"
COPY --from=backend-rust /output/codexone /usr/local/bin/codexone
RUN case "${SOURCE_REVISION}" in *[!0-9a-f]*|'') exit 1;; esac \
    && test "${#SOURCE_REVISION}" = 40 \
    && case "${VERSION}" in *[!A-Za-z0-9._-]*|'') exit 1;; esac \
    && schema_version="$(/usr/local/bin/codexone --schema-version)" \
    && printf '{"revision":"%s","version":"%s","schemaVersion":%s}\n' \
      "$SOURCE_REVISION" "$VERSION" "$schema_version" > /opt/release.json
COPY --from=web /build/web/dist/ /opt/codexone/web/
COPY LICENSE /opt/codexone/LICENSE
COPY --from=backend-rust /output/licenses/ /opt/codexone/licenses/
COPY --from=web /licenses/ /opt/codexone/licenses/npm/
# Bound glibc arena growth and return large request allocations on multi-core hosts.
ENV MALLOC_ARENA_MAX=1 \
    MALLOC_MMAP_THRESHOLD_=131072 \
    MALLOC_TRIM_THRESHOLD_=16777216
ENV CODEXONE_DATA_DIRECTORY=/var/lib/codexone \
    CODEXONE_WEB_DIRECTORY=/opt/codexone/web
USER 10001:10001
WORKDIR /var/lib/codexone
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD curl --silent --fail --max-time 2 http://127.0.0.1:${CODEXONE_ADMIN_PORT:-18081}/health/live >/dev/null || exit 1
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/codexone"]
