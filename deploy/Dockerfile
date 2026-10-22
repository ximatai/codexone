# syntax=docker/dockerfile:1.7
ARG SWIFT_VERSION=6.4.1
ARG NODE_VERSION=22.23.0
FROM node:${NODE_VERSION}-bookworm-slim AS web
WORKDIR /build/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY web/ ./
RUN npm run build

FROM swift:${SWIFT_VERSION}-noble AS backend
ARG BUILD_JOBS=2
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Package.swift Package.resolved ./
COPY Sources/ Sources/
COPY Tests/ Tests/
RUN --mount=type=cache,id=codexone-swift64-amd64-release,sharing=locked,target=/build/.build \
    swift build --force-resolved-versions --build-system native -c release --product codexone -j ${BUILD_JOBS} \
      -Xswiftc -driver-batch-size-limit -Xswiftc 16 \
    && mkdir /output && cp .build/release/codexone /output/codexone

FROM swift:${SWIFT_VERSION}-noble-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
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
    && printf '{"revision":"%s","version":"%s"}\n' "$SOURCE_REVISION" "$VERSION" > /opt/release.json
COPY --from=backend /output/codexone /usr/local/bin/codexone
COPY --from=web /build/web/dist/ /opt/codexone/web/
COPY LICENSE /opt/codexone/LICENSE
ENV CODEXONE_DATA_DIRECTORY=/var/lib/codexone \
    CODEXONE_WEB_DIRECTORY=/opt/codexone/web
USER 10001:10001
WORKDIR /var/lib/codexone
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD curl --silent --fail --max-time 2 http://127.0.0.1:${CODEXONE_ADMIN_PORT:-18081}/health/live >/dev/null || exit 1
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/codexone"]
