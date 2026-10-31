# syntax=docker/dockerfile:1.7
ARG SWIFT_BUILD_IMAGE=swift:6.4.1-noble@sha256:19cbe56bdaec1918f7cf5fdeba42b9bd55bdd8a6149c9990d0e0e3a89a127d63
ARG SWIFT_RUNTIME_IMAGE=swift:6.4.1-noble-slim@sha256:46c3f2b7b5f9ad083a941af264fec95b3dcd66e41885d6458606316c62e0d5c8
ARG NODE_IMAGE=node:22.23.0-bookworm-slim@sha256:d9f850096136edbc402debdd8729579a288aac64574ada0ff4db26b6ae58b0b2
# Optional pinned dependency mirrors: --build-context swiftpm-mirrors=<dir of OWNER/REPO.git>.
# Empty by default; Package.resolved revisions still select the exact sources.
FROM scratch AS swiftpm-mirrors

FROM ${NODE_IMAGE} AS web
WORKDIR /build/web
COPY web/package.json web/package-lock.json ./
# Optional registry mirror; package-lock integrity hashes still verify every tarball.
ARG NPM_REGISTRY=
RUN npm ci --ignore-scripts --no-audit --no-fund ${NPM_REGISTRY:+--registry=$NPM_REGISTRY}
COPY web/ ./
RUN npm run build
COPY web/licenses/ /licenses/
RUN node -e 'if (require("./node_modules/react-remove-scroll-bar/package.json").version !== "2.3.8") process.exit(1)'
RUN set -eu; npm ls --omit=dev --all --parseable > /tmp/runtime-dependencies; \
    while IFS= read -r dependency; do \
      case "$dependency" in /build/web/node_modules/*) ;; *) continue ;; esac; \
      relative="${dependency#/build/web/node_modules/}"; mkdir -p "/licenses/$relative"; \
      cd "$dependency"; \
      find . -type f \( -iname 'license*' -o -iname 'notice*' -o -iname 'copying*' \) \
        -exec cp --parents --target-directory="/licenses/$relative" -- {} +; \
    done < /tmp/runtime-dependencies

FROM ${SWIFT_BUILD_IMAGE} AS backend
# Optional Ubuntu mirror for this install only; the original sources are restored afterwards.
ARG APT_MIRROR=
RUN src=/etc/apt/sources.list.d/ubuntu.sources && cp "$src" /tmp/ubuntu.sources \
    && if [ -n "$APT_MIRROR" ]; then sed -i "s|http://archive.ubuntu.com/ubuntu|$APT_MIRROR|g; s|http://security.ubuntu.com/ubuntu|$APT_MIRROR|g" "$src"; fi \
    && apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev python3 openssl \
    && rm -rf /var/lib/apt/lists/* && mv /tmp/ubuntu.sources "$src"
WORKDIR /build
COPY Package.swift Package.resolved ./
COPY Sources/ Sources/
COPY Tests/ Tests/
ARG BUILD_JOBS=1
ARG SWIFT_BATCH_LIMIT=1
RUN --mount=type=cache,id=codexone-swift64-amd64-release,sharing=locked,target=/build/.build \
    --mount=type=bind,from=swiftpm-mirrors,target=/mirrors \
    if [ -n "$(ls -A /mirrors)" ]; then export GIT_CONFIG_COUNT=2 \
      GIT_CONFIG_KEY_0=url.file:///mirrors/.insteadOf GIT_CONFIG_VALUE_0=https://github.com/ \
      GIT_CONFIG_KEY_1=safe.directory GIT_CONFIG_VALUE_1='*'; fi \
    && swift build --force-resolved-versions --build-system native -c release --product codexone -j ${BUILD_JOBS} \
      -Xswiftc -driver-batch-size-limit -Xswiftc ${SWIFT_BATCH_LIMIT} \
    && mkdir /output && cp .build/release/codexone /output/codexone \
    && strip --strip-debug /output/codexone
RUN --mount=type=cache,id=codexone-swift64-amd64-release,sharing=locked,target=/build/.build \
    mkdir /output/licenses && cd .build/checkouts \
    && find . -type f \( -iname 'license*' -o -iname 'notice*' -o -iname 'copying*' \) \
       -exec cp --parents --target-directory=/output/licenses -- {} +

FROM backend AS verification
# Test-only fixture executable; it is never copied into the runtime image.
RUN --mount=type=cache,id=codexone-swift64-amd64-release,sharing=locked,target=/build/.build \
    --mount=type=bind,from=swiftpm-mirrors,target=/mirrors \
    if [ -n "$(ls -A /mirrors)" ]; then export GIT_CONFIG_COUNT=2 \
      GIT_CONFIG_KEY_0=url.file:///mirrors/.insteadOf GIT_CONFIG_VALUE_0=https://github.com/ \
      GIT_CONFIG_KEY_1=safe.directory GIT_CONFIG_VALUE_1='*'; fi \
    && swift build --force-resolved-versions --build-system native -c release --product ExecutionProbe -j ${BUILD_JOBS} \
      -Xswiftc -driver-batch-size-limit -Xswiftc ${SWIFT_BATCH_LIMIT} \
    && cp .build/release/ExecutionProbe /output/ExecutionProbe
COPY scripts/ /build/scripts/
RUN --network=none python3 scripts/verify_protocol.py --binary /output/codexone \
    && python3 scripts/verify_websocket.py --binary /output/codexone \
    && python3 scripts/verify_lite.py --binary /output/codexone \
    && python3 scripts/verify_upstream_proxy.py --binary /output/codexone \
    && python3 scripts/verify_upstream_events.py --binary /output/codexone \
    && python3 scripts/verify_codex_shapes.py --binary /output/codexone \
    && python3 scripts/verify_text_contract.py --binary /output/codexone \
    && python3 scripts/verify_request_parameters.py --binary /output/codexone \
    && python3 scripts/verify_turn_diagnostics.py --binary /output/codexone \
    && python3 scripts/verify_trial_provider.py --binary /output/codexone \
    && python3 scripts/verify_images.py --binary /output/codexone \
    && python3 scripts/verify_migration_readiness.py --binary /output/codexone \
    && python3 scripts/verify_control.py --binary /output/codexone
RUN --network=none python3 scripts/verify_key_maintenance.py --binary /output/codexone \
    && python3 scripts/verify_snapshot_restore.py --binary /output/codexone \
    && python3 scripts/verify_storage_pressure.py --binary /output/codexone \
    && python3 scripts/verify_migration_cutback.py --binary /output/codexone

FROM ${SWIFT_RUNTIME_IMAGE} AS runtime
# Optional Ubuntu mirror for this install only; the original sources are restored afterwards.
ARG APT_MIRROR=
RUN src=/etc/apt/sources.list.d/ubuntu.sources && cp "$src" /tmp/ubuntu.sources \
    && if [ -n "$APT_MIRROR" ]; then sed -i "s|http://archive.ubuntu.com/ubuntu|$APT_MIRROR|g; s|http://security.ubuntu.com/ubuntu|$APT_MIRROR|g" "$src"; fi \
    && apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 sqlite3 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* && mv /tmp/ubuntu.sources "$src" \
    && groupadd --gid 10001 codexone && useradd --uid 10001 --gid 10001 --no-create-home codexone \
    && mkdir -p /var/lib/codexone /run/codexone /opt/codexone/web \
    && chown 10001:10001 /var/lib/codexone && chmod 700 /var/lib/codexone
ARG SOURCE_REVISION
ARG VERSION=0.0.0-dev
LABEL org.opencontainers.image.title="CodexOne" \
      org.opencontainers.image.version=${VERSION} \
      org.opencontainers.image.revision=${SOURCE_REVISION} \
      org.opencontainers.image.licenses="MIT"
RUN case "${SOURCE_REVISION}" in *[!0-9a-f]*|'') exit 1;; esac \
    && test "${#SOURCE_REVISION}" = 40 \
    && case "${VERSION}" in *[!A-Za-z0-9._-]*|'') exit 1;; esac \
    && printf '{"revision":"%s","version":"%s","schemaVersion":8}\n' "$SOURCE_REVISION" "$VERSION" > /opt/release.json
COPY --from=backend /output/codexone /usr/local/bin/codexone
COPY --from=web /build/web/dist/ /opt/codexone/web/
COPY LICENSE /opt/codexone/LICENSE
COPY --from=backend /output/licenses/ /opt/codexone/licenses/swift/
COPY --from=web /licenses/ /opt/codexone/licenses/npm/
ENV CODEXONE_DATA_DIRECTORY=/var/lib/codexone \
    CODEXONE_WEB_DIRECTORY=/opt/codexone/web
USER 10001:10001
WORKDIR /var/lib/codexone
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD curl --silent --fail --max-time 2 http://127.0.0.1:${CODEXONE_ADMIN_PORT:-18081}/health/live >/dev/null || exit 1
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/codexone"]
